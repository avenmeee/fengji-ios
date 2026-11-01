import SwiftUI
import UIKit

/// 一次发好几件（11-01）：选很多张照片，AI 分成一件一件，卖家确认后一起发。
/// 这里只管逻辑；界面在 BatchViews.swift，设计稿在 视觉\批量发布。
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

    /// 刚删掉的一件，黑条上能撤销
    struct Removed {
        let item: Item
        let shots: [Shot]
        let index: Int
    }

    static let maxPhotos = 30
    /// 和普通发布一样，一件最多 3 张
    static let maxPerItem = 3
    static let aiFailed = "AI 没认出来，自己填一下名字和价格"
    static let aiOut = "这个月的 AI 用完了，下个月 1 号恢复，名字和价格自己填一下"

    @Published private(set) var shots: [Shot] = []
    @Published var items: [Item] = []
    @Published private(set) var grouping = false
    @Published private(set) var publishing = false
    /// AI 用不了时的一句说明，界面显示在顶上
    @Published var notice: String?
    /// 分组后本月 AI 还剩几条，界面交给 AppState.setAILeft
    @Published private(set) var aiLeft: Int?
    /// 是 AI 分出来的：标题写“认出 N 件”
    @Published private(set) var aiGrouped = false
    /// 正在让 AI 认的几件
    @Published private(set) var describing: Set<UUID> = []
    @Published private(set) var removed: Removed?
    @Published var error: String?
    /// 出错的是第几件，界面滚过去标红
    @Published var badIndex: Int?

    // 共用的，统一填一次
    @Published var pickup = false
    @Published var deliver = false
    @Published var deliveryFee = ""
    @Published var place = ""
    @Published var availTime = ""
    @Published var contact = ""

    private var task: Task<Void, Never>?
    /// 传好的照片：发布失败重试时不再传一遍
    private var uploaded: [UUID: String] = [:]

    init() {
        #if DEBUG
        if let scene = Demo.scene, scene.hasPrefix("batch-") { fillDemo(scene) }
        #endif
    }

    func shot(_ id: UUID) -> Shot? { shots.first { $0.id == id } }
    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// 放进来的照片：压到 1200、去掉定位。返回放进去的几张
    @discardableResult
    func add(_ datas: [Data]) async -> [UUID] {
        let room = max(0, Self.maxPhotos - shots.count)
        let ready = await Task.detached(priority: .userInitiated) {
            datas.prefix(room).compactMap { ImagePrep.prepare($0) }
        }.value
        let new = ready.map { Shot(jpeg: $0.jpeg, preview: $0.preview) }
        shots += new
        return new.map(\.id)
    }

    /// 再加几张照片到这一件
    func attach(_ datas: [Data], to id: UUID) async {
        guard let it = item(id) else { return }
        let ids = await add(Array(datas.prefix(Self.maxPerItem - it.shots.count)))
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].shots += ids }
    }

    func reset() {
        cancel()
        shots = []
        items = []
        notice = nil
        error = nil
        badIndex = nil
        removed = nil
        aiGrouped = false
        describing = []
        uploaded = [:]
    }

    func cancel() {
        task?.cancel()
        task = nil
        grouping = false
    }

    /// 按选的方式分。AI 用不了就每张一件，名字价格自己填
    func start(_ how: Split, consent: Bool, aiOn: Bool, left: Int?) {
        task?.cancel()
        notice = nil
        error = nil
        badIndex = nil
        removed = nil
        aiGrouped = false
        aiLeft = left
        switch how {
        case .allOne:
            items = [Item(shots: shots.map(\.id), title: "", price: "", priceSuggested: false)]
        case .eachOne:
            eachOne()
            if aiOn {
                describeAll(consent: consent)
            } else {
                notice = left == 0 ? Self.aiOut : Self.aiFailed
            }
        case .ai:
            guard aiOn else {
                eachOne()
                notice = left == 0 ? Self.aiOut : Self.aiFailed
                return
            }
            grouping = true
            task = Task { await group(consent: consent) }
        }
    }

    private func group(consent: Bool) async {
        let list = shots.map { ($0.id, $0.preview) }
        let small = await Task.detached(priority: .userInitiated) {
            list.compactMap { s in ImagePrep.forAI(s.1).map { (s.0, $0) } }
        }.value
        do {
            let result = try await API.shared.group(jpegs: small.map(\.1), consent: consent)
            guard !Task.isCancelled else { return }
            aiLeft = result.aiLeft
            items = result.items.map { g in
                Item(shots: g.photos.compactMap { small.indices.contains($0) ? small[$0].0 : nil },
                     title: g.title, price: g.price.map(String.init) ?? "", cat: g.cat, cond: g.cond, priceSuggested: g.price != nil)
            }.filter { !$0.shots.isEmpty }
            if items.isEmpty {
                eachOne()
                notice = Self.aiFailed
            } else {
                aiGrouped = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            // AI 用不了：退回每张一件，让卖家自己填
            eachOne()
            if (error as? APIError)?.code == "ai_limit" {
                notice = "这个月的 AI 不够分这些照片了，下个月 1 号恢复。先每张一件，名字和价格自己填一下"
            } else {
                notice = Self.aiFailed
            }
        }
        grouping = false
    }

    private func eachOne() {
        items = shots.map { Item(shots: [$0.id], title: "", price: "", priceSuggested: false) }
    }

    /// 每张一件时，AI 照样一件件填名字和价格；一次认三件
    private func describeAll(consent: Bool) {
        let todo = items.compactMap { it in it.shots.first.map { (it.id, $0) } }
        describing = Set(todo.map(\.0))
        task = Task {
            var start = 0
            while start < todo.count, !Task.isCancelled {
                let chunk = todo[start..<min(start + 3, todo.count)]
                await withTaskGroup(of: Void.self) { g in
                    for (id, shot) in chunk {
                        g.addTask { await self.describe(id, shot: shot, consent: consent) }
                    }
                }
                start += 3
            }
            describing = []
        }
    }

    private func describe(_ id: UUID, shot: UUID, consent: Bool) async {
        defer { describing.remove(id) }
        guard aiLeft != 0, let preview = self.shot(shot)?.preview else {
            if notice == nil { notice = Self.aiOut }
            return
        }
        let jpeg = await Task.detached(priority: .userInitiated) { ImagePrep.forAI(preview) }.value
        guard let jpeg else { return }
        do {
            let g = try await API.shared.describe(jpeg: jpeg, consent: consent)
            if g.aiLeft != nil { aiLeft = g.aiLeft }
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // 卖家已经填了的不动
            if items[i].title.isEmpty { items[i].title = g.name }
            if items[i].price.isEmpty, let p = g.price {
                items[i].price = String(p)
                items[i].priceSuggested = true
            }
            items[i].cat = items[i].cat ?? g.cat
            items[i].cond = items[i].cond ?? g.cond
        } catch {
            guard !Task.isCancelled else { return }
            if (error as? APIError)?.code == "ai_limit" {
                aiLeft = 0
                notice = Self.aiOut
            } else if notice == nil {
                notice = "有几件 AI 没认出来，自己填一下名字和价格"
            }
        }
    }

    // MARK: - 确认页上的改动

    /// 照片挪到另一件；原来那件空了就去掉。一件满 3 张就挪不进去
    func move(_ shot: UUID, to target: UUID) {
        guard let from = items.firstIndex(where: { $0.shots.contains(shot) }), let to = items.firstIndex(where: { $0.id == target }), from != to,
              items[to].shots.count < Self.maxPerItem else { return }
        items[from].shots.removeAll { $0 == shot }
        items[to].shots.append(shot)
        if items[from].shots.isEmpty { items.remove(at: from) }
    }

    /// 照片单独拿出来成一件，AI 再认一下名字和价格
    func splitOut(_ shot: UUID, consent: Bool, aiOn: Bool) {
        guard let from = items.firstIndex(where: { $0.shots.contains(shot) }), items[from].shots.count > 1 else { return }
        items[from].shots.removeAll { $0 == shot }
        let new = Item(shots: [shot], title: "", price: "", priceSuggested: false)
        items.insert(new, at: from + 1)
        guard aiOn else { return }
        describing.insert(new.id)
        Task { await describe(new.id, shot: shot, consent: consent) }
    }

    /// 删一张；这件的照片删光了，这件也一起删
    func removeShot(_ shot: UUID) {
        guard let i = items.firstIndex(where: { $0.shots.contains(shot) }) else { return }
        if items[i].shots.count == 1 {
            removeItem(items[i].id)
        } else {
            items[i].shots.removeAll { $0 == shot }
            shots.removeAll { $0.id == shot }
        }
    }

    func removeItem(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items[i]
        removed = Removed(item: it, shots: shots.filter { it.shots.contains($0.id) }, index: i)
        shots.removeAll { it.shots.contains($0.id) }
        items.remove(at: i)
    }

    func undoRemove() {
        guard let r = removed else { return }
        shots += r.shots
        items.insert(r.item, at: min(r.index, items.count))
        removed = nil
    }

    func clearRemoved() { removed = nil }

    // MARK: - 发布

    static func noTitle(_ it: Item) -> Bool { it.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static func noPrice(_ it: Item) -> Bool { (Int(it.price.trimmingCharacters(in: .whitespaces)) ?? -1) < 0 }

    /// 还差什么：每件要名字和价格
    var missing: [Int] {
        items.indices.filter { Self.noTitle(items[$0]) || Self.noPrice(items[$0]) }
    }

    /// 先传照片，再一起发；成功返回发出去的几件
    func publish(aiConsent: Bool) async -> [Listing]? {
        error = nil
        badIndex = nil
        if let first = missing.first {
            badIndex = first
            return nil
        }
        let fee = deliveryFee.trimmingCharacters(in: .whitespaces)
        if deliver, !fee.isEmpty, Int(fee) == nil {
            error = "配送费要填整数。"
            return nil
        }
        publishing = true
        defer { publishing = false }
        do {
            let todo = shots.filter { s in uploaded[s.id] == nil && items.contains { $0.shots.contains(s.id) } }
            var start = 0
            while start < todo.count {
                try await withThrowingTaskGroup(of: (UUID, String).self) { g in
                    for s in todo[start..<min(start + 4, todo.count)] {
                        let id = s.id, jpeg = s.jpeg
                        g.addTask { (id, try await API.shared.upload(jpeg: jpeg)) }
                    }
                    for try await (id, key) in g { uploaded[id] = key }
                }
                start += 4
            }
            let delivery: String? = pickup && deliver ? "both" : (pickup ? "pickup" : (deliver ? "deliver" : nil))
            let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = availTime.trimmingCharacters(in: .whitespacesAndNewlines)
            let inputs: [ListingInput] = items.map { it in
                var input = ListingInput(kind: "goods", title: it.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                         price: Int(it.price.trimmingCharacters(in: .whitespaces)) ?? 0,
                                         place: pickup ? place.trimmingCharacters(in: .whitespacesAndNewlines) : "", desc: "",
                                         contact: c, photos: it.shots.compactMap { uploaded[$0] })
                input.cat = it.cat
                input.cond = it.cond
                input.delivery = delivery
                input.deliveryFee = deliver ? Int(fee) : nil
                input.availTime = t.isEmpty ? nil : t
                return input
            }
            let saved = try await API.shared.createBatch(inputs, aiConsent: aiConsent)
            if !c.isEmpty { UserDefaults.standard.set(c, forKey: "contact") }
            return saved
        } catch {
            let e = error as? APIError
            // 微信号是几件共用的，不用说第几件
            let index = e?.code == "bad_wechat" ? nil : e?.index
            badIndex = index
            self.error = (index.map { "第 \($0 + 1) 件：" } ?? "") + error.localizedDescription
            return nil
        }
    }

    #if DEBUG
    /// 截图用的几件
    private func fillDemo(_ scene: String) {
        let names = ["a1", "a2", "a3", "b1", "c1", "d1", "e1"]
        shots = names.compactMap { n in
            let data = DemoServer.jpeg(n)
            return UIImage(data: data).map { Shot(jpeg: data, preview: $0) }
        }
        pickup = true
        place = "Monty 一楼大厅"
        availTime = "工作日晚上、周末"
        contact = "wx_linxia"
        if scene == "batch-choose" || scene == "batch-recognize" {
            if scene == "batch-recognize" { grouping = true }
            return
        }
        if scene == "batch-failed" {
            eachOne()
            notice = Self.aiFailed
            return
        }
        let id = shots.map(\.id)
        aiGrouped = true
        items = [
            Item(shots: Array(id[0...2]), title: "榉木画架", price: "25", priceSuggested: true),
            Item(shots: [id[3]], title: "白色书桌", price: "40", priceSuggested: true),
            Item(shots: [id[4]], title: "台灯", price: "15", priceSuggested: true),
            Item(shots: Array(id[5...6]), title: "马克笔和颜料一套", price: "30", priceSuggested: true)
        ]
        if scene == "batch-removed" { removeItem(items[2].id) }
        if scene == "batch-missing" {
            items[1].title = ""
            items[2].price = ""
        }
    }
    #endif
}
