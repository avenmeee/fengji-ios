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
    /// 联系我们用的微信，后端配置
    @Published private(set) var contactWechat: String?
    /// 后端开着 AI 生成才走；关了发布页就是手填名字
    @Published private(set) var aiDescribe = false
    /// 再点底栏当前图标：各页看到加一就回顶部
    @Published private(set) var topTicks: [AppTab: Int] = [:]
    /// 左滑删了、还能撤销的那条
    @Published private(set) var pendingDelete: Listing?
    private var deleteTask: Task<Void, Never>?
    /// 加号弹层开着
    @Published var plusOpen = Demo.scene == "plus-open"
    /// 页面上开着底部弹层：底栏先收起来，免得挡住
    @Published var panelOpen = false
    /// 按住加号拖动时，手指在哪一项上
    @Published var plusHover: PlusAction?
    /// 加号中心在屏幕上的位置，拖动时判断手指落在哪一项
    var plusCenter: CGPoint = .zero
    /// 正在发布什么，弹在最外层
    @Published var posting: PostKind? = Demo.initialPosting
    /// “我”页露在最上面：底栏显示，但没有选中项
    @Published var onMe = false
    /// 在“我”页点底栏：回到列表
    @Published private(set) var popRequests = 0
    /// 让当前页推到“我”
    @Published private(set) var meRequests = 0
    /// 登录之后接着做的事
    private var afterLogin: (() -> Void)?
    /// 网页上点“在蜂集里打开”：要打开的这条，买或租页看到就推进去
    @Published var linked: Listing?
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

    /// 加号里的三项：没登录先登录，登录后接着进
    func plusAction(_ action: PlusAction) {
        plusOpen = false
        let go: () -> Void = { [weak self] in
            guard let self else { return }
            switch action {
            case .goods: self.posting = .goods
            case .rent: self.posting = .rent
            case .me: self.meRequests += 1
            }
        }
        if isLoggedIn {
            go()
        } else {
            afterLogin = go
            showLogin = true
        }
    }

    /// 登录弹层收起时调
    func loginDismissed() {
        let next = afterLogin
        afterLogin = nil
        if isLoggedIn { next?() }
    }

    func popToRoot() { popRequests += 1 }

    /// fengji://l/<id>
    func openLink(_ url: URL) async {
        guard url.scheme == "fengji", url.host == "l", let id = url.pathComponents.last, id != "/" else { return }
        do {
            let item = try await API.shared.listing(id)
            plusOpen = false
            posting = nil
            tab = item.isRent ? .rent : .buy
            linked = item
        } catch {
            toast("这条已经没有了")
        }
    }

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

    /// 删掉前留一张小图给自己的记录：最长边 240
    private static func thumbnail(_ item: Listing) async -> Data? {
        guard let first = item.photos.first, let url = URL(string: first.url),
              let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
        let k = 240 / max(image.size.width, image.size.height, 1)
        let small = await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * k, height: image.size.height * k))
        return (small ?? image).jpegData(compressionQuality: 0.7)
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
                try await API.shared.delete(item.id, thumb: await Self.thumbnail(item))
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
            contactWechat = c.contactWechat
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
        // 退出登录时令牌删了，重新登录要再报一次
        Notifier.refresh()
    }

    func setProfile(_ value: Me) {
        me = value
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
