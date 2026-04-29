/// ============================================================================
/// UdpFrameService — UDP JPEG frame receiver for iCan Eye live streaming.
/// ============================================================================
/// When the Eye is provisioned onto WiFi, it forwards JPEG frames over UDP
/// instead of BLE. Each JPEG is chopped into chunks of up to ~1400 bytes
/// prefixed by an 8-byte little-endian header:
///
///   uint16 frame_id      (bytes 0–1)
///   uint16 chunk_index   (bytes 2–3)
///   uint16 chunk_count   (bytes 4–5)
///   uint16 payload_len   (bytes 6–7)
///
/// Chunks are reassembled in-memory by frame_id. When all chunks arrive, the
/// complete JPEG is emitted on [frameStream].
/// ============================================================================
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class _FramePending {
  _FramePending(this.chunkCount)
    : chunks = List<Uint8List?>.filled(chunkCount, null),
      firstSeen = DateTime.now();

  final int chunkCount;
  final List<Uint8List?> chunks;
  int receivedCount = 0;
  final DateTime firstSeen;
}

class UdpFrameService {
  UdpFrameService._();

  static final UdpFrameService instance = UdpFrameService._();

  static const int _headerBytes = 8;
  static const int _maxChunkCount = 2000; // sanity cap (~2.8MB frame)
  static const Duration _staleAfter = Duration(seconds: 2);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  final Map<int, _FramePending> _pending = {};
  int _highestSeenFrameId = -1;
  bool _isActive = false;
  bool _loggedFirstFrame = false;
  DateTime? _lastFrameAt;

  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get frameStream => _frameController.stream;
  bool get isActive => _isActive;
  DateTime? get lastFrameAt => _lastFrameAt;

  Future<void> start({int port = 8080}) async {
    if (_isActive) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      _socket = socket;
      _socketSub = socket.listen(_onSocketEvent, onError: _onSocketError);
      _isActive = true;
      _loggedFirstFrame = false;
      debugPrint('[UdpFrameService] listening on UDP :$port');
    } catch (e) {
      debugPrint('[UdpFrameService] bind failed on :$port — $e');
      _isActive = false;
      _socket = null;
      _socketSub = null;
    }
  }

  Future<void> stop() async {
    if (!_isActive && _socket == null && _socketSub == null) return;
    try {
      await _socketSub?.cancel();
    } catch (_) {}
    _socketSub = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _pending.clear();
    _highestSeenFrameId = -1;
    _isActive = false;
    debugPrint('[UdpFrameService] stopped');
  }

  void _onSocketError(Object error, [StackTrace? stack]) {
    debugPrint('[UdpFrameService] socket error: $error');
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    _handleDatagram(datagram.data);
  }

  void _handleDatagram(Uint8List data) {
    if (data.length < _headerBytes) return;
    final bd = ByteData.view(data.buffer, data.offsetInBytes);
    final frameId = bd.getUint16(0, Endian.little);
    final chunkIndex = bd.getUint16(2, Endian.little);
    final chunkCount = bd.getUint16(4, Endian.little);
    final payloadLen = bd.getUint16(6, Endian.little);

    if (chunkCount == 0 || chunkCount > _maxChunkCount) return;
    if (chunkIndex >= chunkCount) return;
    if (data.length < _headerBytes + payloadLen) return;

    // Drop very stale frames relative to what we've already started.
    if (_highestSeenFrameId >= 0 && frameId < _highestSeenFrameId - 2) {
      _pending.remove(frameId);
      return;
    }
    if (frameId > _highestSeenFrameId) {
      _highestSeenFrameId = frameId;
    }

    _reapStale();

    var pending = _pending[frameId];
    if (pending == null) {
      pending = _FramePending(chunkCount);
      _pending[frameId] = pending;
    } else if (pending.chunkCount != chunkCount) {
      // Corrupt / mismatched; rebuild
      pending = _FramePending(chunkCount);
      _pending[frameId] = pending;
    }

    if (pending.chunks[chunkIndex] != null) return; // duplicate

    final payload = Uint8List.sublistView(
      data,
      _headerBytes,
      _headerBytes + payloadLen,
    );
    pending.chunks[chunkIndex] = Uint8List.fromList(payload);
    pending.receivedCount += 1;

    if (pending.receivedCount == pending.chunkCount) {
      final builder = BytesBuilder(copy: false);
      for (final c in pending.chunks) {
        if (c != null) builder.add(c);
      }
      _pending.remove(frameId);
      final jpeg = builder.toBytes();
      _lastFrameAt = DateTime.now();
      if (!_loggedFirstFrame) {
        _loggedFirstFrame = true;
        debugPrint(
          '[UdpFrameService] first frame complete: id=$frameId '
          'bytes=${jpeg.length} chunks=$chunkCount',
        );
      }
      _frameController.add(jpeg);
    }
  }

  void _reapStale() {
    if (_pending.isEmpty) return;
    final now = DateTime.now();
    final expired = <int>[];
    for (final entry in _pending.entries) {
      if (now.difference(entry.value.firstSeen) > _staleAfter) {
        expired.add(entry.key);
      } else if (_highestSeenFrameId >= 0 &&
          entry.key < _highestSeenFrameId - 2) {
        expired.add(entry.key);
      }
    }
    for (final id in expired) {
      _pending.remove(id);
    }
  }
}
