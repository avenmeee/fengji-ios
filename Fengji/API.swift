import Foundation
import Security

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}

struct APIError: LocalizedError {
    let code: String

    var errorDescription: String? {
        switch code {
        case "not_allowed": return "内容不合规，改一下再发。"
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
    func logout() async throws { try await act("POST", "/v1/auth/logout") }
    func deleteAccount() async throws { try await act("DELETE", "/v1/me") }

    // 条目
    func feed(kind: String, filter: String, q: String, before: Int64?) async throws -> ListingPage {
        var items = [URLQueryItem(name: "kind", value: kind)]
        if filter != "all" { items.append(URLQueryItem(name: kind == "rent" ? "rtype" : "cat", value: filter)) }
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        var c = URLComponents()
        c.queryItems = items
        return try await get("/v1/listings" + (c.string ?? ""))
    }
    func listing(_ id: String) async throws -> Listing { try await get("/v1/listings/\(id)") }
    func mine() async throws -> [Listing] {
        let r: ListingList = try await get("/v1/me/listings")
        return r.items
    }
    func create(_ input: ListingInput) async throws -> Listing { try await post("POST", "/v1/listings", input) }
    func update(_ id: String, _ input: ListingInput) async throws -> Listing { try await post("PUT", "/v1/listings/\(id)", input) }
    func setStatus(_ id: String, _ status: String) async throws -> Listing {
        try await post("POST", "/v1/listings/\(id)/status", ["status": status])
    }
    func countView(_ id: String) async throws { try await act("POST", "/v1/listings/\(id)/view") }
    func delete(_ id: String) async throws { try await act("DELETE", "/v1/listings/\(id)") }
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
