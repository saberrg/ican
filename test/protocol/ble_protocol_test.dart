import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/protocol/ble_protocol.dart';

void main() {
  group('TelemetryPacket.fromBytes', () {
    test('decodes flags, vitals, battery, and little-endian yaw', () {
      final data = Uint8List(6);
      final byteData = ByteData.sublistView(data);
      data[0] = 0x03;
      data[1] = 72;
      data[2] = 88;
      byteData.setInt16(3, -1234, Endian.little);
      data[5] = 0x7f;

      final packet = TelemetryPacket.fromBytes(data);

      expect(packet.fallDetected, isTrue);
      expect(packet.pulseValid, isTrue);
      expect(packet.pulseBpm, 72);
      expect(packet.batteryPercent, 88);
      expect(packet.yawAngleTenths, -1234);
    });

    test('throws for packets shorter than 6 bytes', () {
      for (var length = 0; length < 6; length += 1) {
        expect(
          () => TelemetryPacket.fromBytes(Uint8List(length)),
          throwsArgumentError,
          reason: 'length $length should be rejected',
        );
      }
    });
  });

  group('GpsPacket.fromBytes', () {
    test('decodes little-endian float fields and fix metadata', () {
      final data = Uint8List(19);
      final byteData = ByteData.sublistView(data);
      byteData.setFloat32(0, 41.8781, Endian.little);
      byteData.setFloat32(4, -87.6298, Endian.little);
      byteData.setFloat32(8, 181.5, Endian.little);
      byteData.setFloat32(12, 3.25, Endian.little);
      data[16] = 9;
      data[17] = 2;
      data[18] = 1;

      final packet = GpsPacket.fromBytes(data);

      expect(packet.latitude, closeTo(41.8781, 0.0001));
      expect(packet.longitude, closeTo(-87.6298, 0.0001));
      expect(packet.altitudeM, closeTo(181.5, 0.001));
      expect(packet.speedKnots, closeTo(3.25, 0.001));
      expect(packet.satellites, 9);
      expect(packet.fixQuality, 2);
      expect(packet.fixValid, isTrue);
    });

    test('decodes zero fix flag as invalid', () {
      final data = Uint8List(19);

      final packet = GpsPacket.fromBytes(data);

      expect(packet.fixValid, isFalse);
    });

    test('throws for packets shorter than 19 bytes', () {
      for (var length = 0; length < 19; length += 1) {
        expect(
          () => GpsPacket.fromBytes(Uint8List(length)),
          throwsArgumentError,
          reason: 'length $length should be rejected',
        );
      }
    });
  });

  group('ImagePacketHeader.fromBytes', () {
    test('decodes little-endian sequence number', () {
      final header = ImagePacketHeader.fromBytes(
        Uint8List.fromList([0x34, 0x12, 0xff, 0xd8]),
      );

      expect(header.sequenceNumber, 0x1234);
    });

    test('throws for packets shorter than the header size', () {
      for (var length = 0; length < ImagePacketHeader.headerSize; length += 1) {
        expect(
          () => ImagePacketHeader.fromBytes(Uint8List(length)),
          throwsArgumentError,
          reason: 'length $length should be rejected',
        );
      }
    });
  });

  group('EyeCommands', () {
    test('exposes firmware command strings', () {
      expect(EyeCommands.capture, 'CAPTURE');
      expect(EyeCommands.liveStart(1500), 'LIVE_START:1500');
      expect(EyeCommands.liveStop, 'LIVE_STOP');
      expect(EyeCommands.profile(2), 'PROFILE:2');
      expect(EyeCommands.status, 'STATUS');
      expect(EyeProfileIndex.fast, 0);
      expect(EyeProfileIndex.balanced, 1);
      expect(EyeProfileIndex.quality, 2);
      expect(EyeProfileIndex.max, 3);
      expect(EyeEvents.buttonDouble, 'BUTTON:DOUBLE');
      expect(EyeEvents.captureStart, 'CAPTURE:START');
      expect(EyeEvents.sizePrefix, 'SIZE:');
      expect(EyeEvents.crcPrefix, 'CRC:');
      expect(EyeEvents.endPrefix, 'END:');
      expect(EyeEvents.statusPrefix, 'STATUS:');
      expect(EyeEvents.errorPrefix, 'ERR:');
      expect(EyeEvents.cameraCaptureFailed, 'CAMERA_CAPTURE_FAILED');
    });
  });
}
