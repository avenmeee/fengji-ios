import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 分享卡片：第一张照片、标题、价格，底下蜂集标志、帖子链接和二维码。不放联系方式。浅色。
struct ShareCard: View {
    let item: Listing
    let photo: UIImage?

    /// 链接去掉 https:// 好看一点
    private var shortLink: String {
        item.shareURL.replacingOccurrences(of: "https://", with: "")
    }

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
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(item.priceText)
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.3)
                        .foregroundStyle(item.price == 0 ? Theme.sell : Theme.ink)
                    if item.isRent { Text("/月").font(.title3).foregroundStyle(Theme.sub) }
                }
                Theme.line.frame(height: 0.5).padding(.top, 10).padding(.bottom, 8)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            BeeIcon(level: 3, size: 24)
                            Text("蜂集").font(.system(size: 17, weight: .bold))
                        }
                        Text(shortLink)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("扫码看详情").font(.system(size: 12)).foregroundStyle(Theme.sub)
                    }
                    Spacer(minLength: 0)
                    if let qr = QRCode.image(item.shareURL) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 76, height: 76)
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .frame(width: 390)
        .environment(\.colorScheme, .light)
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage,
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
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
