import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Applies the stereo alignment to individual frames using Core Image.
/// Used both for the interactive preview and, frame by frame, by the exporter.
final class StereoFrameRenderer {
    let context: CIContext

    init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709) as Any,
            .cacheIntermediates: false
        ])
    }

    // MARK: Per-eye correction

    /// Returns the left and right eye images, corrected and cropped to `outputSize`.
    func correctedPair(left: CIImage, right: CIImage, alignment: StereoAlignment, swapEyes: Bool, outputSize: CGSize) -> (left: CIImage, right: CIImage) {
        let (l, r) = swapEyes ? (right, left) : (left, right)
        let leftOut = fit(l, to: outputSize)
        var rightOut = fit(r, to: outputSize)
        rightOut = applyAlignment(alignment, to: rightOut, size: outputSize)
        return (leftOut, rightOut)
    }

    /// Scales (aspect-fill) and crops an image to the given size, anchored at the origin.
    func fit(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        var out = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        if abs(scale - 1) > 0.0001 {
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let dx = (scaledSize.width - size.width) / 2
        let dy = (scaledSize.height - size.height) / 2
        out = out.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    func applyAlignment(_ alignment: StereoAlignment, to image: CIImage, size: CGSize) -> CIImage {
        var out = image
        if alignment.brightness != 0 || alignment.contrast != 1 || alignment.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = out
            filter.brightness = Float(alignment.brightness)
            filter.contrast = Float(alignment.contrast)
            filter.saturation = Float(alignment.saturation)
            out = filter.outputImage ?? out
        }
        if alignment != .identity {
            // Extend edges so the transform doesn't reveal transparent borders.
            out = out.clampedToExtent()
                .transformed(by: alignment.transform(for: size))
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        return out
    }

    // MARK: Preview

    func renderPreview(left: AVAsset, leftTime: CMTime, right: AVAsset, rightTime: CMTime,
                       alignment: StereoAlignment, swapEyes: Bool, mode: PreviewMode, maxWidth: CGFloat) async throws -> CGImage {
        let leftImage = try await grabFrame(asset: left, time: leftTime)
        let rightImage = try await grabFrame(asset: right, time: rightTime)

        let sourceSize = leftImage.extent.size
        let previewScale = min(1, maxWidth / max(sourceSize.width, 1))
        let previewSize = CGSize(width: floor(sourceSize.width * previewScale), height: floor(sourceSize.height * previewScale))

        let (l, r) = correctedPair(left: leftImage, right: rightImage, alignment: alignment, swapEyes: swapEyes, outputSize: previewSize)
        let composite = compose(left: l, right: r, mode: mode, size: previewSize)

        guard let cgImage = context.createCGImage(composite, from: composite.extent) else {
            throw SpatialMakerError.unsupported("プレビューの生成に失敗しました")
        }
        return cgImage
    }

    func compose(left: CIImage, right: CIImage, mode: PreviewMode, size: CGSize) -> CIImage {
        switch mode {
        case .left:
            return left
        case .right:
            return right
        case .blend:
            let filter = CIFilter.dissolveTransition()
            filter.inputImage = left
            filter.targetImage = right
            filter.time = 0.5
            return filter.outputImage ?? left
        case .difference:
            let filter = CIFilter.differenceBlendMode()
            filter.inputImage = right
            filter.backgroundImage = left
            return filter.outputImage ?? left
        case .anaglyph:
            // Red channel from the left eye, green + blue from the right eye.
            let redOnly = CIFilter.colorMatrix()
            redOnly.inputImage = left
            redOnly.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            redOnly.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            redOnly.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            redOnly.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let cyanOnly = CIFilter.colorMatrix()
            cyanOnly.inputImage = right
            cyanOnly.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            cyanOnly.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            cyanOnly.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
            cyanOnly.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let add = CIFilter.additionCompositing()
            add.inputImage = redOnly.outputImage
            add.backgroundImage = cyanOnly.outputImage
            return add.outputImage ?? left
        case .sideBySide:
            let shiftedRight = right.transformed(by: CGAffineTransform(translationX: size.width, y: 0))
            return shiftedRight.composited(over: left.cropped(to: CGRect(origin: .zero, size: size)))
                .cropped(to: CGRect(x: 0, y: 0, width: size.width * 2, height: size.height))
        }
    }

    private func grabFrame(asset: AVAsset, time: CMTime) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (cgImage, _) = try await generator.image(at: time)
        return CIImage(cgImage: cgImage)
    }

    // MARK: Pixel buffer output (export path)

    func render(_ image: CIImage, to pixelBuffer: CVPixelBuffer) {
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        context.render(image, to: pixelBuffer, bounds: image.extent, colorSpace: colorSpace)
    }
}
