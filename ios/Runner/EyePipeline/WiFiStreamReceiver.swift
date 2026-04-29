import Foundation
import Network

protocol WiFiStreamReceiverDelegate: AnyObject {
    func didReassembleFrame(_ data: Data)
}

class WiFiStreamReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let port: NWEndpoint.Port = 8080
    
    weak var delegate: WiFiStreamReceiverDelegate?
    
    private var frameBuffer = Data()
    
    // JPEG Magic Bytes
    private let jpegStart = Data([0xFF, 0xD8])
    private let jpegEnd = Data([0xFF, 0xD9])
    
    func start() {
        do {
            let parameters = NWParameters.udp
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { state in
                print("[WiFiStreamReceiver] Listener state: \(state)")
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                print("[WiFiStreamReceiver] New connection: \(newConnection)")
                self?.connection = newConnection
                self?.connection?.start(queue: .main)
                self?.receiveLoop()
            }
            
            listener?.start(queue: .main)
        } catch {
            print("[WiFiStreamReceiver] Failed to start listener: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        connection?.cancel()
    }
    
    private func receiveLoop() {
        connection?.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[WiFiStreamReceiver] Receive error: \(error)")
                return
            }
            
            if let data = content, !data.isEmpty {
                self.processChunk(data)
            }
            
            self.receiveLoop()
        }
    }
    
    private func processChunk(_ data: Data) {
        frameBuffer.append(data)
        
        // Very basic JPEG reassembly: look for End of Image marker
        if let endIndex = frameBuffer.range(of: jpegEnd, options: .backwards) {
            let frameEndIndex = endIndex.upperBound
            
            if let startIndex = frameBuffer.range(of: jpegStart) {
                if startIndex.lowerBound < frameEndIndex {
                    let frameData = frameBuffer[startIndex.lowerBound..<frameEndIndex]
                    delegate?.didReassembleFrame(Data(frameData))
                }
            }
            
            // Remove the processed part
            frameBuffer.removeSubrange(0..<frameEndIndex)
        }
        
        // Optional: clear buffer if it gets too large (e.g. dropped packets)
        if frameBuffer.count > 1024 * 1024 { // 1MB limit
            print("[WiFiStreamReceiver] Buffer exceeded limit, clearing")
            frameBuffer.removeAll()
        }
    }
}
