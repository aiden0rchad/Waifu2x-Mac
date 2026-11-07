import CoreImage
import CoreML
import VideoToolbox

final class RIFEInterpolation {
    private static let compiled = Result { try compileBundledModel("RIFE46", "mlpackage") }
    private let model: MLModel
    private var previous: (CIImage, CMTime)?
    private var buffers: (size: Dimensions, first: CVPixelBuffer, second: CVPixelBuffer)?

    init() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: Self.compiled.get(), configuration: configuration)
    }

    static func validate(_ size: Dimensions) throws {
        guard (1...1920).contains(size.width), (1...1920).contains(size.height),
              size.width * size.height <= 2_073_600 else { throw UpscaleError.rifeInputTooLarge }
    }

    func midpoint(_ first: CIImage, _ second: CIImage, renderer: FrameRenderer) throws -> CIImage {
        try autoreleasepool {
            try Task.checkCancellation()
            let size = first.dimensions
            try Self.validate(size)
            guard size == second.dimensions else { throw UpscaleError.render }
            if buffers?.size != size {
                let paddedWidth = (size.width + 31) & ~31
                let paddedHeight = (size.height + 31) & ~31
                func makeBuffer() throws -> CVPixelBuffer {
                    var buffer: CVPixelBuffer?
                    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                    guard CVPixelBufferCreate(nil, paddedWidth, paddedHeight, kCVPixelFormatType_32BGRA,
                                              attributes, &buffer) == kCVReturnSuccess, let buffer else {
                        throw UpscaleError.render
                    }
                    return buffer
                }
                buffers = (size, try makeBuffer(), try makeBuffer())
            }
            guard let buffers else { throw UpscaleError.render }
            let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffers.first),
                                height: CVPixelBufferGetHeight(buffers.first))
            let black = CIImage(color: .black).cropped(to: bounds)
            // The reference model pads the right and bottom edges to multiples of 32.
            func padded(_ frame: CIImage) -> CIImage {
                frame.normalized.transformed(by: .init(translationX: 0, y: bounds.height - frame.extent.height))
                    .composited(over: black)
            }
            renderer.context.render(padded(first), to: buffers.first, bounds: bounds, colorSpace: renderer.colorSpace)
            renderer.context.render(padded(second), to: buffers.second, bounds: bounds, colorSpace: renderer.colorSpace)
            let inputs = try MLDictionaryFeatureProvider(dictionary: [
                "first": MLFeatureValue(pixelBuffer: buffers.first),
                "second": MLFeatureValue(pixelBuffer: buffers.second)
            ])
            let result = try model.prediction(from: inputs)
            guard let pixels = result.featureValue(for: "result")?.imageBufferValue else { throw UpscaleError.render }
            let output = CIImage(cvPixelBuffer: pixels, options: [.colorSpace: renderer.colorSpace])
            return output.cropped(to: CGRect(x: 0, y: bounds.height - CGFloat(size.height),
                                              width: CGFloat(size.width), height: CGFloat(size.height))).normalized
        }
    }

    func submit(_ image: CIImage, at time: CMTime, renderer: FrameRenderer) throws -> (CIImage, CMTime)? {
        defer { previous = (image, time) }
        guard let (frame, earlier) = previous else { return nil }
        let interval = CMTimeSubtract(time, earlier).convertScale(60_000, method: .default)
        let middle = CMTimeAdd(earlier, CMTimeMultiplyByRatio(interval, multiplier: 1, divisor: 2))
        guard middle > earlier, middle < time else { return nil }
        return (try midpoint(frame, image, renderer: renderer), middle)
    }
}

@available(macOS 26, *)
final class MotionInterpolation {
    private let configuration: VTLowLatencyFrameInterpolationConfiguration
    private let processor = VTFrameProcessor()
    private var previous: VTFrameProcessorFrame?

    init(size: Dimensions) throws {
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: size.width, frameHeight: size.height, numberOfInterpolatedFrames: 1
        ) else { throw UpscaleError.motionUnavailable }
        self.configuration = configuration
        do { try processor.startSession(configuration: configuration) }
        catch { throw UpscaleError.motionUnavailable }
    }

    deinit { processor.endSession() }

    func submit(_ image: CIImage, at time: CMTime, renderer: FrameRenderer) async throws -> (CIImage, CMTime)? {
        let buffer = try frameProcessorBuffer(configuration.sourcePixelBufferAttributes)
        renderer.context.render(image, to: buffer, bounds: image.extent, colorSpace: renderer.colorSpace)
        guard let current = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
            throw UpscaleError.render
        }
        defer { previous = current }
        guard let previous else { return nil }

        let previousTime = previous.presentationTimeStamp
        let interval = CMTimeSubtract(time, previousTime).convertScale(60_000, method: .default)
        let middle = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(interval, multiplier: 1, divisor: 2))
        guard middle > previousTime, middle < time else { return nil }
        let destination = try frameProcessorBuffer(configuration.destinationPixelBufferAttributes)
        guard let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: middle),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: current, previousFrame: previous,
                interpolationPhase: [0.5], destinationFrames: [output]
              ) else { throw UpscaleError.motionUnavailable }
        _ = try await processor.process(parameters: parameters)
        return (CIImage(cvPixelBuffer: destination), middle)
    }
}
