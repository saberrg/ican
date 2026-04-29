import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/protocol/ble_protocol.dart';
import 'package:ican/protocol/eye_capture_diagnostics.dart';

void main() {
  group('EyeImageTransferAssembler', () {
    test('assembles SIZE, chunks, CRC, and END into one complete image', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();
      final images = <Uint8List>[];

      expect(
        assembler.handleControlMessage(EyeEvents.captureStart)?.captureStarted,
        isTrue,
      );
      expect(
        assembler.handleControlMessage('SIZE:${jpeg.length}')?.sizeArrived,
        isTrue,
      );
      assembler.handleControlMessage(
        'CRC:${EyeImageTransferAssembler.crc32Hex(jpeg)}',
      );
      assembler.handleImageChunk(_chunk(0, jpeg.sublist(0, 3)));
      assembler.handleImageChunk(_chunk(1, jpeg.sublist(3)));
      final result = assembler.handleControlMessage('END:2');
      if (result?.image != null) images.add(result!.image!);

      expect(images, hasLength(1));
      expect(images.single, jpeg);
    });

    test('slow but progressing transfer does not fail before timeout', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleControlMessage('SIZE:${jpeg.length}');
      final progress = assembler.handleImageChunk(
        _chunk(0, jpeg.sublist(0, 2)),
      );

      expect(progress?.progress, isTrue);
      expect(progress?.diagnostic, isNull);
      expect(
        assembler.currentTimeoutStage,
        EyeTransferTimeoutStage.awaitingEnd,
      );
    });

    test('chunks that arrive before SIZE are preserved', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleImageChunk(_chunk(0, jpeg.sublist(0, 3)));
      assembler.handleControlMessage('SIZE:${jpeg.length}');
      assembler.handleControlMessage(
        'CRC:${EyeImageTransferAssembler.crc32Hex(jpeg)}',
      );
      assembler.handleImageChunk(_chunk(1, jpeg.sublist(3)));
      final result = assembler.handleControlMessage('END:2');

      expect(result?.image, jpeg);
    });

    test('duplicate END after a completed transfer is ignored', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleControlMessage('SIZE:${jpeg.length}');
      assembler.handleImageChunk(_chunk(0, jpeg));
      final firstEnd = assembler.handleControlMessage('END:1');
      final duplicateEnd = assembler.handleControlMessage('END:1');

      expect(firstEnd?.image, jpeg);
      expect(duplicateEnd, isNull);
    });

    test('no SIZE produces Eye E01', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();

      assembler.handleControlMessage(EyeEvents.captureStart);
      final diagnostic = assembler.handleTimeout();

      expect(diagnostic.stableCode, 'Eye E01');
      expect(diagnostic.sizeArrived, isFalse);
      expect(diagnostic.spokenMessage, contains('no capture start or SIZE'));
    });

    test('partial transfer stall produces Eye E02 with counts', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleControlMessage('SIZE:${jpeg.length}');
      assembler.handleImageChunk(_chunk(0, jpeg.sublist(0, 2)));
      final diagnostic = assembler.handleTimeout();

      expect(diagnostic.stableCode, 'Eye E02');
      expect(diagnostic.receivedBytes, 2);
      expect(diagnostic.expectedBytes, jpeg.length);
      expect(diagnostic.uniqueChunks, 1);
      expect(diagnostic.spokenMessage, contains('2/${jpeg.length} bytes'));
    });

    test('invalid JPEG produces Eye E03', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleControlMessage('SIZE:${bytes.length}');
      assembler.handleImageChunk(_chunk(0, bytes));
      final result = assembler.handleControlMessage('END:1');

      expect(result?.diagnostic?.stableCode, 'Eye E03');
      expect(result?.diagnostic?.jpegMagicValid, isFalse);
    });

    test('CRC mismatch produces Eye E04', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();
      final jpeg = _jpegBytes();

      assembler.handleControlMessage(EyeEvents.captureStart);
      assembler.handleControlMessage('SIZE:${jpeg.length}');
      assembler.handleControlMessage('CRC:00000000');
      assembler.handleImageChunk(_chunk(0, jpeg));
      final result = assembler.handleControlMessage('END:1');

      expect(result?.diagnostic?.stableCode, 'Eye E04');
      expect(result?.diagnostic?.expectedCrc, '00000000');
      expect(result?.diagnostic?.actualCrc, isNot('00000000'));
    });

    test('firmware camera error produces Eye E05', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();

      final result = assembler.handleControlMessage(
        'ERR:${EyeEvents.cameraCaptureFailed}',
      );

      expect(result?.diagnostic?.stableCode, 'Eye E05');
      expect(result?.diagnostic?.spokenMessage, contains('camera capture'));
    });

    test('firmware stream abort reports sent and expected byte counts', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();

      final result = assembler.handleControlMessage(
        'ERR:${EyeEvents.streamAborted}:3:120:240',
      );

      final diagnostic = result?.diagnostic;
      expect(diagnostic?.stableCode, 'Eye E02');
      expect(diagnostic?.firmwareError, EyeEvents.streamAborted);
      expect(diagnostic?.sentChunks, 3);
      expect(diagnostic?.sentBytes, 120);
      expect(diagnostic?.expectedBytes, 240);
    });

    test('firmware chunk notify failure reports failed sequence', () {
      final assembler = EyeImageTransferAssembler()..beginCaptureCommand();

      final result = assembler.handleControlMessage(
        'ERR:${EyeEvents.chunkNotifyFailed}:7',
      );

      final diagnostic = result?.diagnostic;
      expect(diagnostic?.stableCode, 'Eye E02');
      expect(diagnostic?.firmwareError, EyeEvents.chunkNotifyFailed);
      expect(diagnostic?.failedSequence, 7);
    });
  });
}

Uint8List _jpegBytes() {
  return Uint8List.fromList([0xff, 0xd8, 0x11, 0x22, 0x33, 0xff, 0xd9]);
}

Uint8List _chunk(int sequence, List<int> payload) {
  final data = Uint8List(ImagePacketHeader.headerSize + payload.length);
  final byteData = ByteData.sublistView(data);
  byteData.setUint16(0, sequence, Endian.little);
  data.setRange(ImagePacketHeader.headerSize, data.length, payload);
  return data;
}
