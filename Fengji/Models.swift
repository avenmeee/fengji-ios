import Foundation

typealias Option = (key: String, label: String)

let CATS: [Option] = [("furn", String(localized: "家具")), ("elec", String(localized: "电子")), ("kitchen", String(localized: "厨具")), ("art", String(localized: "画材"))]  // 后端还有 other，界面不显示
let ALL_OPTION: Option = ("all", String(localized: "全部"))

func plainOptions(_ list: [String]) -> [Option] {
    list.map { (key: $0, label: $0) }
}

let CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"]
let UNIT_OPTIONS: [Option] = [("whole", String(localized: "整套")), ("room", String(localized: "单间"))]

/// 热门地点，卖东西和房子都用；选了存文字
let PLACES = ["Monty", "TP", "Mark", "大中超"]
/// 房子地段：群里出现最多的三个
let RENT_PLACES = ["Monty", "大中超", "四大"]
let REASONS = ["违规内容", "虚假信息", "骚扰或诈骗", "其他"]
/// 群帖原帖人想删：记一条举报给管理员，不让帖子自动隐藏
let OWNER_ASK = "原帖人申请删除"

struct Photo: Codable, Hashable {
    let key: String
    let url: String
}

struct Listing: Codable, Identifiable, Hashable {
    var sellerAvatar: String? = nil
    /// 标记卖完的时间
    var soldAt: Int64? = nil
    /// 删掉后留给本人的小图（30 天后照片清掉时用）
    var thumb: String? = nil
    /// 方便的时间：东西是方便取货，房子是方便看房
    var availTime: String? = nil
    /// 只有本人的记录里有
    var soldPrice: Int? = nil
    var deletedAt: Int64? = nil
    var updatedAt: Int64? = nil
    var sellerName: String? = nil
    var sellerColor: Int? = nil
    var sellerNamed: Bool? = nil
    let id: String
    let uid: String
    let kind: String
    var title: String
    var price: Int
    var cat: String?
    var cond: String?
    var from: String?
    var to: String?
    /// "xun" 是上中下旬
    var fromPrec: String? = nil
    var toPrec: String? = nil
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
    /// 四档，1 偏贵 2 价格合理 3 有性价比 4 捡漏；没打分或是自己的就是空
    var score: Int?
    var sourceType: String?
    var sourceGroup: String?
    var sourcePoster: String?
    var sourcePostedAt: Int64?
    var roomType: String?
    var unitType: String?
    var internet: Bool?
    var furniture: String?
    var deposit: Int?
    var appFee: Int?
    var parking: String?
    var pets: String?
    var roommates: String?

    var isRent: Bool { kind == "rent" }
    var isOn: Bool { status == "on" }
    /// 卖完了 / 租出去了：别人照样看得到，标“已卖出”
    var isSold: Bool { status == "off" }
    var isReserved: Bool { status == "reserved" }
    /// 群里搬来的
    var isGroup: Bool { sourceType == "group" }
    /// 没认领的群帖子：只能去群里找
    var findInGroup: Bool { isGroup }
    var sellerLabel: String { sellerName ?? sourcePoster ?? String(localized: "同学") }
    /// “3 天前发在群里”里的前半句
    var groupAge: String {
        guard let t = sourcePostedAt else { return "" }
        let days = Int((Date().timeIntervalSince1970 * 1000 - Double(t)) / 86_400_000)
        return days < 1 ? String(localized: "今天") : String(localized: "\(days) 天前")
    }
    var shareURL: String { "\(Config.base)/l/\(id)" }

    var priceText: String {
        price == 0 ? String(localized: "免费") : "$" + price.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    var catLabel: String { CATS.first { $0.key == cat }?.label ?? "" }

    var statusText: String {
        switch status {
        case "on": return String(localized: "在售")
        case "reserved": return String(localized: "已预订")
        case "hidden": return String(localized: "被举报，审核中")
        default: return isRent ? String(localized: "已租出") : String(localized: "已卖出")
        }
    }

    var period: String {
        let a = Self.day(from, fromPrec), b = Self.day(to, toPrec)
        if longTerm == true, let a { return String(localized: "\(a) 起，长租") }
        if let a, let b { return "\(a) – \(b)" }
        if let a { return String(localized: "\(a) 起") }
        if let b { return String(localized: "到 \(b)") }
        return ""
    }

    /// 东西怎么拿：自取、配送费、取货时间
    var pickupText: String {
        var parts: [String] = []
        switch delivery {
        case "deliver": parts.append(String(localized: "可配送"))
        case "both": parts.append(String(localized: "自取或配送"))
        case "pickup": parts.append(String(localized: "自取"))
        default: break
        }
        if let fee = deliveryFee, delivery != "pickup" { parts.append(fee == 0 ? String(localized: "免配送费") : String(localized: "配送费 $\(String(fee))")) }
        if let d = Self.day(pickupBefore) { parts.append(String(localized: "\(d)前取走")) }
        if let d = Self.day(pickupAfter) { parts.append(String(localized: "\(d)后可取")) }
        return parts.joined(separator: " · ")
    }

    /// 租房的条件：包水电、独卫、租约到期
    var rentFacts: String {
        var parts: [String] = []
        if unitType == "whole" { parts.append(String(localized: "整套")) }
        if unitType == "room" { parts.append(String(localized: "单间")) }
        if unitType == "both" { parts.append(String(localized: "可整套可单间")) }
        if let roomType { parts.append(roomType) }
        if let utilities { parts.append(utilities ? String(localized: "包水电") : String(localized: "不包水电")) }
        if let internet { parts.append(internet ? String(localized: "包网") : String(localized: "不包网")) }
        if let furniture { parts.append(String(localized: "家具：\(furniture)")) }
        if let privateBath { parts.append(privateBath ? String(localized: "独卫") : String(localized: "没有独卫")) }
        if let end = Self.day(leaseEnd) { parts.append(String(localized: "租约到 \(end)")) }
        if let deposit { parts.append(String(localized: "押金 $\(String(deposit))")) }
        if let appFee { parts.append(String(localized: "申请费 $\(String(appFee))")) }
        if let roommates { parts.append(String(localized: "室友：\(roommates)")) }
        return parts.joined(separator: " · ")
    }

    /// 卡片上用的短日期：1/5–5/20
    var shortPeriod: String {
        let a = Self.slash(from, fromPrec), b = Self.slash(to, toPrec)
        if longTerm == true, let a { return String(localized: "\(a) 起长租") }
        if let a, let b { return "\(a)–\(b)" }
        return a ?? b ?? ""
    }

    private static func slash(_ iso: String?, _ prec: String? = nil) -> String? {
        guard let parts = iso?.split(separator: "-"), parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        if prec == "xun" { return String(localized: "\(m)月") + xunName(d) }
        return "\(m)/\(d)"
    }

    var ago: String {
        let minutes = Int((Date().timeIntervalSince1970 * 1000 - Double(createdAt)) / 60000)
        if minutes < 1 { return String(localized: "刚刚") }
        if minutes < 60 { return String(localized: "\(minutes) 分钟前") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours) 小时前") }
        let days = hours / 24
        return days < 30 ? String(localized: "\(days) 天前") : String(localized: "\(days / 30) 个月前")
    }

    /// 1～10 上旬，11～20 中旬，其余下旬
    static func xunName(_ day: Int) -> String { day <= 10 ? String(localized: "上旬") : (day <= 20 ? String(localized: "中旬") : String(localized: "下旬")) }

    /// 详情的信息块：一行一项（图标、标签、内容）。房子：类型、地段、可住、房间、其他；东西：自取或地点、日期、送货
    var infoRows: [(icon: String, label: String, value: String)] {
        var rows: [(icon: String, label: String, value: String)] = []
        if isRent {
            let unit = unitType == "whole" ? String(localized: "整套") : (unitType == "room" ? String(localized: "单间") : (unitType == "both" ? String(localized: "整套或单间") : ""))
            var other: [String] = []
            if let utilities { other.append(utilities ? String(localized: "包水电") : String(localized: "不包水电")) }
            if let internet { other.append(internet ? String(localized: "包网") : String(localized: "不包网")) }
            if let furniture { other.append(String(localized: "家具：\(furniture)")) }
            if let privateBath { other.append(privateBath ? String(localized: "独卫") : String(localized: "没有独卫")) }
            if let end = Self.day(leaseEnd) { other.append(String(localized: "租约到 \(end)")) }
            if let deposit { other.append(String(localized: "押金 $\(String(deposit))")) }
            if let appFee { other.append(String(localized: "申请费 $\(String(appFee))")) }
            rows = [("house", String(localized: "类型"), unit), ("mappin", String(localized: "地段"), place), ("calendar", String(localized: "可住"), period),
                    ("bed.double", String(localized: "房间"), roomType ?? ""), ("clock", String(localized: "看房"), availTime ?? ""), ("info.circle", String(localized: "其他"), other.joined(separator: " · "))]
        } else {
            var dates: [String] = []
            if let d = Self.day(pickupBefore) { dates.append(String(localized: "\(d)前")) }
            if let d = Self.day(pickupAfter) { dates.append(String(localized: "\(d)后可取")) }
            var send = ""
            if delivery == "deliver" || delivery == "both" {
                send = deliveryFee == nil ? String(localized: "可以送") : (deliveryFee == 0 ? String(localized: "可以送，免配送费") : String(localized: "可以送，配送费 $\(String(deliveryFee ?? 0))"))
            }
            rows = [("mappin", delivery == "deliver" ? String(localized: "地点") : String(localized: "自取"), place), ("calendar", String(localized: "日期"), dates.joined(separator: " · ")),
                    ("clock", String(localized: "时间"), availTime ?? ""), ("box.truck", String(localized: "送货"), send)]
        }
        return rows.filter { !$0.value.isEmpty }
    }

    private static func day(_ iso: String?, _ prec: String? = nil) -> String? {
        if prec == "xun", let parts = iso?.split(separator: "-"), parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) {
            return String(localized: "\(m)月") + xunName(d)
        }
        guard let parts = iso?.split(separator: "-"), parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return String(localized: "\(m)月\(d)日")
    }
}

/// 卖家主页：群帖的 seller.id 是空的
struct SellerInfo: Codable {
    let id: String?
    let name: String
    let color: Int?
    let named: Bool
    let avatar: String?
    let group: Bool
    let groupName: String?
}

struct SellerPage: Codable {
    let seller: SellerInfo
    let items: [Listing]
}

/// AI 分出来的一件：照片编号、名字、建议价
struct GroupItem: Codable {
    let photos: [Int]
    let title: String
    let price: Int?
    let cat: String?
    let cond: String?
}

struct GroupResult: Codable {
    let items: [GroupItem]
    var aiLeft: Int?
}

struct ListingPage: Codable {
    let items: [Listing]
    let next: Int?
}

struct AppConfig: Codable {
    let opsWechat: String?
    /// 原帖人想删除时加的微信
    var contactWechat: String?
    let aiDescribe: Bool?
}

/// AI 看照片填的三项
struct AIGuess: Codable {
    let name: String
    let cat: String
    let cond: String
    /// 建议价；AI 没把握就是空
    let price: Int?
    /// 本月 AI 还剩几条
    var aiLeft: Int?
}

/// 收到的“想要”留言，只有卖家看得到
struct Want: Codable, Identifiable {
    let id: String
    let listingId: String
    let title: String
    let photo: String?
    let message: String
    let contact: String
    let createdAt: Int64
}

struct WantList: Codable {
    let items: [Want]
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
    /// 从“记录”里把删掉的重新发出去
    var relist: Bool?
    var availTime: String?
    let kind: String
    let title: String
    let price: Int
    var cat: String?
    var cond: String?
    var from: String?
    var to: String?
    /// "xun" 是上中下旬
    var fromPrec: String? = nil
    var toPrec: String? = nil
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
    var roomType: String?
    var unitType: String?
    var internet: Bool?
    var furniture: String?
    var deposit: Int?
    var appFee: Int?
    var parking: String?
    var pets: String?
    var roommates: String?
}

struct Me: Codable {
    let id: String
    let isAdmin: Bool
    let agreed: Bool
    var name: String?
    var color: Int?
    var named: Bool?
    /// "/p/…" 相对路径
    var avatar: String?
    /// 同意过把东西的信息发给 AI
    var aiConsent: Bool?
    /// 本月 AI 还剩几条（每人每月 50 条）
    var aiLeft: Int?
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
    var name: String?
    var color: Int?
    var named: Bool?
    var avatar: String?
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
    var reportedUser: String?
    /// listing / want / name / avatar
    var type: String?
    /// 帖子类的举报按条目合并后有几条
    var count: Int?
    /// 被举报的内容：留言原文、昵称、头像网址
    var content: String?
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
