import AVFoundation
import AudioToolbox
import CoreImage

func exportVideo(_ source: URL, to output: URL, options: UpscaleOptions,
                 renderer: FrameRenderer, progress: @Sendable (Double) -> Void) async throws {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw UpscaleError.noVideo
    }
    let duration = try await asset.load(.duration)
    guard duration.seconds.isFinite, duration.seconds > 0 else { throw UpscaleError.unreadable }
    let sourceSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let displaySize = CGRect(origin: .zero, size: sourceSize).applying(transform).standardized.size
    let inputSize = Dimensions(width: Int(displaySize.width.rounded()), height: Int(displaySize.height.rounded()))
    let target = try options.dimensions(for: inputSize, video: true)
    let content = try options.dimensions(for: inputSize)
    let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
    try options.videoEngine.validate(inputSize)
    let temporalModel = options.usesTemporalVideo
        ? try VideoNeuralScaler(engine: options.videoEngine, size: inputSize, renderer: renderer) : nil
    let videoModel: NeuralScaler.Kind? = options.videoEngine == .safmn ? .safmn : nil
    let interpolate: ((CIImage, CMTime) async throws -> (CIImage, CMTime)?)?
    switch options.interpolatesMotion ? options.motionEngine : .off {
    case .rife:
        try RIFEInterpolation.validate(inputSize)
        let motion = try RIFEInterpolation()
        interpolate = { try motion.submit($0, at: $1, renderer: renderer) }
    case .apple:
        guard #available(macOS 26, *), UpscaleOptions.canInterpolateVideo else {
            throw UpscaleError.motionUnavailable
        }
        let motion = try MotionInterpolation(size: inputSize)
        interpolate = { try await motion.submit($0, at: $1, renderer: renderer) }
    case .off:
        interpolate = nil
    }
    let videoEnd = interpolate == nil ? nil : try await track.load(.timeRange).end

    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    defer {
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
    }

    let pixels: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: target.width,
        kCVPixelBufferHeightKey as String: target.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let video = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    video.alwaysCopiesSampleData = false
    let nominalRate = Double(try await track.load(.nominalFrameRate))
    let frameRate = (nominalRate > 0 && nominalRate.isFinite ? nominalRate : 30) * (options.interpolatesMotion ? 2 : 1)
    let bitrate = Int(min(100_000_000, max(120_000,
        Double(target.width * target.height) * frameRate * options.export.videoQuality.bitsPerPixelPerFrame)))
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: options.export.videoCodec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        AVVideoWidthKey: target.width,
        AVVideoHeightKey: target.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: pixels)
    guard reader.canAdd(video), writer.canAdd(videoInput) else { throw UpscaleError.encode }
    reader.add(video)
    writer.add(videoInput)

    let audio = options.export.keepAudio ? try await audioPipeline(asset: asset, reader: reader, writer: writer) : nil
    try Task.checkCancellation()
    guard reader.startReading() else { throw reader.error ?? UpscaleError.unreadable }
    guard writer.startWriting() else { throw writer.error ?? UpscaleError.encode }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw UpscaleError.encode }

    func writeFrame(_ frame: CIImage, at time: CMTime, endAt end: CMTime? = nil) async throws {
        let scaled: CIImage
        if temporalModel != nil { scaled = frame }
        else { scaled = try await renderer.scale(frame, to: content, options: options, opaque: true, videoModel: videoModel) }
        try autoreleasepool {
            var outputBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                  let outputBuffer else { throw UpscaleError.render }
            let padded = scaled.composited(over: CIImage(color: .black).cropped(to: bounds))
            renderer.context.render(padded, to: outputBuffer, bounds: bounds, colorSpace: renderer.colorSpace)
            let appended: Bool
            if let end, end > time {
                var format: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: outputBuffer,
                                                                    formatDescriptionOut: &format) == noErr,
                      let format else { throw UpscaleError.encode }
                var timing = CMSampleTimingInfo(duration: end - time, presentationTimeStamp: time, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: outputBuffer,
                                                                formatDescription: format, sampleTiming: &timing,
                                                                sampleBufferOut: &sample) == noErr,
                      let sample else { throw UpscaleError.encode }
                appended = videoInput.append(sample)
            } else {
                appended = adaptor.append(outputBuffer, withPresentationTime: time)
            }
            guard appended else {
                throw writer.error ?? UpscaleError.encode
            }
        }
    }

    let read = { try readVideoFrame(video, transform: transform) }
    let temporalFrames = temporalModel.map { TemporalVideoFrames(model: $0, target: content, read: read) }
    func nextFrame() throws -> TimedFrame? {
        if let temporalFrames { return try temporalFrames.next() }
        return try read()
    }

    var nextVideo = try nextFrame()
    var nextAudio = audio?.output.copyNextSampleBuffer()
    var pendingIntermediate: TimedFrame?
    var preparedIntermediate = false
    var wroteFrame = false
    let clock = ContinuousClock()
    var lastAppend = clock.now
    if nextVideo == nil { throw reader.error ?? UpscaleError.noVideo }
    if nextAudio == nil { audio?.input.markAsFinished() }

    while nextVideo != nil || nextAudio != nil {
        try Task.checkCancellation()
        guard writer.status == .writing, reader.status != .failed else {
            throw writer.error ?? reader.error ?? UpscaleError.encode
        }

        let canWriteVideo = nextVideo != nil && videoInput.isReadyForMoreMediaData
        let canWriteAudio = nextAudio != nil && audio?.input.isReadyForMoreMediaData == true
        if !preparedIntermediate, let sample = nextVideo, canWriteVideo {
            if let (image, time) = try await interpolate?(sample.image, sample.time) {
                pendingIntermediate = TimedFrame(image: image, time: time)
            }
            preparedIntermediate = true
        }
        let videoTime = pendingIntermediate?.time ?? nextVideo?.time ?? .positiveInfinity
        let audioTime = nextAudio?.presentationTimeStamp ?? .positiveInfinity

        if canWriteVideo, (!canWriteAudio || videoTime <= audioTime), let sample = nextVideo {
            if let middle = pendingIntermediate {
                try await writeFrame(middle.image, at: middle.time)
                lastAppend = clock.now
                pendingIntermediate = nil
                continue
            }
            let following = try nextFrame()
            try await writeFrame(sample.image, at: videoTime, endAt: following == nil ? videoEnd : nil)
            preparedIntermediate = false
            lastAppend = clock.now
            wroteFrame = true
            progress(min(0.99, max(0, videoTime.seconds / duration.seconds)))
            nextVideo = following
            if nextVideo == nil { videoInput.markAsFinished() }
        } else if canWriteAudio, let audio, let sample = nextAudio {
            guard audio.input.append(sample) else { throw writer.error ?? UpscaleError.encode }
            lastAppend = clock.now
            nextAudio = audio.output.copyNextSampleBuffer()
            if nextAudio == nil { audio.input.markAsFinished() }
        } else {
            guard lastAppend.duration(to: clock.now) < .seconds(30) else { throw UpscaleError.encoderStalled }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    guard wroteFrame, reader.status == .completed else { throw reader.error ?? UpscaleError.unreadable }
    writer.endSession(atSourceTime: duration)
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? UpscaleError.encode }
}

private func audioPipeline(asset: AVAsset, reader: AVAssetReader, writer: AVAssetWriter)
    async throws -> (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)? {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
    guard let format = try await track.load(.formatDescriptions).first,
          let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
        throw UpscaleError.unreadable
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    let channels = min(Int(stream.mChannelsPerFrame), 2)
    guard channels > 0 else { throw UpscaleError.unreadable }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: min(stream.mSampleRate, 48_000),
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
    ])
    guard reader.canAdd(output), writer.canAdd(input) else { throw UpscaleError.encode }
    reader.add(output)
    writer.add(input)
    return (output, input)
}
