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

    // Route change observer token
    private var routeChangeObserver: Any?

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
            try session.setCategory(category, mode: mode, options: options)
            try session.setPreferredSampleRate(preferredSampleRate)
            try session.setPreferredIOBufferDuration(preferredBufferDuration)
            // setInputGain may throw if device doesn't allow it; ignore errors
            if session.isInputGainSettable {
                try session.setInputGain(1.0)
            }
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            let appliedOptions = session.categoryOptions.rawValue
            print("Audio session configured: sampleRate=\(session.sampleRate), channels=\(session.outputNumberOfChannels), inputGain=\(session.inputGain), options=\(appliedOptions), bufferDuration=\(session.ioBufferDuration)")
            // Fallback safety already handled in original code; keep as-is
        } catch {
            print("Failed to configure audio session: \(error)")
            errorPublisher.send("Audio session error: \(error.localizedDescription)")
        }

        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: session.sampleRate,
            channels: channels,
            interleaved: true
        )!
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: session.sampleRate,
            channels: 2,
            interleaved: false
        )!
        self.webSocketFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: channels,
            interleaved: true
        )!
        setupConverters()

        // observe route changes (headset plug/unplug / BT connect/disconnect)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification: notification)
        }
    }

    deinit {
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
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
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: audioFormat)
        audioEngine.mainMixerNode.outputVolume = 1.0

        let session = AVAudioSession.sharedInstance()
        do {
            // ensure session active
            try session.setActive(true)

            // Route according to whether headset is connected
            try routeAudioAccordingToHeadset()

            // enable voice processing (AEC) on input node if requested and supported
            if enableAEC {
                if #available(iOS 13.0, *) {
                    do {
                        try inputNode.setVoiceProcessingEnabled(true)
                        print("Voice processing enabled for AEC")
                    } catch {
                        print("Failed to enable voice processing on input node: \(error)")
                    }
                } else {
                    // older iOS - voice processing not available on inputNode
                    print("Voice processing not available before iOS 13")
                }
            }

            try audioEngine.start()
            print("Audio engine started with outputFormat=\(audioFormat)")
        } catch {
            print("Failed to start audio engine or enable AEC: \(error)")
            errorPublisher.send("Engine error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(["type": "error", "message": "Engine error: \(error.localizedDescription)"])
            }
        }
    }

    // MARK: - Route handling

    private func isHeadsetConnected() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        for out in outputs {
            switch out.portType {
            case .headphones, .headsetMic:
                return true
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func routeAudioAccordingToHeadset() throws {
        let session = AVAudioSession.sharedInstance()
        // Re-apply category to ensure options are respected; keep playAndRecord for AEC
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        // if headset connected -> clear any speaker override so system routes to the headset
        if isHeadsetConnected() {
            print("Headset detected (iOS). Clearing speaker override to route to headset.")
            do {
                try session.overrideOutputAudioPort(.none)
            } catch {
                print("overrideOutputAudioPort(.none) failed: \(error)")
            }
            // if bluetooth SCO/HFP is available you might want to start bluetooth audio:
            // Note: starting bluetooth SCO programmatically is limited; iOS will route to BT if paired and allowed by category
        } else {
            // no headset -> route to speaker (loud)
            print("No headset detected (iOS). Forcing speaker output.")
            do {
                try session.overrideOutputAudioPort(.speaker)
            } catch {
                print("overrideOutputAudioPort(.speaker) failed: \(error)")
            }
            // We cannot set system volume programmatically; routing to speaker gives louder output.
        }
    }

    private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        if let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) {
            print("Audio route changed: \(reason)")
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
                // re-evaluate routing
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        try self?.routeAudioAccordingToHeadset()
                        // if engine is running and recording, reinstall tap to adapt formats if needed
                        if let self = self, self.audioEngine.isRunning {
                            if self.isRecording {
                                print("Reinstalling recording tap after route change")
                                self.installRecordingTap()
                            }
                        }
                    } catch {
                        print("Error re-routing audio after route change: \(error)")
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Recording tap & processing

    private func installRecordingTap() {
        let bus = 0
        inputNode.removeTap(onBus: bus)
        inputNode.installTap(onBus: bus, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.recordingConverter else {
                self?.errorPublisher.send("Recording converter unavailable")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Recording converter unavailable"])
                }
                return
            }
            let amplitude = buffer.floatChannelData?.pointee.withMemoryRebound(to: Float.self, capacity: Int(buffer.frameLength)) { ptr in
                (0..<Int(buffer.frameLength)).reduce(0.0) { max($0, abs(ptr[$1])) }
            } ?? 0
            let frameCapacity = UInt32(round(Double(buffer.frameLength) * converter.outputFormat.sampleRate / buffer.format.sampleRate))
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: frameCapacity
            ) else {
                self.errorPublisher.send("Failed to create output buffer")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Failed to create output buffer"])
                }
                return
            }
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error = error {
                self.errorPublisher.send("Recording conversion error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Recording conversion error: \(error.localizedDescription)"])
                }
                return
            }
            if status == .error {
                self.errorPublisher.send("Recording conversion failed")
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "Recording conversion failed"])
                }
                return
            }
            if let dataPtr = outputBuffer.int16ChannelData?.pointee {
                let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size * Int(outputBuffer.format.channelCount)
                let audioData = Data(bytes: dataPtr, count: byteCount)
                self.audioChunkPublisher.send(audioData)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.eventSink?(["type": "error", "message": "No audio data in output buffer"])
                }
            }
        }
    }

    public func startRecording() -> AnyPublisher<Data, Never> {
        guard !isRecording else {
            print("Already recording")
            return audioChunkPublisher.eraseToAnyPublisher()
        }
        isRecording = true
        print("Starting recording with format=\(webSocketFormat)")
        installRecordingTap()
        return audioChunkPublisher.eraseToAnyPublisher()
    }

    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        inputNode.removeTap(onBus: 0)
        print("Recording stopped")
    }

    // MARK: - Playback

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

    // MARK: - Shutdown

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
    /// (background music methods unchanged from your original; they remain below)
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

    // Helpers
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

    // Music position emitter
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

    public func startEmittingMusicPosition() {
      stopEmittingMusicPosition()

      musicPositionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        guard let self = self,
              let currentItem = self.queuePlayer.currentItem,
              currentItem.status == .readyToPlay
        else { return }

        let rawPos  = CMTimeGetSeconds(self.queuePlayer.currentTime())
        let duration = CMTimeGetSeconds(currentItem.duration)
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
}
