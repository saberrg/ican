import 'connectivity_service.dart';
import 'on_device_vision_service.dart';
import 'vertex_ai_service.dart';

enum VisionRuntimeAvailability { available, degraded, unavailable, unknown }

class VisionRuntimeCheck {
  const VisionRuntimeCheck({
    required this.availability,
    required this.label,
    required this.message,
  });

  final VisionRuntimeAvailability availability;
  final String label;
  final String message;

  bool get isAvailable => availability == VisionRuntimeAvailability.available;
  bool get isUsable =>
      availability == VisionRuntimeAvailability.available ||
      availability == VisionRuntimeAvailability.degraded;

  static VisionRuntimeCheck available(String label, String message) {
    return VisionRuntimeCheck(
      availability: VisionRuntimeAvailability.available,
      label: label,
      message: message,
    );
  }

  static VisionRuntimeCheck degraded(String label, String message) {
    return VisionRuntimeCheck(
      availability: VisionRuntimeAvailability.degraded,
      label: label,
      message: message,
    );
  }

  static VisionRuntimeCheck unavailable(String label, String message) {
    return VisionRuntimeCheck(
      availability: VisionRuntimeAvailability.unavailable,
      label: label,
      message: message,
    );
  }

  static VisionRuntimeCheck unknown(String label, String message) {
    return VisionRuntimeCheck(
      availability: VisionRuntimeAvailability.unknown,
      label: label,
      message: message,
    );
  }
}

class VisionRuntimeStatus {
  const VisionRuntimeStatus({
    required this.nativeChannel,
    required this.appleVision,
    required this.objectDetector,
    required this.depthEstimator,
    required this.smolVlmRuntime,
    required this.smolVlmModels,
    required this.cloudDescribe,
    required this.eyeConnection,
    this.blockingReason,
  });

  final VisionRuntimeCheck nativeChannel;
  final VisionRuntimeCheck appleVision;
  final VisionRuntimeCheck objectDetector;
  final VisionRuntimeCheck depthEstimator;
  final VisionRuntimeCheck smolVlmRuntime;
  final VisionRuntimeCheck smolVlmModels;
  final VisionRuntimeCheck cloudDescribe;
  final VisionRuntimeCheck eyeConnection;
  final String? blockingReason;

  bool get basicLocalVisionReady =>
      nativeChannel.isAvailable && appleVision.isAvailable;

  bool get fullLiveDetectionReady =>
      basicLocalVisionReady && objectDetector.isAvailable;

  bool get basicLiveModeReady =>
      basicLocalVisionReady && eyeConnection.isAvailable;

  bool get cloudDescribeReady => cloudDescribe.isAvailable;
}

class VisionHealthService {
  VisionHealthService({
    required this.onDeviceService,
    required this.cloudService,
    ConnectivityService? connectivityService,
  }) : _connectivity = connectivityService ?? ConnectivityService();

  final OnDeviceVisionService onDeviceService;
  final VertexAiService cloudService;
  final ConnectivityService _connectivity;

  Future<VisionRuntimeStatus> check({
    required bool eyeConnected,
    bool includeNetworkCheck = true,
  }) async {
    final nativeOk = await onDeviceService.pingNativeChannel();
    final nativeChannel = nativeOk
        ? VisionRuntimeCheck.available(
            'Native channel',
            'Native vision channel is registered.',
          )
        : VisionRuntimeCheck.unavailable(
            'Native channel',
            'Native vision channel is not registered.',
          );

    final appleVision = nativeOk
        ? await _appleVisionCheck()
        : VisionRuntimeCheck.unavailable(
            'Apple Vision',
            'Apple Vision cannot run because the native channel is missing.',
          );

    final offlineStatus = nativeOk
        ? await onDeviceService.getOfflineVisionStatus()
        : const OfflineVisionStatus(
            foundationModelsAvailable: false,
            modelStatus: ModelStatus.notAvailable,
            objectDetectionAvailable: false,
            depthEstimationAvailable: false,
          );
    final diagnostics = nativeOk
        ? await onDeviceService.getOfflineVisionDiagnostics()
        : const OfflineVisionDiagnostics(
            objectDetector: NativeModelDiagnostic(
              name: 'YOLOv3Tiny',
              bundleFound: false,
              compiledModelFound: false,
              loaded: false,
              message: 'Native vision channel is not registered.',
            ),
            depthEstimator: NativeModelDiagnostic(
              name: 'DepthAnythingV2SmallF16P6',
              bundleFound: false,
              compiledModelFound: false,
              loaded: false,
              message: 'Native vision channel is not registered.',
            ),
          );

    final status = VisionRuntimeStatus(
      nativeChannel: nativeChannel,
      appleVision: appleVision,
      objectDetector: _modelCheck(
        diagnostics.objectDetector,
        offlineStatus.objectDetectionAvailable,
      ),
      depthEstimator: _modelCheck(
        diagnostics.depthEstimator,
        offlineStatus.depthEstimationAvailable,
      ),
      smolVlmRuntime: _smolRuntimeCheck(offlineStatus.modelStatus),
      smolVlmModels: _smolModelCheck(offlineStatus.modelStatus),
      cloudDescribe: await _cloudCheck(
        includeNetworkCheck: includeNetworkCheck,
      ),
      eyeConnection: eyeConnected
          ? VisionRuntimeCheck.available('iCan Eye', 'iCan Eye is connected.')
          : VisionRuntimeCheck.unavailable(
              'iCan Eye',
              'iCan Eye is not connected.',
            ),
    );

    return VisionRuntimeStatus(
      nativeChannel: status.nativeChannel,
      appleVision: status.appleVision,
      objectDetector: status.objectDetector,
      depthEstimator: status.depthEstimator,
      smolVlmRuntime: status.smolVlmRuntime,
      smolVlmModels: status.smolVlmModels,
      cloudDescribe: status.cloudDescribe,
      eyeConnection: status.eyeConnection,
      blockingReason: _blockingReason(status),
    );
  }

  Future<VisionRuntimeCheck> _appleVisionCheck() async {
    final available = await onDeviceService.isAppleVisionAvailable();
    return available
        ? VisionRuntimeCheck.available(
            'Apple Vision',
            'Apple Vision OCR, scene, and person APIs are available.',
          )
        : VisionRuntimeCheck.unavailable(
            'Apple Vision',
            'Apple Vision APIs are unavailable on this device.',
          );
  }

  VisionRuntimeCheck _modelCheck(
    NativeModelDiagnostic diagnostic,
    bool available,
  ) {
    if (available || diagnostic.loaded) {
      return VisionRuntimeCheck.available(diagnostic.name, diagnostic.message);
    }
    if (diagnostic.bundleFound || diagnostic.compiledModelFound) {
      return VisionRuntimeCheck.degraded(diagnostic.name, diagnostic.message);
    }
    return VisionRuntimeCheck.unavailable(diagnostic.name, diagnostic.message);
  }

  VisionRuntimeCheck _smolRuntimeCheck(ModelStatus status) {
    return switch (status) {
      ModelStatus.notAvailable => VisionRuntimeCheck.unavailable(
        'SmolVLM2 runtime',
        'SmolVLM2 runtime is not linked into this build.',
      ),
      _ => VisionRuntimeCheck.available(
        'SmolVLM2 runtime',
        'SmolVLM2 runtime is linked.',
      ),
    };
  }

  VisionRuntimeCheck _smolModelCheck(ModelStatus status) {
    return switch (status) {
      ModelStatus.loaded => VisionRuntimeCheck.available(
        'SmolVLM2 models',
        'SmolVLM2 model is loaded.',
      ),
      ModelStatus.ready => VisionRuntimeCheck.available(
        'SmolVLM2 models',
        'SmolVLM2 model files are downloaded.',
      ),
      ModelStatus.downloading => VisionRuntimeCheck.degraded(
        'SmolVLM2 models',
        'SmolVLM2 model download is still in progress.',
      ),
      ModelStatus.notAvailable => VisionRuntimeCheck.unavailable(
        'SmolVLM2 models',
        'SmolVLM2 model support is unavailable in this build.',
      ),
      ModelStatus.notDownloaded => VisionRuntimeCheck.unavailable(
        'SmolVLM2 models',
        'SmolVLM2 model files are not downloaded.',
      ),
    };
  }

  Future<VisionRuntimeCheck> _cloudCheck({
    required bool includeNetworkCheck,
  }) async {
    if (!cloudService.isConfigured) {
      return VisionRuntimeCheck.unavailable(
        'Cloud describe',
        'Gemini API key/config is missing.',
      );
    }
    if (!includeNetworkCheck) {
      return VisionRuntimeCheck.degraded(
        'Cloud describe',
        'Gemini cloud describe is configured; network reachability was not checked.',
      );
    }
    final online = await _connectivity.hasInternet();
    return online
        ? VisionRuntimeCheck.available(
            'Cloud describe',
            'Gemini cloud describe is configured and network is reachable.',
          )
        : VisionRuntimeCheck.unavailable(
            'Cloud describe',
            'Network is not reachable.',
          );
  }

  String? _blockingReason(VisionRuntimeStatus status) {
    if (!status.nativeChannel.isAvailable) return status.nativeChannel.message;
    if (!status.appleVision.isAvailable) return status.appleVision.message;
    if (!status.cloudDescribeReady && !status.basicLocalVisionReady) {
      return status.cloudDescribe.message;
    }
    if (!status.eyeConnection.isAvailable) return status.eyeConnection.message;
    return null;
  }
}
