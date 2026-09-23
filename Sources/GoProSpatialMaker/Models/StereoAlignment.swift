import Foundation
import CoreGraphics

/// Geometric correction applied to the right-eye image so that it lines up with the left eye.
/// All values are expressed relative to the output frame so they are resolution independent.
struct StereoAlignment: Equatable, Codable {
    /// Horizontal shift of the right eye as a fraction of frame width. Positive moves right.
    /// This is the convergence control: shifting the right eye changes where the zero-parallax plane sits.
    var horizontalShift: Double = 0
    /// Vertical shift of the right eye as a fraction of frame height. Positive moves down.
    var verticalShift: Double = 0
    /// Rotation of the right eye in degrees, counter-clockwise positive.
    var rotationDegrees: Double = 0
    /// Uniform scale of the right eye. 1.0 = unchanged.
    var scale: Double = 1
    /// Brightness offset applied to the right eye (-1...1).
    var brightness: Double = 0
    /// Contrast multiplier applied to the right eye.
    var contrast: Double = 1
    /// Saturation multiplier applied to the right eye.
    var saturation: Double = 1

    static let identity = StereoAlignment()

    /// Affine transform mapping right-eye pixels into output space for a frame of the given size.
    /// Rotation and scale are applied around the frame centre.
    func transform(for size: CGSize) -> CGAffineTransform {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radians = rotationDegrees * .pi / 180
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: center.x + horizontalShift * size.width,
                           y: center.y - verticalShift * size.height)
        t = t.rotated(by: radians)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -center.x, y: -center.y)
        return t
    }
}
