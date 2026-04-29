import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart' show WinServer;
import '../protocol/ble_protocol.dart';
import '../protocol/eye_capture_diagnostics.dart';
import 'app_log_service.dart';
import 'device_prefs_service.dart';
import 'notification_service.dart';

/// BLE connection status.
enum BleConnectionState { disconnected, scanning, connecting, connected }

enum BleDeviceKind { eye, cane }

enum BleReadinessPhase {
  idle,
  waitingForBluetooth,
  scanning,
  connecting,
  discoveringServices,
  subscribing,
  verifyingCommandPath,
  ready,
  failed,
}

class BleReadinessStatus {
  const BleReadinessStatus({
    required this.deviceKind,
    required this.phase,
    required this.ready,
    this.deviceId,
    this.requiredCharacteristicsReady = false,
    this.commandPathReady = false,
    this.lastError,
    this.lastEvent,
  });

  final BleDeviceKind deviceKind;
  final BleReadinessPhase phase;
  final bool ready;
  final String? deviceId;
  final bool requiredCharacteristicsReady;
  final bool commandPathReady;
  final String? lastError;
  final String? lastEvent;

  BleReadinessStatus copyWith({
    BleReadinessPhase? phase,
    bool? ready,
    String? deviceId,
    bool? requiredCharacteristicsReady,
    bool? commandPathReady,
    String? lastError,
    String? lastEvent,
  }) {
    return BleReadinessStatus(
      deviceKind: deviceKind,
      phase: phase ?? this.phase,
      ready: ready ?? this.ready,
      deviceId: deviceId ?? this.deviceId,
      requiredCharacteristicsReady:
          requiredCharacteristicsReady ?? this.requiredCharacteristicsReady,
      commandPathReady: commandPathReady ?? this.commandPathReady,
      lastError: lastError,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

class BleConnectionEvent {
  const BleConnectionEvent({
    required this.deviceKind,
    required this.phase,
    required this.ready,
    this.deviceId,
    this.message,
  });

  final BleDeviceKind deviceKind;
  final BleReadinessPhase phase;
  final bool ready;
  final String? deviceId;
  final String? message;
}

enum _FlutterScanOwner { eye, cane }

/// Enum for connection error reasons
enum BleConnectionError {
  timeout,
  deviceNotFound,
  connectionFailed,
  servicesNotDiscovered,
  cancelled,
}

/// Extension for readable error messages
extension BleConnectionErrorMessage on BleConnectionError {
  String get message {
    switch (this) {
      case BleConnectionError.timeout:
        return 'Connection timed out';
      case BleConnectionError.deviceNotFound:
        return 'Device not found';
      case BleConnectionError.connectionFailed:
        return 'Connection failed';
      case BleConnectionError.servicesNotDiscovered:
        return 'Could not discover services';
      case BleConnectionError.cancelled:
        return 'Connection cancelled';
    }
  }
}

/// BLE Service — wraps BLE scanning, connection, and data exchange.
///
/// Uses UUIDs and codecs from [BleCharacteristics] and [BleServices].
/// Singleton to allow easy access from UI and background tasks.
class BleService extends ChangeNotifier {
  BleService._internal();
  // --- Singleton Setup ---
  static final BleService instance = BleService._internal();

  // Eye connection state
  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  BleReadinessStatus _eyeReadinessStatus = const BleReadinessStatus(
    deviceKind: BleDeviceKind.eye,
    phase: BleReadinessPhase.idle,
    ready: false,
  );
  BleReadinessStatus get eyeReadinessStatus => _eyeReadinessStatus;

  BluetoothDevice? _connectedDevice;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  // Cane connection state (tracked separately from Eye)
  BleConnectionState _caneState = BleConnectionState.disconnected;
  BleConnectionState get caneState => _caneState;

  BluetoothDevice? _caneDevice;
  StreamSubscription<BluetoothConnectionState>? _caneConnectionSub;
  String? _preferredCaneDeviceId;

  BluetoothCharacteristic? _navRxChar;
  BluetoothCharacteristic? _eyeCaptureRxChar;

  // Stored Eye characteristics so we can safely setNotifyValue(false) on reconnect
  BluetoothCharacteristic? _eyeImageStreamChar;
  BluetoothCharacteristic? _eyeCaptureChar;
  BluetoothCharacteristic? _eyeInstantTextChar;

  // Latest telemetry from the cane
  TelemetryPacket? _lastTelemetry;
  TelemetryPacket? get lastTelemetry => _lastTelemetry;

  // Fall detection edge tracking — only fire notification on rising edge
  bool _prevFallDetected = false;

  // Streams for real-time data
  final _telemetryController = StreamController<TelemetryPacket>.broadcast();
  Stream<TelemetryPacket> get telemetryStream => _telemetryController.stream;

  final _obstacleController = StreamController<ObstacleAlert>.broadcast();
  Stream<ObstacleAlert> get obstacleStream => _obstacleController.stream;

  final _instantTextController = StreamController<String>.broadcast();
  Stream<String> get instantTextStream => _instantTextController.stream;

  final _connectionEventController =
      StreamController<BleConnectionEvent>.broadcast();
  Stream<BleConnectionEvent> get connectionEventStream =>
      _connectionEventController.stream;

  // Image Assembly State
  final _imageController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get imageStream => _imageController.stream;

  final _eyeDiagnosticController =
      StreamController<EyeCaptureDiagnostic>.broadcast();
  Stream<EyeCaptureDiagnostic> get eyeCaptureDiagnosticStream =>
      _eyeDiagnosticController.stream;

  EyeCaptureDiagnostic? _lastEyeCaptureDiagnostic;
  EyeCaptureDiagnostic? get lastEyeCaptureDiagnostic =>
      _lastEyeCaptureDiagnostic;

  final _captureStartedController = StreamController<void>.broadcast();
  Stream<void> get captureStartedStream => _captureStartedController.stream;

  // Button events from Eye (double-press triggers voice commands)
  final _buttonEventController = StreamController<String>.broadcast();
  Stream<String> get buttonEventStream => _buttonEventController.stream;

  // GPS data stream from Cane
  final _gpsController = StreamController<GpsPacket>.broadcast();
  Stream<GpsPacket> get gpsDataStream => _gpsController.stream;
  GpsPacket? _lastGps;
  GpsPacket? get lastGps => _lastGps;
  StreamSubscription<List<int>>? _gpsSub;

  final EyeImageTransferAssembler _imageAssembler = EyeImageTransferAssembler();
  // Legacy counters kept only for low-level debug logging while the structured
  // assembler above owns actual frame validation and emission.
  final List<int> _imageBuffer = [];
  int _expectedImageSize = 0;
  int _lastSequenceNumber = -1;
  int _lostChunks = 0;
  final Set<int> _seenSequenceNumbers = {};
  bool _frameEmitted = false;
  int _frameSessionId = 0;
  String _lastControlMessage = ''; // Dedup control messages
  DateTime? _lastControlMessageTime;
  Timer? _imageTimeoutTimer;
  Timer? _captureResponseRetryTimer;
  int _captureResponseRetryCount = 0;
  Timer? _eyeReconnectTimer;
  Timer? _eyeHeartbeatTimer;
  int _eyeReconnectAttempt = 0;
  int _missedEyeHeartbeats = 0;
  String? _preferredEyeDeviceId;

  static const Duration _imageTransferTimeout = Duration(seconds: 45);
  static const Duration _captureResponseTimeout = Duration(seconds: 3);
  static const Duration _eyeHeartbeatInterval = Duration(seconds: 15);
  static const Duration _eyeReconnectInitialDelay = Duration(seconds: 3);
  static const Duration _eyeReconnectMaxDelay = Duration(seconds: 30);

  bool get _legacyImageAssemblerEnabled => false;

  // Known MAC for the iCan Eye hardware. Used as fallback when no device has
  // been saved yet, and as the auto-connect target on startup.
  static const String fallbackEyeDeviceId = '90:70:69:12:53:be';

  // ---------------------------------------------------------------------------
  // Windows BLE state — Eye (win_ble transport)
  // ---------------------------------------------------------------------------
  bool _winBleInitialized = false;
  String? _connectedWindowsMac;
  StreamSubscription? _winConnectionSub;
  StreamSubscription? _winImageSub;
  StreamSubscription? _winCaptureSub;
  StreamSubscription? _winInstantTextSub;

  // ---------------------------------------------------------------------------
  // Windows BLE state — Cane (win_ble transport)
  // ---------------------------------------------------------------------------
  String? _winCaneMac;
  StreamSubscription? _winCaneConnectionSub;
  StreamSubscription? _winCaneScanSub;
  StreamSubscription? _winCaneGpsSub;
  StreamSubscription? _winCaneObstacleSub;
  StreamSubscription? _winCaneTelemetrySub;

  bool _isBleSupported() {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  // ---------------------------------------------------------------------------
  // Primary Connection Entry Point
  // ---------------------------------------------------------------------------

  /// Connect directly to the iCan Eye by MAC address — no scanning required.
  /// The BLE stack connects as soon as the device is advertising nearby.
  /// Called on app startup and automatically retried on disconnect.
  Future<void> connectToEyeByMac(String mac) async {
    if (!_isBleSupported()) return;
    if (_state == BleConnectionState.connecting ||
        _state == BleConnectionState.connected)
      return;
    _cancelEyeReconnect();
    _preferredEyeDeviceId = mac;
    debugPrint('[BLE] Connect Eye to $mac...');
    _setState(BleConnectionState.connecting);
    if (Platform.isWindows) {
      // Windows WinRT BLE requires a scan to discover devices before connect.
      // Direct connect by MAC does not work (returns "Device not found").
      await _startWinBleScanForEye();
    } else if (Platform.isIOS && _isMacAddress(mac)) {
      // iOS CoreBluetooth never exposes real MAC addresses — it assigns its own
      // per-device UUIDs. A MAC-format ID means we have no saved iOS UUID yet
      // (e.g. first launch). Fall through to a scan so we discover the Eye by
      // its service UUID and name, then save the real iOS UUID for next time.
      debugPrint(
        '[BLE] iOS: MAC-format ID not valid on CoreBluetooth — scanning instead.',
      );
      _setState(BleConnectionState.disconnected);
      await startScan();
    } else {
      try {
        final device = BluetoothDevice.fromId(mac);
        await connectToEye(device);
      } catch (e) {
        debugPrint('[BLE] Direct connect failed: $e');
        _setState(BleConnectionState.disconnected);
        if (Platform.isIOS) {
          _recordBleLog(
            'Eye direct connect failed on iOS; falling back to service scan.',
          );
          await startScan();
        } else {
          _scheduleEyeReconnect('Direct Eye connect failed: ${e.runtimeType}.');
        }
      }
    }
  }

  /// Returns true if [id] looks like a colon-separated MAC address
  /// (e.g. "90:70:69:12:53:be") rather than a CoreBluetooth UUID.
  static bool _isMacAddress(String id) {
    return RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(id);
  }

  StreamSubscription? _winEyeScanSub;

  /// Scan for the iCan Eye using win_ble on Windows, then connect when found.
  Future<void> _startWinBleScanForEye() async {
    try {
      await _ensureWinBleInitialized();
      await _winEyeScanSub?.cancel();

      final targetSvc = BleServices.eyeServiceUuid.toLowerCase();
      final targetMac = (_preferredEyeDeviceId ?? fallbackEyeDeviceId)
          .toLowerCase();

      _winEyeScanSub = WinBle.scanStream.listen((device) {
        final name = device.name.trim();
        final addr = device.address.toLowerCase();
        final svcUuids = device.serviceUuids
            .map(
              (u) => u.toString().toLowerCase().replaceAll(RegExp(r'[{}]'), ''),
            )
            .toList();

        debugPrint('[BLE Eye Win] NEARBY: "$name" [$addr] services:$svcUuids');

        final isEyeByService = svcUuids.contains(targetSvc);
        final isEyeByMac = addr == targetMac;
        final isEyeByName =
            name.toLowerCase().contains('eye') ||
            name.toLowerCase().contains('ican');

        if (isEyeByService || isEyeByMac || isEyeByName) {
          debugPrint(
            '[BLE Eye Win] MATCH: "$name" [$addr] '
            '(service=$isEyeByService mac=$isEyeByMac name=$isEyeByName)',
          );
          WinBle.stopScanning();
          _winEyeScanSub?.cancel();
          _winEyeScanSub = null;
          _connectWindowsBle(addr);
        }
      });

      debugPrint('[BLE Eye Win] WinBle scan started (15s timeout).');
      WinBle.startScanning();

      Future.delayed(const Duration(seconds: 15), () {
        if (_state == BleConnectionState.scanning ||
            _state == BleConnectionState.connecting) {
          WinBle.stopScanning();
          _winEyeScanSub?.cancel();
          _winEyeScanSub = null;
          if (_state != BleConnectionState.connected) {
            _setState(BleConnectionState.disconnected);
            debugPrint('[BLE Eye Win] Scan timed out — Eye not found.');
          }
        }
      });
    } catch (e) {
      debugPrint('[BLE Eye Win] Scan error: $e');
      _setState(BleConnectionState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Windows BLE transport (win_ble)
  // ---------------------------------------------------------------------------

  Future<void> _ensureWinBleInitialized() async {
    if (_winBleInitialized) return;
    await WinBle.initialize(
      serverPath: await WinServer.path(),
      enableLog: false,
    );
    _winBleInitialized = true;
    debugPrint('[BLE] WinBle initialized.');
  }

  Future<void> _connectWindowsBle(String mac) async {
    try {
      await _ensureWinBleInitialized();

      await _winConnectionSub?.cancel();
      _winConnectionSub = WinBle.connectionStreamOf(mac).listen((connected) {
        if (connected) {
          _connectedWindowsMac = mac;
          _updateEyeReadiness(
            BleReadinessPhase.discoveringServices,
            deviceId: mac,
          );
          _discoverWindowsEyeServices(mac);
          DevicePrefsService.instance.saveLastDeviceId(mac);
        } else {
          final wasConnected = _state == BleConnectionState.connected;
          _connectedWindowsMac = null;
          _winImageSub?.cancel();
          _winCaptureSub?.cancel();
          _winInstantTextSub?.cancel();
          _setState(BleConnectionState.disconnected);
          if (wasConnected && _preferredEyeDeviceId != null) {
            _scheduleEyeReconnect(
              'Windows Eye connection stream disconnected.',
            );
          }
        }
      });

      await WinBle.connect(mac);
    } catch (e) {
      debugPrint('[BLE] Windows connect failed: $e');
      await _winConnectionSub?.cancel();
      _setState(BleConnectionState.disconnected);
      _scheduleEyeReconnect('Windows Eye connect failed: ${e.runtimeType}.');
    }
  }

  Future<void> _discoverWindowsEyeServices(String mac) async {
    debugPrint('[BLE] Subscribing to Eye characteristics on Windows...');
    try {
      const svc = BleServices.eyeServiceUuid;

      await _winImageSub?.cancel();
      await _winCaptureSub?.cancel();
      await _winInstantTextSub?.cancel();

      // Image stream
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.eyeImageStreamTx,
      );
      _winImageSub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.eyeImageStreamTx,
          ).listen(
            (data) {
              try {
                final bytes = List<int>.from(data);
                if (bytes.isNotEmpty) {
                  _handleIncomingImageChunk(Uint8List.fromList(bytes));
                }
              } catch (e) {
                debugPrint('[BLE Eye] Image chunk error: $e');
              }
            },
            onError: (e) {
              debugPrint('[BLE Eye] Image stream ERROR: $e');
            },
            onDone: () {
              debugPrint('[BLE Eye] Image stream DONE (closed).');
            },
          );
      debugPrint('[BLE Eye] Subscribed to image stream.');

      // Control / capture (ESP32 notifies SIZE/CRC/END on this characteristic)
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.eyeCaptureRx,
      );
      _winCaptureSub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.eyeCaptureRx,
          ).listen(
            (data) {
              try {
                final bytes = List<int>.from(data);
                if (bytes.isNotEmpty) {
                  _handleEyeControlMessage(String.fromCharCodes(bytes));
                }
              } catch (e) {
                debugPrint('[BLE Eye] Control msg error: $e');
              }
            },
            onError: (e) {
              debugPrint('[BLE Eye] Control stream ERROR: $e');
            },
            onDone: () {
              debugPrint('[BLE Eye] Control stream DONE (closed).');
            },
          );
      debugPrint('[BLE Eye] Subscribed to control/capture.');

      // Instant text
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.eyeInstantTextTx,
      );
      _winInstantTextSub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.eyeInstantTextTx,
          ).listen((data) {
            try {
              final bytes = List<int>.from(data);
              if (bytes.isNotEmpty) {
                _instantTextController.add(String.fromCharCodes(bytes));
              }
            } catch (e) {
              debugPrint('[BLE Eye] Instant text error: $e');
            }
          });
      debugPrint('[BLE Eye] Subscribed to instant text.');

      debugPrint('[BLE] Windows Eye subscriptions active.');
      _setState(BleConnectionState.connected);
      _updateEyeReadiness(
        BleReadinessPhase.verifyingCommandPath,
        deviceId: mac,
        requiredCharacteristicsReady: true,
        commandPathReady: false,
        lastEvent: 'Eye notifications subscribed; verifying STATUS.',
      );
      await requestEyeStatus();
    } catch (e) {
      debugPrint('[BLE] Windows service subscription failed: $e');
      _updateEyeReadiness(
        BleReadinessPhase.failed,
        deviceId: mac,
        lastError: 'Windows Eye subscription failed: $e',
      );
      _setState(BleConnectionState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Windows BLE — Cane (win_ble transport)
  // ---------------------------------------------------------------------------

  Future<void> _startWinBleScanForCane() async {
    try {
      await _ensureWinBleInitialized();
      await _winCaneScanSub?.cancel();
      _winCaneScanSub = null;

      _winCaneScanSub = WinBle.scanStream.listen((device) {
        final name = device.name.trim();
        final addr = device.address;
        final svcUuids = device.serviceUuids
            .map((u) => u.toString().toLowerCase())
            .toList();
        debugPrint('[BLE Cane Win] NEARBY: "$name" [$addr] services:$svcUuids');

        final isCaneName =
            name.toLowerCase().contains('ican') ||
            name.toLowerCase().contains('cane');
        // win_ble wraps UUIDs in curly braces: {xxxxxxxx-...} — strip them
        final isCaneService = svcUuids.any(
          (uuid) =>
              uuid.replaceAll('{', '').replaceAll('}', '') ==
              BleServices.caneServiceUuid.toLowerCase(),
        );

        if (isCaneName || isCaneService) {
          debugPrint('[BLE Cane Win] MATCH: "$name" [$addr]');
          try {
            WinBle.stopScanning();
          } catch (_) {}
          _winCaneScanSub?.cancel();
          _winCaneScanSub = null;
          _connectWindowsCaneBle(addr);
        }
      });

      debugPrint('[BLE Cane Win] WinBle scan started (20s timeout).');
      WinBle.startScanning();

      // Stop after 20 s if nothing found, then retry after 5 s
      Future.delayed(const Duration(seconds: 20), () {
        if (_caneState == BleConnectionState.scanning) {
          try {
            WinBle.stopScanning();
          } catch (_) {}
          _winCaneScanSub?.cancel();
          _winCaneScanSub = null;
          _setCaneState(BleConnectionState.disconnected);
          debugPrint('[BLE Cane Win] Scan timed out — retrying in 5s...');
          Future.delayed(const Duration(seconds: 5), () {
            if (_caneState == BleConnectionState.disconnected) {
              debugPrint('[BLE Cane Win] Retrying scan...');
              startScanForCane();
            }
          });
        }
      });
    } catch (e) {
      debugPrint('[BLE Cane Win] Scan error: $e');
      _setCaneState(BleConnectionState.disconnected);
    }
  }

  Future<void> _connectWindowsCaneBle(String mac) async {
    _setCaneState(BleConnectionState.connecting);
    try {
      await _ensureWinBleInitialized();
      await _winCaneConnectionSub?.cancel();

      _winCaneConnectionSub = WinBle.connectionStreamOf(mac).listen((
        connected,
      ) {
        if (connected) {
          _winCaneMac = mac;
          _preferredCaneDeviceId = mac;
          _setCaneState(BleConnectionState.connected);
          _discoverWindowsCaneServices(mac);
          DevicePrefsService.instance.saveLastCaneDeviceId(mac);
        } else {
          final wasConnected = _caneState == BleConnectionState.connected;
          _winCaneMac = null;
          _winCaneGpsSub?.cancel();
          _winCaneObstacleSub?.cancel();
          _winCaneTelemetrySub?.cancel();
          _setCaneState(BleConnectionState.disconnected);
          if (wasConnected && _preferredCaneDeviceId != null) {
            Future.delayed(const Duration(seconds: 3), () {
              if (_caneState == BleConnectionState.disconnected) {
                connectToCaneByMac(_preferredCaneDeviceId!);
              }
            });
          }
        }
      });

      await WinBle.connect(mac);
    } catch (e) {
      debugPrint('[BLE Cane Win] Connect failed: $e');
      await _winCaneConnectionSub?.cancel();
      _setCaneState(BleConnectionState.disconnected);
    }
  }

  Future<void> _discoverWindowsCaneServices(String mac) async {
    debugPrint('[BLE Cane Win] Subscribing to Cane characteristics...');
    try {
      const svc = BleServices.caneServiceUuid;
      await _winCaneObstacleSub?.cancel();
      await _winCaneTelemetrySub?.cancel();
      await _winCaneGpsSub?.cancel();

      // Obstacle Alert TX
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.obstacleAlertTx,
      );
      _winCaneObstacleSub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.obstacleAlertTx,
          ).listen((data) {
            if (data.isNotEmpty) {
              try {
                // win_ble delivers List<dynamic> — cast to List<int> first
                final alert = ObstacleAlert.fromBytes(
                  Uint8List.fromList(List<int>.from(data)),
                );
                _obstacleController.add(alert);
              } catch (e) {
                debugPrint('[BLE Cane Win] Obstacle parse error: $e');
              }
            }
          });

      // IMU Telemetry TX
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.imuTelemetryTx,
      );
      _winCaneTelemetrySub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.imuTelemetryTx,
          ).listen((data) {
            if (data.isNotEmpty) {
              onTelemetryReceived(Uint8List.fromList(List<int>.from(data)));
            }
          });

      // GPS Data TX
      await WinBle.subscribeToCharacteristic(
        address: mac,
        serviceId: svc,
        characteristicId: BleCharacteristics.gpsDataTx,
      );
      _winCaneGpsSub =
          WinBle.characteristicValueStreamOf(
            address: mac,
            serviceId: svc,
            characteristicId: BleCharacteristics.gpsDataTx,
          ).listen((data) {
            final bytes = List<int>.from(data);
            if (bytes.length >= 19) {
              try {
                final pkt = GpsPacket.fromBytes(Uint8List.fromList(bytes));
                _lastGps = pkt;
                _gpsController.add(pkt);
                notifyListeners();
              } catch (e) {
                debugPrint('[BLE Cane] GPS parse error: $e');
              }
            }
          });

      debugPrint('[BLE Cane Win] Cane subscriptions active.');
    } catch (e) {
      debugPrint('[BLE Cane Win] Service subscription failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Cane Auto-Connect
  // ---------------------------------------------------------------------------

  /// Auto-connect to the iCan Cane on startup.
  /// Uses saved MAC if available; falls back to scanning by service UUID.
  Future<void> autoConnectToCane() async {
    if (!_isBleSupported()) return;
    if (_caneState == BleConnectionState.connecting ||
        _caneState == BleConnectionState.scanning ||
        _caneState == BleConnectionState.connected)
      return;
    final saved = await DevicePrefsService.instance.getLastCaneDeviceId();
    if (saved != null && saved.isNotEmpty) {
      debugPrint('[BLE Cane] Saved MAC found: $saved — connecting directly.');
      connectToCaneByMac(saved);
    } else {
      debugPrint('[BLE Cane] No saved MAC — starting scan.');
      startScanForCane();
    }
  }

  /// Connect directly to the iCan Cane by MAC address — no scanning required.
  Future<void> connectToCaneByMac(String mac) async {
    if (!_isBleSupported()) return;
    if (mac.isEmpty) {
      startScanForCane();
      return;
    }
    if (_caneState == BleConnectionState.connecting ||
        _caneState == BleConnectionState.scanning ||
        _caneState == BleConnectionState.connected)
      return;
    debugPrint('[BLE Cane] Direct connect to $mac...');
    _setCaneState(BleConnectionState.connecting);
    if (Platform.isWindows) {
      await _connectWindowsCaneBle(mac);
    } else {
      try {
        final device = BluetoothDevice.fromId(mac);
        await connectToCane(device);
      } catch (e) {
        debugPrint('[BLE Cane] Direct connect failed: $e');
        // Clear stale MAC — next startup will scan instead of looping
        _preferredCaneDeviceId = null;
        await DevicePrefsService.instance.saveLastCaneDeviceId('');
        _setCaneState(BleConnectionState.disconnected);
      }
    }
  }

  /// Scan for iCan Cane by service UUID or device name and connect.
  StreamSubscription? _caneScanSub;

  Future<void> startScanForCane() async {
    if (!_isBleSupported()) return;
    if (_caneState == BleConnectionState.connecting ||
        _caneState == BleConnectionState.scanning ||
        _caneState == BleConnectionState.connected)
      return;
    debugPrint('[BLE Cane] Starting scan for iCan Cane...');
    _setCaneState(BleConnectionState.scanning);

    if (Platform.isWindows) {
      await _startWinBleScanForCane();
      return;
    }

    try {
      await _beginFlutterScan(_FlutterScanOwner.cane);
      await _caneScanSub?.cancel();
      _caneScanSub = null;
      await Future.delayed(const Duration(milliseconds: 300));

      final targetGuid = Guid(BleServices.caneServiceUuid);

      _caneScanSub = FlutterBluePlus.scanResults.listen((results) {
        if (_caneState != BleConnectionState.scanning) return;

        // Log every discovered device so we can see what's nearby
        for (final r in results) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          final id = r.device.remoteId.str;
          final serviceUuids = r.advertisementData.serviceUuids
              .map((u) => u.toString())
              .toList();
          debugPrint(
            '[BLE Cane] NEARBY: "$name" [$id] RSSI:${r.rssi} services:$serviceUuids',
          );

          final isCaneName =
              name.toLowerCase().contains('ican') ||
              name.toLowerCase().contains('cane');

          bool isCaneService = false;
          try {
            for (final uuid in r.advertisementData.serviceUuids) {
              if (Guid(uuid.toString()) == targetGuid) {
                isCaneService = true;
                break;
              }
            }
          } catch (_) {}

          if (isCaneName || isCaneService) {
            debugPrint(
              '[BLE Cane] MATCH: "$name" [$id] — connecting. '
              'reason: name=$isCaneName service=$isCaneService',
            );
            _caneScanSub?.cancel();
            _caneScanSub = null;
            FlutterBluePlus.stopScan().catchError((_) {});
            connectToCane(r.device);
            return;
          }
        }
      });

      debugPrint('[BLE Cane] FlutterBluePlus.startScan() — timeout 20s');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
      debugPrint('[BLE Cane] Scan finished — no Cane found.');
    } catch (e) {
      debugPrint('[BLE Cane] Scan error: $e');
    }

    await _caneScanSub?.cancel();
    _caneScanSub = null;
    if (_caneState == BleConnectionState.scanning) {
      _setCaneState(BleConnectionState.disconnected);
    }
  }

  void _setCaneState(BleConnectionState newState) {
    _caneState = newState;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Scan & Connect (manual fallback — Eye)
  // ---------------------------------------------------------------------------

  StreamSubscription? _scanSub;
  _FlutterScanOwner? _activeFlutterScanOwner;

  bool _isEyeCandidate(String name, String id) {
    if (name.isEmpty) {
      // If name is empty, we must rely on Service UUID (checked elsewhere)
      // or a direct MAC/ID match.
      return id.toUpperCase() == fallbackEyeDeviceId.toUpperCase() ||
          id.toUpperCase() == _preferredEyeDeviceId?.toUpperCase();
    }

    final normalizedName = name.toLowerCase();
    final normalizedId = id.toUpperCase();
    final normalizedPreferred = _preferredEyeDeviceId?.toUpperCase();

    return normalizedName == 'ican eye' ||
        normalizedName == 'xiao_camera' ||
        normalizedName.contains('ican') ||
        normalizedName.contains('eye') ||
        normalizedName.contains('xiao') ||
        normalizedName.contains('camera') ||
        (normalizedPreferred != null && normalizedId == normalizedPreferred) ||
        normalizedId == fallbackEyeDeviceId;
  }

  bool _isEyeServiceAdvertised(dynamic advertisementData) {
    try {
      final dynamic serviceUuids = advertisementData.serviceUuids;
      if (serviceUuids is Iterable) {
        final targetGuid = Guid(BleServices.eyeServiceUuid);
        for (final dynamic uuid in serviceUuids) {
          // Compare as Guid objects to be platform-agnostic
          if (Guid(uuid.toString()) == targetGuid) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _stopActiveScan() async {
    if (Platform.isWindows) {
      try {
        WinBle.stopScanning();
      } catch (_) {}
      await _winEyeScanSub?.cancel();
      _winEyeScanSub = null;
    } else {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    await _scanSub?.cancel();
    _scanSub = null;
    await _caneScanSub?.cancel();
    _caneScanSub = null;
    _activeFlutterScanOwner = null;
  }

  Future<void> _beginFlutterScan(_FlutterScanOwner owner) async {
    if (_activeFlutterScanOwner == owner) return;
    if (_activeFlutterScanOwner != null) {
      await _stopActiveScan();
      if (owner == _FlutterScanOwner.eye &&
          _caneState == BleConnectionState.scanning) {
        _setCaneState(BleConnectionState.disconnected);
      } else if (owner == _FlutterScanOwner.cane &&
          _state == BleConnectionState.scanning) {
        _setState(BleConnectionState.disconnected);
      }
    }
    _activeFlutterScanOwner = owner;
  }

  /// Start scanning for iCan devices.
  Future<void> startScan() async {
    if (!_isBleSupported()) {
      debugPrint('[BLE] BLE is not supported on this platform. Aborting scan.');
      return;
    }
    debugPrint('[BLE] Attempting to start scan...');
    _updateEyeReadiness(BleReadinessPhase.waitingForBluetooth);

    // Windows: route through win_ble scan (flutter_blue_plus has no Windows plugin)
    if (Platform.isWindows) {
      _setState(BleConnectionState.scanning);
      await _startWinBleScanForEye();
      return;
    }

    if (!Platform.isWindows) {
      final stateStream = FlutterBluePlus.adapterState;
      try {
        final state = await stateStream
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => BluetoothAdapterState.unknown,
            );

        debugPrint('[BLE] Bluetooth adapter state: $state');

        if (state != BluetoothAdapterState.on) {
          debugPrint('[BLE] Error: Bluetooth is not turned on.');
          _updateEyeReadiness(
            BleReadinessPhase.failed,
            lastError: 'Bluetooth adapter is not on.',
          );
          _setState(BleConnectionState.disconnected);
          return;
        }
      } catch (e) {
        debugPrint('[BLE] Failed to check adapter state: $e');
        _updateEyeReadiness(
          BleReadinessPhase.failed,
          lastError: 'Bluetooth adapter check failed: $e',
        );
        _setState(BleConnectionState.disconnected);
        return;
      }
    } else {
      debugPrint(
        '[BLE] Windows platform detected - skipping adapter state check',
      );
    }

    _setState(BleConnectionState.scanning);
    _updateEyeReadiness(BleReadinessPhase.scanning);
    debugPrint('[BLE] Scanning for iCan Eye...');

    try {
      await _beginFlutterScan(_FlutterScanOwner.eye);
      await _stopActiveScan();
      _activeFlutterScanOwner = _FlutterScanOwner.eye;
      // Small delay after stop to let the adapter breathe
      await Future.delayed(const Duration(milliseconds: 200));

      _scanSub = FlutterBluePlus.scanResults.listen(
        (results) {
          debugPrint(
            '[BLE] Scan Results Received: ${results.length} devices found in this batch.',
          );

          if (_state != BleConnectionState.scanning ||
              _connectedDevice != null) {
            return;
          }

          for (var r in results) {
            final id = r.device.remoteId.str;
            final pName = r.device.platformName;
            final aName = r.advertisementData.advName;
            final name = pName.isNotEmpty ? pName : aName;

            debugPrint(
              '[BLE] DISCOVERED: Name: "$name", ID: $id, RSSI: ${r.rssi}',
            );
            if (r.advertisementData.serviceUuids.isNotEmpty) {
              debugPrint(
                '[BLE]   Services: ${r.advertisementData.serviceUuids.join(', ')}',
              );
            }

            final isEyeByNameOrId = _isEyeCandidate(name, id);
            final isEyeByService = _isEyeServiceAdvertised(r.advertisementData);

            if (isEyeByNameOrId || isEyeByService) {
              debugPrint('[BLE] MATCH FOUND! Connecting to iCan Eye...');
              debugPrint(
                '[BLE]   Match Reason: Name/ID=$isEyeByNameOrId, Service=$isEyeByService',
              );

              _stopActiveScan();
              connectToEye(r.device);
              return;
            }
          }
        },
        onError: (e) {
          debugPrint('[BLE] Scan result stream error: $e');
        },
      );

      debugPrint('[BLE] Calling FlutterBluePlus.startScan()');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[BLE] Critical error during startScan: $e');
      _updateEyeReadiness(
        BleReadinessPhase.failed,
        lastError: 'Scan failed: $e',
      );
    }

    debugPrint('[BLE] Scan finished.');

    await _stopActiveScan();

    if (_state == BleConnectionState.scanning) {
      _setState(BleConnectionState.disconnected);
    }
  }

  /// Connect to a discovered iCan Cane device.
  Future<void> connectToCane(BluetoothDevice device) async {
    _setCaneState(BleConnectionState.connecting);
    debugPrint('[BLE Cane] Connecting to: ${device.remoteId}');

    try {
      await device.connect(autoConnect: false);
      _caneDevice = device;
      _preferredCaneDeviceId = device.remoteId.str;

      _caneConnectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _setCaneState(BleConnectionState.disconnected);
          _caneDevice = null;
          // Auto-reconnect after 3 s
          if (_preferredCaneDeviceId != null) {
            Future.delayed(const Duration(seconds: 3), () {
              if (_caneState == BleConnectionState.disconnected) {
                connectToCaneByMac(_preferredCaneDeviceId!);
              }
            });
          }
        }
      });

      _setCaneState(BleConnectionState.connected);
      await _discoverCaneServices(device);

      // Persist MAC for next app startup
      await DevicePrefsService.instance.saveLastCaneDeviceId(
        device.remoteId.str,
      );
    } catch (e) {
      debugPrint('[BLE Cane] Connection error: $e');
      _setCaneState(BleConnectionState.disconnected);
    }
  }

  StreamSubscription<List<int>>? _navSub;
  StreamSubscription<List<int>>? _obstacleSub;
  StreamSubscription<List<int>>? _telemetrySub;
  BluetoothCharacteristic? _gpsDataChar;
  StreamSubscription<List<int>>? _eyeImageSub;
  StreamSubscription<List<int>>? _eyeCaptureSub;
  StreamSubscription<List<int>>? _eyeInstantTextSub;

  Future<void> _discoverCaneServices(BluetoothDevice device) async {
    // Cancel any previous subscriptions
    await _navSub?.cancel();
    await _obstacleSub?.cancel();
    await _telemetrySub?.cancel();
    try {
      await _gpsDataChar?.setNotifyValue(false);
    } catch (_) {}
    await _gpsSub?.cancel();
    _gpsDataChar = null;

    final List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid == Guid(BleServices.caneServiceUuid)) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          // Nav RX
          if (characteristic.uuid == Guid(BleCharacteristics.navCommandRx)) {
            _navRxChar = characteristic;
          }
          // Obstacle TX (Notify)
          else if (characteristic.uuid ==
              Guid(BleCharacteristics.obstacleAlertTx)) {
            await characteristic.setNotifyValue(true);
            _obstacleSub = characteristic.onValueReceived.listen((value) {
              if (value.isNotEmpty) {
                try {
                  final alert = ObstacleAlert.fromBytes(
                    Uint8List.fromList(value),
                  );
                  _obstacleController.add(alert);
                } catch (e) {
                  debugPrint('[BLE] Obstacle parse error: $e');
                }
              }
            });
          }
          // Telemetry TX (Notify)
          else if (characteristic.uuid ==
              Guid(BleCharacteristics.imuTelemetryTx)) {
            await characteristic.setNotifyValue(true);
            _telemetrySub = characteristic.onValueReceived.listen((value) {
              if (value.isNotEmpty) {
                onTelemetryReceived(Uint8List.fromList(value));
              }
            });
          }
          // GPS Data TX (Notify)
          else if (characteristic.uuid == Guid(BleCharacteristics.gpsDataTx)) {
            _gpsDataChar = characteristic;
            await characteristic.setNotifyValue(true);
            _gpsSub = characteristic.onValueReceived.listen((value) {
              if (value.length >= 19) {
                try {
                  final pkt = GpsPacket.fromBytes(Uint8List.fromList(value));
                  _lastGps = pkt;
                  _gpsController.add(pkt);
                  notifyListeners();
                } catch (e) {
                  debugPrint('[BLE Cane] GPS parse error: $e');
                }
              }
            });
          }
        }
      }
    }
  }

  /// Connect to a discovered iCan Eye device.
  Future<void> connectToEye(BluetoothDevice device) async {
    _setState(BleConnectionState.connecting);
    _updateEyeReadiness(
      BleReadinessPhase.connecting,
      deviceId: device.remoteId.str,
    );
    debugPrint('[BLE] Connecting to Eye: ${device.remoteId}');

    try {
      // Only cancel the Eye scan subscription — do NOT call FlutterBluePlus.stopScan()
      // here because the Cane scan may be running on the same BLE radio.
      await _scanSub?.cancel();
      _scanSub = null;
      await device.connect(autoConnect: false);
      _preferredEyeDeviceId = device.remoteId.str;

      // Request MTU 517 for faster transfers
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await device.requestMtu(517);
          // Allow MTU to settle on Windows before discovering services
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (e) {
          debugPrint('[BLE] Failed to request MTU: $e');
        }
      }

      _connectedDevice = device;
      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          unawaited(
            _cancelEyeNotificationSubscriptions(
              disablePlatformNotifications: false,
            ),
          );
          _setState(BleConnectionState.disconnected);
          _connectedDevice = null;
          _eyeCaptureRxChar = null;
          if (_preferredEyeDeviceId != null) {
            _scheduleEyeReconnect('Eye connection state stream disconnected.');
          }
        }
      });

      await _discoverEyeServices(device);
      _setState(BleConnectionState.connected);
      _updateEyeReadiness(
        BleReadinessPhase.verifyingCommandPath,
        deviceId: device.remoteId.str,
        requiredCharacteristicsReady: true,
        commandPathReady: false,
        lastEvent: 'Eye notifications subscribed; verifying STATUS.',
      );

      // Persist this device ID for auto-connect on next app startup
      await DevicePrefsService.instance.saveLastDeviceId(device.remoteId.str);
      await requestEyeStatus();
    } catch (e) {
      debugPrint('[BLE] Connection error: $e');
      _updateEyeReadiness(
        BleReadinessPhase.failed,
        deviceId: device.remoteId.str,
        lastError: 'Eye connection failed: $e',
      );
      _setState(BleConnectionState.disconnected);
      if (Platform.isIOS) {
        _recordBleLog(
          'Eye connection failed on iOS; falling back to service scan.',
        );
        await startScan();
      } else {
        _scheduleEyeReconnect('Eye connect failed: ${e.runtimeType}.');
      }
    }
  }

  Future<void> _discoverEyeServices(BluetoothDevice device) async {
    _updateEyeReadiness(
      BleReadinessPhase.discoveringServices,
      deviceId: device.remoteId.str,
    );
    await _cancelEyeNotificationSubscriptions(
      disablePlatformNotifications: true,
    );

    final List<BluetoothService> services = await device.discoverServices();
    _updateEyeReadiness(
      BleReadinessPhase.subscribing,
      deviceId: device.remoteId.str,
    );
    for (BluetoothService service in services) {
      if (service.uuid == Guid(BleServices.eyeServiceUuid)) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          // Image Stream TX (Notify)
          if (characteristic.uuid ==
              Guid(BleCharacteristics.eyeImageStreamTx)) {
            _eyeImageStreamChar = characteristic;
            _eyeImageSub = await _subscribeToEyeNotifications(
              device,
              characteristic,
              'image stream',
              (value) {
                if (value.isNotEmpty) {
                  _handleIncomingImageChunk(Uint8List.fromList(value));
                }
              },
            );
          }
          // Control / Capture characteristic (Write + Notify)
          else if (characteristic.uuid ==
              Guid(BleCharacteristics.eyeCaptureRx)) {
            _eyeCaptureRxChar = characteristic;
            _eyeCaptureChar = characteristic;
            _eyeCaptureSub = await _subscribeToEyeNotifications(
              device,
              characteristic,
              'capture control',
              (value) {
                if (value.isNotEmpty) {
                  _handleEyeControlMessage(String.fromCharCodes(value));
                }
              },
            );
          }
          // Instant Text TX (Notify)
          else if (characteristic.uuid ==
              Guid(BleCharacteristics.eyeInstantTextTx)) {
            _eyeInstantTextChar = characteristic;
            _eyeInstantTextSub = await _subscribeToEyeNotifications(
              device,
              characteristic,
              'instant text',
              (value) {
                if (value.isNotEmpty) {
                  _instantTextController.add(String.fromCharCodes(value));
                }
              },
            );
          }
        }
      }
    }
    final requiredReady =
        _eyeImageSub != null &&
        _eyeCaptureSub != null &&
        _eyeInstantTextSub != null;
    if (!requiredReady) {
      throw StateError(
        'Missing Eye notifications. image=${_eyeImageSub != null}, '
        'control=${_eyeCaptureSub != null}, instantText=${_eyeInstantTextSub != null}',
      );
    }
  }

  Future<StreamSubscription<List<int>>> _subscribeToEyeNotifications(
    BluetoothDevice device,
    BluetoothCharacteristic characteristic,
    String label,
    void Function(List<int> value) onData,
  ) async {
    final subscription = characteristic.onValueReceived.listen(
      onData,
      onError: (Object error) {
        debugPrint('[BLE Eye] $label notification error: $error');
      },
    );
    device.cancelWhenDisconnected(subscription);
    try {
      await characteristic.setNotifyValue(true);
      debugPrint('[BLE Eye] Notifications enabled for $label.');
      return subscription;
    } catch (e) {
      await subscription.cancel();
      debugPrint('[BLE Eye] Failed to enable $label notifications: $e');
      rethrow;
    }
  }

  Future<void> _cancelEyeNotificationSubscriptions({
    required bool disablePlatformNotifications,
  }) async {
    if (disablePlatformNotifications) {
      try {
        await _eyeImageStreamChar?.setNotifyValue(false);
      } catch (_) {}
      try {
        await _eyeCaptureChar?.setNotifyValue(false);
      } catch (_) {}
      try {
        await _eyeInstantTextChar?.setNotifyValue(false);
      } catch (_) {}
    }
    await _eyeImageSub?.cancel();
    await _eyeCaptureSub?.cancel();
    await _eyeInstantTextSub?.cancel();
    _eyeImageSub = null;
    _eyeCaptureSub = null;
    _eyeInstantTextSub = null;
    _eyeImageStreamChar = null;
    _eyeCaptureChar = null;
    _eyeCaptureRxChar = null;
    _eyeInstantTextChar = null;
  }

  void _handleEyeControlMessage(String message) {
    final now = DateTime.now();

    // Deduplicate: same message within 50ms = Windows BLE adapter double-fire
    final isDuplicate =
        message == _lastControlMessage &&
        _lastControlMessageTime != null &&
        now.difference(_lastControlMessageTime!).inMilliseconds < 50;

    if (isDuplicate) return;

    _lastControlMessage = message;
    _lastControlMessageTime = now;
    debugPrint('[BLE Eye Msg] $message');
    _recordEyeControlMessage(message);

    if (message.startsWith(EyeEvents.statusPrefix)) {
      _markEyeCommandPathReady(message);
    }

    if (message.startsWith('BUTTON:')) {
      _buttonEventController.add(message);
      return;
    }

    final event = _imageAssembler.handleControlMessage(message);
    if (event != null) {
      if (event.captureStarted || event.sizeArrived) {
        _cancelCaptureResponseRetryTimer();
        _captureStartedController.add(null);
      }
      if (event.progress) {
        _armImageTransferTimeout();
      }
      _handleImageAssemblyEvent(event);
    }

    if (_legacyImageAssemblerEnabled && message.startsWith('SIZE:')) {
      final newSize = int.tryParse(message.substring(5)) ?? 0;

      // Ignore duplicate SIZE messages while we're already accumulating this
      // frame. iOS BLE can fire the same notification 2-3× and each duplicate
      // would wipe the buffer mid-transfer.
      if (_imageBuffer.isNotEmpty &&
          newSize == _expectedImageSize &&
          !_frameEmitted) {
        debugPrint(
          '[BLE] Ignoring duplicate SIZE:$newSize (already buffering ${_imageBuffer.length} bytes)',
        );
        return;
      }

      _imageBuffer.clear();
      _seenSequenceNumbers.clear();
      _lastSequenceNumber = -1;
      _lostChunks = 0;
      _frameEmitted = false;
      _frameSessionId++;
      _expectedImageSize = newSize;
      debugPrint('[BLE] Expecting image of size $_expectedImageSize bytes');
      _captureStartedController.add(null);

      _armImageTransferTimeout();
    } else if (_legacyImageAssemblerEnabled && message.startsWith('END:')) {
      _imageTimeoutTimer?.cancel();
      debugPrint(
        '[BLE] Transfer END. Buffer has ${_imageBuffer.length}/$_expectedImageSize bytes. '
        'Chunks received: ${_seenSequenceNumbers.length}, Lost: $_lostChunks',
      );

      if (_imageBuffer.isEmpty || _frameEmitted) return;

      if (_imageBuffer.length != _expectedImageSize) {
        final endSessionId = _frameSessionId;
        debugPrint('[BLE] Size mismatch — waiting 300ms for late chunks...');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (endSessionId != _frameSessionId) return;
          if (_imageBuffer.isNotEmpty && !_frameEmitted) {
            debugPrint(
              '[BLE] Emitting ${_imageBuffer.length} bytes (partial).',
            );
            _emitImageIfValid(_imageBuffer);
            _imageBuffer.clear();
            _expectedImageSize = 0;
          }
        });
      } else {
        _emitImageIfValid(_imageBuffer);
        _imageBuffer.clear();
        _expectedImageSize = 0;
      }
    }
  }

  void _handleIncomingImageChunk(Uint8List data) {
    if (data.length <= ImagePacketHeader.headerSize) return;

    try {
      final header = ImagePacketHeader.fromBytes(data);
      final payload = data.sublist(ImagePacketHeader.headerSize);

      final event = _imageAssembler.handleImageChunk(data);
      if (event != null) {
        if (event.progress) {
          _armImageTransferTimeout();
        }
        _handleImageAssemblyEvent(event);
      }

      // Log first chunk for diagnostics
      if (header.sequenceNumber == 0) {
        debugPrint(
          '[BLE] Chunk 0: ${data.length} bytes total, '
          '${payload.length} payload, '
          'header=[${data.take(4).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}]',
        );
      }
      // Log progress every 10 chunks
      if (header.sequenceNumber > 0 && header.sequenceNumber % 10 == 0) {
        debugPrint(
          '[BLE] Chunk ${header.sequenceNumber}: buffer=${_imageBuffer.length + payload.length}/$_expectedImageSize bytes',
        );
      }

      // Defensive reset: seq 0 without a prior SIZE: means we missed the control message
      if (header.sequenceNumber == 0 && _lastSequenceNumber != -1) {
        debugPrint(
          '[BLE] WARN: Got chunk 0 without SIZE: — clearing stale state.',
        );
        _imageBuffer.clear();
        _seenSequenceNumbers.clear();
        _lastSequenceNumber = -1;
        _lostChunks = 0;
        _frameEmitted = false;
      }

      // Deduplicate — skip chunks we've already processed
      if (_seenSequenceNumbers.contains(header.sequenceNumber)) return;
      _seenSequenceNumbers.add(header.sequenceNumber);

      if (_lastSequenceNumber != -1 &&
          header.sequenceNumber != _lastSequenceNumber + 1) {
        debugPrint(
          '[BLE] WARN: Missed chunk! Expected ${_lastSequenceNumber + 1}, got ${header.sequenceNumber}',
        );
        _lostChunks++;
      }
      _lastSequenceNumber = header.sequenceNumber;

      // Structured assembler above owns buffering.
      _armImageTransferTimeout();

      if (_expectedImageSize > 0 &&
          _imageBuffer.length >= _expectedImageSize &&
          !_frameEmitted) {
        _emitImageIfValid(_imageBuffer);
        _imageBuffer.clear();
        _expectedImageSize = 0;
      }
    } catch (e) {
      debugPrint('[BLE] Chunk error: $e');
    }
  }

  void _handleImageAssemblyEvent(EyeImageAssemblyEvent event) {
    final diagnostic = event.diagnostic;
    if (diagnostic != null) {
      _imageTimeoutTimer?.cancel();
      _cancelCaptureResponseRetryTimer();
      _emitEyeDiagnostic(diagnostic);
      return;
    }

    final image = event.image;
    if (image != null) {
      _imageTimeoutTimer?.cancel();
      _cancelCaptureResponseRetryTimer();
      debugPrint('[BLE] Emitting complete image (${image.length} bytes).');
      _imageController.add(image);
    }
  }

  @visibleForTesting
  void handleEyeControlMessageForTesting(String message) {
    _handleEyeControlMessage(message);
  }

  @visibleForTesting
  void handleIncomingImageChunkForTesting(Uint8List data) {
    _handleIncomingImageChunk(data);
  }

  @visibleForTesting
  void emitEyeTimeoutForTesting() {
    _emitImageTimeoutDiagnostic();
  }

  @visibleForTesting
  void beginEyeCaptureCommandForTesting() {
    _imageAssembler.beginCaptureCommand();
    _captureResponseRetryCount = 0;
  }

  @visibleForTesting
  Future<void> handleCaptureResponseTimeoutForTesting() {
    return _handleCaptureResponseTimeout();
  }

  @visibleForTesting
  void updateEyeReadinessForTesting(
    BleReadinessPhase phase, {
    bool? requiredCharacteristicsReady,
    bool? commandPathReady,
  }) {
    _updateEyeReadiness(
      phase,
      requiredCharacteristicsReady: requiredCharacteristicsReady,
      commandPathReady: commandPathReady,
    );
  }

  void _emitImageTimeoutDiagnostic({String? context}) {
    _cancelCaptureResponseRetryTimer();
    final diagnostic = _imageAssembler.handleTimeout();
    _emitEyeDiagnostic(
      diagnostic,
      context: context ?? 'Image transfer timeout.',
    );
  }

  void _cancelImageTransfer({bool reset = false}) {
    _imageTimeoutTimer?.cancel();
    _imageTimeoutTimer = null;
    _cancelCaptureResponseRetryTimer();
    if (reset) {
      _imageAssembler.reset();
    }
  }

  void _armImageTransferTimeout() {
    _imageTimeoutTimer?.cancel();
    _imageTimeoutTimer = Timer(_imageTransferTimeout, () {
      if (_imageAssembler.hasActiveTransfer) {
        _emitImageTimeoutDiagnostic();
      }
    });
  }

  void _armCaptureResponseRetry() {
    _captureResponseRetryTimer?.cancel();
    _captureResponseRetryTimer = Timer(_captureResponseTimeout, () {
      unawaited(_handleCaptureResponseTimeout());
    });
  }

  void _cancelCaptureResponseRetryTimer() {
    _captureResponseRetryTimer?.cancel();
    _captureResponseRetryTimer = null;
  }

  void _cancelEyeReconnect() {
    _eyeReconnectTimer?.cancel();
    _eyeReconnectTimer = null;
  }

  void _scheduleEyeReconnect(String reason, {Duration? initialDelay}) {
    if (_preferredEyeDeviceId == null) return;
    if (_eyeReconnectTimer != null) {
      _recordBleLog(
        'Eye reconnect already scheduled; ignoring duplicate. reason=$reason',
      );
      return;
    }
    final attempt = _eyeReconnectAttempt + 1;
    final backoffSeconds =
        (_eyeReconnectInitialDelay.inSeconds * (1 << _eyeReconnectAttempt))
            .clamp(
              _eyeReconnectInitialDelay.inSeconds,
              _eyeReconnectMaxDelay.inSeconds,
            )
            .toInt();
    final delay = initialDelay ?? Duration(seconds: backoffSeconds);
    _eyeReconnectAttempt = attempt;
    _recordBleLog(
      'Eye reconnect scheduled attempt=$attempt delay=${delay.inSeconds}s reason=$reason',
    );
    _eyeReconnectTimer = Timer(delay, () {
      _eyeReconnectTimer = null;
      unawaited(_performEyeReconnect());
    });
  }

  Future<void> _performEyeReconnect() async {
    if (_state == BleConnectionState.connected ||
        _state == BleConnectionState.connecting ||
        _state == BleConnectionState.scanning) {
      return;
    }
    final target = _preferredEyeDeviceId;
    if (target == null) return;
    _recordBleLog('Eye reconnect attempt $_eyeReconnectAttempt starting.');
    await connectToEyeByMac(target);
  }

  void _startEyeHeartbeat() {
    if (_eyeHeartbeatTimer != null) return;
    _missedEyeHeartbeats = 0;
    _eyeHeartbeatTimer = Timer.periodic(_eyeHeartbeatInterval, (_) {
      unawaited(_handleEyeHeartbeatTick());
    });
    _recordBleLog('Eye heartbeat started.');
  }

  void _stopEyeHeartbeat() {
    _eyeHeartbeatTimer?.cancel();
    _eyeHeartbeatTimer = null;
    _missedEyeHeartbeats = 0;
  }

  Future<void> _handleEyeHeartbeatTick({bool sendCommand = true}) async {
    if (_state != BleConnectionState.connected) {
      _stopEyeHeartbeat();
      return;
    }
    if (_imageAssembler.hasActiveTransfer) return;
    if (!_eyeReadinessStatus.requiredCharacteristicsReady) return;

    _missedEyeHeartbeats++;
    _recordBleLog('Eye heartbeat STATUS missed=$_missedEyeHeartbeats.');
    if (_missedEyeHeartbeats >= 2) {
      _recordBleLog('Eye heartbeat missed twice; marking Eye not ready.');
      _updateEyeReadiness(
        BleReadinessPhase.failed,
        requiredCharacteristicsReady:
            _eyeReadinessStatus.requiredCharacteristicsReady,
        commandPathReady: false,
        lastError: 'Eye STATUS heartbeat missed twice.',
      );
      await _forceEyeReconnect('Eye STATUS heartbeat missed twice.');
      return;
    }

    if (sendCommand) {
      await requestEyeStatus();
    }
  }

  Future<void> _forceEyeReconnect(String reason) async {
    _stopEyeHeartbeat();
    await _cancelEyeNotificationSubscriptions(
      disablePlatformNotifications: false,
    );
    if (Platform.isWindows) {
      final mac = _connectedWindowsMac;
      _connectedWindowsMac = null;
      if (mac != null) {
        try {
          await WinBle.disconnect(mac);
        } catch (e) {
          debugPrint('[BLE] Eye reconnect WinBle disconnect failed: $e');
        }
      }
    } else {
      final device = _connectedDevice;
      _connectedDevice = null;
      if (device != null) {
        try {
          await device.disconnect();
        } catch (e) {
          debugPrint('[BLE] Eye reconnect disconnect failed: $e');
        }
      }
    }
    _setState(BleConnectionState.disconnected);
    _scheduleEyeReconnect(reason, initialDelay: Duration.zero);
  }

  Future<void> _handleCaptureResponseTimeout() async {
    if (!_imageAssembler.hasActiveTransfer) return;
    if (_imageAssembler.currentTimeoutStage !=
        EyeTransferTimeoutStage.awaitingCaptureStart) {
      _cancelCaptureResponseRetryTimer();
      return;
    }

    if (_captureResponseRetryCount == 0) {
      _captureResponseRetryCount = 1;
      _recordBleLog(
        'Eye command CAPTURE got no CAPTURE:START or SIZE within '
        '${_captureResponseTimeout.inMilliseconds}ms; retrying once.',
      );
      _imageAssembler.beginCaptureCommand();
      await _sendEyeCommand(EyeCommands.capture);
      if (_imageAssembler.hasActiveTransfer &&
          _imageAssembler.currentTimeoutStage ==
              EyeTransferTimeoutStage.awaitingCaptureStart) {
        _armCaptureResponseRetry();
      }
      return;
    }

    _recordBleLog(
      'Eye command CAPTURE retry also got no CAPTURE:START or SIZE; emitting E01.',
    );
    _emitImageTimeoutDiagnostic(context: 'Capture command response timeout.');
  }

  void _emitImageIfValid(List<int> buffer) {
    final bytes = Uint8List.fromList(buffer);

    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      debugPrint(
        '[BLE] ERROR: Not a valid JPEG (first 6 bytes: '
        '${bytes.take(6).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}). '
        'Discarding ${bytes.length} bytes.',
      );
      return;
    }

    // Reject severely truncated frames — a JPEG missing >25% of its data
    // will produce heavy artifacts that confuse the vision AI. Better to
    // discard and let the user retry than send garbage to the API.
    if (_expectedImageSize > 0) {
      final pct = bytes.length * 100 ~/ _expectedImageSize;
      if (pct < 75) {
        debugPrint(
          '[BLE] WARN: Image too incomplete '
          '(${bytes.length}/$_expectedImageSize = $pct%). Discarding.',
        );
        return;
      }
      debugPrint(
        '[BLE] Emitting ${bytes.length} bytes ($pct% of $_expectedImageSize expected).',
      );
    } else {
      debugPrint(
        '[BLE] Emitting ${bytes.length} bytes (expected size unknown).',
      );
    }

    _imageController.add(bytes);
    _frameEmitted = true;
  }

  /// Disconnect from the current device and clear the saved device ID.
  /// Call this when the user manually disconnects to prevent auto-reconnect on next startup.
  Future<void> disconnectAndForget() async {
    debugPrint('[BLE] Disconnecting and clearing saved device...');
    _preferredEyeDeviceId = null;
    _cancelEyeReconnect();
    _stopEyeHeartbeat();
    try {
      await DevicePrefsService.instance.clearLastDeviceId();
      if (Platform.isWindows) {
        await _winConnectionSub?.cancel();
        await _winImageSub?.cancel();
        await _winCaptureSub?.cancel();
        await _winInstantTextSub?.cancel();
        if (_connectedWindowsMac != null) {
          await WinBle.disconnect(_connectedWindowsMac!);
          _connectedWindowsMac = null;
        }
      } else {
        await _cancelEyeNotificationSubscriptions(
          disablePlatformNotifications: true,
        );
        if (_connectedDevice != null) {
          await _connectedDevice!.disconnect();
          _connectedDevice = null;
        }
        await _connectionSub?.cancel();
      }
      _setState(BleConnectionState.disconnected);
    } catch (e) {
      debugPrint('[BLE] Error during disconnect: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Write Commands
  // ---------------------------------------------------------------------------

  /// Send a navigation command to the cane.
  Future<void> sendNavCommand(NavCommand command) async {
    if (_caneState != BleConnectionState.connected) return;
    debugPrint(
      '[BLE] Sending nav command: ${command.name} (0x${command.opcode.toRadixString(16)})',
    );
    if (Platform.isWindows) {
      if (_winCaneMac == null) return;
      await WinBle.write(
        address: _winCaneMac!,
        service: BleServices.caneServiceUuid,
        characteristic: BleCharacteristics.navCommandRx,
        data: Uint8List.fromList([command.opcode]),
        writeWithResponse: false,
      );
    } else {
      if (_navRxChar == null) return;
      await _navRxChar!.write([command.opcode], withoutResponse: true);
    }
  }

  /// Send a string command to the Eye via the capture/control characteristic.
  Future<void> _sendEyeCommand(String cmd) async {
    if (_state != BleConnectionState.connected) {
      debugPrint('[BLE] Cannot send "$cmd": not connected.');
      return;
    }
    debugPrint('[BLE] Sending Eye command: $cmd');
    _recordBleLog(
      'Sending Eye command: $cmd. readiness=${_eyeReadinessStatus.phase.name} '
      'ready=${_eyeReadinessStatus.ready} '
      'requiredChars=${_eyeReadinessStatus.requiredCharacteristicsReady}',
    );
    if (Platform.isWindows) {
      if (_connectedWindowsMac == null) return;
      try {
        await WinBle.write(
          address: _connectedWindowsMac!,
          service: BleServices.eyeServiceUuid,
          characteristic: BleCharacteristics.eyeCaptureRx,
          data: Uint8List.fromList(cmd.codeUnits),
          writeWithResponse: false,
        );
        _recordBleLog('Eye command $cmd write succeeded on Windows.');
      } catch (e) {
        debugPrint('[BLE] Eye command write FAILED: $e');
        _recordBleLog(
          'Eye command $cmd write failed on Windows: ${e.runtimeType}.',
        );
      }
    } else {
      if (_eyeCaptureRxChar == null) {
        _emitEyeCommandWriteFailureDiagnostic(
          cmd,
          StateError('Eye control characteristic is missing.'),
        );
        _updateEyeReadiness(
          BleReadinessPhase.failed,
          lastError: 'Eye control characteristic is missing.',
        );
        return;
      }
      try {
        await _eyeCaptureRxChar!.write(cmd.codeUnits, withoutResponse: false);
        _recordBleLog('Eye command $cmd write succeeded.');
      } catch (e) {
        debugPrint('[BLE] Eye command write FAILED: $e');
        _emitEyeCommandWriteFailureDiagnostic(cmd, e);
      }
    }
  }

  /// Remotely trigger a single image capture on the Eye.
  Future<void> triggerEyeCapture() {
    _imageAssembler.beginCaptureCommand();
    _captureResponseRetryCount = 0;
    _armImageTransferTimeout();
    return _sendEyeCommand(EyeCommands.capture).then((_) {
      if (_imageAssembler.hasActiveTransfer &&
          _imageAssembler.currentTimeoutStage ==
              EyeTransferTimeoutStage.awaitingCaptureStart) {
        _armCaptureResponseRetry();
      }
    });
  }

  /// Start firmware-driven periodic capture at [intervalMs].
  /// The Eye will auto-capture and stream images until [stopLiveCapture] is called.
  Future<void> startLiveCapture({int intervalMs = 1500}) =>
      _sendEyeCommand(EyeCommands.liveStart(intervalMs));

  /// Stop firmware-driven periodic capture.
  Future<void> stopLiveCapture() => _sendEyeCommand(EyeCommands.liveStop);

  /// Send a camera profile change command to the Eye.
  /// Profile indices: 0=FAST, 1=BALANCED, 2=QUALITY, 3=MAX
  Future<void> setEyeProfile(int profileIndex) =>
      _sendEyeCommand(EyeCommands.profile(profileIndex));

  Future<void> requestEyeStatus() => _sendEyeCommand(EyeCommands.status);

  @visibleForTesting
  void emitEyeCommandWriteFailureForTesting(String command, Object error) {
    _emitEyeCommandWriteFailureDiagnostic(command, error);
  }

  @visibleForTesting
  void setEyeConnectionStateForTesting(BleConnectionState state) {
    _setState(state);
  }

  @visibleForTesting
  bool get eyeReconnectPendingForTesting => _eyeReconnectTimer != null;

  @visibleForTesting
  int get eyeReconnectAttemptForTesting => _eyeReconnectAttempt;

  @visibleForTesting
  int get missedEyeHeartbeatsForTesting => _missedEyeHeartbeats;

  @visibleForTesting
  void scheduleEyeReconnectForTesting(String reason) {
    _preferredEyeDeviceId ??= fallbackEyeDeviceId;
    _scheduleEyeReconnect(reason);
  }

  @visibleForTesting
  Future<void> handleEyeHeartbeatTickForTesting({bool sendCommand = false}) {
    return _handleEyeHeartbeatTick(sendCommand: sendCommand);
  }

  @visibleForTesting
  void resetEyeReliabilityForTesting() {
    _cancelEyeReconnect();
    _stopEyeHeartbeat();
    _eyeReconnectAttempt = 0;
    _missedEyeHeartbeats = 0;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _emitEyeCommandWriteFailureDiagnostic(String command, Object error) {
    _cancelImageTransfer(reset: true);
    const diagnostic = EyeCaptureDiagnostic(
      code: EyeCaptureDiagnosticCode.noCaptureStartOrSize,
      captureStarted: false,
      sizeArrived: false,
      expectedBytes: 0,
      receivedBytes: 0,
      uniqueChunks: 0,
      duplicateChunks: 0,
      endArrived: false,
      jpegMagicValid: false,
      jpegEndValid: false,
      timeoutStage: EyeTransferTimeoutStage.awaitingCaptureStart,
    );
    _emitEyeDiagnostic(
      diagnostic,
      context: 'Eye command $command write failed: ${error.runtimeType}.',
    );
    _updateEyeReadiness(
      BleReadinessPhase.failed,
      lastError: 'Eye command $command write failed: ${error.runtimeType}.',
    );
  }

  void _emitEyeDiagnostic(EyeCaptureDiagnostic diagnostic, {String? context}) {
    _lastEyeCaptureDiagnostic = diagnostic;
    _eyeDiagnosticController.add(diagnostic);
    final message = diagnostic.spokenMessage;
    debugPrint('[BLE Eye Diagnostic] $message');
    _recordBleLog(
      '${context == null ? '' : '$context '}'
      'Eye diagnostic ${diagnostic.stableCode}: $message',
    );
  }

  void _recordBleLog(String message) {
    unawaited(AppLogService.instance.record(message, source: 'ble'));
  }

  void _recordEyeControlMessage(String message) {
    final isTrackedControlMessage =
        message.startsWith(EyeEvents.statusPrefix) ||
        message.startsWith(EyeEvents.profileSetPrefix) ||
        message == EyeEvents.captureStart ||
        message.startsWith(EyeEvents.sizePrefix) ||
        message.startsWith(EyeEvents.crcPrefix) ||
        message.startsWith(EyeEvents.endPrefix) ||
        message.startsWith(EyeEvents.errorPrefix);
    if (!isTrackedControlMessage) return;
    _recordBleLog('Eye control notification: $message');
  }

  void _markEyeCommandPathReady(String statusMessage) {
    _missedEyeHeartbeats = 0;
    if (_eyeReadinessStatus.commandPathReady &&
        _eyeReadinessStatus.phase == BleReadinessPhase.ready) {
      _startEyeHeartbeat();
      return;
    }
    _updateEyeReadiness(
      BleReadinessPhase.ready,
      requiredCharacteristicsReady: true,
      commandPathReady: true,
      lastEvent: 'Eye STATUS round trip verified: $statusMessage',
    );
    _eyeReconnectAttempt = 0;
    _startEyeHeartbeat();
    unawaited(setEyeProfile(1));
  }

  void _updateEyeReadiness(
    BleReadinessPhase phase, {
    String? deviceId,
    bool? requiredCharacteristicsReady,
    bool? commandPathReady,
    String? lastError,
    String? lastEvent,
  }) {
    final ready = phase == BleReadinessPhase.ready;
    final nextRequiredCharacteristicsReady =
        requiredCharacteristicsReady ??
        (phase == BleReadinessPhase.idle
            ? false
            : ready
            ? true
            : null) ??
        _eyeReadinessStatus.requiredCharacteristicsReady;
    final nextCommandPathReady =
        commandPathReady ??
        (phase == BleReadinessPhase.idle
            ? false
            : ready
            ? true
            : false);
    _recordBleLog(
      'Eye readiness ${_eyeReadinessStatus.phase.name}->${phase.name} '
      'ready=$ready requiredChars=$nextRequiredCharacteristicsReady '
      'commandPath=$nextCommandPathReady'
      '${lastEvent == null ? '' : ' event=$lastEvent'}'
      '${lastError == null ? '' : ' error=$lastError'}',
    );
    _eyeReadinessStatus = _eyeReadinessStatus.copyWith(
      phase: phase,
      ready: ready,
      deviceId: deviceId,
      requiredCharacteristicsReady: nextRequiredCharacteristicsReady,
      commandPathReady: nextCommandPathReady,
      lastError: lastError,
      lastEvent: lastEvent,
    );
    _connectionEventController.add(
      BleConnectionEvent(
        deviceKind: BleDeviceKind.eye,
        phase: phase,
        ready: ready,
        deviceId: _eyeReadinessStatus.deviceId,
        message: lastEvent ?? lastError,
      ),
    );
    notifyListeners();
  }

  void _setState(BleConnectionState newState) {
    if (newState == BleConnectionState.disconnected) {
      _cancelImageTransfer(reset: true);
      _stopEyeHeartbeat();
    } else if (newState == BleConnectionState.connected) {
      _cancelEyeReconnect();
    }
    if (_state != newState) {
      _recordBleLog('Eye connection state ${_state.name}->${newState.name}.');
    }
    _state = newState;
    if (newState == BleConnectionState.disconnected) {
      _updateEyeReadiness(BleReadinessPhase.idle);
    }
    notifyListeners();
  }

  /// Parse raw telemetry bytes from BLE notification.
  /// Called by the BLE subscription callback when data arrives.
  void onTelemetryReceived(Uint8List data) {
    try {
      final pkt = TelemetryPacket.fromBytes(data);
      _lastTelemetry = pkt;
      _telemetryController.add(pkt);

      // Rising-edge fall detection — trigger OS notification only on transition
      if (pkt.fallDetected && !_prevFallDetected) {
        debugPrint(
          '[BLE] FALL DETECTED — hr=${pkt.pulseBpm} bat=${pkt.batteryPercent}%',
        );
        NotificationService.showFallAlert();
      }
      _prevFallDetected = pkt.fallDetected;

      notifyListeners();
    } catch (e) {
      // In complete app, handle properly. Can ignore partial packets silently here.
    }
  }

  @override
  void dispose() {
    _cancelEyeReconnect();
    _stopEyeHeartbeat();
    if (Platform.isWindows) {
      _winConnectionSub?.cancel();
      _winImageSub?.cancel();
      _winCaptureSub?.cancel();
      _winInstantTextSub?.cancel();
      if (_connectedWindowsMac != null) {
        WinBle.disconnect(_connectedWindowsMac!).catchError((e) {
          debugPrint('[BLE] Error disconnecting on dispose: $e');
        });
      }
    } else {
      _stopActiveScan().catchError((e) {
        debugPrint('[BLE] Error stopping scan on dispose: $e');
      });
      _cancelEyeNotificationSubscriptions(
        disablePlatformNotifications: true,
      ).catchError((Object e) {
        debugPrint('[BLE] Error canceling Eye notifications: $e');
      });
      _connectedDevice?.disconnect().catchError((e) {
        debugPrint('[BLE] Error disconnecting Eye on dispose: $e');
      });
      _connectionSub?.cancel();
    }
    _caneScanSub?.cancel();
    _caneDevice?.disconnect().catchError((e) {
      debugPrint('[BLE] Error disconnecting Cane on dispose: $e');
    });
    _caneConnectionSub?.cancel();
    _navSub?.cancel();
    _obstacleSub?.cancel();
    _telemetrySub?.cancel();
    _gpsSub?.cancel();
    _winCaneConnectionSub?.cancel();
    _winCaneScanSub?.cancel();
    _winCaneGpsSub?.cancel();
    _winCaneObstacleSub?.cancel();
    _winCaneTelemetrySub?.cancel();
    if (_winCaneMac != null) {
      WinBle.disconnect(_winCaneMac!).catchError((_) {});
    }
    _imageTimeoutTimer?.cancel();
    _telemetryController.close();
    _obstacleController.close();
    _instantTextController.close();
    _imageController.close();
    _eyeDiagnosticController.close();
    _connectionEventController.close();
    _captureStartedController.close();
    _buttonEventController.close();
    _gpsController.close();
    super.dispose();
  }
}

/// Simple obstacle alert data class.
class ObstacleAlert {
  const ObstacleAlert({required this.side, required this.distanceCm});

  factory ObstacleAlert.fromBytes(Uint8List data) {
    if (data.length < 3) throw ArgumentError('Obstacle alert must be 3 bytes');
    return ObstacleAlert(
      side: ObstacleSide.fromCode(data[0]),
      distanceCm: data[1] | (data[2] << 8),
    );
  }
  final ObstacleSide side;
  final int distanceCm;
}
