import SwiftUI
import ImageIO

/// `AsyncImage` decodes only the first frame of a GIF and never animates
/// it -- SwiftUI has no built-in animated-GIF support. This decodes every
/// frame (plus each frame's individual duration, which real GIFs vary
/// frame-to-frame, not a fixed rate) via ImageIO, the same system
/// framework macOS/iOS use internally, and drives playback with a loop
/// that sleeps for each frame's actual duration rather than a fixed
/// timer -- a GIF with a held final frame or variable pacing plays back
/// correctly instead of looking rushed/wrong.
struct AnimatedGIFView: View {
    let url: URL

    @State private var frames: [UIImage] = []
    @State private var durations: [Double] = []
    @State private var currentFrame = 0
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let image = frames[safe: currentFrame] {
                Image(uiImage: image).resizable()
            } else {
                Color.black.opacity(0.05)
                    .overlay { ProgressView() }
            }
        }
        .task(id: url) {
            await loadFrames()
        }
        .onDisappear {
            playbackTask?.cancel()
        }
    }

    private func loadFrames() async {
        playbackTask?.cancel()
        frames = []
        durations = []
        currentFrame = 0

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return }

        let count = CGImageSourceGetCount(source)
        var decodedFrames: [UIImage] = []
        var decodedDurations: [Double] = []
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            decodedFrames.append(UIImage(cgImage: cgImage))
            decodedDurations.append(Self.frameDuration(source: source, index: i))
        }
        guard !decodedFrames.isEmpty else { return }
        frames = decodedFrames
        durations = decodedDurations

        guard decodedFrames.count > 1 else { return } // static image, nothing to animate
        playbackTask = Task {
            while !Task.isCancelled {
                let duration = durations[safe: currentFrame] ?? 0.1
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                currentFrame = (currentFrame + 1) % frames.count
            }
        }
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        // GIFs commonly under-specify very short delays (some encoders
        // write 0) -- browsers/other viewers clamp to a sane minimum
        // rather than spinning as fast as the CPU allows.
        return max(unclamped ?? clamped ?? 0.1, 0.02)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension URL {
    /// GIF and WebP can both be animated (Giphy serves stickers as either);
    /// PNG/JPEG never are. Used to decide whether a media message/picker
    /// cell is worth the extra multi-frame decode at all.
    var isLikelyAnimated: Bool {
        let ext = pathExtension.lowercased()
        return ext == "gif" || ext == "webp"
    }
}
