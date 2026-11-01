import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 分享卡片：首页 C 卡放大（卡纸、价签、名字、卖家和地点），底下蜂集标志、“扫码看详情”和二维码。不放联系方式。浅色。
struct ShareCard: View {
    let item: Listing
    let photo: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(item.isRent ? 1.6 : 0.8, contentMode: .fit)
                    .overlay {
                        if let photo {
                            Image(uiImage: photo).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ListingImage(item: item)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { PriceTag(item: item).scaleEffect(1.2, anchor: .bottomLeading).padding(4) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
                    SellerLine(item: item, extra: [item.place], avatarSize: 18, fontSize: 14)
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .padding(8)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18))
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Hexagon().fill(Theme.accent).frame(width: 40, height: 40)
                    BeeIcon(level: 3, size: 22)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("蜂集").font(.system(size: 18, weight: .bold))
                    Text("扫码看详情").font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                Spacer(minLength: 0)
                if let qr = QRCode.image(item.shareURL) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .padding(4)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                }
            }
            .padding(.horizontal, 8)
        }
        .foregroundStyle(Theme.ink)
        .padding(14)
        .frame(width: 390)
        .background(Theme.bg)
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
