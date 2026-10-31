import AuthenticationServices
import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published var tab: AppTab = .buy
    @Published private(set) var token: String?
    @Published private(set) var me: Me?
    @Published var showLogin = false
    @Published private(set) var toastText: String?
    /// 写操作后加一，各列表跟着刷新
    @Published private(set) var version = 0
    /// 运营微信，后端配置；没配是空
    @Published private(set) var opsWechat: String?
    /// 后端开着 AI 生成才走；关了发布页就是手填名字
    @Published private(set) var aiDescribe = false
    /// 再点底栏当前图标：各页看到加一就回顶部
    @Published private(set) var topTicks: [AppTab: Int] = [:]
    /// 左滑删了、还能撤销的那条
    @Published private(set) var pendingDelete: Listing?
    private var deleteTask: Task<Void, Never>?
    /// 哪几页进了下一层（这时藏底栏）
    @Published private(set) var pushed: Set<AppTab> = []

    var isLoggedIn: Bool { token != nil }
    var isAdmin: Bool { me?.isAdmin == true }

    init() {
        token = Demo.isOn ? Demo.initialToken : Keychain.read()
        API.shared.token = token
        tab = Demo.initialTab
        _ = NotificationCenter.default.addObserver(forName: .sessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clearSession() }
        }
    }

    func changed() { version += 1 }

    func scrollToTop(_ tab: AppTab) {
        topTicks[tab, default: 0] += 1
    }

    /// 先从界面上拿掉，5 秒内能撤销，过了才真删
    func softDelete(_ item: Listing) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flushDelete()
        pendingDelete = item
        deleteTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            flushDelete()
        }
    }

    func undoDelete() {
        deleteTask?.cancel()
        deleteTask = nil
        pendingDelete = nil
    }

    /// 真删。切后台也提前做完，不留半截。
    func flushDelete() {
        deleteTask?.cancel()
        deleteTask = nil
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        Task {
            do {
                try await API.shared.delete(item.id)
                changed()
            } catch {
                toast(error.localizedDescription)
                changed()
            }
        }
    }

    func setPushed(_ tab: AppTab, _ isPushed: Bool) {
        if isPushed { pushed.insert(tab) } else { pushed.remove(tab) }
    }

    func toast(_ text: String) {
        toastText = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastText == text { toastText = nil }
        }
    }

    /// 登录了返回 true；没登录就弹登录
    func needLogin() -> Bool {
        if isLoggedIn { return true }
        showLogin = true
        return false
    }

    func loadConfig() async {
        if let c = try? await API.shared.config() {
            opsWechat = c.opsWechat
            aiDescribe = c.aiDescribe == true
        }
    }

    func refreshMe() async {
        guard isLoggedIn else { return }
        if let m = try? await API.shared.me() { me = m }
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) async throws {
        let auth = try result.get()
        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let identity = String(data: tokenData, encoding: .utf8) else {
            throw APIError(code: "bad_identity")
        }
        let code = cred.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let r = try await API.shared.signIn(identityToken: identity, code: code)
        setSession(r.token)
        me = r.me
        if !r.me.agreed { me = try await API.shared.agree() }
        changed()
    }

    private func setSession(_ value: String?) {
        token = value
        API.shared.token = value
        Keychain.write(value)
    }

    private func clearSession() {
        setSession(nil)
        me = nil
        changed()
    }

    func logout() async {
        try? await API.shared.logout()
        clearSession()
    }

    func deleteAccount() async throws {
        try await API.shared.deleteAccount()
        clearSession()
    }
}

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发布要先登录")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            SignInBlock { dismiss() }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .presentationDragIndicator(.visible)
    }
}
