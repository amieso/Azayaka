
import UserNotifications
import ScreenCaptureKit
import AVFAudio
import AVFoundation

enum Preferences {
    static let fileName = "outputFileName"
}

class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    var vW: AVAssetWriter!
    var awInput, micInput: AVAssetWriterInput!
    let audioEngine = AVAudioEngine()
    var startTime: Date?
    var stream: SCStream!
    var filePath: String!
    let audioSettings: [String : Any] = [
        AVSampleRateKey : 48000,
        AVNumberOfChannelsKey : 2,
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVEncoderBitRateKey: AudioQuality.high.rawValue * 1000
    ]
    var filter: SCContentFilter?
    
    var screen: SCDisplay?
    var window: SCWindow?
    var streamType: StreamType?
    let ud = UserDefaults.standard
    
    override init() {
        let userDesktop =
        (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true) as [String])
            .first!
        
        // the `com.apple.screencapture` domain has the user set path for where they want to store screenshots or videos
        let saveDirectory =
        (UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? userDesktop)
        as NSString
        
        streamType = .systemaudio
        
        ud.register( // default defaults (used if not set)
            defaults: [
                "encoder": Encoder.h264.rawValue,
                "saveDirectory": saveDirectory,
                Preferences.fileName: "Meeting_%t"
            ]
        )
        
        super.init()
    }
    
    func startRecording() async {
        let micCheck = await performMicCheck()
        
        if (!micCheck) { return }
        
        let availableContent = try! await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        
        await record(availableContent: availableContent)
    }
    
    func performMicCheck() async -> Bool {
        if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        
        
        DispatchQueue.main.async {
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
        }
        
        return false
    }
    
    private func record(availableContent: SCShareableContent) async {
        let conf = SCStreamConfiguration()
        conf.width = 2
        conf.height = 2
        
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
        conf.capturesAudio = true
        conf.sampleRate = audioSettings["AVSampleRateKey"] as! Int
        conf.channelCount = audioSettings["AVNumberOfChannelsKey"] as! Int
        
        stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: availableContent.windows.first!), configuration: conf, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
            initMedia(conf: conf)
            try await stream.startCapture()
        } catch {
            assertionFailure("capture failed")
            return
        }
        
    }
    
    func stopRecording() -> String {
        if stream != nil {
            stream.stopCapture()
        }
        stream = nil
        closeMedia()
        streamType = nil
        window = nil
        screen = nil
        startTime = nil
        
        return filePath
    }
    
    func getFilePath() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        var fileName = ud.string(forKey: Preferences.fileName)
        if fileName == nil || fileName!.isEmpty {
            fileName = "Meeting-%t"
        }
        // bit of a magic number but worst case ".flac" is 5 characters on top of this..
        let fileNameWithDates = fileName!.replacingOccurrences(of: "%t", with: dateFormatter.string(from: Date())).prefix(Int(NAME_MAX) - 5)
        return ud.string(forKey: "saveDirectory")! + "/" + fileNameWithDates
    }
    
    func initMedia(conf: SCStreamConfiguration) {
        startTime = nil
        
        let filePathAndAssetWriter = getFilePathAndAssetWriter()
        
        filePath = filePathAndAssetWriter.0
        vW = filePathAndAssetWriter.1
        awInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
        micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
        awInput.expectsMediaDataInRealTime = true
        micInput.expectsMediaDataInRealTime = true
        
        if vW.canAdd(awInput) {
            vW.add(awInput)
        }
        
        if vW.canAdd(micInput) {
            vW.add(micInput)
        }
        
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { [self] (buffer, time) in
            if micInput.isReadyForMoreMediaData && startTime != nil {
                micInput.append(buffer.asSampleBuffer!)
            }
        }
        try! audioEngine.start()
        vW.startWriting()
    }
    
    func closeMedia() {
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        awInput.markAsFinished()
        micInput.markAsFinished()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        vW.finishWriting {
            self.startTime = nil
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        if vW != nil && vW?.status == .writing, startTime == nil {
            startTime = Date.now
            vW.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
        switch outputType {
        case .audio:
            if awInput.isReadyForMoreMediaData {
                awInput.append(sampleBuffer)
            }
        case .screen:
            break;
        @unknown default:
            assertionFailure("unknown stream type")
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        print("closing stream with error:\n", error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui")
        DispatchQueue.main.async {
            self.stream = nil
            _ = self.stopRecording()
        }
    }
    
    /**
     Get the filepath of where the asset writer is writing to and asset writer itself
     */
    private func getFilePathAndAssetWriter()-> (String, AVAssetWriter?){
        let fileEnding = "m4a"
        let fileType: AVFileType = .m4a
        
        filePath = "\(getFilePath()).\(fileEnding)"
        let assetWriter = try? AVAssetWriter(outputURL: URL(fileURLWithPath: filePath), fileType: fileType)
        
        return (filePath, assetWriter)
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
