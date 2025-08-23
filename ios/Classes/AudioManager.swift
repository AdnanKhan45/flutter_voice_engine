import AVFoundation
import Combine
import CommonCrypto
import Flutter

public class AudioManager {
    // Voice Bot Related
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }
    private var inputFormat: AVAudioFormat!
    private var audioFormat: AVAudioFormat!
    private var webSocketFormat: AVAudioFormat!
    private var isRecording = false
    private let audioChunkPublisher = PassthroughSubject<Data, Never>()
    public let errorPublisher = PassthroughSubject<String, Never>()
    private var recordingConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private let amplitudeThreshold: Float
    private let enableAEC: Bool
    private var cancellables = Set<AnyCancellable>()
    private let targetSampleRate: Float64 = 24000
    
    // Background Music Related
    private var queuePlayer: AVQueuePlayer = AVQueuePlayer()
    private var playerLooper: AVPlayerLooper?
    private var playlistItems: [AVPlayerItem] = []
    private var musicPositionTimer: Timer?
    public var musicIsPlaying = false
    public var eventSink: FlutterEventSink?
    
    // CRITICAL FIX: Track engine setup state
    private var isEngineSetup = false
    
    public init(
        channels: UInt32 = 1,
        sampleRate: Double = 48000,
        bitDepth: Int = 16,
        bufferSize: Int = 4096,
        amplitudeThreshold: Float = 0.05,
        enableAEC: Bool = true,
        category: AVAudioSession.Category = .playAndRecord,
        mode: AVAudioSession.Mode = .spokenAudio,
        options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP],
        preferredSampleRate: Double = 48000,
        preferredBufferDuration: Double = 0.005
    ) {
        self.amplitudeThreshold = amplitudeThreshold
        self.enableAEC = enableAEC
        
        // CRITICAL FIX: Don't configure audio session in init - do it in setupEngine
        // Just store the parameters for later use
        print("AudioManager init completed - formats will be created in setupEngine")
    }
    
    public func setupEngine() {
        print("Setting up audio engine...")
        
        // CRITICAL FIX: Only configure audio session here, once
        configureAudioSession()
        
        // CRITICAL FIX: Only disconnect if engine was previously setup
        if isEngineSetup {
            if audioEngine.attachedNodes.contains(playerNode) {
                audioEngine.disconnectNodeOutput(playerNode)
                audioEngine.detach(playerNode)
            }
        }
        
        // Reset engine if running
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        guard let audioFormat = audioFormat else {
            print("❌ Cannot setup engine: audioFormat not initialized")
            return
        }
        
        // Attach and connect nodes
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: nil) // Use default format
        audioEngine.mainMixerNode.outputVolume = 1.0
        
        // Start engine and enable AEC
        do {
            if enableAEC {
                try inputNode.setVoiceProcessingEnabled(true)
                print("✅ Voice processing (AEC) enabled")
            }
            
            try audioEngine.start()
            isEngineSetup = true
            print("✅ Audio engine started successfully")
            
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            errorPublisher.send("Engine start error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Engine start error: \(error.localizedDescription)"])
            }
        }
    }
    
    // CRITICAL FIX: Simplified audio session configuration
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Set category first
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
            print("✅ Audio category set successfully")
            
            // Set preferred settings
            try session.setPreferredSampleRate(48000.0)
            try session.setPreferredIOBufferDuration(0.005)
            
            // Activate session
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            print("✅ Audio session activated")
            
            // Get actual hardware capabilities
            let actualSampleRate = session.sampleRate
            let actualInputChannels = session.inputNumberOfChannels
            
            print("📊 Actual audio session: sampleRate=\(actualSampleRate), inputCh=\(actualInputChannels)")
            
            // CRITICAL FIX: Create formats based on actual hardware
            guard actualInputChannels > 0 else {
                throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No input channels available"])
            }
            
            // Use actual sample rate from hardware
            self.inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: actualSampleRate,
                channels: 1,
                interleaved: true
            )
            
            self.audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: actualSampleRate,
                channels: 2,
                interleaved: false
            )
            
            self.webSocketFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
            )
            
            // Validate formats
            guard let inputFormat = self.inputFormat,
                  let audioFormat = self.audioFormat,
                  let webSocketFormat = self.webSocketFormat else {
                throw NSError(domain: "AudioManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create valid audio formats"])
            }
            
            print("✅ Audio formats created successfully")
            print("   Input: \(inputFormat)")
            print("   Output: \(audioFormat)")
            print("   WebSocket: \(webSocketFormat)")
            
            // Setup converters
            setupConverters()
            
        } catch {
            print("❌ Failed to configure audio session: \(error)")
            errorPublisher.send("Audio session error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Audio session error: \(error.localizedDescription)"])
            }
        }
    }
    
    private func setupConverters() {
        guard let inputFormat = inputFormat,
              let audioFormat = audioFormat,
              let webSocketFormat = webSocketFormat else {
            print("❌ Cannot setup converters: formats not initialized")
            return
        }
        
        recordingConverter = AVAudioConverter(from: inputFormat, to: webSocketFormat)
        playbackConverter = AVAudioConverter(from: webSocketFormat, to: audioFormat)
        
        guard recordingConverter != nil, playbackConverter != nil else {
            let error = "Failed to initialize audio converters"
            print("❌ \(error)")
            errorPublisher.send(error)
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": error])
            }
            return
        }
        
        print("✅ Converters initialized successfully")
    }
    
    // CRITICAL FIX: Safer tap installation
    private func installRecordingTap() {
        let bus = 0
        inputNode.removeTap(onBus: bus)
        
        guard let converter = recordingConverter else {
            print("❌ Cannot install tap: missing converter")
            return
        }
        
        // Use input node's actual format
        let tapFormat = inputNode.inputFormat(forBus: bus)
        print("📊 Installing tap with format: \(tapFormat)")
        
        // CRITICAL FIX: If format changed, recreate converter
        if tapFormat != inputFormat {
            print("⚠️ Format mismatch, recreating converter")
            recordingConverter = AVAudioConverter(from: tapFormat, to: webSocketFormat!)
            guard recordingConverter != nil else {
                print("❌ Failed to recreate recording converter")
                return
            }
        }
        
        inputNode.installTap(onBus: bus, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.processRecordingBuffer(buffer)
        }
        
        print("✅ Recording tap installed successfully")
    }
    
    private func processRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = recordingConverter else { return }
        
        let frameCapacity = UInt32(round(Double(buffer.frameLength) * converter.outputFormat.sampleRate / buffer.format.sampleRate))
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            return
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        guard error == nil, status != .error, let data = outputBuffer.int16ChannelData?.pointee else {
            return
        }
        
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size * Int(outputBuffer.format.channelCount)
        let audioData = Data(bytes: data, count: byteCount)
        audioChunkPublisher.send(audioData)
    }
    
    public func startRecording() -> AnyPublisher<Data, Never> {
        guard !isRecording else {
            print("Already recording")
            return audioChunkPublisher.eraseToAnyPublisher()
        }
        
        isRecording = true
        print("Starting recording...")
        installRecordingTap()
        return audioChunkPublisher.eraseToAnyPublisher()
    }
    
    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        inputNode.removeTap(onBus: 0)
        print("Recording stopped")
    }
    
    public func playAudioChunk(audioData: Data) throws {
        guard audioEngine.isRunning, let converter = playbackConverter else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine or converter unavailable"])
        }
        
        let frameCount = AVAudioFrameCount(audioData.count / (MemoryLayout<Int16>.size * Int(webSocketFormat!.channelCount)))
        
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: webSocketFormat!, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create input buffer"])
        }
        
        inputBuffer.frameLength = frameCount
        audioData.withUnsafeBytes { rawBuffer in
            inputBuffer.int16ChannelData?.pointee.update(
                from: rawBuffer.baseAddress!.assumingMemoryBound(to: Int16.self),
                count: Int(frameCount * webSocketFormat!.channelCount)
            )
        }
        
        let outputFrameCapacity = UInt32(round(Double(frameCount) * audioFormat!.sampleRate / webSocketFormat!.sampleRate))
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat!, frameCapacity: outputFrameCapacity) else {
            throw NSError(domain: "AudioManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if let error = error { throw error }
        if status == .error {
            throw NSError(domain: "AudioManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Playback conversion failed"])
        }
        
        playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
    
    public func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
        print("Playback stopped")
    }
    
    public func shutdownBot() {
        stopRecording()
        stopPlayback()
        print("Bot stopped, music continues if playing.")
    }
    
    public func shutdownAll() {
        stopRecording()
        stopPlayback()
        
        // Stop music
        queuePlayer.pause()
        playerLooper?.disableLooping()
        playlistItems.removeAll()
        stopEmittingMusicPosition()
        
        // Stop engine
        if isEngineSetup {
            audioEngine.stop()
            isEngineSetup = false
        }
        cancellables.removeAll()
        
        // Deactivate session
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        print("AudioManager shutdown complete")
    }
    
    // CRITICAL FIX: Simpler configuration change handling
    public func handleConfigurationChange() {
        print("⚠️ Audio engine configuration changed")
        
        if !audioEngine.isRunning && isEngineSetup {
            print("Engine stopped, restarting...")
            setupEngine()
        }
    }
    
    // Music methods remain the same...
    public func emitMusicIsPlaying() {
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.eventSink else { return }
            sink(["type": "music_state", "state": self?.musicIsPlaying ?? false])
        }
    }
    
    public func setBackgroundMusicVolume(_ volume: Float) {
        queuePlayer.volume = volume
    }
    
    public func getBackgroundMusicVolume() -> Float {
        return queuePlayer.volume
    }
    
    public func startEmittingMusicPosition() {
        stopEmittingMusicPosition()
        musicPositionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let currentItem = self.queuePlayer.currentItem, currentItem.status == .readyToPlay else { return }
            let rawPos = CMTimeGetSeconds(self.queuePlayer.currentTime())
            let duration = CMTimeGetSeconds(currentItem.duration)
            let position = max(0, min(rawPos, duration))
            DispatchQueue.main.async {
                self.eventSink?(["type": "music_position", "position": position, "duration": duration])
            }
        }
        RunLoop.main.add(musicPositionTimer!, forMode: .common)
    }
    
    public func stopEmittingMusicPosition() {
        musicPositionTimer?.invalidate()
        musicPositionTimer = nil
    }
    
    private func isRemoteURL(_ source: String) -> Bool {
        return source.lowercased().hasPrefix("http://") || source.lowercased().hasPrefix("https://")
    }
    
    private func downloadToTemp(_ urlStr: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlStr) else { completion(nil); return }
        let tempDir = FileManager.default.temporaryDirectory
        let filename = md5(urlStr) + (url.pathExtension.isEmpty ? ".mp3" : ".\(url.pathExtension)")
        let localPath = tempDir.appendingPathComponent(filename).path
        if FileManager.default.fileExists(atPath: localPath) {
            completion(localPath)
            return
        }
        
        let task = URLSession.shared.downloadTask(with: url) { (tempURL, _, error) in
            if let tempURL = tempURL, error == nil {
                do {
                    try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: localPath))
                    completion(localPath)
                } catch {
                    print("Failed to move downloaded file: \(error)")
                    completion(nil)
                }
            } else {
                print("Failed to download music from \(urlStr): \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
            }
        }
        task.resume()
    }
    
    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    public func setMusicPlaylist(_ urls: [String]) {
        playerLooper?.disableLooping()
        queuePlayer.removeAllItems()
        playlistItems = urls.compactMap { urlStr in
            let assetURL: URL
            if isRemoteURL(urlStr), let u = URL(string: urlStr) {
                assetURL = u
            } else {
                assetURL = URL(fileURLWithPath: urlStr)
            }
            let asset = AVURLAsset(url: assetURL)
            asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) { }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 5.0
            return item
        }
    }
    
    public func playBackgroundMusic(source: String, loop: Bool = true) {
        let url = URL(fileURLWithPath: source)
        let item = AVPlayerItem(url: url)
        queuePlayer.removeAllItems()
        queuePlayer.insert(item, after: nil)
        if loop {
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            playerLooper?.disableLooping()
        }
        queuePlayer.play()
        musicIsPlaying = true
        emitMusicIsPlaying()
        startEmittingMusicPosition()
    }
    
    public func playTrackAtIndex(_ index: Int) {
        guard index >= 0 && index < playlistItems.count else {
            eventSink?(["type":"error","message":"Invalid track index"])
            return
        }
        playerLooper?.disableLooping()
        queuePlayer.pause()
        queuePlayer.removeAllItems()
        let template = playlistItems[index]
        queuePlayer.insert(template, after: nil)
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: template)
        queuePlayer.play()
        musicIsPlaying = true
        emitMusicIsPlaying()
        startEmittingMusicPosition()
    }
    
    public func stopBackgroundMusic() {
        queuePlayer.pause()
        musicIsPlaying = false
        stopEmittingMusicPosition()
        emitMusicIsPlaying()
        playerLooper?.disableLooping()
    }
    
    public func seekBackgroundMusic(to position: Double) {
        let cm = CMTime(seconds: position, preferredTimescale: 1_000)
        queuePlayer.seek(to: cm) { [weak self] _ in
            guard let self = self else { return }
            if self.musicIsPlaying {
                self.queuePlayer.play()
            }
        }
    }
    
    public func isRecordingActive() -> Bool {
        return isRecording
    }
}
