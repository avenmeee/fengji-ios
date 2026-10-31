import Foundation

typealias Option = (key: String, label: String)

let CATS: [Option] = [("furn", "家具"), ("elec", "电子"), ("kitchen", "厨具家电"), ("art", "画材"), ("other", "其他")]
let ALL_OPTION: Option = ("all", "全部")

func plainOptions(_ list: [String]) -> [Option] {
    list.map { (key: $0, label: $0) }
}

let CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"]
let RTYPES = ["短租", "转租"]
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
    var deliveryFee: Int?
    var pickupBefore: String?
    var pickupAfter: String?
    var longTerm: Bool?
    var furnished: Bool?
    /// AI 五档，1～5；没打分或是自己的就是空
    var score: Int?
    var sourceType: String?
    var sourceGroup: String?
    var sourcePoster: String?
    var sourcePostedAt: Int64?

    var isRent: Bool { kind == "rent" }
    var isOn: Bool { status == "on" }
    var isReserved: Bool { status == "reserved" }
    /// 群里搬来的
    var isGroup: Bool { sourceType == "group" }
    /// 没有公开微信号的群帖子（包括认领了还没填的）：只能去群里找
    var findInGroup: Bool { (contact ?? "").isEmpty && sourceGroup != nil }
    /// “3 天前发在群里”里的前半句
    var groupAge: String {
        guard let t = sourcePostedAt else { return "" }
        let days = Int((Date().timeIntervalSince1970 * 1000 - Double(t)) / 86_400_000)
        return days < 1 ? "今天" : "\(days) 天前"
    }
    var shareURL: String { "\(Config.base)/l/\(id)" }

    var priceText: String {
        price == 0 ? "免费" : "$" + price.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    var catLabel: String { CATS.first { $0.key == cat }?.label ?? "其他" }

    var statusText: String {
        switch status {
        case "on": return "在售"
        case "reserved": return "已预订"
        case "hidden": return "被举报，审核中"
        default: return isRent ? "已租出" : "已卖出"
        }
    }

    var period: String {
        let a = Self.day(from), b = Self.day(to)
        if longTerm == true, let a { return "\(a) 起，长租" }
        if let a, let b { return "\(a) – \(b)" }
        if let a { return "\(a) 起" }
        if let b { return "到 \(b)" }
        return ""
    }

    /// 东西怎么拿：自取、配送费、取货时间
    var pickupText: String {
        var parts: [String] = []
        switch delivery {
        case "deliver": parts.append("可配送")
        case "both": parts.append("自取或配送")
        case "pickup": parts.append("自取")
        default: break
        }
        if let fee = deliveryFee, delivery != "pickup" { parts.append(fee == 0 ? "免配送费" : "配送费 $\(fee)") }
        if let d = Self.day(pickupBefore) { parts.append("\(d)前取走") }
        if let d = Self.day(pickupAfter) { parts.append("\(d)后可取") }
        return parts.joined(separator: " · ")
    }

    /// 租房的条件：包水电、独卫、租约到期
    var rentFacts: String {
        var parts: [String] = []
        if let utilities { parts.append(utilities ? "包水电" : "不包水电") }
        if furnished == true { parts.append("可拎包入住") }
        if privateBath == true { parts.append("独卫") }
        if let end = Self.day(leaseEnd) { parts.append("租约到 \(end)") }
        return parts.joined(separator: " · ")
    }

    /// 卡片上用的短日期：1/5–5/20
    var shortPeriod: String {
        let a = Self.slash(from), b = Self.slash(to)
        if longTerm == true, let a { return "\(a) 起长租" }
        if let a, let b { return "\(a)–\(b)" }
        return a ?? b ?? ""
    }

    private static func slash(_ iso: String?) -> String? {
        guard let parts = iso?.split(separator: "-"), parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return "\(m)/\(d)"
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
    let next: Int?
}

struct AppConfig: Codable {
    let opsWechat: String?
    let aiDescribe: Bool?
}

/// AI 看照片填的三项
struct AIGuess: Codable {
    let name: String
    let cat: String
    let cond: String
}

struct ClaimCode: Codable {
    let code: String
    let expiresAt: Int64
}

struct ClaimStatus: Codable {
    let claimed: Bool
    let count: Int
    let contact: String?
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
    var deliveryFee: Int?
    var pickupBefore: String?
    var pickupAfter: String?
    var leaseEnd: String?
    var utilities: Bool?
    var privateBath: Bool?
    var longTerm: Bool?
    var furnished: Bool?
    var aiConsent: Bool?
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
    let copies: Int
    let groupClicks: Int
}

struct OK: Codable {
    let ok: Bool
}
