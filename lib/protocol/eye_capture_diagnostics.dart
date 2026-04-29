import 'dart:typed_data';

import 'ble_protocol.dart';

enum EyeCaptureDiagnosticCode {
  noCaptureStartOrSize,
  streamStalled,
  corruptOrIncompleteJpeg,
  crcMismatch,
  cameraCaptureFailed,
}

extension EyeCaptureDiagnosticCodeLabel on EyeCaptureDiagnosticCode {
  String get stableCode {
    switch (this) {
      case EyeCaptureDiagnosticCode.noCaptureStartOrSize:
        return 'Eye E01';
      case EyeCaptureDiagnosticCode.streamStalled:
        return 'Eye E02';
      case EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg:
        return 'Eye E03';
      case EyeCaptureDiagnosticCode.crcMismatch:
        return 'Eye E04';
      case EyeCaptureDiagnosticCode.cameraCaptureFailed:
        return 'Eye E05';
    }
  }
}

enum EyeTransferTimeoutStage {
  awaitingCaptureStart('awaiting capture start'),
  awaitingSize('awaiting SIZE'),
  awaitingImageData('awaiting image data'),
  awaitingEnd('awaiting END');

  const EyeTransferTimeoutStage(this.label);

  final String label;
}

class EyeCaptureDiagnostic {
  const EyeCaptureDiagnostic({
    required this.code,
    required this.captureStarted,
    required this.sizeArrived,
    required this.expectedBytes,
    required this.receivedBytes,
    required this.uniqueChunks,
    required this.duplicateChunks,
    required this.endArrived,
    required this.jpegMagicValid,
    required this.jpegEndValid,
    this.missedChunks = 0,
    this.timeoutStage,
    this.expectedCrc,
    this.actualCrc,
    this.firmwareError,
    this.sentChunks,
    this.sentBytes,
    this.failedSequence,
    this.firmwareAbortReason,
  });

  final EyeCaptureDiagnosticCode code;
  final bool captureStarted;
  final bool sizeArrived;
  final int expectedBytes;
  final int receivedBytes;
  final int uniqueChunks;
  final int duplicateChunks;
  final int missedChunks;
  final bool endArrived;
  final bool jpegMagicValid;
  final bool jpegEndValid;
  final EyeTransferTimeoutStage? timeoutStage;
  final String? expectedCrc;
  final String? actualCrc;
  final String? firmwareError;
  final int? sentChunks;
  final int? sentBytes;
  final int? failedSequence;

  /// Optional trailing reason on `ERR:STREAM_ABORTED:...:reason`. Currently
  /// only `"user"` is defined (sent when the app issued an ABORT command).
  final String? firmwareAbortReason;

  String get stableCode => code.stableCode;

  String get spokenMessage {
    final expected = expectedBytes > 0 ? expectedBytes.toString() : 'unknown';
    final stage = timeoutStage?.label ?? 'unknown';
    switch (code) {
      case EyeCaptureDiagnosticCode.noCaptureStartOrSize:
        return '$stableCode: no capture start or SIZE from Eye. '
            'Stage: $stage; received $receivedBytes/$expected bytes across '
            '$uniqueChunks chunks.';
      case EyeCaptureDiagnosticCode.streamStalled:
        if (firmwareError == 'STREAM_ABORTED') {
          if (firmwareAbortReason == EyeEvents.abortReasonUser) {
            return '$stableCode: capture cancelled by the app at '
                '${sentBytes ?? receivedBytes}/$expected bytes after '
                '${sentChunks ?? uniqueChunks} chunks.';
          }
          return '$stableCode: firmware aborted image stream at '
              '${sentBytes ?? receivedBytes}/$expected bytes after '
              '${sentChunks ?? uniqueChunks} chunks.';
        }
        if (firmwareError == 'CHUNK_NOTIFY_FAILED') {
          return '$stableCode: firmware could not notify image chunk '
              '${failedSequence ?? -1}. Received $receivedBytes/$expected '
              'bytes across $uniqueChunks chunks.';
        }
        return '$stableCode: image stream stalled at $receivedBytes/$expected '
            'bytes across $uniqueChunks chunks, with $duplicateChunks '
            'duplicates. Stage: $stage.';
      case EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg:
        return '$stableCode: corrupt or incomplete JPEG. Received '
            '$receivedBytes/$expected bytes across $uniqueChunks chunks. '
            'JPEG start valid: $jpegMagicValid, end valid: $jpegEndValid.';
      case EyeCaptureDiagnosticCode.crcMismatch:
        return '$stableCode: CRC mismatch. Expected ${expectedCrc ?? 'unknown'}, '
            'got ${actualCrc ?? 'unknown'}. Received $receivedBytes/$expected '
            'bytes.';
      case EyeCaptureDiagnosticCode.cameraCaptureFailed:
        return '$stableCode: firmware reported camera capture failure.';
    }
  }

  /// Multi-line copy-to-clipboard representation used by the Vision
  /// Diagnostic screen. Kept stable so support can ask the user to paste
  /// and diff against known-good output. Lines are ordered roughly from
  /// "what went wrong" to "all the raw counters" so the most important
  /// information stays on the first screen of any chat window.
  String toCopyString() {
    final lines = <String>[
      '[$stableCode] ${code.name}',
      'spoken: $spokenMessage',
      'timeoutStage: ${timeoutStage?.label ?? 'none'}',
      'captureStarted: $captureStarted',
      'sizeArrived: $sizeArrived',
      'endArrived: $endArrived',
      'expectedBytes: $expectedBytes',
      'receivedBytes: $receivedBytes',
      'uniqueChunks: $uniqueChunks',
      'duplicateChunks: $duplicateChunks',
      'missedChunks: $missedChunks',
      'jpegMagicValid: $jpegMagicValid',
      'jpegEndValid: $jpegEndValid',
    ];
    if (expectedCrc != null) lines.add('expectedCrc: $expectedCrc');
    if (actualCrc != null) lines.add('actualCrc: $actualCrc');
    if (firmwareError != null) lines.add('firmwareError: $firmwareError');
    if (sentChunks != null) lines.add('sentChunks: $sentChunks');
    if (sentBytes != null) lines.add('sentBytes: $sentBytes');
    if (failedSequence != null) lines.add('failedSequence: $failedSequence');
    if (firmwareAbortReason != null) {
      lines.add('firmwareAbortReason: $firmwareAbortReason');
    }
    return lines.join('\n');
  }

  @override
  String toString() => spokenMessage;
}

class EyeImageAssemblyEvent {
  const EyeImageAssemblyEvent._({
    this.image,
    this.diagnostic,
    this.captureStarted = false,
    this.sizeArrived = false,
    this.progress = false,
  });

  factory EyeImageAssemblyEvent.image(Uint8List image) {
    return EyeImageAssemblyEvent._(image: image);
  }

  factory EyeImageAssemblyEvent.failure(EyeCaptureDiagnostic diagnostic) {
    return EyeImageAssemblyEvent._(diagnostic: diagnostic);
  }

  factory EyeImageAssemblyEvent.captureStarted() {
    return const EyeImageAssemblyEvent._(captureStarted: true, progress: true);
  }

  factory EyeImageAssemblyEvent.sizeArrived() {
    return const EyeImageAssemblyEvent._(sizeArrived: true, progress: true);
  }

  factory EyeImageAssemblyEvent.progress() {
    return const EyeImageAssemblyEvent._(progress: true);
  }

  final Uint8List? image;
  final EyeCaptureDiagnostic? diagnostic;
  final bool captureStarted;
  final bool sizeArrived;
  final bool progress;
}

class EyeImageTransferAssembler {
  final List<int> _imageBuffer = [];
  final Set<int> _seenSequenceNumbers = {};

  bool _captureStarted = false;
  bool _captureCommandSent = false;
  bool _sizeArrived = false;
  bool _endArrived = false;
  bool _frameEmitted = false;
  int _expectedImageSize = 0;
  int _lastSequenceNumber = -1;
  int _missedChunks = 0;
  int _duplicateChunks = 0;
  String? _expectedCrc;

  bool get hasActiveTransfer =>
      _captureCommandSent ||
      _captureStarted ||
      _sizeArrived ||
      _imageBuffer.isNotEmpty;

  EyeTransferTimeoutStage get currentTimeoutStage {
    if (!_captureStarted && !_sizeArrived) {
      return EyeTransferTimeoutStage.awaitingCaptureStart;
    }
    if (!_sizeArrived) return EyeTransferTimeoutStage.awaitingSize;
    if (_imageBuffer.isEmpty) return EyeTransferTimeoutStage.awaitingImageData;
    return EyeTransferTimeoutStage.awaitingEnd;
  }

  void beginCaptureCommand() {
    reset();
    _captureCommandSent = true;
  }

  void reset() {
    _imageBuffer.clear();
    _seenSequenceNumbers.clear();
    _captureStarted = false;
    _captureCommandSent = false;
    _sizeArrived = false;
    _endArrived = false;
    _frameEmitted = false;
    _expectedImageSize = 0;
    _lastSequenceNumber = -1;
    _missedChunks = 0;
    _duplicateChunks = 0;
    _expectedCrc = null;
  }

  EyeImageAssemblyEvent? handleControlMessage(String rawMessage) {
    final message = rawMessage.trim();

    if (message == EyeEvents.captureStart) {
      _captureStarted = true;
      return EyeImageAssemblyEvent.captureStarted();
    }

    if (message.startsWith(EyeEvents.sizePrefix)) {
      final newSize =
          int.tryParse(message.substring(EyeEvents.sizePrefix.length)) ?? 0;
      if (_sizeArrived &&
          _imageBuffer.isNotEmpty &&
          newSize == _expectedImageSize &&
          !_frameEmitted) {
        return null;
      }
      _beginSizedFrame(newSize);
      return EyeImageAssemblyEvent.sizeArrived();
    }

    if (message.startsWith(EyeEvents.crcPrefix)) {
      if (!hasActiveTransfer) return null;
      _expectedCrc = _normalizeCrc(
        message.substring(EyeEvents.crcPrefix.length),
      );
      return null;
    }

    if (message.startsWith(EyeEvents.endPrefix)) {
      if (!hasActiveTransfer) return null;
      _endArrived = true;
      return _completeFrame();
    }

    if (message.startsWith(EyeEvents.errorPrefix)) {
      final error = message.substring(EyeEvents.errorPrefix.length);
      return EyeImageAssemblyEvent.failure(_diagnosticForFirmwareError(error));
    }

    return null;
  }

  EyeImageAssemblyEvent? handleImageChunk(Uint8List data) {
    if (data.length <= ImagePacketHeader.headerSize || _frameEmitted) {
      return null;
    }

    final header = ImagePacketHeader.fromBytes(data);
    final payload = data.sublist(ImagePacketHeader.headerSize);

    if (_seenSequenceNumbers.contains(header.sequenceNumber)) {
      _duplicateChunks++;
      return null;
    }

    _seenSequenceNumbers.add(header.sequenceNumber);
    if (_lastSequenceNumber != -1 &&
        header.sequenceNumber != _lastSequenceNumber + 1) {
      _missedChunks++;
    }
    _lastSequenceNumber = header.sequenceNumber;
    _imageBuffer.addAll(payload);

    return EyeImageAssemblyEvent.progress();
  }

  EyeCaptureDiagnostic handleTimeout() {
    final code = !_sizeArrived
        ? EyeCaptureDiagnosticCode.noCaptureStartOrSize
        : EyeCaptureDiagnosticCode.streamStalled;
    final diagnostic = _buildDiagnostic(
      code,
      timeoutStage: currentTimeoutStage,
    );
    reset();
    return diagnostic;
  }

  static String crc32Hex(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xedb88320;
        } else {
          crc >>= 1;
        }
      }
    }
    crc = (crc ^ 0xffffffff) & 0xffffffff;
    return crc.toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  void _beginSizedFrame(int size) {
    final hadCaptureStart = _captureStarted;
    final hadCaptureCommand = _captureCommandSent;
    if (!_sizeArrived && _imageBuffer.isNotEmpty && !_frameEmitted) {
      _captureStarted = hadCaptureStart;
      _captureCommandSent = hadCaptureCommand;
      _sizeArrived = true;
      _expectedImageSize = size;
      return;
    }
    reset();
    _captureStarted = hadCaptureStart;
    _captureCommandSent = hadCaptureCommand;
    _sizeArrived = true;
    _expectedImageSize = size;
  }

  EyeImageAssemblyEvent? _completeFrame() {
    if (_frameEmitted) return null;

    final bytes = Uint8List.fromList(_imageBuffer);
    final jpegMagicValid =
        bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
    final jpegEndValid =
        bytes.length >= 2 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9;

    if (!_sizeArrived ||
        _expectedImageSize <= 0 ||
        bytes.length != _expectedImageSize ||
        !jpegMagicValid ||
        !jpegEndValid) {
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg,
        jpegMagicValid: jpegMagicValid,
        jpegEndValid: jpegEndValid,
      );
      reset();
      return EyeImageAssemblyEvent.failure(diagnostic);
    }

    final expectedCrc = _expectedCrc;
    if (expectedCrc != null) {
      final actualCrc = crc32Hex(bytes);
      if (actualCrc != expectedCrc) {
        final diagnostic = _buildDiagnostic(
          EyeCaptureDiagnosticCode.crcMismatch,
          jpegMagicValid: jpegMagicValid,
          jpegEndValid: jpegEndValid,
          actualCrc: actualCrc,
        );
        reset();
        return EyeImageAssemblyEvent.failure(diagnostic);
      }
    }

    _frameEmitted = true;
    final image = Uint8List.fromList(bytes);
    reset();
    return EyeImageAssemblyEvent.image(image);
  }

  EyeCaptureDiagnostic _diagnosticForFirmwareError(String error) {
    if (error == EyeEvents.cameraCaptureFailed) {
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.cameraCaptureFailed,
        firmwareError: error,
      );
      reset();
      return diagnostic;
    }

    if (error.startsWith('${EyeEvents.streamAborted}:')) {
      final parts = error.split(':');
      // Wire format: STREAM_ABORTED:{sentChunks}:{sentBytes}:{expectedBytes}[:{reason}]
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.streamStalled,
        firmwareError: EyeEvents.streamAborted,
        sentChunks: parts.length > 1 ? int.tryParse(parts[1]) : null,
        sentBytes: parts.length > 2 ? int.tryParse(parts[2]) : null,
        expectedBytesOverride: parts.length > 3 ? int.tryParse(parts[3]) : null,
        firmwareAbortReason: parts.length > 4 && parts[4].isNotEmpty
            ? parts[4]
            : null,
      );
      reset();
      return diagnostic;
    }

    if (error.startsWith('${EyeEvents.chunkNotifyFailed}:')) {
      final parts = error.split(':');
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.streamStalled,
        firmwareError: EyeEvents.chunkNotifyFailed,
        failedSequence: parts.length > 1 ? int.tryParse(parts[1]) : null,
      );
      reset();
      return diagnostic;
    }

    final diagnostic = _buildDiagnostic(
      EyeCaptureDiagnosticCode.streamStalled,
      firmwareError: error,
      timeoutStage: currentTimeoutStage,
    );
    reset();
    return diagnostic;
  }

  EyeCaptureDiagnostic _buildDiagnostic(
    EyeCaptureDiagnosticCode code, {
    bool? jpegMagicValid,
    bool? jpegEndValid,
    EyeTransferTimeoutStage? timeoutStage,
    String? actualCrc,
    String? firmwareError,
    int? sentChunks,
    int? sentBytes,
    int? failedSequence,
    int? expectedBytesOverride,
    String? firmwareAbortReason,
  }) {
    final bytes = _imageBuffer;
    final computedMagicValid =
        bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
    final computedEndValid =
        bytes.length >= 2 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9;

    return EyeCaptureDiagnostic(
      code: code,
      captureStarted: _captureStarted,
      sizeArrived: _sizeArrived,
      expectedBytes: expectedBytesOverride ?? _expectedImageSize,
      receivedBytes: _imageBuffer.length,
      uniqueChunks: _seenSequenceNumbers.length,
      duplicateChunks: _duplicateChunks,
      missedChunks: _missedChunks,
      endArrived: _endArrived,
      jpegMagicValid: jpegMagicValid ?? computedMagicValid,
      jpegEndValid: jpegEndValid ?? computedEndValid,
      timeoutStage: timeoutStage,
      expectedCrc: _expectedCrc,
      actualCrc: actualCrc,
      firmwareError: firmwareError,
      sentChunks: sentChunks,
      sentBytes: sentBytes,
      failedSequence: failedSequence,
      firmwareAbortReason: firmwareAbortReason,
    );
  }

  static String _normalizeCrc(String value) {
    final trimmed = value.trim().toUpperCase();
    final withoutPrefix = trimmed.startsWith('0X')
        ? trimmed.substring(2)
        : trimmed;
    return withoutPrefix.padLeft(8, '0');
  }
}
