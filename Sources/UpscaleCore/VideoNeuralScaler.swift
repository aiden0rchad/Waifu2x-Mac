import AVFoundation
import CoreImage
import CoreML

typealias TimedFrame = (image: CIImage, time: CMTime)

final class VideoNeuralScaler {
    private static let compactModels = Result { try compile("NanoVSR") }
    private static let detailModels = Result { try compile("NanoVSRDetail") }

    private static func compile(_ prefix: String) throws -> [URL] {
        try ["Forward", "Backward", "Reconstruct"].map { try compileBundledModel(prefix + $0, "mlpackage") }
    }

    private let models: [MLModel]
    private let renderer: FrameRenderer
    private let pixel: CVPixelBuffer
    private let zero: MLMultiArray

    init(engine: VideoEngine, size: Dimensions, renderer: FrameRenderer) throws {
        try engine.validate(size)
        self.renderer = renderer
        let configuration = MLModelConfiguration()
        let detail = engine == .nanoDetail
        let urls = try (detail ? Self.detailModels : Self.compactModels).get()
        models = try urls.map { try MLModel(contentsOf: $0, configuration: configuration) }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
                == kCVReturnSuccess, let buffer else { throw UpscaleError.render }
        pixel = buffer
        zero = try MLMultiArray(shape: [1, NSNumber(value: detail ? 48 : 32), NSNumber(value: size.height), NSNumber(value: size.width)],
                                dataType: .float16)
        _ = zero.withUnsafeMutableBytes { bytes, _ in bytes.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    func scale(_ frames: [TimedFrame], emitting range: Range<Int>, to target: Dimensions) throws -> [TimedFrame] {
        var previous = zero
        var past: [MLMultiArray] = []
        for index in 0..<range.upperBound {
            previous = try autoreleasepool {
                try propagate(frames[index].image, through: models[0], from: previous)
            }
            if range.contains(index) { past.append(previous) }
        }

        previous = zero
        var output: [TimedFrame] = []
        for index in (range.lowerBound..<frames.count).reversed() {
            try autoreleasepool {
                let frame = frames[index]
                previous = try propagate(frame.image, through: models[1], from: previous)
                if range.contains(index) {
                    let result = try predict(models[2], with: frame.image, states: [
                        "past": past[index - range.lowerBound], "future": previous
                    ])
                    guard let buffer = result.featureValue(for: "result")?.imageBufferValue else {
                        throw UpscaleError.render
                    }
                    let decoded = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: renderer.colorSpace])
                    let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
                    let image = decoded.dimensions == target ? decoded : renderer.lanczos(decoded, to: bounds)
                    // Release the native 4× surfaces when a smaller export was requested.
                    output.append((image: CIImage(cgImage: try renderer.image(image)), time: frame.time))
                }
            }
        }
        return output.reversed()
    }

    private func propagate(_ image: CIImage, through model: MLModel, from previous: MLMultiArray) throws -> MLMultiArray {
        let result = try predict(model, with: image, states: ["previous": previous])
        guard let state = result.featureValue(for: "next_features")?.multiArrayValue else { throw UpscaleError.render }
        return state
    }

    private func predict(_ model: MLModel, with image: CIImage, states: [String: MLMultiArray]) throws -> MLFeatureProvider {
        try Task.checkCancellation()
        renderer.context.render(image, to: pixel, bounds: image.extent, colorSpace: renderer.colorSpace)
        var inputs = states.mapValues { MLFeatureValue(multiArray: $0) }
        inputs["rgb"] = MLFeatureValue(pixelBuffer: pixel)
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }
}

final class TemporalVideoFrames {
    private let model: VideoNeuralScaler
    private let read: () throws -> TimedFrame?
    private let target: Dimensions
    private let context = 3
    private var frames: [TimedFrame] = []
    private var rendered: ArraySlice<TimedFrame> = []
    private var emitted = 0

    init(model: VideoNeuralScaler, target: Dimensions, read: @escaping () throws -> TimedFrame?) {
        self.model = model
        self.target = target
        self.read = read
    }

    func next() throws -> TimedFrame? {
        if rendered.isEmpty {
            while frames.count < 12, let frame = try read() { frames.append(frame) }
            guard frames.count > emitted else { return nil }
            let end = frames.count == 12 ? frames.count - context : frames.count
            rendered = try model.scale(frames, emitting: emitted..<end, to: target)[...]
            let retainFrom = max(0, end - context)
            frames.removeFirst(retainFrom)
            emitted = end - retainFrom
        }
        return rendered.popFirst()
    }
}

func readVideoFrame(_ output: AVAssetReaderTrackOutput, transform: CGAffineTransform) throws -> TimedFrame? {
    guard let sample = output.copyNextSampleBuffer() else { return nil }
    guard let buffer = sample.imageBuffer else { throw UpscaleError.unreadable }
    return (CIImage(cvPixelBuffer: buffer).transformed(by: transform).normalized, sample.presentationTimeStamp)
}

func temporalPreview(asset: AVAsset, track: AVAssetTrack, transform: CGAffineTransform,
                     input: Dimensions, options: UpscaleOptions) throws -> MediaPreview {
    let output = try options.dimensions(for: input, video: true)
    let renderer = FrameRenderer()
    let model = try VideoNeuralScaler(engine: options.videoEngine, size: input, renderer: renderer)
    let reader = try AVAssetReader(asset: asset)
    let video = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    guard reader.canAdd(video) else { throw UpscaleError.unreadable }
    reader.add(video)
    guard reader.startReading() else { throw reader.error ?? UpscaleError.unreadable }
    defer { if reader.status == .reading { reader.cancelReading() } }

    var frames: [TimedFrame] = []
    while frames.count < 4, let frame = try readVideoFrame(video, transform: transform) { frames.append(frame) }
    guard let first = frames.first else { throw reader.error ?? UpscaleError.noVideo }
    let factor = min(1, 1200 / Double(max(output.width, output.height)))
    let size = Dimensions(width: max(1, Int(Double(output.width) * factor)),
                          height: max(1, Int(Double(output.height) * factor)))
    guard let after = try model.scale(frames, emitting: 0..<1, to: size).first else { throw UpscaleError.render }
    return try MediaPreview(before: renderer.image(first.image), after: renderer.image(after.image),
                            input: input, output: output, method: options.videoEngine.rawValue)
}
