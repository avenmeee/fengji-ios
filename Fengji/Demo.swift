import Foundation
import UIKit

/// 模拟器截图用：SH_DEMO=<页面> 启动时，网络请求由本地假服务器回答，走的还是真的解码和界面代码。发布包里没有。
enum Demo {
    #if DEBUG
    static let scene = ProcessInfo.processInfo.environment["SH_DEMO"]
    #else
    static let scene: String? = nil
    #endif

    /// live- 开头的是商店截图：走线上真实接口，只是自动翻到那一页
    static var isOn: Bool { scene != nil && scene?.hasPrefix("live-") != true }
    static var initialToken: String? { scene == "guest" || scene == "guest-detail" || scene == "guest-me" ? nil : "demo" }

    static var initialTab: AppTab {
        switch scene {
        case "me", "guest-me", "mine-actions", "undo", "form", "posted", "rentform", "settings", "claim": return .me
        case "rent", "rentdetail", "live-rent", "live-rentdetail": return .rent
        default: return .buy
        }
    }

    static var sampleListing: Listing? {
        #if DEBUG
        return DemoServer.goodsList.first
        #else
        return nil
        #endif
    }

    static func install() {
        #if DEBUG
        if isOn { URLProtocol.registerClass(DemoProtocol.self) }
        #endif
    }
}

#if DEBUG
private final class DemoProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == Config.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, data, type) = DemoServer.respond(url: url, method: request.httpMethod ?? "GET")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["content-type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum DemoServer {
    static let now = Int64(Date().timeIntervalSince1970 * 1000)

    static func photo(_ name: String) -> Photo {
        Photo(key: name, url: "\(Config.base)/p/\(name).jpg")
    }

    static func goods(_ id: Int, _ title: String, _ price: Int, _ cat: String, _ cond: String, _ place: String, photos: [Photo] = [], mine: Bool = false, status: String = "on") -> Listing {
        Listing(id: "g\(id)", uid: mine ? "me" : "u\(id)", kind: "goods", title: title, price: price, cat: cat, cond: cond, rtype: nil, from: nil, to: nil, place: place, desc: id == 1 ? "搬家出，桌面没有划痕。自己来拿。" : "", status: status, contact: "wx_demo\(id)", photos: photos, createdAt: now - Int64(id) * 3_400_000, mine: mine, delivery: id == 3 ? "both" : "pickup", deliveryFee: id == 3 ? 5 : nil, pickupBefore: id == 1 ? "2027-01-10" : nil, score: mine ? nil : [5, 4, 3, 5, 2, nil, 4, 1][(id - 1) % 8])
    }

    static func rent(_ id: Int, _ title: String, _ price: Int, _ type: String, _ place: String, photos: [Photo] = []) -> Listing {
        Listing(id: "r\(id)", uid: "u\(id + 20)", kind: "rent", title: title, price: price, cat: nil, cond: nil, rtype: type, from: "2027-01-05", to: "2027-05-20", place: place, desc: "", status: "on", contact: "wx_rent\(id)", photos: photos, createdAt: now - Int64(id) * 7_000_000, mine: false, leaseEnd: "2027-05-31", utilities: id == 1, privateBath: id != 2, furnished: id == 1)
    }

    static let goodsList: [Listing] = [
        goods(1, "宜家书桌，九成新", 40, "furn", "几乎全新", "学校门口", photos: [photo("a1"), photo("a2")]),
        goods(2, "木画架", 25, "art", "有使用痕迹", "Starland", photos: [photo("b1")]),
        goods(3, "Dell 27 寸显示器", 60, "elec", "几乎全新", "宿舍楼下"),
        goods(4, "素描纸一箱", 0, "art", "全新", "Arnold Hall"),
        goods(5, "设计史教材", 15, "other", "有点旧", "学校门口", photos: [photo("c1")]),
        goods(6, "羽绒服 M 码", 30, "other", "几乎全新", "Victory Dr"),
        goods(7, "小冰箱", 50, "kitchen", "有使用痕迹", "Forsyth Park"),
        goods(8, "台灯", 8, "furn", "几乎全新", "学校门口")
    ]

    /// 群里搬来的样子
    static let groupItem = Listing(id: "g20", uid: "0", kind: "goods", title: "落地灯，搬家出", price: 15, cat: "furn", cond: nil, rtype: nil, from: nil, to: nil, place: "downtown", desc: "", status: "on", contact: nil, photos: [photo("c2")], createdAt: now - 900_000, mine: false, score: 4, sourceType: "group", sourceGroup: "二手群 3", sourcePoster: "小林", sourcePostedAt: now - 3 * 86_400_000)

    static let rentList: [Listing] = [
        rent(1, "一室一厅，走路到学校 10 分钟", 950, "转租", "Starland 附近", photos: [photo("d1")]),
        rent(2, "单间，寒假可住", 620, "短租", "Victory Dr"),
        rent(3, "独栋一层，带院子", 1400, "转租", "Ardsley Park")
    ]

    static let mineList: [Listing] = [
        goods(11, "显示器支架", 12, "elec", "几乎全新", "学校门口", photos: [photo("e1")], mine: true),
        goods(12, "油画颜料一套", 20, "art", "有使用痕迹", "Arnold Hall", mine: true, status: "reserved"),
        goods(13, "小书架", 10, "furn", "有点旧", "TP", mine: true, status: "off")
    ]

    static func color(_ name: String) -> UIColor {
        switch name.first {
        case "a": return UIColor(hex: 0xB9A07A)
        case "b": return UIColor(hex: 0x7C8F73)
        case "c": return UIColor(hex: 0x8797A8)
        case "d": return UIColor(hex: 0xA88E7E)
        default: return UIColor(hex: 0x9A9A8C)
        }
    }

    static func jpeg(_ name: String) -> Data {
        let size = CGSize(width: 800, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            color(name).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.25).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 180, y: 180, width: 440, height: 440))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func respond(url: URL, method: String) -> (Int, Data, String) {
        let path = url.path, json = "application/json"
        if path.hasPrefix("/p/") { return (200, jpeg(url.deletingPathExtension().lastPathComponent), "image/jpeg") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param: (String) -> String? = { name in query.first { $0.name == name }?.value }
        let all = goodsList + rentList + mineList + [groupItem]

        if method == "GET", path == "/v1/me" { return (200, encode(Me(id: "me", isAdmin: false, agreed: true)), json) }
        if method == "GET", path == "/v1/me/listings" { return (200, encode(ListingList(items: mineList)), json) }
        if method == "GET", path == "/v1/admin/stats" { return (200, encode(Stats(posts: 12, views: 340, sold: 5, copies: 40, groupClicks: 18)), json) }
        if method == "GET", path == "/v1/me/claim" { return (200, encode(ClaimStatus(claimed: false, count: 0, contact: nil)), json) }
        if method == "POST", path == "/v1/claim/code" { return (200, encode(ClaimCode(code: "K7M2QX", expiresAt: now + 900_000)), json) }
        if method == "POST", path == "/v1/ai/describe" { return (200, encode(AIGuess(name: "宜家小书桌", cat: "furn", cond: "几乎全新")), json) }
        if method == "GET", path == "/v1/config" { return (200, encode(AppConfig(opsWechat: "demo_ops", aiDescribe: true)), json) }
        if method == "GET", path == "/v1/me/blocks" { return (200, encode(BlockList(items: [])), json) }
        if method == "GET", path == "/v1/listings" {
            var list = param("kind") == "rent" ? rentList : (Demo.scene == "group" ? [groupItem] + goodsList : goodsList)
            if let c = param("cat") { list = list.filter { $0.cat == c } }
            if let t = param("rtype") { list = list.filter { $0.rtype == t } }
            if let q = param("q") { list = list.filter { $0.title.contains(q) || $0.place.contains(q) } }
            return (200, encode(ListingPage(items: list, next: nil)), json)
        }
        if method == "GET", path.hasPrefix("/v1/listings/") {
            if let hit = all.first(where: { $0.id == url.lastPathComponent }) { return (200, encode(hit), json) }
            return (404, encode(["error": "not_found"]), json)
        }
        return (200, encode(OK(ok: true)), json)
    }
}
#endif
