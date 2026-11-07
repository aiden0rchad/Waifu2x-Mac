import Foundation

public struct DetailGeometry: Equatable, Sendable {
    // Source pixels, with a top-left origin to match image gestures.
    public let rect: CGRect
    public let output: Dimensions

    public init(imageSize: Dimensions, focus: CGPoint, scale: CGSize) throws {
        guard imageSize.width > 0, imageSize.height > 0,
              focus.x.isFinite, focus.y.isFinite,
              scale.width.isFinite, scale.height.isFinite, scale.width > 0, scale.height > 0 else {
            throw UpscaleError.invalidSize
        }
        let width = CGFloat(min(256, imageSize.width))
        let height = CGFloat(min(256, imageSize.height))
        let x = min(CGFloat(imageSize.width) - width,
                    max(0, (min(1, max(0, focus.x)) * CGFloat(imageSize.width) - width / 2).rounded()))
        let y = min(CGFloat(imageSize.height) - height,
                    max(0, (min(1, max(0, focus.y)) * CGFloat(imageSize.height) - height / 2).rounded()))
        let outputWidth = max(1, (width * scale.width).rounded())
        let outputHeight = max(1, (height * scale.height).rounded())
        guard outputWidth <= 16384, outputHeight <= 16384, outputWidth * outputHeight <= 50_000_000 else {
            throw UpscaleError.tooLarge
        }
        rect = CGRect(x: x, y: y, width: width, height: height)
        output = Dimensions(width: Int(outputWidth), height: Int(outputHeight))
    }
}
