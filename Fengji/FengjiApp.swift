import SwiftUI
import UIKit

enum Config {
    static let host = "fengji.sinantrails.com"
    static let base = "https://" + host
    // 规则 1.2 要公开联系方式。支持页在后端 /support，用 Worker 变量 CONTACT_EMAIL。
    static let contactEmail = "avenmeee@gmail.com"
}

@main
struct FengjiApp: App {
    @StateObject private var state = AppState()
    /// 外观：默认浅色，不跟随手机；存在本机
    @AppStorage("appearance") private var appearance = "light"

    private var colorScheme: ColorScheme? {
        if Demo.isOn { return nil }  // 模拟器截图由 simctl 切深浅
        switch appearance {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }

    init() {
        Demo.install()
        UITabBar.appearance().isHidden = true
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
            .preferredColorScheme(colorScheme)
            .scrollIndicators(.hidden)   // 全 App 不显示滚动条
        }
    }
}

enum AppTab: Hashable {
    case buy, rent, me
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var phase
    @State private var keyboardUp = false

    var body: some View {
        TabView(selection: $state.tab) {
            BuyView().tag(AppTab.buy).toolbar(.hidden, for: .tabBar)
            RentView().tag(AppTab.rent).toolbar(.hidden, for: .tabBar)
            MeView().tag(AppTab.me).toolbar(.hidden, for: .tabBar)
        }
        .overlay(alignment: .bottom) {
            if !state.pushed.contains(state.tab), !keyboardUp {
                FloatingBar()
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.pushed.contains(state.tab))
        .animation(.easeOut(duration: 0.15), value: keyboardUp)
        // 键盘弹起时藏底栏，收起后恢复
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .overlay(alignment: .bottom) {
            if state.pendingDelete != nil {
                HStack(spacing: 14) {
                    Text("已删除").foregroundStyle(Theme.bg)
                    Button("撤销") { state.undoDelete() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.buy)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 140)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.pendingDelete?.id)
        .sheet(isPresented: $state.showLogin) {
            LoginSheet()
                .presentationDetents([.height(240)])
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
        .onChange(of: phase) { _, p in
            if p != .active { state.flushDelete() }
        }
        .task {
            await state.loadConfig()
            await state.refreshMe()
        }
    }
}

/// 浮起的底栏：只有图标，当前页垫这一页颜色的六边形。再点当前图标回顶部。
struct FloatingBar: View {
    @EnvironmentObject var state: AppState
    @Namespace private var hex

    private let items: [(tab: AppTab, symbol: String, label: String, act: Act)] = [
        (.buy, "bag", "买东西", .buy),
        (.rent, "house", "租房子", .rent),
        (.me, "person", "我", .sell)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.label) { item in
                let on = state.tab == item.tab
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if on {
                        state.scrollToTop(item.tab)
                    } else {
                        withAnimation(.snappy(duration: 0.22)) { state.tab = item.tab }
                    }
                } label: {
                    ZStack {
                        if on {
                            Hexagon()
                                .fill(item.act.fill)
                                .frame(width: 46, height: 46)
                                .matchedGeometryEffect(id: "hex", in: hex)
                        }
                        Image(systemName: item.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(on ? item.act.on : Theme.sub)
                    }
                    .frame(width: 60, height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 60)
        .background(Theme.bar, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .padding(.bottom, 6)
    }
}
