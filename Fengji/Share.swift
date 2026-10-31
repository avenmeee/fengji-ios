import SwiftUI
import UIKit

/// 发到微信群的图：照片、标题、价格、地点、微信号
struct ShareCard: View {
    let item: Listing
    let photo: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let photo {
                        Image(uiImage: photo).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ListingImage(item: item)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(item.priceText + (item.isRent ? " /月" : ""))
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(item.price == 0 ? Theme.sell : Theme.ink)
                Text(item.isRent ? [item.place, item.period].filter { !$0.isEmpty }.joined(separator: " · ") : [item.place, item.pickupText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
                if item.findInGroup {
                    Text("去 \(item.sourceGroup ?? "") 群找 \(item.sourcePoster ?? "")").font(.subheadline.weight(.semibold))
                    Text("\(item.groupAge)发在群里").font(.footnote).foregroundStyle(Theme.sub)
                } else if let contact = item.contact {
                    Text("微信 " + contact).font(.subheadline.weight(.semibold))
                }
                HStack(spacing: 6) {
                    Hexagon().fill(Theme.accent).frame(width: 16, height: 16)
                    Text("蜂集").font(.footnote.weight(.semibold))
                }
                .padding(.top, 6)
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .frame(width: 390)
        .environment(\.colorScheme, .light)
    }
}

struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage

    @MainActor
    static func make(_ item: Listing) async -> ShareImage? {
        var photo: UIImage?
        if let first = item.photos.first, let url = URL(string: first.url),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            photo = UIImage(data: data)
        }
        let renderer = ImageRenderer(content: ShareCard(item: item, photo: photo))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }
        return ShareImage(image: image)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
