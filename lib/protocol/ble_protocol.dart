/// ============================================================================
/// iCan BLE Protocol — Dart Constants (mirrors protocol/ble_protocol.yaml)
/// ============================================================================
/// DO NOT edit UUIDs or opcodes here without updating ble_protocol.yaml first.
/// ============================================================================
library;

import 'dart:typed_data';

// ===========================================================================
// BLE Service UUIDs
// ===========================================================================

class BleServices {
  BleServices._();

  static const String caneServiceUuid = '10000001-1000-1000-1000-100000000000';
  static const String eyeServiceUuid = '20000001-2000-2000-2000-200000000000';
}

// ===========================================================================
// BLE Characteristic UUIDs
// ===========================================================================

class BleCharacteristics {
  BleCharacteristics._();

  // ---- Cane ----
  static const String navCommandRx = '10000002-1000-1000-1000-100000000000';
  static const String obstacleAlertTx = '10000003-1000-1000-1000-100000000000';
  static const String imuTelemetryTx = '10000004-1000-1000-1000-100000000000';
  static const String caneStatusTx = '10000005-1000-1000-1000-100000000000';

  // ---- Eye ----
  static const String eyeInstantTextTx = '20000002-2000-2000-2000-200000000000';
  static const String eyeImageStreamTx = '20000003-2000-2000-2000-200000000000';
  static const String eyeCaptureRx = '20000004-2000-2000-2000-200000000000';
}

// ===========================================================================
// Navigation Command Opcodes (App → Cane)
// ===========================================================================

enum NavCommand {
  stop(0x00),
  turnLeft(0x01),
  turnRight(0x02),
  goStraight(0x03),
  uTurn(0x04),
  arrived(0x05),
  recalculate(0x06);

  const NavCommand(this.opcode);
  final int opcode;
}

// ===========================================================================
// Obstacle Side Codes (Cane → App)
// ===========================================================================

enum ObstacleSide {
  none(0x00),
  left(0x01),
  right(0x02),
  head(0x03),
  front(0x04);

  const ObstacleSide(this.code);
  final int code;

  static ObstacleSide fromCode(int code) {
    return ObstacleSide.values.firstWhere((s) => s.code == code, orElse: () => ObstacleSide.none);
  }
}

// ===========================================================================
// Telemetry Packet Codec (6 bytes)
// ===========================================================================

class TelemetryPacket {
  // degrees * 10

  const TelemetryPacket({
    required this.fallDetected,
    required this.pulseValid,
    required this.pulseBpm,
    required this.batteryPercent,
    required this.yawAngleTenths,
  });

  /// Decode a 6-byte telemetry payload from the Cane.
  factory TelemetryPacket.fromBytes(Uint8List data) {
    if (data.length < 6) {
      throw ArgumentError('Telemetry packet must be at least 6 bytes');
    }
    final flags = data[0];
    final byteData = ByteData.sublistView(data);
    return TelemetryPacket(
      fallDetected: (flags & 0x01) != 0,
      pulseValid: (flags & 0x02) != 0,
      pulseBpm: data[1],
      batteryPercent: data[2],
      yawAngleTenths: byteData.getInt16(3, Endian.little),
    );
  }
  final bool fallDetected;
  final bool pulseValid;
  final int pulseBpm;
  final int batteryPercent;
  final int yawAngleTenths;

  /// Encode to 6 bytes (useful for testing / simulation).
  Uint8List toBytes() {
    final data = Uint8List(6);
    final byteData = ByteData.sublistView(data);
    int flags = 0;
    if (fallDetected) flags |= 0x01;
    if (pulseValid) flags |= 0x02;
    data[0] = flags;
    data[1] = pulseBpm;
    data[2] = batteryPercent;
    byteData.setInt16(3, yawAngleTenths, Endian.little);
    data[5] = 0; // reserved
    return data;
  }

  @override
  String toString() =>
      'Telemetry(fall=$fallDetected, pulse=$pulseBpm bpm, '
      'battery=$batteryPercent%, yaw=${yawAngleTenths / 10}°)';
}

// ===========================================================================
// Image Stream Packet Codec
// ===========================================================================

class ImagePacketHeader {
  const ImagePacketHeader({
    required this.sequenceNumber,
    required this.totalChunks,
    required this.checksum,
  });

  factory ImagePacketHeader.fromBytes(Uint8List data) {
    if (data.length < headerSize) {
      throw ArgumentError('Image header must be at least $headerSize bytes');
    }
    final bd = ByteData.sublistView(data);
    return ImagePacketHeader(
      sequenceNumber: bd.getUint16(0, Endian.little),
      totalChunks: bd.getUint16(2, Endian.little),
      checksum: data[4],
    );
  }
  static const int headerSize = 5;
  static const int maxPayload = 235;

  final int sequenceNumber;
  final int totalChunks;
  final int checksum;

  /// Compute XOR checksum over [payload] bytes.
  static int computeChecksum(Uint8List payload) {
    int xor = 0;
    for (final b in payload) {
      xor ^= b;
    }
    return xor & 0xFF;
  }
}
