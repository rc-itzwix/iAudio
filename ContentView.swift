import SwiftUI
import AVFoundation
import Network

struct MicInputOption: Hashable {
    let id: String
    let name: String
    let portUID: String
    let dataSourceID: NSNumber?
}

class StreamSettings: ObservableObject {
    @AppStorage("connectionMode") var connectionMode: String = "Network" // Network или USB
    @AppStorage("ipAddress") var ipAddress: String = "192.168.1.100"
    @AppStorage("port") var port: String = "12345"
    @AppStorage("sampleRate") var sampleRate: Double = 48000.0
    @AppStorage("channels") var channels: Int = 1
    @AppStorage("bitDepth") var bitDepth: String = "Int16"
    @AppStorage("protocolType") var protocolType: String = "UDP"
    @AppStorage("bufferSize") var bufferSize: Int = 1024
    @AppStorage("keepAwake") var keepAwake: Bool = true
    @AppStorage("hapticFeedback") var hapticFeedback: Bool = true
    @AppStorage("selectedMicID") var selectedMicID: String = ""
    @Published var activeMic: MicInputOption? = nil
}

class AudioStreamer: ObservableObject {
    @Published var isStreaming = false
    @Published var usbConnected = false
    
    private var audioEngine = AVAudioEngine()
    private var connection: NWConnection?
    private var listener: NWListener?
    
    func start(config: StreamSettings) {
        let portNum = NWEndpoint.Port(config.port) ?? 12345
        
        if config.connectionMode == "Network" {
            let host = NWEndpoint.Host(config.ipAddress)
            let params: NWParameters = config.protocolType == "TCP" ? .tcp : .udp
            connection = NWConnection(host: host, port: portNum, using: params)
            connection?.start(queue: .global())
            setupAudio(config: config)
        } else {
            // USB Mode (TCP Server)
            do {
                listener = try NWListener(using: .tcp, on: portNum)
                listener?.newConnectionHandler = { newConn in
                    self.connection = newConn
                    newConn.stateUpdateHandler = { state in
                        DispatchQueue.main.async { self.usbConnected = state == .ready }
                    }
                    newConn.start(queue: .global())
                }
                listener?.start(queue: .global())
                setupAudio(config: config)
            } catch { print("Listener Error: \(error)") }
        }
    }
    
    private func setupAudio(config: StreamSettings) {
        UIApplication.shared.isIdleTimerDisabled = config.keepAwake
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        
        if let targetMic = config.activeMic, let inputs = session.availableInputs {
            if let port = inputs.first(where: { $0.uid == targetMic.portUID }) {
                try? session.setPreferredInput(port)
            }
        }
        
        try? session.setPreferredSampleRate(config.sampleRate)
        try? session.setActive(true)
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = AVAudioFormat(
            commonFormat: config.bitDepth == "Int16" ? .pcmFormatInt16 : .pcmFormatFloat32,
            sampleRate: session.sampleRate,
            channels: AVAudioChannelCount(config.channels),
            interleaved: true
        )!
        
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(config.bufferSize), format: inputFormat) { buffer, _ in
            let frameCount = AVAudioFrameCount(outputFormat.sampleRate / 100)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }
            var error: NSError?
            converter?.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let data = self.toData(buffer: outBuffer) {
                self.connection?.send(content: data, completion: .contentProcessed({ _ in }))
            }
        }
        
        try? audioEngine.start()
        DispatchQueue.main.async { self.isStreaming = true }
        if config.hapticFeedback { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    }
    
    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        connection?.cancel()
        listener?.cancel()
        isStreaming = false
        usbConnected = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    private func toData(buffer: AVAudioPCMBuffer) -> Data? {
        let frameLength = Int(buffer.frameLength)
        if buffer.format.commonFormat == .pcmFormatInt16 {
            guard let channelData = buffer.int16ChannelData else { return nil }
            return Data(bytes: channelData[0], count: frameLength * 2)
        } else {
            guard let channelData = buffer.floatChannelData else { return nil }
            return Data(bytes: channelData[0], count: frameLength * 4)
        }
    }
}

struct MainView: View {
    @ObservedObject var streamer: AudioStreamer
    @ObservedObject var settings: StreamSettings
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Text(settings.connectionMode == "USB" ? "РЕЖИМ: КАБЕЛЬ (USB)" : "РЕЖИМ: СЕТЬ (IP)")
                    .font(.caption).foregroundColor(.gray).padding(.top)
                
                Spacer()
                ZStack {
                    if streamer.isStreaming { WaveView() }
                    Button(action: { streamer.isStreaming ? streamer.stop() : streamer.start(config: settings) }) {
                        Image(systemName: streamer.isStreaming ? (settings.connectionMode == "USB" && !streamer.usbConnected ? "cable.connector.slash" : "mic.fill") : "mic.slash.fill")
                            .font(.system(size: 100))
                            .foregroundColor(streamer.isStreaming ? (settings.connectionMode == "USB" && !streamer.usbConnected ? .orange : .blue) : .white)
                            .frame(width: 160, height: 160)
                    }
                }
                
                if settings.connectionMode == "USB" && streamer.isStreaming {
                    Text(streamer.usbConnected ? "СОЕДИНЕНИЕ УСТАНОВЛЕНО" : "ОЖИДАНИЕ ПОДКЛЮЧЕНИЯ ПК...")
                        .font(.caption).foregroundColor(streamer.usbConnected ? .green : .orange).padding()
                }
                
                Spacer()
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: StreamSettings
    @State private var availableOptions: [MicInputOption] = []
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Тип подключения")) {
                    Picker("Метод", selection: $settings.connectionMode) {
                        Text("Сеть (IP)").tag("Network")
                        Text("Кабель (USB)").tag("USB")
                    }.pickerStyle(.segmented)
                }
                
                Section(header: Text("Параметры связи")) {
                    if settings.connectionMode == "Network" {
                        HStack {
                            Text("IP-адрес")
                            TextField("192.168.1.1", text: $settings.ipAddress)
                                .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                        }
                    }
                    HStack {
                        Text("Порт")
                        TextField("12345", text: $settings.port)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    if settings.connectionMode == "Network" {
                        Picker("Протокол", selection: $settings.protocolType) {
                            Text("UDP").tag("UDP")
                            Text("TCP").tag("TCP")
                        }
                    }
                }
                
                Section(header: Text("Аудио")) {
                    Picker("Устройство", selection: $settings.activeMic) {
                        Text("Авто").tag(nil as MicInputOption?)
                        ForEach(availableOptions, id: \.self) { Text($0.name).tag($0 as MicInputOption?) }
                    }
                    Picker("Частота", selection: $settings.sampleRate) {
                        Text("44.1 кГц").tag(44100.0)
                        Text("48.0 кГц").tag(48000.0)
                    }
                }
            }
            .navigationTitle("Настройки")
            .onAppear { refreshDevices() }
        }
    }
    
    func refreshDevices() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        var options: [MicInputOption] = []
        if let inputs = session.availableInputs {
            for input in inputs {
                let newOption = MicInputOption(id: input.uid, name: input.portName, portUID: input.uid, dataSourceID: nil)
                options.append(newOption)
            }
        }
        availableOptions = options
    }
}

struct WaveView: View {
    @State private var wave = false
    var body: some View {
        Circle().fill(Color.blue.opacity(0.2)).frame(width: 140, height: 140)
            .scaleEffect(wave ? 4 : 1).opacity(wave ? 0 : 1)
            .animation(.easeOut(duration: 2).repeatForever(autoreverses: false), value: wave)
            .onAppear { wave = true }
    }
}

struct ContentView: View {
    @StateObject var streamer = AudioStreamer()
    @StateObject var settings = StreamSettings()
    var body: some View {
        TabView {
            MainView(streamer: streamer, settings: settings)
                .tabItem { Label("Микрофон", systemImage: "waveform") }
            SettingsView(settings: settings)
                .tabItem { Label("Настройки", systemImage: "gear") }
        }
        .onAppear { AVAudioSession.sharedInstance().requestRecordPermission { _ in } }
    }
}
