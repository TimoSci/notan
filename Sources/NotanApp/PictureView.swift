import NotanCore
import SwiftUI

/// Shows a fitted picture drawn from its vectors at the view's full resolution, or the
/// original photo, keeping the aspect ratio and centred. Reports clicks in picture
/// coordinates and outlines the selected region.
struct PictureView: View {
    var picture: NotanCore.Picture?
    var original: CGImage?
    var showsOriginal: Bool
    /// Refinements nested deeper than this are not drawn.
    var maxDepth: Int = .max
    var selectedShapes: [NotanCore.Shape] = []
    var backgroundSelected = false
    /// For each selected gap, white where it shows; a gap has no outline to draw.
    var selectedGapMasks: [CGImage] = []
    /// Called with the clicked point in picture coordinates, or nil for a click outside
    /// the picture, and whether Shift was held.
    var onClick: ((SIMD2<Float>?, Bool) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                if showsOriginal, let original {
                    let rect = fit(
                        CGSize(width: original.width, height: original.height), in: size)
                    context.draw(Image(decorative: original, scale: 1), in: rect)
                } else if let picture {
                    let rect = fit(CGSize(width: picture.width, height: picture.height), in: size)
                    context.withCGContext { cg in
                        cg.translateBy(x: rect.minX, y: rect.minY)
                        draw(picture, in: cg, size: rect.size, maxDepth: maxDepth)
                        outlineSelection(of: picture, in: cg, size: rect.size)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    guard let picture, !showsOriginal else { return }
                    let shift = NSEvent.modifierFlags.contains(.shift)
                    let rect = fit(
                        CGSize(width: picture.width, height: picture.height), in: geometry.size)
                    guard rect.contains(tap.location), rect.width > 0, rect.height > 0 else {
                        onClick?(nil, shift)
                        return
                    }
                    onClick?(
                        SIMD2(
                            Float((tap.location.x - rect.minX) / rect.width) * Float(picture.width),
                            Float((tap.location.y - rect.minY) / rect.height) * Float(picture.height)),
                        shift)
                })
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// A dark line under a light one, so the outline shows on any colour.
    private func outlineSelection(of picture: NotanCore.Picture, in cg: CGContext, size: CGSize) {
        for mask in selectedGapMasks {
            // Lighten the gap and leave everything else as it is.
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)  // images, and so masks, are bottom-up
            cg.clip(to: CGRect(origin: .zero, size: size), mask: mask)
            cg.setFillColor(CGColor(gray: 1, alpha: 0.32))
            cg.fill(CGRect(origin: .zero, size: size))
            cg.restoreGState()
        }
        let scaleX = size.width / CGFloat(picture.width)
        let scaleY = size.height / CGFloat(picture.height)
        var transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let path = CGMutablePath()
        for shape in selectedShapes {
            if let scaled = outline(of: shape).copy(using: &transform) { path.addPath(scaled) }
        }
        // The background with its gaps not told apart: frame the whole picture.
        if backgroundSelected, selectedGapMasks.isEmpty {
            path.addRect(CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
        }
        guard !path.isEmpty else { return }
        cg.saveGState()
        cg.clip(to: CGRect(origin: .zero, size: size))
        cg.setLineJoin(.round)
        for (width, color) in [(4.0, CGColor(gray: 0, alpha: 0.85)), (1.5, CGColor(gray: 1, alpha: 1))] {
            cg.setLineWidth(width)
            cg.setStrokeColor(color)
            cg.addPath(path)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    private func fit(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}
