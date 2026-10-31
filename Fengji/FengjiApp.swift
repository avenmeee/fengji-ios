import SwiftUI

enum Config {
    static let host = "fengji.sinantrails.com"
    static let base = "https://" + host
    // 规则 1.2 要公开联系方式。支持页在后端 /support，用 Worker 变量 CONTACT_EMAIL。
    static let contactEmail = "avenmeee@gmail.com"
}

@main
struct FengjiApp: App {
    @StateObject private var state = AppState()

    init() {
        Demo.install()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Demo.scene == "sharecard", let item = Demo.sampleListing {
                    ShareCard(item: item, photo: nil)
                } else {
                    RootView()
                }
            }
            .environmentObject(state)
            .tint(Theme.tint)
        }
    }
}

enum AppTab: Hashable {
    case buy, rent, me
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // 三页都留着，切回来不丢滚动位置
        ZStack {
            page(.buy) { BuyView() }
            page(.rent) { RentView() }
            page(.me) { MeView() }
        }
        .overlay(alignment: .bottom) {
            if !state.pushed.contains(state.tab) {
                FloatingBar(tab: $state.tab)
                    .ignoresSafeArea(.keyboard)
            }
        }
        .sheet(isPresented: $state.showLogin) {
            LoginSheet()
                .presentationDetents([.height(340)])
        }
        .overlay(alignment: .bottom) {
            if let text = state.toastText {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 92)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toastText)
        .task {
            await state.loadConfig()
            await state.refreshMe()
        }
    }

    private func page<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(state.tab == tab ? 1 : 0)
            .allowsHitTesting(state.tab == tab)
            .accessibilityHidden(state.tab != tab)
    }
}

/// 浮起的胶囊底栏：只有图标，当前页是这一页的颜色
struct FloatingBar: View {
    @Binding var tab: AppTab

    private let items: [(tab: AppTab, symbol: String, label: String, act: Act)] = [
        (.buy, "bag", "买东西", .buy),
        (.rent, "house", "租房子", .rent),
        (.me, "person", "我", .sell)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.label) { item in
                Button {
                    tab = item.tab
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tab == item.tab ? item.act.on : Theme.sub)
                        .frame(width: 72, height: 48)
                        .background(tab == item.tab ? item.act.fill : Color.clear, in: Capsule())
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(tab == item.tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 62)
        .background(Theme.bar, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .padding(.horizontal, 66)
        .padding(.bottom, 6)
    }
}
