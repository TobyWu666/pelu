import SwiftUI

#if os(iOS)
import ImageIO
import UIKit

struct AnimatedGIFView: UIViewRepresentable {
    let name: String
    var size: CGSize = CGSize(width: 30, height: 30)

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.image = animatedImage()
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = animatedImage()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? size.width,
            height: proposal.height ?? size.height
        )
    }

    private func animatedImage() -> UIImage? {
        guard let asset = NSDataAsset(name: name),
              let source = CGImageSourceCreateWithData(asset.data as CFData, nil)
        else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        var frames: [UIImage] = []
        var duration = 0.0

        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDuration(at: index, source: source)
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private func frameDuration(at index: Int, source: CGImageSource) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.08 }

        return (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.08
    }
}
#endif
