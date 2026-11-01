import SwiftUI

// 设计规范（11-01 统一重做）里的通用零件：组标题、卡纸里的白底块、输入块、导航行。
// 页面白底 → 卡纸（圆角 16，留边 7）→ 白底块（圆角 10）。

/// 组标题：15 粗（大号 19 粗）+ 后面一句 12.5 浅灰
struct GroupHeader: View {
    let title: String
    var note: String? = nil
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: large ? 19 : 15, weight: .bold)).foregroundStyle(Theme.ink)
            if let note {
                Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.hint).lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// 卡纸里一块白底，里面一项一项竖着排
struct FormCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 块和块之间的细线
struct FormDivider: View {
    var body: some View {
        Theme.line.frame(height: 0.5)
    }
}

/// 一项：13 灰标签在上，内容在下，底下可以有一句提示
struct FieldBlock<Content: View>: View {
    let label: String
    var hint: String? = nil
    var hintColor: Color = Theme.hint
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.sub)
            content()
            if let hint {
                Text(hint).font(.system(size: 12.5)).foregroundStyle(hintColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

/// 一行：浅底六边形图标 + 标题 + 右边灰字的值 + 小箭头（点开选日期之类）
struct NavRow: View {
    let symbol: String
    let title: String
    let value: String
    var empty = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Hexagon().fill(Theme.fill).frame(width: 30, height: 30)
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.sub)
                }
                Text(title).font(.system(size: 17)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 15)).foregroundStyle(empty ? Theme.hint : Theme.sub).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " " + value)
    }
}
