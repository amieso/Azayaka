
import UserNotifications
import ScreenCaptureKit
import AVFAudio
import AVFoundation

@available(macOS 13.0, *)
class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    enum AudioQuality: Int {
        case normal = 128, good = 192, high = 256, extreme = 320
    }
    
    private let audioEngine = AVAudioEngine()
    private var assetWriter: AVAssetWriter?
    private var audioInput, micInput: AVAssetWriterInput?
    private var startTime: Date?
    private var stream: SCStream?

    let audioSettings: [String : Any] = [
        AVSampleRateKey : 48000,
        AVNumberOfChannelsKey : 2,
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVEncoderBitRateKey: AudioQuality.normal.rawValue * 1000
    ]
    
//    let logger = NodeLogger.shared

    @MainActor
    func startRecording() async -> String? {
        let micCheck = await performMicCheck()
        
        if (!micCheck) { return nil }
        
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            await record(availableContent: availableContent)
            return assetWriter?.outputURL.absoluteString.replacingOccurrences(of: "file://", with: "")
        } catch let error {
           switch error {
                case SCStreamError.userDeclined:
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                    }
                default:
//                    logger.error("Failed to start recording \(error)")
                    break
            }

            return nil
        }
    }
    
    @MainActor func performMicCheck() async -> Bool {
        let mediaType = AVMediaType.audio
        let mediaAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch mediaAuthorizationStatus {
            case .denied, .restricted:
//                logger.error("Rejected media auth \(mediaAuthorizationStatus)")

                let alert = NSAlert()
                alert.messageText = "Amie needs permissions"
                alert.informativeText = "Amie needs permission to record your microphone"
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "No thanks")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                    )
                }

                return false
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .audio)
            @unknown default:
//                logger.error("Unknown media auth \(mediaAuthorizationStatus)")
                return false
        }
    }
    
    private func record(availableContent: SCShareableContent) async {
        let conf = SCStreamConfiguration()
        conf.width = 2
        conf.height = 2
        
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
        conf.capturesAudio = true
        conf.sampleRate = audioSettings["AVSampleRateKey"] as! Int
        conf.channelCount = audioSettings["AVNumberOfChannelsKey"] as! Int
        
        let stream = SCStream(filter: SCContentFilter(display: availableContent.displays.first!, excludingWindows: []), configuration: conf, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
            try setupWriters(conf)
            try await stream.startCapture()
        } catch {
            assertionFailure("capture failed")
            return
        }
        
    }
    
    @MainActor
    func stopRecording() async -> String? {
        let url = assetWriter?.outputURL.absoluteString
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await closeMedia()
        startTime = nil
        assetWriter = nil
        micInput = nil
        audioInput = nil
        
        return url?.replacingOccurrences(of: "file://", with: "")
    }
    
    func getFilePath(date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        let fileName = "Meeting_%t"
        let userDesktop = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first!
        let fileNameWithDates = fileName.replacingOccurrences(of: "%t", with: dateFormatter.string(from: date)).prefix(Int(NAME_MAX) - 5)
        
        return "\(userDesktop)/\(fileNameWithDates).m4a"
    }
    
    func setupWriters(_ conf: SCStreamConfiguration) throws {
        startTime = nil
        
        let fileType: AVFileType = .m4a
        let filePath = getFilePath(date: Date())
        
        let assetWriter = try AVAssetWriter(outputURL: URL(fileURLWithPath: filePath), fileType: fileType)
        
        let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
        let micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        micInput.expectsMediaDataInRealTime = true
        
        self.assetWriter = assetWriter
        self.micInput = micInput
        self.audioInput = audioInput
        
        if assetWriter.canAdd(audioInput) {
            assetWriter.add(audioInput)
        }
        
        if assetWriter.canAdd(micInput) {
            assetWriter.add(micInput)
        }
        
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { [self] (buffer, time) in
            if micInput.isReadyForMoreMediaData && startTime != nil {
                micInput.append(buffer.asSampleBuffer!)
            }
        }
        try! audioEngine.start()
        assetWriter.startWriting()
    }
    
    func closeMedia() async {
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        if let assetWriter {
            await withCheckedContinuation { continuation in
                assetWriter.finishWriting {
                    self.startTime = nil
                    continuation.resume()
                }
            }
            
            try! await self.merge(assetWriter: assetWriter)
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        if let assetWriter, assetWriter.status == .writing, startTime == nil {
            startTime = Date.now
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
        switch outputType {
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        case .screen:
            break;
        @unknown default:
            assertionFailure("unknown stream type")
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
//        logger.error("closing stream with error:\n \(error) \nthis might be due to the window closing or the user stopping from the sonoma ui")
        Task {
            self.stream = nil
            _ = await self.stopRecording()
        }
    }
    
    @MainActor
    func merge(assetWriter: AVAssetWriter) async throws {
        let mergeComposition = AVMutableComposition()
        let audioAsset = AVAsset(url: assetWriter.outputURL)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        for audioTrack in audioTracks {
            let audioCompositionTrack = mergeComposition.addMutableTrack(withMediaType: .audio,
                                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            try await audioCompositionTrack?.insertTimeRange(
                CMTimeRange(
                    start: CMTime.zero,
                    end: audioAsset.load(.duration)),
                of: audioTrack,
                at: CMTime.zero
            )
        }
        
        let outputURL = URL(fileURLWithPath: getFilePath(date: Date()))
        
        try? FileManager.default.removeItem(at: outputURL)

        if let exportSession = AVAssetExportSession(asset: mergeComposition, presetName: AVAssetExportPresetAppleM4A) {
            exportSession.outputFileType = .m4a
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.outputURL = outputURL
            await exportSession.export()
            try? FileManager.default.removeItem(at: assetWriter.outputURL)
            try FileManager.default.moveItem(at: outputURL, to: assetWriter.outputURL)
        }
    }
}

// Based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c
extension AVAudioPCMBuffer {
    var asSampleBuffer: CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil
        
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }
        
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }
        
        return sampleBuffer
    }
}
