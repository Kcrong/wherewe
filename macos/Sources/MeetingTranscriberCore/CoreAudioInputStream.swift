import AudioToolbox
import CoreAudio
import Foundation

public enum CoreAudioCaptureError: Error, Equatable, LocalizedError, Sendable {
    case componentUnavailable
    case createUnit(OSStatus)
    case configure(selector: AudioUnitPropertyID, status: OSStatus)
    case initialise(OSStatus)
    case start(OSStatus)
    case startTimedOut
    case microphonePermissionDenied
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .componentUnavailable:
            return "The requested CoreAudio capture component is unavailable."
        case .createUnit:
            return "The selected CoreAudio capture component could not be created."
        case .configure:
            return "The selected audio input could not be configured without changing capture mode."
        case .initialise:
            return "The selected audio input could not be initialised."
        case .start:
            return "The selected audio input could not be started. Check microphone permission and device availability."
        case .startTimedOut:
            return "The selected audio input did not start in time. Reconnect the device or choose another input."
        case .microphonePermissionDenied:
            return "Wherewe is not allowed to record audio. Allow it in System Settings › Privacy & Security › Microphone."
        case .alreadyRunning:
            return "The selected audio input is already running."
        }
    }
}

public final class CoreAudioInputStream: @unchecked Sendable {
    public enum ProcessingMode: Sendable {
        case voiceProcessedMicrophone
        case unprocessedSystemInput
    }

    private let device: AudioInputDevice
    private let source: AudioInputSource
    private let processingMode: ProcessingMode
    private let sampleRate: Double
    private let voiceProcessingAllowed: Bool
    private let onChunk: @Sendable (TimedAudioChunk) -> Void
    private let lock = NSLock()
    private var audioUnit: AudioUnit?
    private var renderContext: CoreAudioRenderContext?

    public init(
        device: AudioInputDevice,
        source: AudioInputSource,
        processingMode: ProcessingMode,
        sampleRate: Double = 48_000,
        voiceProcessingAllowed: Bool = true,
        onChunk: @escaping @Sendable (TimedAudioChunk) -> Void
    ) {
        self.device = device
        self.source = source
        self.processingMode = processingMode
        self.sampleRate = sampleRate
        self.voiceProcessingAllowed = voiceProcessingAllowed
        self.onChunk = onChunk
    }

    deinit {
        stop()
    }

    static func shouldUseVoiceProcessingIO(
        processingMode: ProcessingMode,
        isDefaultInput: Bool,
        voiceProcessingAllowed: Bool = true
    ) -> Bool {
        processingMode == .voiceProcessedMicrophone && isDefaultInput && voiceProcessingAllowed
    }

    // macOS VoiceProcessingIO must own the default input route. Forcing its
    // CurrentDevice while the default output uses a different clock can
    // initialise successfully but deliver input at the wrong real-time rate.
    // Independently selected non-default microphones therefore use AUHAL.
    var usesVoiceProcessingIO: Bool {
        Self.shouldUseVoiceProcessingIO(
            processingMode: processingMode,
            isDefaultInput: device.isDefaultInput,
            voiceProcessingAllowed: voiceProcessingAllowed
        )
    }

    /// Starts capture on a dedicated GCD thread and gives up after `timeout`.
    ///
    /// CoreAudio configuration is synchronous IPC to coreaudiod. When the HAL
    /// wedges, blocking a Swift-concurrency thread would stall the recording
    /// actor indefinitely, so the caller is released with `startTimedOut`
    /// and a start that completes afterwards is stopped immediately.
    public func start(timeout: TimeInterval) async throws {
        try await CoreAudioStartDeadline.run(
            timeout: timeout,
            work: { [self] in try start() },
            abandon: { [self] in stop() }
        )
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard audioUnit == nil else { throw CoreAudioCaptureError.alreadyRunning }

        let subtype = usesVoiceProcessingIO
            ? kAudioUnitSubType_VoiceProcessingIO
            : kAudioUnitSubType_HALOutput
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioCaptureError.componentUnavailable
        }
        var newUnit: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &newUnit)
        guard createStatus == noErr, let unit = newUnit else {
            throw CoreAudioCaptureError.createUnit(createStatus)
        }

        do {
            let inputSampleRate = try configure(unit)
            let context = CoreAudioRenderContext(
                audioUnit: unit,
                source: source,
                inputSampleRate: inputSampleRate,
                outputSampleRate: sampleRate,
                onChunk: onChunk
            )
            var callback = AURenderCallbackStruct(
                inputProc: coreAudioInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try setProperty(
                unit,
                property: kAudioOutputUnitProperty_SetInputCallback,
                scope: kAudioUnitScope_Global,
                element: 0,
                value: &callback
            )

            let initialiseStatus = AudioUnitInitialize(unit)
            guard initialiseStatus == noErr else {
                throw CoreAudioCaptureError.initialise(initialiseStatus)
            }
            let startStatus = AudioOutputUnitStart(unit)
            guard startStatus == noErr else {
                AudioUnitUninitialize(unit)
                throw CoreAudioCaptureError.start(startStatus)
            }
            audioUnit = unit
            renderContext = context
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        renderContext?.drainDelivery()
        renderContext?.invalidate()
        renderContext = nil
        audioUnit = nil
        AudioComponentInstanceDispose(unit)
    }

    private func configure(_ unit: AudioUnit) throws -> Double {
        var enableInput: UInt32 = 1
        try setProperty(
            unit,
            property: kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Input,
            element: 1,
            value: &enableInput
        )
        var disableOutput: UInt32 = 0
        try setProperty(
            unit,
            property: kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Output,
            element: 0,
            value: &disableOutput
        )
        if !usesVoiceProcessingIO {
            var deviceID = device.id
            try setProperty(
                unit,
                property: kAudioOutputUnitProperty_CurrentDevice,
                scope: kAudioUnitScope_Global,
                element: 0,
                value: &deviceID
            )
        }

        let inputSampleRate: Double
        if usesVoiceProcessingIO {
            inputSampleRate = try currentInputClientFormat(unit).mSampleRate
        } else {
            inputSampleRate = device.nominalSampleRate
        }
        guard inputSampleRate.isFinite, inputSampleRate > 0 else {
            throw CoreAudioCaptureError.configure(
                selector: kAudioUnitProperty_StreamFormat,
                status: kAudio_ParamError
            )
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try setProperty(
            unit,
            property: kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Output,
            element: 1,
            value: &format
        )
        return inputSampleRate
    }

    private func currentInputClientFormat(_ unit: AudioUnit) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            &size
        )
        guard status == noErr else {
            throw CoreAudioCaptureError.configure(
                selector: kAudioUnitProperty_StreamFormat,
                status: status
            )
        }
        return format
    }

    private func setProperty<Value>(
        _ unit: AudioUnit,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: inout Value
    ) throws {
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioUnitSetProperty(
                unit,
                property,
                scope,
                element,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard status == noErr else {
            throw CoreAudioCaptureError.configure(selector: property, status: status)
        }
    }
}

private final class CoreAudioRenderContext: @unchecked Sendable {
    private static let maximumFrames: UInt32 = 32_768

    private let audioUnit: AudioUnit
    private let source: AudioInputSource
    private let onChunk: @Sendable (TimedAudioChunk) -> Void
    private let resampler: HostTimeAudioResampler
    private let deliveryQueue = DispatchQueue(label: "wherewe.audio-delivery", qos: .userInteractive)
    private let storage: UnsafeMutablePointer<Float>
    private let validLock = NSLock()
    private var valid = true

    init(
        audioUnit: AudioUnit,
        source: AudioInputSource,
        inputSampleRate: Double,
        outputSampleRate: Double,
        onChunk: @escaping @Sendable (TimedAudioChunk) -> Void
    ) {
        self.audioUnit = audioUnit
        self.source = source
        self.onChunk = onChunk
        self.resampler = HostTimeAudioResampler(
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        self.storage = .allocate(capacity: Int(Self.maximumFrames))
        self.storage.initialize(repeating: 0, count: Int(Self.maximumFrames))
    }

    deinit {
        storage.deinitialize(count: Int(Self.maximumFrames))
        storage.deallocate()
    }

    func invalidate() {
        validLock.lock()
        valid = false
        validLock.unlock()
    }

    func drainDelivery() {
        deliveryQueue.sync {}
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return kAudio_ParamError }
        validLock.lock()
        let isValid = valid
        validLock.unlock()
        guard isValid else { return noErr }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: frameCount * UInt32(MemoryLayout<Float>.size),
                mData: storage
            )
        )
        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,
            frameCount,
            &bufferList
        )
        guard status == noErr else { return status }

        let copied = Array(UnsafeBufferPointer(start: storage, count: Int(frameCount)))
        let hostTimeNanoseconds: UInt64
        if timestamp.pointee.mFlags.contains(.hostTimeValid) {
            hostTimeNanoseconds = AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime)
        } else {
            hostTimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        let source = self.source
        let onChunk = self.onChunk
        let resampler = self.resampler
        deliveryQueue.async {
            guard let output = resampler.process(
                samples: copied,
                hostTimeNanoseconds: hostTimeNanoseconds
            ) else { return }
            onChunk(TimedAudioChunk(
                source: source,
                hostTimeNanoseconds: output.hostTimeNanoseconds,
                samples: output.samples
            ))
        }
        return noErr
    }
}

private let coreAudioInputCallback: AURenderCallback = {
    refCon,
    actionFlags,
    timestamp,
    _,
    frameCount,
    _ in
    let context = Unmanaged<CoreAudioRenderContext>.fromOpaque(refCon).takeUnretainedValue()
    return context.render(
        actionFlags: actionFlags,
        timestamp: timestamp,
        frameCount: frameCount
    )
}

/// Runs blocking CoreAudio start work off the Swift-concurrency pool with a
/// deadline. `abandon` runs if the work succeeds only after the deadline.
enum CoreAudioStartDeadline {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        /// Resumes once; returns false when the caller was already released.
        func resume(_ result: Result<Void, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result)
            return true
        }
    }

    static func run(
        timeout: TimeInterval,
        queue: DispatchQueue = .global(qos: .userInitiated),
        work: @escaping @Sendable () throws -> Void,
        abandon: @escaping @Sendable () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = Gate(continuation)
            queue.async {
                do {
                    try work()
                    if !gate.resume(.success(())) { abandon() }
                } catch {
                    _ = gate.resume(.failure(error))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                _ = gate.resume(.failure(CoreAudioCaptureError.startTimedOut))
            }
        }
    }
}
