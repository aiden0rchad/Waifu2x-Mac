import CoreImage
import VideoToolbox

final class SuperResolution {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
    }

    @available(macOS 26, *)
    static func supports(_ input: Dimensions, output: Dimensions) -> Bool {
        let factor = Float(output.width) / Float(input.width)
        return factor > 1 && Float(input.height) * factor == Float(output.height) &&
            VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: input.width, frameHeight: input.height
            ).contains(factor)
    }

    private let run: (CIImage, CIContext, CGColorSpace) async throws -> CIImage
    private let end: () -> Void

    @available(macOS 26, *)
    init?(input: Dimensions, output: Dimensions) throws {
        guard Self.supports(input, output: output) else { return nil }
        let config = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: input.width, frameHeight: input.height,
            scaleFactor: Float(output.width) / Float(input.width)
        )
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        end = { processor.endSession() }
        var frameIndex: Int64 = 0
        run = { image, context, colorSpace in
            let source = try frameProcessorBuffer(config.sourcePixelBufferAttributes)
            let destination = try frameProcessorBuffer(config.destinationPixelBufferAttributes)
            context.render(image, to: source, bounds: image.extent, colorSpace: colorSpace)
            let timestamp = CMTime(value: frameIndex, timescale: 60)
            frameIndex += 1
            guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: timestamp),
                  let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: timestamp)
            else { throw UpscaleError.render }
            let parameters = VTLowLatencySuperResolutionScalerParameters(
                sourceFrame: sourceFrame, destinationFrame: destinationFrame
            )
            _ = try await processor.process(parameters: parameters)
            return CIImage(cvPixelBuffer: destination)
        }
    }

    deinit { end() }

    func scale(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace) async throws -> CIImage {
        try await run(image, context, colorSpace)
    }
}

func frameProcessorBuffer(_ attributes: [String: Any]) throws -> CVPixelBuffer {
    guard let width = attributes[kCVPixelBufferWidthKey as String] as? Int,
          let height = attributes[kCVPixelBufferHeightKey as String] as? Int,
          let format = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
    else { throw UpscaleError.render }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { throw UpscaleError.render }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return buffer
}
