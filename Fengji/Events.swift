import Foundation

/// 匿名使用记录（11-01）：只带本机随机生成的安装编号，不带账号。攒一批发，失败就丢，不影响使用。
@MainActor
final class Events {
    static let shared = Events()

    struct Event: Encodable {
        let name: String
        var listing: String? = nil
        var kind: String? = nil
        var cat: String? = nil
        var tier: Int? = nil
        var seconds: Int? = nil
        var q: String? = nil
        var results: Int? = nil
        var method: String? = nil
        var step: String? = nil
        var mode: String? = nil
        var count: Int? = nil
        var aiName: String? = nil
        var nameEdited: Bool? = nil
        var aiPrice: Int? = nil
        var priceEdited: Bool? = nil
        var priceDiff: Int? = nil
    }

    private struct Batch: Encodable {
        let install: String
        let events: [Event]
    }

    private var buffer: [Event] = []
    private var timer: Task<Void, Never>?
    private var lastOpen: Date?

    private var install: String {
        let key = "installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    func log(_ event: Event) {
        // 截图不记
        guard Demo.scene == nil else { return }
        buffer.append(event)
        if buffer.count >= 20 {
            flush()
        } else if timer == nil {
            timer = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                flush()
            }
        }
    }

    /// 回到前台：隔五分钟以上才算又打开一次
    func appOpen() {
        if let lastOpen, Date().timeIntervalSince(lastOpen) < 300 { return }
        lastOpen = Date()
        log(Event(name: "app_open"))
    }

    func detailView(_ item: Listing, seconds: TimeInterval) {
        log(Event(name: "detail_view", listing: item.id, kind: item.kind, cat: item.cat, tier: item.tier, seconds: min(600, Int(seconds))))
    }

    func contact(_ item: Listing, method: String) {
        log(Event(name: "contact", listing: item.id, kind: item.kind, cat: item.cat, tier: item.tier, method: method))
    }

    func flush() {
        timer?.cancel()
        timer = nil
        guard !buffer.isEmpty, let url = URL(string: Config.base + "/v1/events") else { return }
        let events = Array(buffer.prefix(50))
        buffer.removeFirst(events.count)
        guard let body = try? JSONEncoder().encode(Batch(install: install, events: events)) else { return }
        // 不走 API.send：那边带登录令牌，这里不能跟账号挂上
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        URLSession.shared.dataTask(with: req).resume()
    }
}

extension Listing {
    /// 蜜蜂分档，没打分是空
    var tier: Int? { score.map { max(1, min(4, $0)) } }
}
