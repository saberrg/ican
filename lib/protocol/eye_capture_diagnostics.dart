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
    this.ackCommand,
    this.nackCommand,
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

  factory EyeImageAssemblyEvent.ack(String command) {
    return EyeImageAssemblyEvent._(ackCommand: command, progress: true);
  }

  factory EyeImageAssemblyEvent.nack(String command) {
    return EyeImageAssemblyEvent._(nackCommand: command, progress: true);
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
  final String? ackCommand;
  final String? nackCommand;
  final bool captureStarted;
  final bool sizeArrived;
  final bool progress;
}

class EyeImageTransferAssembler {
  final Map<int, Uint8List> _chunks = {};

  bool _captureStarted = false;
  bool _captureCommandSent = false;
  bool _sizeArrived = false;
  bool _endArrived = false;
  bool _frameEmitted = false;
  int? _activeFrameId;
  int _expectedImageSize = 0;
  int? _expectedChunks;
  int _missedChunks = 0;
  int _duplicateChunks = 0;
  int _nackRounds = 0;
  bool _allowChunkReplacement = false;
  String? _expectedCrc;

  bool get hasActiveTransfer =>
      _captureCommandSent ||
      _captureStarted ||
      _sizeArrived ||
      _chunks.isNotEmpty;

  EyeTransferTimeoutStage get currentTimeoutStage {
    if (!_captureStarted && !_sizeArrived) {
      return EyeTransferTimeoutStage.awaitingCaptureStart;
    }
    if (!_sizeArrived) return EyeTransferTimeoutStage.awaitingSize;
    if (_chunks.isEmpty) return EyeTransferTimeoutStage.awaitingImageData;
    return EyeTransferTimeoutStage.awaitingEnd;
  }

  void beginCaptureCommand() {
    reset();
    _captureCommandSent = true;
  }

  void reset() {
    _chunks.clear();
    _captureStarted = false;
    _captureCommandSent = false;
    _sizeArrived = false;
    _endArrived = false;
    _frameEmitted = false;
    _activeFrameId = null;
    _expectedImageSize = 0;
    _expectedChunks = null;
    _missedChunks = 0;
    _duplicateChunks = 0;
    _nackRounds = 0;
    _allowChunkReplacement = false;
    _expectedCrc = null;
  }

  EyeImageAssemblyEvent? handleControlMessage(String rawMessage) {
    final message = rawMessage.trim();

    if (message == EyeEvents.captureStart) {
      _captureStarted = true;
      return EyeImageAssemblyEvent.captureStarted();
    }

    if (message.startsWith(EyeEvents.framePrefix)) {
      final frame = _parseFrameMessage(message);
      if (frame == null) return null;
      _beginProtocolV2Frame(frame);
      return _tryCompleteFrame() ?? EyeImageAssemblyEvent.sizeArrived();
    }

    if (message.startsWith(EyeEvents.sizePrefix)) {
      final newSize =
          int.tryParse(message.substring(EyeEvents.sizePrefix.length)) ?? 0;
      if (_sizeArrived &&
          _chunks.isNotEmpty &&
          newSize == _expectedImageSize &&
          !_frameEmitted) {
        return null;
      }
      _beginSizedFrame(newSize);
      return _tryCompleteFrame() ?? EyeImageAssemblyEvent.sizeArrived();
    }

    if (message.startsWith(EyeEvents.crcPrefix)) {
      if (!hasActiveTransfer) return null;
      _expectedCrc = _normalizeCrc(
        message.substring(EyeEvents.crcPrefix.length),
      );
      return _tryCompleteFrame();
    }

    if (message.startsWith(EyeEvents.endPrefix)) {
      if (!hasActiveTransfer) return null;
      _endArrived = true;
      final parsed = _parseEndMessage(message);
      if (parsed.frameId != null && !_isCurrentFrame(parsed.frameId)) {
        return null;
      }
      if (parsed.chunkCount != null) {
        _expectedChunks = parsed.chunkCount;
      }
      return _tryCompleteFrame() ?? _buildNackEventIfPossible();
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

    final isProtocolV2 =
        _activeFrameId != null && data.length > ImagePacketHeader.v2HeaderSize;
    final header = isProtocolV2
        ? ImagePacketHeader.v2FromBytes(data)
        : ImagePacketHeader.fromBytes(data);
    if (header.frameId != null && !_isCurrentFrame(header.frameId)) {
      return null;
    }

    final headerSize = header.frameId == null
        ? ImagePacketHeader.headerSize
        : ImagePacketHeader.v2HeaderSize;
    final payload = Uint8List.fromList(data.sublist(headerSize));

    if (_chunks.containsKey(header.sequenceNumber) && !_allowChunkReplacement) {
      _duplicateChunks++;
      return null;
    }

    _chunks[header.sequenceNumber] = payload;
    _updateMissedChunkCount();

    return _tryCompleteFrame() ?? EyeImageAssemblyEvent.progress();
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

  EyeImageAssemblyEvent handleTimeoutEvent({int maxNackRounds = 3}) {
    final nackEvent = _buildNackEventIfPossible(maxRounds: maxNackRounds);
    if (nackEvent != null) return nackEvent;
    return EyeImageAssemblyEvent.failure(handleTimeout());
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
    if (!_sizeArrived && _chunks.isNotEmpty && !_frameEmitted) {
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

  void _beginProtocolV2Frame(_FrameMessage frame) {
    final hadCaptureStart = _captureStarted;
    final hadCaptureCommand = _captureCommandSent;
    reset();
    _captureStarted = hadCaptureStart;
    _captureCommandSent = hadCaptureCommand;
    _sizeArrived = true;
    _activeFrameId = frame.frameId;
    _expectedImageSize = frame.bytes;
    _expectedCrc = _normalizeCrc(frame.crcHex);
    _expectedChunks = frame.chunks;
  }

  EyeImageAssemblyEvent? _tryCompleteFrame() {
    if (_frameEmitted) return null;
    if (!_sizeArrived || _expectedImageSize <= 0) return null;
    if (_expectedChunks != null && _chunks.length < _expectedChunks!) {
      return null;
    }
    if (_expectedCrc == null) {
      return null;
    }

    final bytes = _orderedBytes();
    if (bytes.length < _expectedImageSize) {
      return null;
    }
    if (bytes.length > _expectedImageSize) {
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg,
      );
      reset();
      return EyeImageAssemblyEvent.failure(diagnostic);
    }

    final jpegMagicValid =
        bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
    final jpegEndValid =
        bytes.length >= 2 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9;

    if (!jpegMagicValid || !jpegEndValid) {
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.corruptOrIncompleteJpeg,
        jpegMagicValid: jpegMagicValid,
        jpegEndValid: jpegEndValid,
      );
      reset();
      return EyeImageAssemblyEvent.failure(diagnostic);
    }

    final actualCrc = crc32Hex(bytes);
    if (actualCrc != _expectedCrc) {
      final nack = _buildNackEventIfPossible(forceAllChunks: true);
      if (nack != null) return nack;
      final diagnostic = _buildDiagnostic(
        EyeCaptureDiagnosticCode.crcMismatch,
        jpegMagicValid: jpegMagicValid,
        jpegEndValid: jpegEndValid,
        actualCrc: actualCrc,
      );
      reset();
      return EyeImageAssemblyEvent.failure(diagnostic);
    }

    _frameEmitted = true;
    final frameId = _activeFrameId;
    final image = Uint8List.fromList(bytes);
    reset();
    if (frameId != null) {
      return EyeImageAssemblyEvent._(
        image: image,
        ackCommand: EyeCommands.ackFrame(frameId),
      );
    }
    return EyeImageAssemblyEvent.image(image);
  }

  EyeImageAssemblyEvent? _buildNackEventIfPossible({
    int maxRounds = 3,
    bool forceAllChunks = false,
  }) {
    final frameId = _activeFrameId;
    final expectedChunks = _expectedChunks;
    if (frameId == null || expectedChunks == null || expectedChunks <= 0) {
      return null;
    }
    if (_nackRounds >= maxRounds) return null;

    final ranges = forceAllChunks
        ? _rangesForAllChunks(expectedChunks)
        : _missingRanges(expectedChunks);
    if (ranges.isEmpty) return null;

    _nackRounds++;
    if (forceAllChunks) {
      _allowChunkReplacement = true;
    }
    _updateMissedChunkCount();
    return EyeImageAssemblyEvent.nack(EyeCommands.nackFrame(frameId, ranges));
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
    final bytes = _orderedBytes();
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
      receivedBytes: bytes.length,
      uniqueChunks: _chunks.length,
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

  bool _isCurrentFrame(int? frameId) {
    return frameId == null ||
        _activeFrameId == null ||
        frameId == _activeFrameId;
  }

  Uint8List _orderedBytes() {
    if (_chunks.isEmpty) return Uint8List(0);
    final keys = _chunks.keys.toList()..sort();
    final buffer = BytesBuilder(copy: false);
    for (final key in keys) {
      buffer.add(_chunks[key]!);
    }
    return buffer.takeBytes();
  }

  void _updateMissedChunkCount() {
    final expectedChunks = _expectedChunks;
    if (expectedChunks != null) {
      _missedChunks = _missingSequences(expectedChunks).length;
      return;
    }
    if (_chunks.isEmpty) {
      _missedChunks = 0;
      return;
    }
    final keys = _chunks.keys.toList()..sort();
    var gaps = 0;
    for (var i = 1; i < keys.length; i++) {
      final delta = keys[i] - keys[i - 1];
      if (delta > 1) gaps += delta - 1;
    }
    _missedChunks = gaps;
  }

  List<int> _missingSequences(int expectedChunks) {
    final missing = <int>[];
    for (var seq = 0; seq < expectedChunks; seq++) {
      if (!_chunks.containsKey(seq)) missing.add(seq);
    }
    return missing;
  }

  String _missingRanges(int expectedChunks) {
    return _rangeString(_missingSequences(expectedChunks));
  }

  String _rangesForAllChunks(int expectedChunks) {
    return expectedChunks <= 0
        ? ''
        : expectedChunks == 1
        ? '0'
        : '0-${expectedChunks - 1}';
  }

  static String _rangeString(List<int> values) {
    if (values.isEmpty) return '';
    final ranges = <String>[];
    var start = values.first;
    var previous = start;
    for (final value in values.skip(1)) {
      if (value == previous + 1) {
        previous = value;
        continue;
      }
      ranges.add(start == previous ? '$start' : '$start-$previous');
      start = value;
      previous = value;
    }
    ranges.add(start == previous ? '$start' : '$start-$previous');
    return ranges.join(',');
  }

  static _FrameMessage? _parseFrameMessage(String message) {
    final parts = message.split(':');
    if (parts.length < 5) return null;
    final frameId = int.tryParse(parts[1]);
    final bytes = int.tryParse(parts[2]);
    final chunks = int.tryParse(parts[4]);
    final crc = parts[3];
    if (frameId == null || bytes == null || chunks == null || crc.isEmpty) {
      return null;
    }
    return _FrameMessage(
      frameId: frameId,
      bytes: bytes,
      crcHex: crc,
      chunks: chunks,
    );
  }

  static _EndMessage _parseEndMessage(String message) {
    final parts = message.split(':');
    if (parts.length >= 3) {
      return _EndMessage(
        frameId: int.tryParse(parts[1]),
        chunkCount: int.tryParse(parts[2]),
      );
    }
    return _EndMessage(
      frameId: null,
      chunkCount: parts.length >= 2 ? int.tryParse(parts[1]) : null,
    );
  }
}

class _FrameMessage {
  const _FrameMessage({
    required this.frameId,
    required this.bytes,
    required this.crcHex,
    required this.chunks,
  });

  final int frameId;
  final int bytes;
  final String crcHex;
  final int chunks;
}

class _EndMessage {
  const _EndMessage({required this.frameId, required this.chunkCount});

  final int? frameId;
  final int? chunkCount;
}
