import SwiftUI
import UIKit
import UserNotifications

enum Config {
    static let host = "fengji.sinantrails.com"
    static let base = "https://" + host
    // 规则 1.2 要公开联系方式。支持页在后端 /support，用 Worker 变量 CONTACT_EMAIL。
    static let contactEmail = "avenmeee@gmail.com"
}

@main
struct FengjiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            .onOpenURL { url in Task { await state.openLink(url) } }
        }
    }
}

extension Notification.Name {
    static let openWants = Notification.Name("openWants")
}

/// 推送：要令牌、前台也显示、点了去“我”
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "deviceToken")
        Task { try? await API.shared.saveDevice(token: token) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { NotificationCenter.default.post(name: .openWants, object: nil) }
    }
}

enum Notifier {
    /// 第一次发了没留微信的东西时问：这时卖家明白为什么要通知。不要角标。
    @MainActor
    static func ask() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// 已经同意过：每次打开刷新令牌
    @MainActor
    static func refresh() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized { UIApplication.shared.registerForRemoteNotifications() }
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
        // 动画只给浮层。放在 TabView 外面的模糊和动画，平时也在拖累里面的滑动
        .overlay {
            ZStack {
                if state.plusOpen { PlusSheet().transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.18), value: state.plusOpen)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if !state.pushed.contains(state.tab) || state.onMe, !keyboardUp {
                    FloatingBar()
                        .ignoresSafeArea(.keyboard)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: state.pushed.contains(state.tab) && !state.onMe)
            .animation(.easeOut(duration: 0.15), value: keyboardUp)
        }
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
                .padding(.bottom, 96)
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
        .onReceive(NotificationCenter.default.publisher(for: .openWants)) { _ in
            state.plusAction(.me)
        }
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
            if state.isLoggedIn { Notifier.refresh() }
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
            plusButton
            tab(.rent, "house", "租房子")
        }
        .padding(.horizontal, 8)
        .frame(height: 60)
        .background(Theme.bar, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .padding(.bottom, 6)
    }

    /// 点一下弹出；按住 0.25 秒弹出，不松手拖到某一项上松开就进去，拖回来或拖到空白松开取消
    private var plusButton: some View {
        ZStack {
            Hexagon().fill(Theme.accent).frame(width: 66, height: 66)
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.onBuy)
                .rotationEffect(.degrees(state.plusOpen ? 45 : 0))
        }
        .frame(width: 70, height: 60)
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { state.plusCenter = CGPoint(x: g.frame(in: .global).midX, y: g.frame(in: .global).midY) }
                .onChange(of: g.frame(in: .global)) { _, f in state.plusCenter = CGPoint(x: f.midX, y: f.midY) }
        })
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) { state.plusOpen.toggle() }
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if !state.plusOpen {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy(duration: 0.2)) { state.plusOpen = true }
                    }
                    guard let drag else { return }
                    let hit = PlusLayout.hit(drag.location, plus: state.plusCenter)
                    if hit != state.plusHover {
                        if hit != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        state.plusHover = hit
                    }
                }
                .onEnded { _ in
                    let hit = state.plusHover
                    state.plusHover = nil
                    if let hit {
                        state.plusAction(hit)
                    } else {
                        withAnimation(.snappy(duration: 0.2)) { state.plusOpen = false }
                    }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state.plusOpen ? "收起" : "发布和我")
        .accessibilityAction { state.plusOpen.toggle() }
    }

    private func tab(_ which: AppTab, _ symbol: String, _ label: String) -> some View {
        let on = state.tab == which && !state.onMe
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if state.onMe {
                state.popToRoot()
                state.tab = which
            } else if on {
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

/// 加号上方的弧形：相对加号中心的位置，判定区比图形大
enum PlusLayout {
    static let width: CGFloat = 100
    static var height: CGFloat { width * 2 / 3.0.squareRoot() }
    static let hitRadius: CGFloat = 72
    /// 以加号中心为圆心，半径 152：145°、90°、35°
    static let side = CGPoint(x: 124.5, y: 87.2)
    static let top: CGFloat = 152

    static func hit(_ point: CGPoint, plus: CGPoint) -> PlusAction? {
        let spots: [(PlusAction, CGPoint)] = [
            (.goods, CGPoint(x: plus.x - side.x, y: plus.y - side.y)),
            (.me, CGPoint(x: plus.x, y: plus.y - top)),
            (.rent, CGPoint(x: plus.x + side.x, y: plus.y - side.y))
        ]
        var best: (PlusAction, CGFloat)?
        for spot in spots {
            let d = hypot(point.x - spot.1.x, point.y - spot.1.y)
            if d <= hitRadius, d < (best?.1 ?? .infinity) { best = (spot.0, d) }
        }
        return best?.0
    }
}

/// 点加号弹出的三项。从加号的位置弹出来；减弱动态效果时直接显示。
struct PlusSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sides = false
    @State private var top = false

    private let barCenter: CGFloat = 36  // 加号中心离安全区底的高度（底栏 60，离底 6）

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.14))
                .ignoresSafeArea()
                .onTapGesture { state.plusOpen = false }
            ZStack {
                cell("发布东西", "bag", fill: Theme.accent, on: Theme.onBuy, action: .goods)
                    .modifier(PopOut(shown: sides, x: -PlusLayout.side.x, y: PlusLayout.height / 2 - PlusLayout.side.y, start: PlusLayout.height / 2))
                cell("发布房子", "house", fill: Theme.accent, on: Theme.onBuy, action: .rent)
                    .modifier(PopOut(shown: sides, x: PlusLayout.side.x, y: PlusLayout.height / 2 - PlusLayout.side.y, start: PlusLayout.height / 2))
                cell("我", "person", fill: Theme.ink, on: Theme.bg, action: .me)
                    .modifier(PopOut(shown: top, x: 0, y: PlusLayout.height / 2 - PlusLayout.top, start: PlusLayout.height / 2))
            }
            .padding(.bottom, barCenter)
        }
        .onAppear {
            if reduceMotion || Demo.scene == "plus-open" {
                sides = true
                top = true
            } else {
                withAnimation(.spring(duration: 0.18, bounce: 0.2)) { sides = true }
                withAnimation(.spring(duration: 0.18, bounce: 0.2).delay(0.04)) { top = true }
            }
        }
    }

    private func cell(_ label: String, _ symbol: String, fill: Color, on: Color, action: PlusAction) -> some View {
        let hovered = state.plusHover == action
        return Button {
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
            .frame(width: PlusLayout.width, height: PlusLayout.height)
            .contentShape(Hexagon())
            .scaleEffect(hovered ? 1.16 : 1)
            .opacity(state.plusHover != nil && !hovered ? 0.6 : 1)
            .shadow(color: .black.opacity(hovered ? 0.25 : 0), radius: 10, y: 4)
            .animation(.snappy(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
    }
}

private struct PopOut: ViewModifier {
    let shown: Bool
    let x: CGFloat
    let y: CGFloat
    let start: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? x : 0, y: shown ? y : start)
    }
}
