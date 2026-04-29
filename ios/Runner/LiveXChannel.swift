import Foundation
import Flutter

class LiveXChannel: NSObject, FlutterStreamHandler, WiFiStreamReceiverDelegate {
    private var eventSink: FlutterEventSink?
    private let receiver = WiFiStreamReceiver()
    
    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterEventChannel(name: "com.ican/livex_stream", binaryMessenger: messenger)
        let instance = LiveXChannel()
        channel.setStreamHandler(instance)
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        receiver.delegate = self
        receiver.start()
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        receiver.stop()
        self.eventSink = nil
        return nil
    }
    
    // MARK: - WiFiStreamReceiverDelegate
    
    func didReassembleFrame(_ data: Data) {
        // Send frame to Flutter as FlutterStandardTypedData
        DispatchQueue.main.async {
            self.eventSink?(FlutterStandardTypedData(bytes: data))
        }
    }
}
