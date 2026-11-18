import LayerFitCore
import SwiftUI

/// Shows a fitted picture drawn from its vectors at the view's full resolution, or the
/// original photo, keeping the aspect ratio and centred.
struct PictureView: View {
    var picture: LayerFitCore.Picture?
    var original: CGImage?
    var showsOriginal: Bool

    var body: some View {
        Canvas { context, size in
            if showsOriginal, let original {
                let rect = fit(
                    CGSize(width: original.width, height: original.height), in: size)
                context.draw(Image(decorative: original, scale: 1), in: rect)
            } else if let picture {
                let rect = fit(CGSize(width: picture.width, height: picture.height), in: size)
                context.withCGContext { cg in
                    cg.translateBy(x: rect.minX, y: rect.minY)
                    draw(picture, in: cg, size: rect.size)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
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
