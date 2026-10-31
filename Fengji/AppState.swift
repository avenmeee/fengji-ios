import AuthenticationServices
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var tab: AppTab = .buy
    @Published private(set) var token: String?
    @Published private(set) var me: Me?
    @Published var showLogin = false
    @Published private(set) var toastText: String?
    /// 写操作后加一，各列表跟着刷新
    @Published private(set) var version = 0
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
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showTerms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发布要先登录")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            SignInWithAppleButton(.signIn) { req in
                req.requestedScopes = []
            } onCompletion: { result in
                Task { await finish(result) }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 48)
            if let error {
                Text(error).font(.subheadline).foregroundStyle(Theme.warn)
            }
            Button { showTerms = true } label: {
                Text("继续即同意用户协议：不许发违规内容、不许骚扰，违者删帖封号。")
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .underline()
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .sheet(isPresented: $showTerms) {
            NavigationStack { TermsView() }
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) async {
        do {
            try await state.completeSignIn(result)
            dismiss()
        } catch let e as ASAuthorizationError where e.code == .canceled {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "登录没成功，再试一次。"
        }
    }
}
