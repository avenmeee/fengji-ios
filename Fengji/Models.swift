import Foundation

typealias Option = (key: String, label: String)

let CATS: [Option] = [("furn", "家具"), ("kitchen", "厨具家电"), ("elec", "电子"), ("art", "画材"), ("book", "书"), ("wear", "衣物"), ("other", "其他")]
let ALL_OPTION: Option = ("all", "全部")

func plainOptions(_ list: [String]) -> [Option] {
    list.map { (key: $0, label: $0) }
}

let CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"]
let RTYPES = ["整租", "单间", "寒假短租", "转租"]
let REASONS = ["违规内容", "虚假信息", "骚扰或诈骗", "其他"]

struct Photo: Codable, Hashable {
    let key: String
    let url: String
}

struct Listing: Codable, Identifiable, Hashable {
    let id: String
    let uid: String
    let kind: String
    var title: String
    var price: Int
    var cat: String?
    var cond: String?
    var rtype: String?
    var from: String?
    var to: String?
    var place: String
    var desc: String
    var status: String
    var contact: String?
    var photos: [Photo]
    let createdAt: Int64
    let mine: Bool
    var leaseEnd: String?
    var utilities: Bool?
    var privateBath: Bool?
    var delivery: String?
    var bumpedAt: Int64 = 0

    var isRent: Bool { kind == "rent" }
    var isOn: Bool { status == "on" }
    var shareURL: String { "\(Config.base)/l/\(id)" }

    var priceText: String {
        price == 0 ? "免费" : "$" + price.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    var catLabel: String { CATS.first { $0.key == cat }?.label ?? "其他" }

    var statusText: String {
        switch status {
        case "on": return "在架上"
        case "hidden": return "被举报，审核中"
        default: return isRent ? "已租出" : "已卖出"
        }
    }

    var period: String {
        let a = Self.day(from), b = Self.day(to)
        if let a, let b { return "\(a) – \(b)" }
        if let a { return "\(a) 起" }
        if let b { return "到 \(b)" }
        return ""
    }

    var deliveryText: String { delivery == "deliver" ? "可配送" : "自取" }

    /// 租房的条件：包水电、独卫、租约到期
    var rentFacts: String {
        var parts: [String] = []
        if utilities == true { parts.append("包水电") }
        if privateBath == true { parts.append("独卫") }
        if let end = Self.day(leaseEnd) { parts.append("租约到 \(end)") }
        return parts.joined(separator: " · ")
    }

    var ago: String {
        let minutes = Int((Date().timeIntervalSince1970 * 1000 - Double(createdAt)) / 60000)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        return days < 30 ? "\(days) 天前" : "\(days / 30) 个月前"
    }

    private static func day(_ iso: String?) -> String? {
        guard let parts = iso?.split(separator: "-"), parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return "\(m)月\(d)日"
    }
}

struct ListingPage: Codable {
    let items: [Listing]
    let next: Int64?
}

struct ListingList: Codable {
    let items: [Listing]
}

struct ListingInput: Encodable {
    let kind: String
    let title: String
    let price: Int
    var cat: String?
    var cond: String?
    var rtype: String?
    var from: String?
    var to: String?
    let place: String
    let desc: String
    let contact: String
    let photos: [String]
    var delivery: String?
    var leaseEnd: String?
    var utilities: Bool?
    var privateBath: Bool?
}

struct Me: Codable {
    let id: String
    let isAdmin: Bool
    let agreed: Bool
}

struct LoginResult: Codable {
    let token: String
    let me: Me
}

struct PhotoKey: Codable {
    let key: String
}

struct Blocked: Codable, Identifiable, Hashable {
    let id: String
    let at: Int64
}

struct BlockList: Codable {
    let items: [Blocked]
}

struct AdminReport: Codable, Identifiable {
    let id: String
    let reason: String
    let note: String
    let at: Int64
    let reporter: String
    let listing: Listing
}

struct AdminReportList: Codable {
    let items: [AdminReport]
}

struct Stats: Codable {
    let posts: Int
    let views: Int
    let sold: Int
}

struct OK: Codable {
    let ok: Bool
}
