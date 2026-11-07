import CoreImage
import Metal
import MetalFX

final class FrameRenderer {
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var spatial: SpatialPass?
    private var enhancement: (input: Dimensions, output: Dimensions, pass: SuperResolution?)?
    private var neural: [NeuralScaler.Kind: NeuralScaler] = [:]
    private(set) var method = "Lanczos"
    private(set) var neuralPasses: [NeuralScaler.Kind] = []

    func thumbnail(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        return image.normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    func image(_ frame: CIImage) throws -> CGImage {
        guard let result = context.createCGImage(frame, from: frame.extent, format: .RGBA8,
                                                colorSpace: colorSpace) else { throw UpscaleError.render }
        return result
    }

    func isOpaque(_ image: CIImage) -> Bool {
        let minimum = image.applyingFilter("CIAreaMinimum", parameters: ["inputExtent": CIVector(cgRect: image.extent)])
        var pixel: UInt32 = 0
        context.render(minimum, toBitmap: &pixel, rowBytes: 4, bounds: minimum.extent,
                       format: .RGBA8, colorSpace: colorSpace)
        return pixel >> 24 == 255
    }

    func scale(_ frame: CIImage, to target: Dimensions, options: UpscaleOptions,
               opaque: Bool, allowML: Bool = true, allowNeural: Bool = true,
               videoModel: NeuralScaler.Kind? = nil,
               neuralPassPlan: [NeuralScaler.Kind]? = nil) async throws -> CIImage {
        let preset = videoModel == nil ? options.preset : .fast
        let neuralKind = videoModel ?? NeuralScaler.model(for: preset, denoise: options.noiseReduction)
        let noise = preset == .realCUGAN ? 0 : options.noiseReduction.strength(default: preset == .photo ? 0.36 : 0)
        let edge = options.edgeDetail.strength(default: preset == .illustration ? 0.48 : 0)
        let input = opaque && noise > 0
            ? frame.normalized.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": noise * 0.05, "inputSharpness": 0.42
            ])
            : frame.normalized
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        let xScale = bounds.width / input.extent.width
        let yScale = bounds.height / input.extent.height
        method = "Lanczos"
        neuralPasses = []
        let scaled: CIImage
        if let model = neuralKind, allowNeural, opaque, xScale > 1 || yScale > 1 {
            var enlarged = input
            for kind in try neuralPassPlan ?? Self.neuralPlan(from: input.dimensions, to: target, kind: model) {
                if neural[kind] == nil { neural[kind] = try NeuralScaler(kind: kind) }
                guard let pass = neural[kind] else { throw UpscaleError.render }
                enlarged = try pass.scale(enlarged, context: context, colorSpace: colorSpace)
                neuralPasses.append(kind)
            }
            method = neuralPasses.isEmpty ? "Lanczos · resize only"
                : videoModel == .safmn ? VideoEngine.safmn.rawValue : preset.rawValue
            scaled = enlarged.dimensions == target ? enlarged : lanczos(enlarged, to: bounds)
        } else if preset == .enhance, allowML, let enhanced = try await enhance(input, to: target, opaque: opaque) {
            scaled = enhanced
        } else if videoModel == nil, preset == .fast, opaque, xScale > 1, yScale > 1, abs(xScale - yScale) < 0.01,
           let accelerated = metalFX(input, target: target) {
            method = "MetalFX"
            scaled = accelerated
        } else {
            if neuralKind != nil {
                method = opaque ? "Lanczos · resize only" : "Lanczos · transparency"
            }
            scaled = lanczos(input, to: bounds)
        }

        if opaque && edge > 0 {
            return scaled.clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": edge])
                .cropped(to: bounds)
        }
        return scaled.cropped(to: bounds)
    }

    static func neuralPlan(from input: Dimensions, to target: Dimensions,
                           kind: NeuralScaler.Kind) throws -> [NeuralScaler.Kind] {
        var size = input
        var next = kind
        var passes: [NeuralScaler.Kind] = []
        while max(Double(target.width) / Double(size.width), Double(target.height) / Double(size.height)) > 1.25 {
            guard next.accepts(size) else {
                if passes.isEmpty { throw UpscaleError.neuralInputTooLarge }
                break
            }
            passes.append(next)
            size = Dimensions(width: size.width * next.factor, height: size.height * next.factor)
            next = next.continuation
        }
        return passes
    }

    func lanczos(_ image: CIImage, to bounds: CGRect) -> CIImage {
        let vertical = bounds.height / image.extent.height
        return image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: vertical, kCIInputAspectRatioKey: bounds.width / image.extent.width / vertical
        ]).cropped(to: bounds)
    }

    private func enhance(_ frame: CIImage, to target: Dimensions, opaque: Bool) async throws -> CIImage? {
        guard opaque, #available(macOS 26, *), SuperResolution.isAvailable else { return nil }
        let input = frame.dimensions
        if enhancement?.input != input || enhancement?.output != target {
            let pass = try? SuperResolution(input: input, output: target)
            enhancement = (input, target, pass)
        }
        guard let pass = enhancement?.pass else { return nil }
        let output = try? await pass.scale(frame.normalized, context: context, colorSpace: colorSpace)
        try Task.checkCancellation()
        if output == nil { enhancement = (input, target, nil) }
        else { method = "Apple ML" }
        return output
    }

    private func metalFX(_ input: CIImage, target: Dimensions) -> CIImage? {
        guard let device, let queue, MTLFXSpatialScalerDescriptor.supportsDevice(device),
              input.extent.width.rounded() == input.extent.width,
              input.extent.height.rounded() == input.extent.height else { return nil }

        if spatial?.inputSize != input.dimensions || spatial?.outputSize != target {
            spatial = SpatialPass(device: device, input: input.dimensions, output: target)
        }
        guard let pass = spatial, let buffer = queue.makeCommandBuffer() else { return nil }
        context.render(input, to: pass.input, commandBuffer: buffer, bounds: input.extent, colorSpace: colorSpace)
        pass.scaler.encode(commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        return CIImage(mtlTexture: pass.output, options: [.colorSpace: colorSpace])
    }
}

private struct SpatialPass {
    let inputSize: Dimensions
    let outputSize: Dimensions
    let input: MTLTexture
    let output: MTLTexture
    let scaler: MTLFXSpatialScaler

    init?(device: MTLDevice, input: Dimensions, output: Dimensions) {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.width
        descriptor.inputHeight = input.height
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = .rgba8Unorm
        descriptor.outputTextureFormat = .rgba8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }

        let source = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: input.width, height: input.height, mipmapped: false
        )
        source.storageMode = .private
        source.usage = scaler.colorTextureUsage.union([.shaderWrite, .renderTarget])
        let destination = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: output.width, height: output.height, mipmapped: false
        )
        destination.storageMode = .private
        destination.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let sourceTexture = device.makeTexture(descriptor: source),
              let destinationTexture = device.makeTexture(descriptor: destination) else { return nil }

        inputSize = input
        outputSize = output
        self.input = sourceTexture
        self.output = destinationTexture
        self.scaler = scaler
        scaler.colorTexture = sourceTexture
        scaler.outputTexture = destinationTexture
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
    }
}
