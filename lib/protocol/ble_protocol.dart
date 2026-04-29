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
  static const String gpsDataTx = '10000006-1000-1000-1000-100000000000';

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
    return ObstacleSide.values.firstWhere(
      (s) => s.code == code,
      orElse: () => ObstacleSide.none,
    );
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
// GPS Data Packet Codec (19 bytes, 1 Hz)
// ===========================================================================

class GpsPacket {
  const GpsPacket({
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
    required this.speedKnots,
    required this.satellites,
    required this.fixQuality,
    required this.fixValid,
  });

  /// Decode a 19-byte GPS payload from the Cane.
  factory GpsPacket.fromBytes(Uint8List data) {
    if (data.length < 19) {
      throw ArgumentError('GPS packet must be at least 19 bytes');
    }
    final bd = ByteData.sublistView(data);
    return GpsPacket(
      latitude: bd.getFloat32(0, Endian.little),
      longitude: bd.getFloat32(4, Endian.little),
      altitudeM: bd.getFloat32(8, Endian.little),
      speedKnots: bd.getFloat32(12, Endian.little),
      satellites: data[16],
      fixQuality: data[17],
      fixValid: data[18] != 0,
    );
  }

  final double latitude;
  final double longitude;
  final double altitudeM;
  final double speedKnots;
  final int satellites;
  final int fixQuality;
  final bool fixValid;

  @override
  String toString() =>
      'GPS(fix=$fixValid, lat=$latitude, lon=$longitude, '
      'alt=${altitudeM.toStringAsFixed(1)}m, '
      'speed=${speedKnots.toStringAsFixed(1)}kts, sats=$satellites)';
}

// ===========================================================================
// Eye Commands (App → Eye via eyeCaptureRx)
// ===========================================================================

class EyeCommands {
  EyeCommands._();

  static const String capture = 'CAPTURE';
  static const String abort = 'ABORT';
  static const String liveStop = 'LIVE_STOP';
  static String liveStart(int intervalMs) => 'LIVE_START:$intervalMs';
  static String profile(int index) => 'PROFILE:$index';
  static const String status = 'STATUS';
}

class EyeEvents {
  EyeEvents._();

  static const String buttonDouble = 'BUTTON:DOUBLE';
  static const String captureStart = 'CAPTURE:START';
  static const String profileSetPrefix = 'PROFILE_SET:';
  static const String sizePrefix = 'SIZE:';
  static const String crcPrefix = 'CRC:';
  static const String endPrefix = 'END:';
  static const String statusPrefix = 'STATUS:';
  static const String errorPrefix = 'ERR:';
  static const String liveStarted = 'LIVE_STARTED';
  static const String liveStopped = 'LIVE_STOPPED';
  static const String liveBusy = 'LIVE_BUSY';
  static const String liveIdle = 'LIVE_IDLE';
  static const String cameraCaptureFailed = 'CAMERA_CAPTURE_FAILED';
  static const String streamAborted = 'STREAM_ABORTED';
  static const String chunkNotifyFailed = 'CHUNK_NOTIFY_FAILED';

  /// Firmware appends this reason when aborting due to an ABORT command.
  static const String abortReasonUser = 'user';
}

// ===========================================================================
// Image Stream Packet Codec
// ===========================================================================

class ImagePacketHeader {
  const ImagePacketHeader({required this.sequenceNumber});

  factory ImagePacketHeader.fromBytes(Uint8List data) {
    if (data.length < headerSize) {
      throw ArgumentError('Image header must be at least $headerSize bytes');
    }
    final bd = ByteData.sublistView(data);
    return ImagePacketHeader(sequenceNumber: bd.getUint16(0, Endian.little));
  }

  static const int headerSize = 2;
  static const int maxPayload = 509;

  /// Production firmware clamps each notify to this cap regardless of MTU.
  /// See `firmware_payload_cap` in `protocol/ble_protocol.yaml` and
  /// `EYE_IMAGE_FIRMWARE_PAYLOAD_CAP` in `firmware/shared/include/ble_protocol.h`.
  static const int firmwarePayloadCap = 240;

  final int sequenceNumber;
}
