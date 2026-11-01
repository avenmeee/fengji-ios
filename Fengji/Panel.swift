import SwiftUI
import UIKit

/// 自己的底部弹层：和日期弹层一个样子，压暗背景，点外面或往下拖收起。减弱动态效果时直接淡入。
struct BottomPanel<Content: View>: View {
    @Binding var shown: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if shown {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { shown = false }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    Capsule().fill(Theme.line).frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 12)
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.bg, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                .background(alignment: .bottom) {
                    // 底下安全区也铺上底色
                    Theme.bg.frame(height: 60).offset(y: 60).ignoresSafeArea()
                }
                .offset(y: max(drag, 0))
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation.height }
                        .onEnded { v in
                            if v.translation.height > 80 { shown = false }
                            withAnimation(.snappy(duration: 0.2)) { drag = 0 }
                        }
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.08), value: shown)
        .onChange(of: shown) { _, on in
            if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }
}

/// 弹层里的一行：浅底六边形图标加字
struct PanelRow: View {
    let symbol: String
    let title: String
    var color: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRow(symbol: symbol, title: title, color: color)
                .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
    }
}

/// 弹层里的确认：标题、一句说明、两个按钮
struct PanelConfirm: View {
    let title: String
    var message: String? = nil
    let confirm: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
            }
            Button(confirm, action: onConfirm)
                .buttonStyle(PrimaryButtonStyle(act: .sell))
                .padding(.top, 4)
            Button("取消", action: onCancel)
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(.top, 4)
    }
}
