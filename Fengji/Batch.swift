import SwiftUI
import UIKit

/// 一次发好几件（11-01）：选很多张照片，AI 分成一件一件，卖家确认后一起发。
/// 这里只管逻辑；界面等设计稿（视觉\批量发布）。
@MainActor
final class BatchModel: ObservableObject {
    /// 选了 2 张以上时问怎么分
    enum Split { case ai, eachOne, allOne }

    struct Shot: Identifiable, Hashable {
        let id = UUID()
        let jpeg: Data
        let preview: UIImage
    }

    struct Item: Identifiable {
        let id = UUID()
        var shots: [UUID]
        var title: String
        var price: String
        var cat: String?
        var cond: String?
        var priceSuggested: Bool
    }

    static let maxPhotos = 30

    @Published private(set) var shots: [Shot] = []
    @Published var items: [Item] = []
    @Published private(set) var grouping = false
    @Published private(set) var publishing = false
    /// AI 用不了时的一句说明，界面显示在顶上
    @Published var notice: String?
    /// 分组后本月 AI 还剩几条，界面交给 AppState.setAILeft
    @Published private(set) var aiLeft: Int?
    @Published var error: String?
    /// 出错的是第几件，界面滚过去标红
    @Published var badIndex: Int?

    // 共用的，统一填一次
    @Published var pickup = false
    @Published var deliver = false
    @Published var deliveryFee = ""
    @Published var place = UserDefaults.standard.string(forKey: "defaultPlace") ?? ""
    @Published var availTime = UserDefaults.standard.string(forKey: "defaultTime") ?? ""
    @Published var contact = UserDefaults.standard.string(forKey: "contact") ?? ""
    @Published var pickupBefore: Date?
    @Published var pickupAfter: Date?

    init() {
        let saved = UserDefaults.standard.string(forKey: "defaultDelivery") ?? ""
        pickup = saved == "pickup" || saved == "both"
        deliver = saved == "deliver" || saved == "both"
    }

    func shot(_ id: UUID) -> Shot? { shots.first { $0.id == id } }

    /// 放进来的照片：压到 1200、去掉定位
    func add(_ datas: [Data]) {
        for d in datas.prefix(Self.maxPhotos - shots.count) {
            if let p = ImagePrep.prepare(d) { shots.append(Shot(jpeg: p.jpeg, preview: p.preview)) }
        }
    }

    /// 按选的方式分
    func split(_ how: Split, consent: Bool) async {
        notice = nil
        switch how {
        case .eachOne: eachOne()
        case .allOne: items = [Item(shots: shots.map(\.id), title: "", price: "", priceSuggested: false)]
        case .ai:
            grouping = true
            defer { grouping = false }
            let small = shots.compactMap { ImagePrep.forAI($0.preview) }
            do {
                let result = try await API.shared.group(jpegs: small, consent: consent)
                aiLeft = result.aiLeft
                let groups = result.items

                items = groups.map { g in
                    Item(shots: g.photos.compactMap { shots.indices.contains($0) ? shots[$0].id : nil },
                         title: g.title, price: g.price.map(String.init) ?? "", cat: g.cat, cond: g.cond, priceSuggested: g.price != nil)
                }.filter { !$0.shots.isEmpty }
                if items.isEmpty { eachOne() }
            } catch {
                // AI 用不了：退回每张一件，让卖家自己填
                eachOne()
                notice = (error as? APIError)?.code == "ai_limit" ? "这个月的 AI 不够分这些照片了，下个月 1 号恢复。先每张一件，名字和价格自己填一下。" : "AI 这会儿用不了，先每张一件，名字和价格自己填一下。"
            }
        }
    }

    private func eachOne() {
        items = shots.map { Item(shots: [$0.id], title: "", price: "", priceSuggested: false) }
    }

    // MARK: - 确认页上的改动

    /// 照片挪到另一件；原来那件空了就去掉
    func move(_ shot: UUID, to target: UUID) {
        guard let from = items.firstIndex(where: { $0.shots.contains(shot) }), let to = items.firstIndex(where: { $0.id == target }), from != to else { return }
        items[from].shots.removeAll { $0 == shot }
        items[to].shots.append(shot)
        if items[from].shots.isEmpty { items.remove(at: from) }
    }

    /// 照片单独拿出来成一件
    func splitOut(_ shot: UUID) {
        guard let from = items.firstIndex(where: { $0.shots.contains(shot) }), items[from].shots.count > 1 else { return }
        items[from].shots.removeAll { $0 == shot }
        items.insert(Item(shots: [shot], title: "", price: "", priceSuggested: false), at: from + 1)
    }

    /// 两件合成一件：照片接在后面，名字价格留前一件的
    func merge(_ a: UUID, into b: UUID) {
        guard let i = items.firstIndex(where: { $0.id == a }), let j = items.firstIndex(where: { $0.id == b }), i != j else { return }
        items[j].shots += items[i].shots
        items.remove(at: i)
    }

    func removeShot(_ shot: UUID) {
        shots.removeAll { $0.id == shot }
        for i in items.indices { items[i].shots.removeAll { $0 == shot } }
        items.removeAll { $0.shots.isEmpty }
    }

    func removeItem(_ id: UUID) {
        guard let it = items.first(where: { $0.id == id }) else { return }
        shots.removeAll { it.shots.contains($0.id) }
        items.removeAll { $0.id == id }
    }

    // MARK: - 发布

    /// 还差什么：每件要名字和价格
    var missing: [Int] {
        items.indices.filter { items[$0].title.trimmingCharacters(in: .whitespaces).isEmpty || Int(items[$0].price.trimmingCharacters(in: .whitespaces)) == nil }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 先传照片，再一起发；成功返回发出去的几件
    func publish(aiConsent: Bool) async -> [Listing]? {
        error = nil
        badIndex = nil
        if let first = missing.first {
            badIndex = first
            error = "第 \(first + 1) 件还差名字或价格。"
            return nil
        }
        publishing = true
        defer { publishing = false }
        do {
            var keyOf: [UUID: String] = [:]
            for s in shots where items.contains(where: { $0.shots.contains(s.id) }) {
                keyOf[s.id] = try await API.shared.upload(jpeg: s.jpeg)
            }
            let delivery: String? = pickup && deliver ? "both" : (pickup ? "pickup" : (deliver ? "deliver" : nil))
            let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = availTime.trimmingCharacters(in: .whitespacesAndNewlines)
            let inputs: [ListingInput] = items.map { it in
                var input = ListingInput(kind: "goods", title: it.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                         price: Int(it.price.trimmingCharacters(in: .whitespaces)) ?? 0,
                                         place: pickup ? place.trimmingCharacters(in: .whitespacesAndNewlines) : "", desc: "",
                                         contact: c, photos: it.shots.compactMap { keyOf[$0] })
                input.cat = it.cat
                input.cond = it.cond
                input.delivery = delivery
                input.deliveryFee = deliver ? Int(deliveryFee.trimmingCharacters(in: .whitespaces)) : nil
                input.pickupBefore = pickupBefore.map { Self.day.string(from: $0) }
                input.pickupAfter = pickupAfter.map { Self.day.string(from: $0) }
                input.availTime = t.isEmpty ? nil : t
                return input
            }
            let saved = try await API.shared.createBatch(inputs, aiConsent: aiConsent)
            if !c.isEmpty { UserDefaults.standard.set(c, forKey: "contact") }
            return saved
        } catch {
            let e = error as? APIError
            badIndex = e?.index
            self.error = (e?.index.map { "第 \($0 + 1) 件：" } ?? "") + error.localizedDescription
            return nil
        }
    }
}
