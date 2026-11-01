import SwiftUI
import UIKit

/// 发好的一件，填进蜂巢的一格
struct HiveItem: Identifiable {
    let id = UUID()
    var image: UIImage?
    var url: String?
    let priceText: String
}

/// 蜂巢的格子：第一件在中间，第二件在右边，之后顺时针一圈圈往外
enum HiveLayout {
    /// 第 n 格的轴坐标（尖朝上）
    static func cells(_ count: Int) -> [(q: Int, r: Int)] {
        var out: [(q: Int, r: Int)] = [(0, 0)]
        var ring = 1
        while out.count < count {
            var q = ring, r = 0
            out.append((q, r))
            for (dq, dr) in [(-1, 1), (-1, 0), (0, -1), (1, -1), (1, 0), (0, 1)] {
                for _ in 0..<ring {
                    q += dq
                    r += dr
                    if q == ring && r == 0 { continue }
                    out.append((q, r))
                }
            }
            ring += 1
        }
        return Array(out.prefix(count))
    }

    /// 一屏放下时的半径和每格中心
    static func fit(_ count: Int, in size: CGSize, maxRadius: CGFloat) -> (radius: CGFloat, centers: [CGPoint]) {
        let raw = cells(count).map { c in
            CGPoint(x: 3.0.squareRoot() * (Double(c.q) + Double(c.r) / 2), y: 1.5 * Double(c.r))
        }
        guard let minX = raw.map(\.x).min(), let maxX = raw.map(\.x).max(),
              let minY = raw.map(\.y).min(), let maxY = raw.map(\.y).max() else { return (0, []) }
        let spanX = maxX - minX + 3.0.squareRoot(), spanY = maxY - minY + 2
        let radius = min(maxRadius, min(size.width / spanX, size.height / spanY))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        return (radius, raw.map { CGPoint(x: size.width / 2 + ($0.x - midX) * radius, y: size.height / 2 + ($0.y - midY) * radius) })
    }
}

private struct HiveCellImage: View {
    let item: HiveItem

    var body: some View {
        Group {
            if let image = item.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let url = item.url {
                RemoteImage(url: url, maxPixel: 500)
            } else {
                Theme.fill
            }
        }
    }
}

/// 发好之后：照片填进新的一格，旁边黄格点了再发一件
struct HivePostedView: View {
    let items: [HiveItem]
    let again: () -> Void
    let share: () -> Void
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown: UUID?

    private var shown: [HiveItem] { Array(items.suffix(10)) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text("发好了").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink)
                Text(items.count == 1 ? "首页已经能看到" : "这次发了 \(items.count) 件，首页已经能看到")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.sub)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
            GeometryReader { geo in
                let fit = HiveLayout.fit(shown.count + 1, in: geo.size, maxRadius: 86)
                ZStack {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        HiveCellImage(item: item)
                            .frame(width: fit.radius * 2, height: fit.radius * 2)
                            .clipShape(Hexagon())
                            .padding(0)
                            .scaleEffect(grown == item.id ? 0.85 : 0.96)
                            .position(fit.centers[index])
                    }
                    Button(action: again) {
                        ZStack {
                            Hexagon().fill(Theme.accent)
                            if fit.radius > 55 {
                                Text("再发一件").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onBuy)
                            } else {
                                Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.onBuy)
                            }
                        }
                        .frame(width: fit.radius * 2 * 0.96, height: fit.radius * 2 * 0.96)
                        .contentShape(Hexagon())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("再发一件")
                    .position(fit.centers[shown.count])
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.3), value: items.count)
            }
            .padding(14)
            .frame(maxHeight: 360)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 0)
            Button(action: share) {
                Label("分享到群", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink))
            Button("完成", action: done)
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .onAppear { popNewest() }
        .onChange(of: items.count) { _, _ in popNewest() }
    }

    /// 新格从 0.85 弹到正常
    private func popNewest() {
        guard !reduceMotion else { return }
        grown = items.last?.id
        withAnimation(.spring(duration: 0.22, bounce: 0.3)) { grown = nil }
    }
}

/// 分享到微信群的竖图：蜂巢清单，带价格和微信号
struct HiveShareCard: View {
    let items: [HiveItem]
    let contact: String
    let total: Int
    var width: CGFloat = 360

    /// 每行几格：4 件以内每行两格，多了三二交替
    private var rows: [Range<Int>] {
        let n = items.count
        var out: [Range<Int>] = []
        var start = 0
        var wide = n > 4
        while start < n {
            let take = min(n <= 4 ? 2 : (wide ? 3 : 2), n - start)
            out.append(start..<(start + take))
            start += take
            wide.toggle()
        }
        return out
    }

    private var cellWidth: CGFloat {
        let columns = CGFloat(rows.map(\.count).max() ?? 1)
        return (width - 32) / max(columns, 1)
    }

    var body: some View {
        let w = cellWidth, r = w / 3.0.squareRoot()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Hexagon().fill(Theme.accent).frame(width: 32, height: 32)
                    BeeIcon(level: 3, size: 18)
                }
                Text("蜂集").font(.system(size: 18, weight: .bold))
                Spacer()
                Text("发了 \(total) 件").font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            VStack(spacing: -r * 0.5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { i in
                            ZStack(alignment: .bottom) {
                                HiveCellImage(item: items[i])
                                    .frame(width: w, height: r * 2)
                                    .clipShape(Hexagon())
                                Text(items[i].priceText)
                                    .font(.system(size: max(14, w * 0.12), weight: .bold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .padding(.bottom, r * 0.32)
                            }
                            .scaleEffect(0.97)
                            .frame(width: w, height: r * 2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
            if !contact.isEmpty {
                HStack(spacing: 12) {
                    ZStack {
                        Hexagon().fill(Theme.fill).frame(width: 32, height: 32)
                        Image(systemName: "message").font(.system(size: 14)).foregroundStyle(Theme.sub)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("加微信").font(.system(size: 13)).foregroundStyle(Theme.sub)
                        Text(contact).font(.system(size: 22, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                .padding(7)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(16)
        .frame(width: width)
        .background(Theme.bg)
        .environment(\.colorScheme, .light)
    }

    /// 宽 1080 的图。网上的照片先取下来，渲染时不会等网络。
    @MainActor
    static func make(items: [HiveItem], contact: String, total: Int) async -> ShareImage? {
        var loaded: [HiveItem] = []
        for item in items.suffix(10) {
            var copy = item
            if copy.image == nil, let s = item.url, let url = URL(string: s),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                copy.image = UIImage(data: data)
            }
            loaded.append(copy)
        }
        let renderer = ImageRenderer(content: HiveShareCard(items: loaded, contact: contact, total: total))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }
        return ShareImage(image: image)
    }
}

// MARK: - 四档小蜜蜂

/// 一档比一档满。5 档可以传翅膀角度和上移，做动效用。
struct BeeIcon: View {
    let level: Int
    var size: CGFloat = 19
    var wing: Double = 0
    var lift: Double = 0
    var scale: Double = 1

    private func hex(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private func wingPath(cx: CGFloat, cy: CGFloat, degrees: CGFloat) -> Path {
        let rect = CGRect(x: cx - 13, y: cy - 7, width: 26, height: 14)
        let t = CGAffineTransform(translationX: cx, y: cy).rotated(by: degrees * .pi / 180).translatedBy(x: -cx, y: -cy)
        return Path(ellipseIn: rect).applying(t)
    }

    private var stroke: Color { Theme.ink }
    private let round = StrokeStyle(lineWidth: 5, lineJoin: .round)

    var body: some View {
        Canvas { ctx, canvas in
            ctx.scaleBy(x: canvas.width / 64, y: canvas.height / 64)
            switch level {
            case ...1:
                ctx.drawLayer { l in
                    l.clip(to: Path(CGRect(x: 0, y: 32, width: 64, height: 32)))
                    l.fill(hex(32, 32, 22), with: .color(Theme.buy))
                }
                ctx.stroke(hex(32, 32, 22), with: .color(Theme.sub), style: round)
            case 2:
                body3(&ctx)
            default:
                ctx.translateBy(x: 32, y: 36 - lift)
                ctx.scaleBy(x: scale, y: scale)
                if level >= 4 { ctx.rotate(by: .degrees(14)) }
                ctx.translateBy(x: -32, y: -36)
                drawWing(&ctx, center: CGPoint(x: 16, y: 17), tilt: 32, root: CGPoint(x: 23, y: 26), angle: wing)
                drawWing(&ctx, center: CGPoint(x: 48, y: 17), tilt: -32, root: CGPoint(x: 41, y: 26), angle: -wing)
                ctx.fill(hex(32, 39, 20), with: .color(Theme.buy))
                ctx.drawLayer { l in
                    l.clip(to: hex(32, 39, 20.5))
                    l.fill(Path(CGRect(x: 0, y: 34.25, width: 64, height: 4.32)), with: .color(.black.opacity(0.9)))
                    l.fill(Path(CGRect(x: 0, y: 42.02, width: 64, height: 4.32)), with: .color(.black.opacity(0.9)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func body3(_ ctx: inout GraphicsContext) {
        ctx.fill(hex(32, 32, 24), with: .color(Theme.buy))
        ctx.drawLayer { l in
            l.clip(to: hex(32, 32, 24.5))
            l.fill(Path(CGRect(x: 0, y: 26.25, width: 64, height: 5.23)), with: .color(.black.opacity(0.9)))
            l.fill(Path(CGRect(x: 0, y: 35.66, width: 64, height: 5.23)), with: .color(.black.opacity(0.9)))
        }
    }

    private func drawWing(_ ctx: inout GraphicsContext, center: CGPoint, tilt: CGFloat, root: CGPoint, angle: Double) {
        let path = wingPath(cx: center.x, cy: center.y, degrees: tilt)
        let filled = level >= 4
        ctx.drawLayer { l in
            l.translateBy(x: root.x, y: root.y)
            l.rotate(by: .degrees(angle))
            l.translateBy(x: -root.x, y: -root.y)
            if filled { l.fill(path, with: .color(Theme.buy)) }
            l.stroke(path, with: .color(stroke), lineWidth: 4)
        }
    }
}

private struct BeeMotion {
    var wing = 0.0
    var lift = 0.0
    var scale = 1.0
}

/// 这次打开已经飞过的，不再飞
@MainActor
enum BeeSeen {
    static var ids = Set<String>()
}

func scoreLabel(_ score: Int) -> String {
    switch score {
    case ...1: return "偏贵"
    case 2: return "价格合理"
    case 3: return "有性价比"
    default: return "捡漏"
    }
}

/// 蜜蜂 + 档位文字。没打分不显示。捡漏第一次出现时扇一下翅膀。
struct ScoreBadge: View {
    let score: Int?
    var size: CGFloat = 18
    /// 列表里传条目编号：同一次打开只飞一次。详情传 nil，打开就飞。
    var playID: String?
    var plays = true
    /// 档位字的大小；不给就按蜜蜂大小定
    var labelSize: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tick = 0
    @State private var waiting: Task<Void, Never>?

    var body: some View {
        if let score {
            HStack(spacing: 3) {
                if score >= 4 {
                    KeyframeAnimator(initialValue: BeeMotion(), trigger: tick) { v in
                        BeeIcon(level: score, size: size, wing: v.wing, lift: v.lift, scale: v.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.wing) {
                            CubicKeyframe(16, duration: 0.08)
                            CubicKeyframe(-16, duration: 0.08)
                            CubicKeyframe(12, duration: 0.08)
                            CubicKeyframe(-12, duration: 0.08)
                            CubicKeyframe(0, duration: 0.16)
                        }
                        KeyframeTrack(\.lift) {
                            CubicKeyframe(1.5, duration: 0.08)
                            CubicKeyframe(3, duration: 0.08)
                            CubicKeyframe(2, duration: 0.08)
                            CubicKeyframe(1, duration: 0.08)
                            CubicKeyframe(0, duration: 0.16)
                        }
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.06, duration: 0.08)
                            CubicKeyframe(1.08, duration: 0.08)
                            CubicKeyframe(1.05, duration: 0.08)
                            CubicKeyframe(1.02, duration: 0.08)
                            CubicKeyframe(1, duration: 0.16)
                        }
                    }
                } else {
                    BeeIcon(level: score, size: size)
                }
                Text(scoreLabel(score))
                    .font(.system(size: labelSize ?? (size >= 24 ? 16 : 13), weight: score >= 4 ? .semibold : .regular))
                    .foregroundStyle(score >= 4 ? Theme.ink : Theme.sub)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scoreLabel(score))
            .onAppear { schedule(score) }
            .onDisappear { waiting?.cancel() }
        }
    }

    /// 等一下还在屏幕上才飞，快速滚动时不飞
    private func schedule(_ score: Int) {
        guard plays, score >= 4, !reduceMotion else { return }
        if let id = playID, BeeSeen.ids.contains(id) { return }
        waiting = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            if let id = playID { BeeSeen.ids.insert(id) }
            tick += 1
        }
    }
}
