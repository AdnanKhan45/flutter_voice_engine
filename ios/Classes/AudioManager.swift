import AVFoundation
import Combine
import CommonCrypto
import Flutter

public class AudioManager {
    // Voice Bot Related
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }
    private var inputFormat: AVAudioFormat
    private var audioFormat: AVAudioFormat
    private var webSocketFormat: AVAudioFormat
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

        let session = AVAudioSession.sharedInstance()
        do {
            // Prefer HFP when AEC is on; avoid A2DP
            var sessionOptions = options
            if enableAEC {
                sessionOptions.remove(.allowBluetoothA2DP)
                sessionOptions.insert(.allowBluetooth)
            }

            try session.setCategory(category, mode: mode, options: sessionOptions)
            try session.setPreferredSampleRate(preferredSampleRate)
            try session.setPreferredIOBufferDuration(preferredBufferDuration)
            if session.isInputGainSettable {
                try session.setInputGain(1.0)
            }
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            print("Audio session configured: sr=\(session.sampleRate), outCh=\(session.outputNumberOfChannels), ioBuffer=\(session.ioBufferDuration), opts=\(session.categoryOptions.rawValue)")
        } catch {
            print("Failed to configure audio session: \(error)")
            errorPublisher.send("Audio session error: \(error.localizedDescription)")
        }

        // ---- Initialize required stored formats with safe placeholders ----
        let sr = session.sampleRate > 0 ? session.sampleRate : sampleRate

        // Input: float32, interleaved, channel count from param
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sr,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        // Mixer/output working format placeholder: float32, non-interleaved, 2ch
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sr,
            channels: 2,
            interleaved: false
        )!

        // Uplink/websocket format: int16 @ target sample rate, channels from param
        self.webSocketFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        // Converters will be built after engine starts (in setupEngine)
        self.recordingConverter = nil
        self.playbackConverter  = nil

        // setupEngine() will:
        // - start the engine + enable voice processing
        // - refresh inputFormat/audioFormat from actual hardware
        // - rebuild converters via setupConverters()
    }


    private func setupConverters() {
        recordingConverter = AVAudioConverter(from: inputFormat, to: webSocketFormat)
        playbackConverter = AVAudioConverter(from: webSocketFormat, to: audioFormat)
        if recordingConverter == nil || playbackConverter == nil {
            errorPublisher.send("Failed to initialize audio converters")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Failed to initialize audio converters"])
            }
        } else {
            print("Converters initialized: recording=\(inputFormat)->\(webSocketFormat), playback=\(webSocketFormat)->\(audioFormat)")
        }
    }

    public func setupEngine() {
        let session = AVAudioSession.sharedInstance()

        // Attach nodes
        audioEngine.attach(playerNode)

        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.mainMixerNode.outputVolume = 1.0

        do {
            try session.setActive(true)

            // Enable voice processing (may change the input node’s actual format)
            if enableAEC {
                try inputNode.setVoiceProcessingEnabled(true)
                print("Voice processing enabled for AEC")
            }

            try audioEngine.start()
            print("Audio engine started")

            // Refresh formats AFTER engine + voice processing are active
            let mixer = audioEngine.mainMixerNode
            self.inputFormat = inputNode.outputFormat(forBus: 0)
            self.audioFormat = mixer.outputFormat(forBus: 0)
            self.webSocketFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: inputFormat.channelCount,
                interleaved: true
            )!

            setupConverters()
            print("Formats: input=\(inputFormat), mixer=\(audioFormat), ws=\(webSocketFormat)")
        } catch {
            print("Failed to start audio engine or enable AEC: \(error)")
            errorPublisher.send("Engine error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Engine error: \(error.localizedDescription)"])
            }
        }
    }


    public func emitMusicIsPlaying() {
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.eventSink else {
                print("eventSink is nil, cannot send music state")
                return
            }
            print("Emitting music state: \(self?.musicIsPlaying ?? false)")
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
        guard let self = self,
              let currentItem = self.queuePlayer.currentItem,
              currentItem.status == .readyToPlay
        else { return }

        let rawPos  = CMTimeGetSeconds(self.queuePlayer.currentTime())
        let duration = CMTimeGetSeconds(currentItem.duration)
        // clamp between 0 and duration:
        let position = max(0, min(rawPos, duration))

        DispatchQueue.main.async {
          self.eventSink?([
            "type":     "music_position",
            "position": position,
            "duration": duration
          ])
        }
      }

      RunLoop.main.add(musicPositionTimer!, forMode: .common)
    }


    public func stopEmittingMusicPosition() {
        print("Stopping music position timer")
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
                    print("Downloaded track: \(urlStr) to \(localPath)")
                } catch {
                    print("Failed to move downloaded file: \(error)")
                    completion(nil)
                }
            } else {
                print("Failed to download music from \(urlStr): \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Failed to download music from \(urlStr)"])
                }
                completion(nil)
            }
        }
        task.resume()
    }

    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func installRecordingTap() {
        let bus = 0
        inputNode.removeTap(onBus: bus)

        // Use nil so the tap uses the node’s native (hardware) format
        inputNode.installTap(onBus: bus, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Rebuild converter if route/format changed
            if self.recordingConverter == nil || self.recordingConverter?.inputFormat != buffer.format {
                self.recordingConverter = AVAudioConverter(from: buffer.format, to: self.webSocketFormat)
                if self.recordingConverter == nil {
                    self.errorPublisher.send("Failed to init recording converter")
                    DispatchQueue.main.async { self.eventSink?(["type":"error","message":"Failed to init recording converter"]) }
                    return
                }
            }

            guard let converter = self.recordingConverter else { return }

            let frameCapacity = UInt32(round(Double(buffer.frameLength) * converter.outputFormat.sampleRate / buffer.format.sampleRate))
            guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
                DispatchQueue.main.async { self.eventSink?(["type":"error","message":"Failed to create output buffer"]) }
                return
            }

            var convErr: NSError?
            let status = converter.convert(to: out, error: &convErr) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error = convErr {
                self.errorPublisher.send("Recording conversion error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.eventSink?(["type": "error", "message": "Recording conversion error: \(error.localizedDescription)"])
                }
                return
            }
            if status == .error {
                self.errorPublisher.send("Recording conversion failed")
                DispatchQueue.main.async {
                    self.eventSink?(["type": "error", "message": "Recording conversion failed"])
                }
                return
            }
            
            guard out.frameLength > 0 else { return }

            if let ptr = out.int16ChannelData?.pointee {
                let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size * Int(out.format.channelCount)
                self.audioChunkPublisher.send(Data(bytes: ptr, count: bytes))
            } else {
                DispatchQueue.main.async { self.eventSink?(["type":"error","message":"No audio data in output buffer"]) }
            }
        }
    }


    public func startRecording() -> AnyPublisher<Data, Never> {
        guard !isRecording else { return audioChunkPublisher.eraseToAnyPublisher() }
        isRecording = true

        // ✅ Defensive: ensure engine is running before installing the tap
        if !audioEngine.isRunning {
            do { try audioEngine.start() } catch {
                errorPublisher.send("Engine start failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type":"error","message":"Engine start failed: \(error.localizedDescription)"])
                }
                return audioChunkPublisher.eraseToAnyPublisher()
            }
        }

        print("Starting recording with wsFormat=\(webSocketFormat)")
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
        print("Received playback chunk, size: \(audioData.count) bytes")
        let frameCount = AVAudioFrameCount(audioData.count / (MemoryLayout<Int16>.size * Int(self.webSocketFormat.channelCount)))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: webSocketFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create input buffer"])
        }
        inputBuffer.frameLength = frameCount
        audioData.withUnsafeBytes { rawBuffer in
            inputBuffer.int16ChannelData?.pointee.update(from: rawBuffer.baseAddress!.assumingMemoryBound(to: Int16.self), count: Int(frameCount * webSocketFormat.channelCount))
        }
        let outputFrameCapacity = UInt32(round(Double(frameCount) * audioFormat.sampleRate / webSocketFormat.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(outputFrameCapacity)) else {
            throw NSError(domain: "AudioManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
        }
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let error = error {
            throw error
        }
        if status == .error {
            throw NSError(domain: "AudioManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "Playback conversion failed"])
        }
        playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
            print("Started playback")
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

        // stop and clear background music
        queuePlayer.pause()
        playerLooper?.disableLooping()
        playlistItems.removeAll()
        stopEmittingMusicPosition()

        // tear down audio engine
        audioEngine.stop()
        cancellables.removeAll()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Failed to deactivate audio session: \(error.localizedDescription)"])
            }
        }
        print("AudioManager shutdown (bot + music)")
    }

    public func handleConfigurationChange() {
        print("Audio engine configuration changed")
        if !audioEngine.isRunning {
            print("Engine stopped, attempting to restart")
            do {
                try audioEngine.start()
                //  Refresh formats; converters may be invalid after a route change
                self.inputFormat = inputNode.outputFormat(forBus: 0)
                self.audioFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
                setupConverters()

                if isRecording {
                    print("Reinstalling recording tap")
                    installRecordingTap()
                }
            } catch {
                print("Failed to restart audio engine: \(error)")
                errorPublisher.send("Engine restart failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Engine restart failed: \(error.localizedDescription)"])
                }
            }
        }
    }


    public func isRecordingActive() -> Bool {
        return isRecording
    }

    
    
    
    
    // ----------------- Background Music Work ---------------------
    
    /// Replace your existing `setMusicPlaylist(_:)` with this:
    // 1) setMusicPlaylist: just builds your array of AVPlayerItems (remote or local). We no longer enqueue them here.
    public func setMusicPlaylist(_ urls: [String]) {
        // 1) Tear down any existing queue/looper
        playerLooper?.disableLooping()
        queuePlayer.removeAllItems()
        
        // 2) Build AVPlayerItems from AVURLAssets, kick off an async preload of the 'playable' & 'duration' keys
        playlistItems = urls.compactMap { urlStr in
            let assetURL: URL
            if isRemoteURL(urlStr), let u = URL(string: urlStr) {
                assetURL = u
            } else {
                assetURL = URL(fileURLWithPath: urlStr)
            }
            
            let asset = AVURLAsset(url: assetURL)
            // prime the asset so metadata & first frames are ready
            asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) {
                // you could inspect statusOfValue here if you need to error-handle
            }
            
            let item = AVPlayerItem(asset: asset)
            // buffer at least a few seconds before playback
            item.preferredForwardBufferDuration = 5.0
            return item
        }
    }



    
    /// Play a single file, optionally looping
    public func playBackgroundMusic(source: String, loop: Bool = true) {
        // Create the item
        let url = URL(fileURLWithPath: source)
        let item = AVPlayerItem(url: url)
        queuePlayer.removeAllItems()
        queuePlayer.insert(item, after: nil)

        if loop {
          // Attach an AVPlayerLooper to keep it seamlessly looping
          playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
          playerLooper?.disableLooping()
        }

        queuePlayer.play()
        musicIsPlaying = true
        emitMusicIsPlaying()
        startEmittingMusicPosition()
    }
    
    /// Replace your existing `playTrackAtIndex(_:)` with this:
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
        emitMusicIsPlaying()         // → sends {"type":"music_state","state": false}
        playerLooper?.disableLooping()
    }
    
    // 3) seekBackgroundMusic: seeks the queuePlayer and resumes if needed
    public func seekBackgroundMusic(to position: Double) {
        let cm = CMTime(seconds: position, preferredTimescale: 1_000)
        queuePlayer.seek(to: cm) { [weak self] _ in
            guard let self = self else { return }
            // resume only if it was already playing
            if self.musicIsPlaying {
                self.queuePlayer.play()
            }
        }
    }

}
