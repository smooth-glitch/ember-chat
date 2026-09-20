import SwiftUI
import AVFoundation

/// Minimal inline voice-note player -- play/pause + elapsed time, no
/// scrubbing (matching the demo scope; the web app's native `<audio
/// controls>` has more, but a play button is what actually matters for a
/// live demo).
struct AudioMessagePlayer: View {
    let url: URL
    let tint: Color

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.15), in: .circle)
            }
            Capsule().fill(tint.opacity(0.3)).frame(height: 3)
        }
        .frame(width: 160)
        .onDisappear {
            player?.pause()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
        }
    }

    private func toggle() {
        if player == nil {
            player = AVPlayer(url: url)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { _ in
                isPlaying = false
                player?.seek(to: .zero)
            }
        }
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
}
