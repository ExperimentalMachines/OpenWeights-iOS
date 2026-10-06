import SwiftUI
import OpenWeightsCore

struct MediaResultCarousel: View {
    let evidence: MediaSearchEvidence
    let cache: MediaPreviewCache?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(evidence.kind == .videos ? "Clips" : "Pictures") for \(evidence.query) from DuckDuckGo")
                .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(evidence.hits.prefix(8).enumerated()), id: \.offset) { _, hit in
                        MediaResultCard(hit: hit, cache: cache)
                    }
                }
            }.accessibilityIdentifier("media.results")
            Text("Open a result to see its source page. Missing previews need a new search to refresh.")
                .font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
        }
    }
}
private struct MediaResultCard: View {
    let hit: MediaSearchHit
    let cache: MediaPreviewCache?
    @State private var preview: UIImage?
    @State private var settled = false
    var body: some View {
        if let address = try? PublicWebAddress(hit.sourceURL) {
            Link(destination: address.url) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        OWTheme.raised
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFill()
                        } else if settled {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                Text("Preview unavailable").font(OWTheme.interface(12))
                            }.foregroundStyle(OWTheme.secondary)
                        } else { ProgressView().accessibilityLabel("Loading saved preview") }
                        if hit.kind == .videos && preview != nil {
                            Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white)
                                .shadow(radius: 3)
                        }
                    }.frame(width: 144, height: 108).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(hit.title).font(OWTheme.interface(13)).foregroundStyle(OWTheme.text).lineLimit(3)
                    Text(address.host).font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary).lineLimit(1)
                }.frame(width: 144, alignment: .leading)
            }.accessibilityLabel("Open \(hit.kind == .videos ? "clip" : "picture") source: \(hit.title)")
                .task(id: hit.previewKey) {
                    preview = nil; settled = false
                    if let key = hit.previewKey, let cache, let data = await cache.cached(key), !Task.isCancelled { preview = UIImage(data: data) }
                    if !Task.isCancelled { settled = true }
                }
        }
    }
}
