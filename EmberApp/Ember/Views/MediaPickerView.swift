import SwiftUI

/// Emoji/GIF/sticker picker, tabbed like the web app's merged content
/// panel. Emoji taps append to the composer draft (`onPickEmoji`, stays
/// open for picking several in a row); GIF/sticker taps send immediately
/// (`onPick`, closes the sheet) -- the receiving bubble's own
/// isImageMessage check renders a picked GIF/sticker inline, no special
/// message kind needed.
struct MediaPickerView: View {
    @Bindable var client: ChatClient
    let onPick: (String) -> Void
    let onPickEmoji: (String) -> Void

    @State private var tab: Tab = .emoji
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    enum Tab { case emoji, gif, sticker }

    private let gridColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
    private let emojiColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Emoji").tag(Tab.emoji)
                    Text("GIFs").tag(Tab.gif)
                    Text("Stickers").tag(Tab.sticker)
                }
                .pickerStyle(.segmented)
                .padding()
                .onChange(of: tab) { if tab != .emoji { search() } }

                if tab != .emoji {
                    TextField("Search", text: $query)
                        .padding(10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .onSubmit(search)
                }

                ScrollView {
                    if tab == .emoji {
                        LazyVGrid(columns: emojiColumns, spacing: 4) {
                            ForEach(EmojiCatalog.all, id: \.self) { emoji in
                                Button {
                                    onPickEmoji(emoji)
                                } label: {
                                    Text(emoji).font(.system(size: 28)).frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 6) {
                            ForEach(results) { item in
                                MediaGridCell(item: item) {
                                    onPick(item.url)
                                    dismiss()
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .navigationTitle("Emoji, GIFs & Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var results: [MediaResult] {
        tab == .gif ? client.gifResults : client.stickerResults
    }

    private func search() {
        if tab == .gif { client.searchGifs(query) } else if tab == .sticker { client.searchStickers(query) }
    }
}

/// A grid cell's square shape comes from the *cell container* (a Color
/// with no intrinsic size of its own, aspect-ratio-constrained to 1:1),
/// never from the image directly -- an AsyncImage/AnimatedGIFView with no
/// definite size yet (still loading) has nothing stable to resolve
/// `.aspectRatio` against, which is exactly the squashed-thumbnail bug
/// this app's web version hit and fixed the same way (see project notes).
private struct MediaGridCell: View {
    let item: MediaResult
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.black.opacity(0.05)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url = URL(string: item.preview) {
                        if url.isLikelyAnimated {
                            AnimatedGIFView(url: url).aspectRatio(contentMode: .fill)
                        } else {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                }
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .clipped()
        }
        .buttonStyle(.plain)
    }
}

/// Generated from the standard Unicode emoji blocks rather than a
/// hand-typed list -- covers the common ranges (emoticons, symbols &
/// pictographs, transport, supplemental symbols) without needing a
/// bundled emoji database. Filters out unassigned code points within
/// each range so no tofu boxes show up in the grid.
enum EmojiCatalog {
    static let all: [String] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, // emoticons
            0x1F300...0x1F5FF, // misc symbols & pictographs
            0x1F680...0x1F6FF, // transport & map
            0x1F900...0x1F9FF, // supplemental symbols & pictographs
            0x2600...0x26FF,   // misc symbols
            0x2700...0x27BF,   // dingbats
        ]
        return ranges.flatMap { range in
            range.compactMap { scalarValue -> String? in
                guard let scalar = Unicode.Scalar(scalarValue), scalar.properties.isEmoji, scalar.properties.isEmojiPresentation else { return nil }
                return String(Character(scalar))
            }
        }
    }()
}
