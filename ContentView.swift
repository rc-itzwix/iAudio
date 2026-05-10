import SwiftUI
import AVFoundation
import Network

struct ContentView: View {
    @State private var isStreaming = false
    @State private var ipAddress = "192.168.137.1"
    @State private var port = "12345"
    
    // Аудио и сеть
    @State private var audioEngine = AVAudioEngine()
    @State private var connection: NWConnection?
    
    var body: some View {
        VStack(spacing: 30) {
            Text("iAudio Mic")
                .font(.largeTitle)
                .bold()
            
            TextField("IP Address", text: $ipAddress)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
                .keyboardType(.numbersAndPunctuation)
            
            Button(action: {
                if isStreaming {
                    stopStreaming()
                } else {
                    requestMicAndStart()
                }
            }) {
                Text(isStreaming ? "Stop Streaming" : "Start Streaming")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 250, height: 60)
                    .background(isStreaming ? Color.red : Color.green)
                    .cornerRadius(15)
            }
        }
        .padding()
    }
    
    func requestMicAndStart() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if granted {
                DispatchQueue.main.async {
                    self.startStreaming()
                }
            }
        }
    }
    
    func startStreaming() {
        let host = NWEndpoint.Host(ipAddress)
        let portNum = NWEndpoint.Port(port) ?? 12345
        connection = NWConnection(host: host, port: portNum, using: .udp)
        connection?.start(queue: .global())
        
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try? audioSession.setPreferredSampleRate(48000)
        try? audioSession.setActive(true)
        
        let inputNode = audioEngine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
        
        inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { (buffer, time) in
            guard let channelData = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
            self.connection?.send(content: data, completion: .contentProcessed({ error in
                if let err = error { print("UDP Error: \(err)") }
            }))
        }
        
        try? audioEngine.start()
        isStreaming = true
    }
    
    func stopStreaming() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        connection?.cancel()
        isStreaming = false
    }
}
