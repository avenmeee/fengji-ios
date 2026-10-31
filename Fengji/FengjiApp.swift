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
        UIRefreshControl.appearance().tintColor = .clear  // 下拉刷新用自己的蜂蜜动画
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Demo.scene == "sharecard", let item = Demo.sampleListing {
                    ShareCard(item: item, photo: nil)
                } else if Demo.scene == "share-hive" {
                    HiveShareCard(items: Demo.sampleHive(10), contact: "wx_demo", total: 10)
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
    case buy, rent
}

enum PostKind: String, Identifiable {
    case goods, rent

    var id: String { rawValue }
}

enum PlusAction {
    case goods, me, rent
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var phase
    @State private var keyboardUp = false
    @State private var restoreBar: Task<Void, Never>?

    var body: some View {
        TabView(selection: $state.tab) {
            BuyView().tag(AppTab.buy).toolbar(.hidden, for: .tabBar)
            RentView().tag(AppTab.rent).toolbar(.hidden, for: .tabBar)
        }
        .blur(radius: state.plusOpen ? 10 : 0)
        .overlay {
            if state.plusOpen { PlusSheet().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.18), value: state.plusOpen)
        .overlay(alignment: .bottom) {
            if !state.pushed.contains(state.tab), !keyboardUp {
                FloatingBar()
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.pushed.contains(state.tab))
        .animation(.easeOut(duration: 0.15), value: keyboardUp)
        // 键盘弹起时藏底栏。切表情、语音时会先收后弹，所以显示要等一下，藏是马上
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            guard (end?.height ?? 0) > 100 else { return }  // 外接键盘只露一条工具栏，不算
            restoreBar?.cancel()
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            showBarSoon()
        }
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
                .padding(.bottom, 24)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.pendingDelete?.id)
        .sheet(item: $state.posting) { kind in
            PostForm(kind: kind.rawValue)
        }
        .sheet(isPresented: $state.showLogin, onDismiss: { state.loginDismissed() }) {
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
            // 切走再回来：键盘还在的话系统会再发一次，不在的话底栏不能卡住
            if p == .background {
                restoreBar?.cancel()
                keyboardUp = false
            }
        }
        .task {
            await state.loadConfig()
            await state.refreshMe()
        }
    }

    private func showBarSoon() {
        restoreBar?.cancel()
        restoreBar = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { keyboardUp = false }
        }
    }
}

/// 底栏：买东西、加号、租房子。选中的垫黑六边形，只有加号是黄的。
struct FloatingBar: View {
    @EnvironmentObject var state: AppState
    @Namespace private var hex

    var body: some View {
        HStack(spacing: 0) {
            tab(.buy, "bag", "买东西")
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) { state.plusOpen.toggle() }
            } label: {
                ZStack {
                    Hexagon().fill(Theme.accent).frame(width: 66, height: 66)
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.onBuy)
                        .rotationEffect(.degrees(state.plusOpen ? 45 : 0))
                }
                .frame(width: 70, height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.plusOpen ? "收起" : "发布和我")
            tab(.rent, "house", "租房子")
        }
        .padding(.horizontal, 8)
        .frame(height: 60)
        .background(Theme.bar, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .padding(.bottom, 6)
    }

    private func tab(_ which: AppTab, _ symbol: String, _ label: String) -> some View {
        let on = state.tab == which
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if on {
                state.scrollToTop(which)
            } else {
                withAnimation(.snappy(duration: 0.22)) { state.tab = which }
            }
        } label: {
            ZStack {
                if on {
                    Hexagon()
                        .fill(Theme.ink)
                        .frame(width: 44, height: 44)
                        .matchedGeometryEffect(id: "hex", in: hex)
                }
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(on ? Theme.bg : Theme.sub)
            }
            .frame(width: 66, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 点加号弹出的三格蜂巢：上面我，左下发布东西，右下发布房子
struct PlusSheet: View {
    @EnvironmentObject var state: AppState
    private let size: CGFloat = 112

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .onTapGesture { state.plusOpen = false }
            VStack(spacing: -size * 0.18) {
                cell("我", "person", fill: Theme.ink, on: Theme.bg, action: .me)
                HStack(spacing: 4) {
                    cell("发布东西", "bag", fill: Theme.accent, on: Theme.onBuy, action: .goods)
                    cell("发布房子", "house", fill: Theme.accent, on: Theme.onBuy, action: .rent)
                }
            }
            .padding(.bottom, 74)
        }
    }

    private func cell(_ label: String, _ symbol: String, fill: Color, on: Color, action: PlusAction) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            state.plusAction(action)
        } label: {
            ZStack {
                Hexagon().fill(fill)
                VStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                    Text(label).font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(on)
            }
            .frame(width: size, height: size)
            .contentShape(Hexagon())
        }
        .buttonStyle(.plain)
    }
}
