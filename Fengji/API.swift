import Foundation
import Security

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}

struct APIError: LocalizedError {
    let code: String

    var errorDescription: String? {
        switch code {
        case "not_allowed": return "这类内容不能发。"
        case "bad_name": return "这个昵称不能用。"
        case "want_again": return "今天已经发过了。"
        case "need_contact": return "留个联系方式，卖家才联系得上你。"
        case "need_ai_consent": return "要同意发给 AI 打分才能发布。"
        case "need_photo": return "要一张实拍照。"
        case "need_utilities": return "选一下包不包水电。"
        case "need_dates": return "写一下起止日期，或者选长租。"
        case "too_soon": return "一天只能擦亮一次。"
        case "daily_limit": return "今天发得太多了，明天再试。"
        case "site_limit": return "今天传照片的人太多，明天再试。"
        case "too_many_listings": return "在架的太多了，先下架几条。"
        case "photo_too_big": return "照片太大了，换一张。"
        case "login_required": return "要先登录。"
        case "terms_required": return "要先同意用户协议。"
        case "banned": return "这个账号已被停用。"
        case "hidden": return "这条被举报了，审核中不能改。"
        case "not_found": return "这条已经没有了。"
        case "bad_identity": return "苹果登录没通过，再试一次。"
        case "bad_wechat": return "微信号格式不对：字母开头，6～20 位。"
        default: return "没连上，再试一次。"
        }
    }
}

final class API: @unchecked Sendable {
    static let shared = API()
    var token: String?

    private func send(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: Config.base + path) else { throw APIError(code: "bad_url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "http_\(status)"
        if status == 401, token != nil, code == "login_required" {
            NotificationCenter.default.post(name: .sessionExpired, object: nil)
        }
        throw APIError(code: code)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send("GET", path))
    }

    private func post<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(method, path, body: try JSONEncoder().encode(body)))
    }

    private func act(_ method: String, _ path: String) async throws {
        _ = try await send(method, path)
    }

    // 登录
    func signIn(identityToken: String, code: String?) async throws -> LoginResult {
        try await post("POST", "/v1/auth/apple", ["identityToken": identityToken, "authorizationCode": code ?? ""])
    }
    func me() async throws -> Me { try await get("/v1/me") }
    func agree() async throws -> Me {
        try JSONDecoder().decode(Me.self, from: await send("POST", "/v1/me/agree"))
    }
    private struct ProfileBody: Encodable {
        let nickname: String
        let color: Int
    }
    func updateProfile(nickname: String, color: Int) async throws -> Me {
        try await post("PATCH", "/v1/me", ProfileBody(nickname: nickname, color: color))
    }
    func reportName(_ id: String) async throws { try await act("POST", "/v1/listings/\(id)/report-name") }
    func adminResetName(_ uid: String) async throws { try await act("POST", "/v1/admin/users/\(uid)/reset-name") }
    func logout() async throws {
        let _: OK = try await post("POST", "/v1/auth/logout", ["deviceToken": UserDefaults.standard.string(forKey: "deviceToken") ?? ""])
    }
    func deleteAccount() async throws { try await act("DELETE", "/v1/me") }

    // 条目
    func feed(kind: String, filter: String, q: String, offset: Int?) async throws -> ListingPage {
        var items = [URLQueryItem(name: "kind", value: kind)]
        if filter != "all" { items.append(URLQueryItem(name: kind == "rent" ? "unit" : "cat", value: filter)) }
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        var c = URLComponents()
        c.queryItems = items
        return try await get("/v1/listings" + (c.string ?? ""))
    }
    func listing(_ id: String) async throws -> Listing { try await get("/v1/listings/\(id)") }
    /// 这条帖子的发帖人主页
    func poster(_ id: String) async throws -> SellerPage { try await get("/v1/listings/\(id)/poster") }
    func mine() async throws -> [Listing] {
        let r: ListingList = try await get("/v1/me/listings")
        return r.items
    }
    func create(_ input: ListingInput) async throws -> Listing { try await post("POST", "/v1/listings", input) }
    func update(_ id: String, _ input: ListingInput) async throws -> Listing { try await post("PUT", "/v1/listings/\(id)", input) }
    private struct StatusBody: Encodable {
        let status: String
        let soldPrice: Int?
    }
    func setStatus(_ id: String, _ status: String, soldPrice: Int? = nil) async throws -> Listing {
        try await post("POST", "/v1/listings/\(id)/status", StatusBody(status: status, soldPrice: soldPrice))
    }
    func setPrice(_ id: String, _ price: Int) async throws {
        let _: Listing = try await post("POST", "/v1/listings/\(id)/price", ["price": price])
    }
    func takedown(_ id: String) async throws { try await act("POST", "/v1/listings/\(id)/takedown") }
    func want(_ id: String, message: String, contact: String) async throws {
        let _: OK = try await post("POST", "/v1/listings/\(id)/want", ["message": message, "contact": contact])
    }
    func wants() async throws -> [Want] {
        let r: WantList = try await get("/v1/me/wants")
        return r.items
    }
    func deleteWant(_ id: String) async throws { try await act("DELETE", "/v1/wants/\(id)") }
    func reportWant(_ id: String, reason: String) async throws {
        let _: OK = try await post("POST", "/v1/wants/\(id)/report", ["reason": reason])
    }
    func blockWant(_ id: String) async throws { try await act("POST", "/v1/wants/\(id)/block") }
    func saveDevice(token: String) async throws {
        let _: OK = try await post("POST", "/v1/me/device", ["token": token])
    }
    func claimCode() async throws -> ClaimCode {
        try JSONDecoder().decode(ClaimCode.self, from: await send("POST", "/v1/claim/code"))
    }
    func claimStatus() async throws -> ClaimStatus { try await get("/v1/me/claim") }
    func setPublicContact(_ contact: String) async throws {
        let _: OK = try await post("POST", "/v1/me/contact", ["contact": contact])
    }
    func config() async throws -> AppConfig { try await get("/v1/config") }
    func bump(_ id: String) async throws { try await act("POST", "/v1/listings/\(id)/bump") }
    func describe(jpeg: Data, consent: Bool) async throws -> AIGuess {
        let data = try await send("POST", "/v1/ai/describe" + (consent ? "?consent=1" : ""), body: jpeg, contentType: "image/jpeg")
        return try JSONDecoder().decode(AIGuess.self, from: data)
    }
    func countClick(_ id: String, _ what: String) async throws {
        let _: OK = try await post("POST", "/v1/listings/\(id)/click", ["what": what])
    }
    func countView(_ id: String) async throws { try await act("POST", "/v1/listings/\(id)/view") }
    /// 卖家删：对外消失，带一张小缩略图留给自己的记录
    func delete(_ id: String, thumb: Data? = nil) async throws {
        _ = try await send("DELETE", "/v1/listings/\(id)", body: thumb, contentType: "image/jpeg")
    }
    func purge(_ id: String) async throws { try await act("DELETE", "/v1/listings/\(id)?purge=1") }
    func uploadAvatar(jpeg: Data) async throws -> Me {
        try JSONDecoder().decode(Me.self, from: await send("POST", "/v1/me/avatar", body: jpeg, contentType: "image/jpeg"))
    }
    func removeAvatar() async throws -> Me {
        try JSONDecoder().decode(Me.self, from: await send("DELETE", "/v1/me/avatar"))
    }
    func reportAvatar(_ id: String) async throws {
        let _: OK = try await post("POST", "/v1/listings/\(id)/report-name", ["what": "avatar"])
    }
    func adminRemoveAvatar(_ uid: String) async throws { try await act("POST", "/v1/admin/users/\(uid)/remove-avatar") }
    func upload(jpeg: Data) async throws -> String {
        let data = try await send("POST", "/v1/photos", body: jpeg, contentType: "image/jpeg")
        return try JSONDecoder().decode(PhotoKey.self, from: data).key
    }

    // 举报、屏蔽
    func report(_ id: String, reason: String) async throws {
        let _: OK = try await post("POST", "/v1/listings/\(id)/report", ["reason": reason])
    }
    func block(_ uid: String) async throws { try await act("POST", "/v1/blocks/\(uid)") }
    func unblock(_ uid: String) async throws { try await act("DELETE", "/v1/blocks/\(uid)") }
    func blocks() async throws -> [Blocked] {
        let r: BlockList = try await get("/v1/me/blocks")
        return r.items
    }

    // 管理
    func adminReports() async throws -> [AdminReport] {
        let r: AdminReportList = try await get("/v1/admin/reports")
        return r.items
    }
    func adminStats() async throws -> Stats { try await get("/v1/admin/stats") }
    /// 管理员下架：彻底删除，举报一起关掉
    func adminRemove(_ listingId: String) async throws { try await act("POST", "/v1/admin/listings/\(listingId)/remove") }
    func adminClose(_ reportId: String) async throws { try await act("POST", "/v1/admin/reports/\(reportId)/close") }
    func adminRestore(_ listingId: String) async throws { try await act("POST", "/v1/admin/listings/\(listingId)/restore") }
    func adminBan(_ uid: String) async throws { try await act("POST", "/v1/admin/users/\(uid)/ban") }
}

enum Keychain {
    private static let account = "session"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.avenmeee.fengji", kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?) {
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
