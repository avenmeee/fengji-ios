import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
}

/// 所有颜色都在这里（视觉定稿 A 蜂蜜）。
enum Theme {
    static let bg = dyn(0xFFFFFF, 0x262524)
    /// 搜索框、小标签、输入框、条目块的底
    static let fill = dyn(0xF2F2F0, 0x353330)
    static let line = dyn(0xE5E5E3, 0x413F3C)
    static let ink = dyn(0x1C1C1E, 0xF2EFE9)
    static let sub = dyn(0x6E6E73, 0xAAA7A1)
    static let bar = dyn(0xFFFFFF, 0x35332F).opacity(0.88)

    // 买、卖、租各一个颜色
    static let buy = dyn(0xF5B800, 0xF7C331)
    static let onBuy = dyn(0x1C1C1E, 0x241E0A)
    static let sell = dyn(0xBE5338, 0xE58A6D)
    static let onSell = dyn(0xFFFFFF, 0x2B1610)
    static let rent = dyn(0x4B7A55, 0x7FAE89)
    static let onRent = dyn(0xFFFFFF, 0x17241B)
    static let rentSoft = dyn(0xE6EFE8, 0x344036)
    static let sellSoft = dyn(0xFAF0EB, 0x3D2C26)
    static let accentSoft = dyn(0xFDF1C7, 0x4A3D14)

    static let accent = buy
    /// 系统控件的强调色：黄字在白底上看不清，浅色下压深。
    static let tint = dyn(0x9A7400, 0xF7C331)
    static let warn = sell
    static let warnSoft = dyn(0xF8E7E1, 0x46322B)

    /// 底栏占的高度，滚动内容底部留出来
    static let barSpace: CGFloat = 96
}

/// 一页的动作色：底色和上面的字
struct Act {
    let fill: Color
    let on: Color
    /// 必填区的底
    let soft: Color

    static let buy = Act(fill: Theme.buy, on: Theme.onBuy, soft: Theme.accentSoft)
    static let sell = Act(fill: Theme.sell, on: Theme.onSell, soft: Theme.sellSoft)
    static let rent = Act(fill: Theme.rent, on: Theme.onRent, soft: Theme.rentSoft)
}

struct Tint {
    let bg: Color
    let fg: Color
    let symbol: String

    static func of(_ item: Listing) -> Tint {
        if item.kind == "rent" { return Tint(bg: dyn(0xE8EAE2, 0x383C33), fg: dyn(0x55624A, 0xB4C2A4), symbol: "house") }
        switch item.cat {
        case "furn": return Tint(bg: dyn(0xF1E8D8, 0x423A2C), fg: dyn(0x8A6A35, 0xD9BC85), symbol: "sofa")
        case "kitchen": return Tint(bg: dyn(0xF3E9DC, 0x43382B), fg: dyn(0x9A6A3A, 0xDDB78C), symbol: "fork.knife")
        case "elec": return Tint(bg: dyn(0xDFE7F0, 0x2F3A47), fg: dyn(0x3F628A, 0x9DBBDD), symbol: "desktopcomputer")
        case "art": return Tint(bg: dyn(0xF6DFD7, 0x46322B), fg: dyn(0xB04E33, 0xE58A6D), symbol: "paintbrush.pointed")
        default: return Tint(bg: dyn(0xECEBE7, 0x3A3936), fg: dyn(0x6B6A66, 0xB4B1AB), symbol: "shippingbox")
        }
    }
}

// MARK: - 小部件

/// 发布表单里的选项：选中的涂这一页的颜色
struct Chip: View {
    let text: String
    let on: Bool
    var act: Act = .buy
    var surface: Color = Theme.fill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? act.on : Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(on ? act.fill : surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 分类图标（视觉定稿的一套），模板色
struct CategoryIcon: View {
    let key: String
    var size: CGFloat = 24

    var body: some View {
        Image(key.hasPrefix("rent-") ? key : "cat-\(key)")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var act: Act = .buy
    /// 必填还没齐：看着淡，点了会说缺什么
    var dimmed = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(act.on)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(act.fill.opacity(dimmed ? 0.4 : (enabled ? (configuration.isPressed ? 0.8 : 1) : 0.55)), in: RoundedRectangle(cornerRadius: 17))
    }
}

struct ActionChip: View {
    let text: String
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(danger ? Theme.warn : Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(danger ? Theme.warn : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SearchBox: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 空状态只写一行，不放框
struct EmptyBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }
}

/// 自动换行的一排选项
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// 六边形细节（尖朝上）
struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY, r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// 小蜜蜂：五档分数的图标。六边形身子、两道黑纹、两片翅膀
struct BeeMark: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            HStack(spacing: size * 0.1) {
                Ellipse().stroke(Theme.ink, lineWidth: size * 0.09).frame(width: size * 0.4, height: size * 0.26).rotationEffect(.degrees(35))
                Ellipse().stroke(Theme.ink, lineWidth: size * 0.09).frame(width: size * 0.4, height: size * 0.26).rotationEffect(.degrees(-35))
            }
            .offset(y: -size * 0.32)
            Hexagon()
                .fill(Theme.buy)
                .frame(width: size * 0.78, height: size * 0.78)
                .overlay {
                    VStack(spacing: size * 0.1) {
                        Rectangle().fill(Color.black.opacity(0.85)).frame(height: size * 0.11)
                        Rectangle().fill(Color.black.opacity(0.85)).frame(height: size * 0.11)
                    }
                }
                .clipShape(Hexagon())
                .offset(y: size * 0.1)
        }
        .frame(width: size, height: size)
    }
}

/// 蜜蜂 + 档位数字。没打分不显示。
struct ScoreBadge: View {
    let score: Int?
    var size: CGFloat = 14

    var body: some View {
        if let score {
            HStack(spacing: 3) {
                BeeMark(size: size)
                Text("\(score)")
                    .font(.system(size: size, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("蜂集评分 \(score) 档")
        }
    }
}

/// 加载动画：六边形慢慢灌满蜂蜜，循环。减弱动态效果时停在半满。
struct HoneyLoader: View {
    var size: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: CGFloat = 0

    var body: some View {
        ZStack {
            Hexagon().fill(Theme.buy.opacity(0.2))
            Rectangle()
                .fill(Theme.buy)
                .frame(height: size * (reduceMotion ? 0.55 : level))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(Hexagon())
        }
        .frame(width: size, height: size)
        .accessibilityLabel("正在加载")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { level = 1 }
        }
    }
}

enum Haptics {
    /// 发布成功：像蜜蜂振翅，连着四下轻触，很短。用系统触感，跟随系统设置。
    @MainActor
    static func beeBuzz() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        for i in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045) {
                gen.impactOccurred(intensity: i == 3 ? 0.5 : 0.8)
            }
        }
    }
}

// MARK: - 图片

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let store = NSCache<NSString, UIImage>()

    func get(_ key: String) -> UIImage? { store.object(forKey: key as NSString) }
    func set(_ key: String, _ image: UIImage) { store.setObject(image, forKey: key as NSString) }
}

struct RemoteImage: View {
    let url: String
    var maxPixel: CGFloat = 600
    var fill = true
    @State private var image: UIImage?

    private var cacheKey: String { "\(url)#\(Int(maxPixel))" }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Color.clear
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        if let hit = ImageCache.shared.get(cacheKey) {
            image = hit
            return
        }
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u) else { return }
        guard let full = UIImage(data: data) else { return }
        let longest = max(full.size.width, full.size.height)
        let scale = min(1, maxPixel / max(longest, 1))
        let target = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let thumb = await full.byPreparingThumbnail(ofSize: target) ?? full
        ImageCache.shared.set(cacheKey, thumb)
        image = thumb
    }
}

/// 条目的图：有照片放照片，没有放分类图标
struct ListingImage: View {
    let item: Listing
    var index = 0
    var maxPixel: CGFloat = 600

    var body: some View {
        let tint = Tint.of(item)
        ZStack {
            tint.bg
            Hexagon()
                .fill(tint.fg.opacity(0.12))
                .frame(width: 84, height: 84)
            Image(systemName: tint.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint.fg)
            if item.photos.indices.contains(index) {
                RemoteImage(url: item.photos[index].url, maxPixel: maxPixel)
            }
        }
    }
}
