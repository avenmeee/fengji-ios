import PhotosUI
import SwiftUI
import UIKit

private enum FormPhoto: Identifiable {
    case existing(Photo)
    case fresh(id: UUID, jpeg: Data, preview: UIImage)

    var id: String {
        switch self {
        case .existing(let p): return p.key
        case .fresh(let id, _, _): return id.uuidString
        }
    }
}

enum ImagePrep {
    /// 给 AI 看的小图，省钱也快
    static func forAI(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let k = min(1, 768 / max(longest, 1))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        .jpegData(compressionQuality: 0.6)
    }

    /// 压到最长边 1200、重新画一遍（顺带去掉定位等信息）
    static func prepare(_ data: Data) -> (jpeg: Data, preview: UIImage)? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let k = min(1, 1200 / max(longest, 1))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        var quality: CGFloat = 0.72
        var out = small.jpegData(compressionQuality: quality)
        while let d = out, d.count > 1_200_000, quality > 0.3 {
            quality -= 0.15
            out = small.jpegData(compressionQuality: quality)
        }
        guard let jpeg = out else { return nil }
        return (jpeg, small)
    }
}

/// 点日期格弹出的是哪个日期
private enum DateField: String, Identifiable {
    case pickupAfter, pickupBefore, from, to, leaseEnd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pickupAfter: return String(localized: "从几号起可取")
        case .pickupBefore: return String(localized: "几号前取走")
        case .from: return String(localized: "起")
        case .to: return String(localized: "止")
        case .leaseEnd: return String(localized: "租约到期日")
        }
    }

    /// 清空按钮的字；起是必填，没有清空
    var clearLabel: String? {
        switch self {
        case .from: return nil
        case .to: return String(localized: "长租")
        default: return String(localized: "不限")
        }
    }
}

/// 发布页能打字的地方：滚到可见、收键盘都靠它
private enum Field: Hashable {
    case price, name, contact, fee, place, desc, deposit, appFee, note, time
}

struct PostForm: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    let kind: String
    let editing: Listing?
    var onSaved: ((Listing) -> Void)?
    /// 在售、已预订、已卖（已租）
    @State private var status: String
    @State private var askSold = Demo.scene == "sold-ask"
    @State private var soldPrice = ""

    // 必填
    @State private var title: String
    @State private var price: String
    @State private var photos: [FormPhoto]
    @State private var contact: String
    /// 方便的时间：东西是取货，房子是看房；从我的信息带进来
    @State private var availTime: String
    // 卖东西选填
    @State private var cat: String?
    @State private var cond: String?
    @State private var pickup: Bool
    @State private var deliver: Bool
    @State private var deliveryFee: String
    @State private var pickupBefore: Date?
    @State private var pickupAfter: Date?
    @State private var place: String
    @State private var desc: String
    // 房子
    @State private var from: Date?
    @State private var to: Date?
    @State private var utilities: Bool?
    @State private var bedrooms: String?
    @State private var baths: String?
    @State private var unitWhole: Bool
    @State private var fromXun: Bool
    @State private var toXun: Bool
    @State private var unitRoom: Bool
    @State private var priceSuggested: Bool
    @State private var priceTouched = false
    @State private var internet: Bool?
    @State private var deposit: String
    @State private var appFee: String
    @State private var furniture: String?
    @State private var privateBath: Bool?
    @State private var parking: String?
    @State private var pets: String?
    @State private var roommateCount: String?
    @State private var roommateNote: String
    @State private var leaseEnd: Date?
    // AI 和流程
    @State private var aiConsent: Bool
    @State private var aiGuessed: Bool
    @State private var aiLoading = false
    @State private var describeTask: Task<Void, Never>?
    @State private var nameTouched = false
    @State private var showConsent = false
    @State private var showCamera = false
    @State private var posted = Demo.scene?.hasPrefix("posted") == true
    @State private var hive: [HiveItem] = Demo.scene == "posted" ? Demo.sampleHive(1) : (Demo.scene == "posted-3" ? Demo.sampleHive(3) : (Demo.scene == "posted-10" ? Demo.sampleHive(10) : []))
    @State private var hiveShare: ShareImage?
    /// 从“记录”里重新发删掉的那条
    private let relist: Bool
    @State private var dateField: DateField? = Demo.scene == "rentcal-to" ? .to : (Demo.scene?.hasPrefix("rentcal") == true ? .from : nil)
    @State private var picked: [PhotosPickerItem] = []
    // 一次选好几张：先问怎么分，再进确认页
    @StateObject private var batch = BatchModel()
    @State private var showSplit = Demo.scene == "batch-choose"
    @State private var inBatch = Demo.scene?.hasPrefix("batch-") == true && Demo.scene != "batch-choose"
    @State private var readingPhotos = false
    // 使用记录：开始发了没发完算放弃
    @State private var postOpen = false
    @State private var aiSaidName: String?
    @State private var aiSaidPrice: Int?
    @State private var error: String?
    @State private var busy = false
    /// 点过发布：缺的那项下面出红字
    @State private var tried = Demo.scene == "form-missing"

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ iso: String?) -> Date? {
        iso.flatMap { dayFormat.date(from: $0) }
    }

    /// prefill：从记录重新发，预填文字，照片要重新放
    init(kind: String, editing: Listing? = nil, prefill: Listing? = nil, startStatus: String? = nil, relist: Bool = false, onSaved: ((Listing) -> Void)? = nil) {
        self.relist = relist
        self.kind = kind
        self.editing = editing
        self.onSaved = onSaved
        let source = editing ?? prefill
        _status = State(initialValue: startStatus ?? source?.status ?? "on")
        let filled = Demo.scene == "form-filled" || Demo.scene == "rentform-filled" || Demo.scene?.hasPrefix("rentcal") == true
        let isRent = kind == "rent"

        _title = State(initialValue: source?.title ?? (filled ? (isRent ? "一室一厅，走路到学校" : "榉木画架") : ""))
        _price = State(initialValue: source.map { String($0.price) } ?? (filled ? (isRent ? "950" : "25") : ""))
        var startPhotos = (editing?.photos ?? []).map { FormPhoto.existing($0) }
        if filled { startPhotos = (Demo.sampleListing?.photos ?? []).map { FormPhoto.existing($0) } }
        #if DEBUG
        if Demo.scene == "form-many" {
            startPhotos = ["a1", "a2", "b1", "c1", "d1", "e1", "a3"].compactMap { n in
                let data = DemoServer.jpeg(n)
                return UIImage(data: data).map { .fresh(id: UUID(), jpeg: data, preview: $0) }
            }
        }
        #endif
        _photos = State(initialValue: startPhotos)
        let savedContact = source?.contact ?? UserDefaults.standard.string(forKey: "contact") ?? (filled ? "wx_demo1" : "")
        _contact = State(initialValue: savedContact)
        _availTime = State(initialValue: source?.availTime ?? (source == nil ? (UserDefaults.standard.string(forKey: "defaultTime") ?? "") : "") )

        _cat = State(initialValue: source?.cat ?? (filled && !isRent ? "art" : nil))
        _cond = State(initialValue: source?.cond ?? (filled && !isRent ? "几乎全新" : nil))
        let savedDelivery = UserDefaults.standard.string(forKey: "defaultDelivery") ?? ""
        let startDelivery = source?.delivery ?? (filled ? "both" : (savedDelivery.isEmpty ? nil : savedDelivery))
        let savedPlace = isRent ? "" : (UserDefaults.standard.string(forKey: "defaultPlace") ?? "")
        // 新开发布页自取、可配送都不选，让卖家自己点；编辑和再发一件照旧带过来
        _pickup = State(initialValue: startDelivery == "pickup" || startDelivery == "both" || (source?.place.isEmpty == false && !isRent))
        _deliver = State(initialValue: startDelivery == "deliver" || startDelivery == "both")
        _deliveryFee = State(initialValue: source?.deliveryFee.map { String($0) } ?? (filled ? "5" : ""))
        _pickupBefore = State(initialValue: Self.date(source?.pickupBefore) ?? (filled && !isRent ? Date().addingTimeInterval(20 * 86400) : nil))
        _pickupAfter = State(initialValue: Self.date(source?.pickupAfter))
        let startPlace = source?.place ?? (filled ? "Monty" : savedPlace)
        _place = State(initialValue: startPlace)
        _desc = State(initialValue: source?.desc ?? (filled && !isRent ? "搬家出，自己来拿" : ""))

        _from = State(initialValue: Self.date(source?.from) ?? (filled && isRent ? Self.demoFrom : nil))
        _to = State(initialValue: Self.date(source?.to) ?? (filled && isRent ? Date().addingTimeInterval(120 * 86400) : nil))
        _utilities = State(initialValue: source?.utilities ?? (filled && isRent ? true : nil))
        let room = Self.parseRoom(source?.roomType)
        _bedrooms = State(initialValue: room.0 ?? (filled && isRent ? "1" : nil))
        _baths = State(initialValue: room.1 ?? (filled && isRent ? "1" : nil))
        let unit = source?.unitType ?? (filled && isRent ? "room" : nil)
        _unitWhole = State(initialValue: unit == "whole" || unit == "both")
        _fromXun = State(initialValue: source?.fromPrec == "xun" || Demo.scene == "rentcal-xun")
        _toXun = State(initialValue: source?.toPrec == "xun")
        _unitRoom = State(initialValue: unit == "room" || unit == "both")
        _priceSuggested = State(initialValue: filled && !isRent)
        _internet = State(initialValue: source?.internet)
        _deposit = State(initialValue: source?.deposit.map { String($0) } ?? "")
        _appFee = State(initialValue: source?.appFee.map { String($0) } ?? "")
        _furniture = State(initialValue: source?.furniture)
        _privateBath = State(initialValue: source?.privateBath)
        _parking = State(initialValue: source?.parking)
        _pets = State(initialValue: source?.pets)
        let mate = Self.parseRoommates(source?.roommates)
        _roommateCount = State(initialValue: mate.0)
        _roommateNote = State(initialValue: mate.1)
        _leaseEnd = State(initialValue: Self.date(source?.leaseEnd))

        _aiConsent = State(initialValue: Demo.isOn)
        _aiGuessed = State(initialValue: filled && !isRent)
    }

    /// 模拟器截图：自动点进某个输入框，看键盘挡不挡
    private static var demoFocus: Field? {
        switch Demo.scene {
        case "form-kb-price": return .price
        case "form-kb-desc": return .desc
        case "rent-kb-deposit": return .deposit
        case "rent-kb-desc": return .desc
        default: return nil
        }
    }

    private static let roommateCounts = ["没有", "1 人", "2 人", "3 人以上"]

    /// “2室1卫”拆回两个按钮
    private static func parseRoom(_ text: String?) -> (String?, String?) {
        guard let text, let r = text.range(of: "室") else { return (nil, nil) }
        let rest = text[r.upperBound...]
        return (String(text[..<r.lowerBound]), rest.hasSuffix("卫") ? String(rest.dropLast()) : nil)
    }

    private static func parseRoommates(_ text: String?) -> (String?, String) {
        guard let text else { return (nil, "") }
        let parts = text.components(separatedBy: "；")
        if let first = parts.first, roommateCounts.contains(first) || first == "没有室友" {
            return (first == "没有室友" ? "没有" : first, parts.dropFirst().joined(separator: "；"))
        }
        return (nil, text)
    }

    private var isRent: Bool { kind == "rent" }
    /// 只留蜂蜜一个强调色（11-01 统一重做）
    private var formAct: Act { .buy }
    private var maxPhotos: Int { BatchModel.maxPhotos }
    private var tile: CGFloat { 68 }

    var body: some View {
        Group {
            if posted {
                postedView
            } else if inBatch {
                batchFlow
            } else if isRent {
                rentForm
            } else {
                goodsForm
            }
        }
        .background(Theme.bg)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy || inBatch)
        .overlay {
            if readingPhotos {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    HoneyLoader(size: 44)
                }
            }
        }
        .overlay {
            BottomPanel(shown: $showSplit) {
                BatchChoosePanel(batch: batch, aiEnough: aiEnough, aiLeft: state.me?.aiLeft) { chooseSplit($0) }
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPicked(items) }
        }
        .onDisappear {
            if postOpen, !showCamera {
                postOpen = false
                Events.shared.log(.init(name: "post_abandon", kind: kind, step: abandonStep))
            }
        }
        .onAppear {
            startPost()
            if state.me?.aiConsent == true { aiConsent = true }
            if !isRent, editing == nil, !aiConsent { showConsent = true }
            if let f = Self.demoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { focus = f }
            }
        }
        .alert("照片会发给 AI", isPresented: $showConsent) {
            Button("同意") { aiConsent = true }
            Button("不发了", role: .cancel) { dismiss() }
        } message: {
            Text("放上的照片和东西的信息会发给 AI（Anthropic 的 Claude）自动填名字，并打分给买家看。")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9) { addPhoto(data) }
            }
            .ignoresSafeArea()
        }
        .alert("卖了多少钱？", isPresented: $askSold) {
            TextField("美元", text: $soldPrice).keyboardType(.numberPad)
            Button("保存") { Task { await markSold(Int(soldPrice.trimmingCharacters(in: .whitespaces))) } }
            Button("跳过", role: .cancel) { Task { await markSold(nil) } }
        } message: {
            Text("选填，只用来比价，不公开")
        }
        .sheet(item: $dateField) { field in
            CalendarSheet(title: field.title, start: dateValue(field), clearLabel: field.clearLabel,
                          allowXun: field == .from || field == .to, xun: field == .from ? fromXun : (field == .to ? toXun : false),
                          xunEnd: field == .to) { value, xun in
                setDate(field, value)
                if field == .from { fromXun = xun && value != nil }
                if field == .to { toXun = xun && value != nil }
            }
        }
    }

    /// 截图用：选旬那张落在本月中旬
    private static var demoFrom: Date {
        guard Demo.scene == "rentcal-xun" else { return Date() }
        var c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        c.day = 11
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    private func dateValue(_ field: DateField) -> Date? {
        switch field {
        case .pickupAfter: return pickupAfter
        case .pickupBefore: return pickupBefore
        case .from: return from
        case .to: return to
        case .leaseEnd: return leaseEnd
        }
    }

    private func setDate(_ field: DateField, _ value: Date?) {
        switch field {
        case .pickupAfter: pickupAfter = value
        case .pickupBefore: pickupBefore = value
        case .from: from = value
        case .to: to = value
        case .leaseEnd: leaseEnd = value
        }
    }

    private func startPost() {
        guard editing == nil, !posted, !postOpen else { return }
        postOpen = true
        Events.shared.log(.init(name: "post_start", kind: kind))
    }

    /// 放弃时停在哪一步
    private var abandonStep: String {
        if inBatch { return batch.grouping ? "batch_recognize" : "batch_confirm" }
        if showSplit { return "batch_choose" }
        if photos.isEmpty { return "photos" }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "name" }
        if price.trimmingCharacters(in: .whitespaces).isEmpty { return "price" }
        return "details"
    }

    // MARK: - 一次发好几件

    /// 一开始放照片时能多选，之后和原来一样
    private var canBatch: Bool { !isRent && editing == nil && photos.isEmpty }

    private var aiUsable: Bool { (state.aiDescribe && state.isLoggedIn && aiConsent) || Demo.isOn }

    /// 本月 AI 够不够分这些照片
    private var aiEnough: Bool {
        guard aiUsable else { return false }
        if let left = state.me?.aiLeft { return left >= batch.shots.count }
        return true
    }

    private func addBatch(_ items: [PhotosPickerItem]) async {
        readingPhotos = true
        var datas: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
        }
        picked = []
        batch.reset()
        await batch.add(datas)
        readingPhotos = false
        if batch.shots.count >= 2 {
            showSplit = true
        } else {
            if datas.count < items.count { state.toast(String(localized: "有张照片打不开")) }
            if let only = datas.first { addPhoto(only) }
            batch.reset()
        }
    }

    private func chooseSplit(_ how: BatchModel.Split) {
        showSplit = false
        if how == .allOne {
            // 都是同一件：回原来的发布页
            let first = batch.shots.first
            photos = batch.shots.map { .fresh(id: UUID(), jpeg: $0.jpeg, preview: $0.preview) }
            batch.reset()
            if let first { startDescribe(first.preview) }
            return
        }
        // 发布页上填过的带过去
        batch.pickup = pickup
        batch.deliver = deliver
        batch.deliveryFee = deliveryFee
        batch.place = place
        batch.availTime = availTime
        batch.contact = contact
        focus = nil
        inBatch = true
        batch.start(how, consent: aiConsent, aiOn: aiUsable && state.me?.aiLeft != 0, left: state.me?.aiLeft)
    }

    private var batchFlow: some View {
        BatchFlow(batch: batch, aiConsent: aiConsent, aiOn: aiUsable && state.me?.aiLeft != 0) {
            inBatch = false
            showSplit = true
        } exit: {
            batch.reset()
            inBatch = false
        } posted: { saved in
            // 再发一件时带上这次填的
            pickup = batch.pickup
            deliver = batch.deliver
            deliveryFee = batch.deliveryFee
            place = batch.place
            availTime = batch.availTime
            contact = batch.contact
            hive = zip(batch.items, saved).map { it, listing in
                HiveItem(image: it.shots.first.flatMap { batch.shot($0)?.preview }, url: listing.photos.first?.url, priceText: listing.priceText)
            }
            if state.me?.aiConsent != true { Task { await state.refreshMe() } }
            state.changed()
            Haptics.beeBuzz()
            if contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Notifier.ask() }
            postOpen = false
            batch.logResults()
            batch.reset()
            inBatch = false
            posted = true
        }
    }

    // MARK: - 发完

    /// 蜂巢连发。再发一件时地点、取货、微信号都带上，只填照片、名字、价格
    private var postedView: some View {
        HivePostedView(items: hive) {
            title = ""
            price = ""
            desc = ""
            photos = []
            cat = nil
            cond = nil
            aiGuessed = false
            nameTouched = false
            priceTouched = false
            priceSuggested = false
            pickupBefore = nil
            pickupAfter = nil
            error = nil
            posted = false
            aiSaidName = nil
            aiSaidPrice = nil
            startPost()
            if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
        } share: {
            Task { hiveShare = await HiveShareCard.make(items: hive, contact: contact, total: hive.count) }
        } done: {
            dismiss()
        }
        .sheet(item: $hiveShare) { ShareSheet(image: $0.image) }
    }

    // MARK: - 卖东西：一屏

    private var goodsForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    formTitle
                    statusCard
                    GroupHeader(title: String(localized: "必填"), note: String(localized: "照片、名字、价格"))
                    FormCard {
                        VStack(alignment: .leading, spacing: 8) {
                            if photos.count < 3 {
                                HStack(alignment: .center, spacing: 8) {
                                    goodsPhotos
                                    Spacer(minLength: 0)
                                    aiHint
                                }
                            } else {
                                // 照片多了折行，和房子一样
                                FlowLayout(spacing: 8) { goodsPhotos }
                            }
                            lackHint(String(localized: "照片"), String(localized: "放一张照片才能发"))
                            aiQuota
                        }
                        .padding(.vertical, 12)
                        FormDivider()
                        nameField
                        FormDivider()
                        priceField
                    }
                    GroupHeader(title: String(localized: "选填"), note: String(localized: "填了买家更好决定"), large: true).padding(.top, 10)
                    FormCard {
                        FieldBlock(label: String(localized: "取货方式"), hint: pickup ? nil : String(localized: "选了自取，再填自取地点")) {
                            HStack(spacing: 8) {
                                Chip(text: String(localized: "自取"), on: pickup, act: formAct) { pickup.toggle() }
                                Chip(text: String(localized: "可配送"), on: deliver, act: formAct) { deliver.toggle() }
                            }
                        }
                        if deliver {
                            FormDivider()
                            FieldBlock(label: String(localized: "配送费")) { dollarLine(String(localized: "0，不收就空着"), text: $deliveryFee, field: .fee) }
                        }
                        if pickup {
                            FormDivider()
                            FieldBlock(label: String(localized: "自取地点")) {
                                inputLine(String(localized: "比如 Monty 楼下"), text: $place, field: .place)
                            }
                        }
                        FormDivider()
                        NavRow(symbol: "calendar", title: String(localized: "从几号起可取"), value: dayText(pickupAfter), empty: pickupAfter == nil) { dateField = .pickupAfter }
                        FormDivider()
                        NavRow(symbol: "calendar", title: String(localized: "几号前取走"), value: dayText(pickupBefore), empty: pickupBefore == nil) { dateField = .pickupBefore }
                    }
                    FormCard {
                        FieldBlock(label: String(localized: "方便的时间"), hint: fromProfile(availTime, "defaultTime") ? String(localized: "来自我的信息") : nil) {
                            inputLine(String(localized: "比如 工作日晚上、周末"), text: $availTime, field: .time)
                        }
                        FormDivider()
                        FieldBlock(label: String(localized: "微信号"), hint: fromProfile(contact, "contact") ? String(localized: "来自我的信息，别人能看到") : String(localized: "填了别人能看到")) {
                            contactField
                        }
                        FormDivider()
                        FieldBlock(label: String(localized: "备注")) {
                            noteEditor(String(localized: "用了多久、有没有毛病"), minHeight: 80)
                        }
                    }
                    .environment(\.formLarge, true)
                    errorLine
                }
                .environment(\.formLarge, true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture { focus = nil }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focus) { _, field in
                guard let field else { return }
                // 等键盘升起来再滚，免得算错位置
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.snappy) { proxy.scrollTo(field, anchor: .center) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { publishBar }
    }

    /// 顶上居中的标题
    private var formTitle: some View {
        Text(editing != nil && !relist ? (isRent ? String(localized: "改房子") : String(localized: "改东西")) : (isRent ? String(localized: "出租房子") : String(localized: "卖东西")))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
    }

    /// 这一项是不是从“我的信息”带进来的
    private func fromProfile(_ value: String, _ key: String) -> Bool {
        editing == nil && !value.isEmpty && value == UserDefaults.standard.string(forKey: key)
    }

    private func dayText(_ date: Date?) -> String {
        guard let date else { return String(localized: "不限") }
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return String(localized: "\(c.month ?? 0)月\(c.day ?? 0)日")
    }

    /// 白底块里的一行输入：17 号字
    private func inputLine(_ placeholder: String, text: Binding<String>, field: Field, number: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 17))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .keyboardType(number ? .numberPad : .default)
            .focused($focus, equals: field)
            .id(field)
            .frame(minHeight: 30)
    }

    /// 钱数输入：$ 当前缀，一行放下
    private func dollarLine(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("$").font(.system(size: 17)).foregroundStyle(text.wrappedValue.isEmpty ? Theme.hint : Theme.ink)
            inputLine(placeholder, text: text, field: field, number: true)
        }
        .lineLimit(1)
    }

    private func noteEditor(_ placeholder: String, minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if desc.isEmpty {
                Text(placeholder).font(.system(size: 17)).foregroundStyle(Theme.hint).padding(.top, 8).padding(.leading, 4)
            }
            TextEditor(text: $desc)
                .focused($focus, equals: .desc)
                .id(Field.desc)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
        }
        .frame(minHeight: minHeight)
    }

    /// 没照片时拍照、相册两块，有了就是一排
    @ViewBuilder
    private var goodsPhotos: some View {
        if photos.isEmpty {
            if UIImagePickerController.isSourceTypeAvailable(.camera) || Demo.isOn {
                Button { showCamera = true } label: { photoTile("camera") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("拍照")
            }
            PhotosPicker(selection: $picked, maxSelectionCount: maxPhotos, matching: .images) {
                photoTile("photo.on.rectangle")
            }
            .accessibilityLabel("相册")
        } else {
            photoThumbs
        }
    }

    private func photoTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Theme.sub)
            .frame(width: tile, height: tile * 1.25)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var photoThumbs: some View {
        ForEach(photos) { photo in
            ZStack(alignment: .topTrailing) {
                Group {
                    switch photo {
                    case .existing(let p):
                        RemoteImage(url: p.url, maxPixel: 300)
                    case .fresh(_, _, let preview):
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: tile, height: tile * 1.25)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    photos.removeAll { $0.id == photo.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("去掉这张")
            }
        }
        if photos.count < maxPhotos {
            PhotosPicker(selection: $picked, maxSelectionCount: maxPhotos - photos.count, matching: .images) {
                photoTile("plus")
            }
            .accessibilityLabel("加照片")
        }
    }

    /// 明白告诉卖家 AI 在帮他填
    @ViewBuilder
    private var aiHint: some View {
        // 照片多了放不下，只在前两格旁边显示
        if state.aiDescribe || Demo.isOn, editing == nil, photos.count < 3 {
            HStack(spacing: 6) {
                if aiLoading {
                    HoneyLoader(size: 26)
                } else {
                    ZStack {
                        Hexagon().fill(Theme.accent).frame(width: 26, height: 26)
                        Image(systemName: "sparkle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onBuy)
                    }
                }
                Text(aiLoading ? String(localized: "AI 正在认\n也可以自己写") : (aiGuessed ? String(localized: "AI 填好了\n可以改") : String(localized: "放上照片\nAI 帮你填名字")))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 本月 AI：剩 10 条及以下才提一句；用完了说清楚下个月 1 号恢复
    @ViewBuilder
    private var aiQuota: some View {
        if state.aiDescribe || Demo.isOn, editing == nil, !isRent, let left = state.me?.aiLeft ?? (Demo.scene == "ai-low" ? 6 : (Demo.scene == "ai-out" ? 0 : nil)), left <= 10 {
            Text(left == 0 ? String(localized: "这个月的 AI 用完了，下个月 1 号恢复，名字和价格自己填一下。") : String(localized: "本月 AI 还剩 \(left) 条"))
                .font(.system(size: 12.5))
                .foregroundStyle(left == 0 ? Theme.warn : Theme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var priceField: some View {
        FieldBlock(label: isRent ? String(localized: "月租") : String(localized: "价格"), hint: tried && missingNames.contains(isRent ? String(localized: "月租") : String(localized: "价格")) ? String(localized: "填个价格才能发") : (priceSuggested ? String(localized: "AI 建议价，可以改") : nil), hintColor: tried && missingNames.contains(isRent ? String(localized: "月租") : String(localized: "价格")) ? Theme.warn : Theme.tint) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !price.isEmpty { Text("$") }
                TextField("$", text: Binding(
                    get: { price },
                    set: {
                        price = $0
                        priceTouched = true
                        priceSuggested = false
                    }
                ))
                .keyboardType(.numberPad)
                .focused($focus, equals: .price)
                .fixedSize()
                if isRent, !price.isEmpty { Text(" /月") }
                Spacer(minLength: 0)
            }
            .id(Field.price)
            .font(.system(size: 22, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(Theme.ink)
        }
    }

    private var nameField: some View {
        FieldBlock(label: isRent ? String(localized: "标题") : String(localized: "名字"), hint: tried && missingNames.contains(isRent ? String(localized: "标题") : String(localized: "名字")) ? (isRent ? String(localized: "写一下标题才能发") : String(localized: "写一下卖什么才能发")) : (title.count > 14 ? String(localized: "名字写短一点，细节放备注") : nil), hintColor: tried && missingNames.contains(isRent ? String(localized: "标题") : String(localized: "名字")) ? Theme.warn : Theme.hint) {
            TextField(isRent ? String(localized: "比如 Monty 旁一室一厅") : String(localized: "比如 榉木画架"), text: Binding(
                get: { title },
                set: {
                    title = $0
                    nameTouched = true
                }
            ))
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .focused($focus, equals: .name)
            .submitLabel(.next)
            .onSubmit { focus = .price }
            .id(Field.name)
        }
    }

    /// 编辑时才有：状态三选一
    @ViewBuilder
    private var statusCard: some View {
        if let editing, editing.status != "hidden", !relist {
            FormCard {
                FieldBlock(label: String(localized: "状态")) {
                    HStack(spacing: 8) {
                        Chip(text: String(localized: "在售"), on: status == "on", act: formAct) { status = "on" }
                        Chip(text: String(localized: "已预订"), on: status == "reserved", act: formAct) { status = "reserved" }
                        Chip(text: isRent ? String(localized: "已租") : String(localized: "已卖"), on: status == "off", act: formAct) { status = "off" }
                    }
                }
            }
            .environment(\.formLarge, true)
        }
    }

    private var contactField: some View {
        inputLine(String(localized: "微信号"), text: $contact, field: .contact)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .contact)
            .id(Field.contact)
    }

    /// 热门地点，下面一条能手填。存的都是文字，能搜。
    private func placeChips(surface: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(isRent ? RENT_PLACES : PLACES, id: \.self) { p in
                    Chip(text: p, on: place == p, act: formAct, surface: surface) {
                        place = place == p ? "" : p
                    }
                }
            }
            TextField("或者自己填", text: Binding(
                get: { (isRent ? RENT_PLACES : PLACES).contains(place) ? "" : place },
                set: { place = $0 }
            ))
            .font(.system(size: 17))
            .focused($focus, equals: .place)
            .id(Field.place)
            .frame(minHeight: 30)
        }
    }

    // MARK: - 出租房子：可以长

    private var rentForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    formTitle
                    statusCard
                    GroupHeader(title: String(localized: "必填"), note: String(localized: "照片、标题、月租、出租、地段、起租、水电"))
                    FormCard {
                        VStack(alignment: .leading, spacing: 8) {
                            FlowLayout(spacing: 8) { rentPhotos }
                            lackHint(String(localized: "照片"), String(localized: "放一张照片才能发"))
                        }
                        .padding(.vertical, 12)
                        FormDivider()
                        nameField
                        FormDivider()
                        priceField
                        FormDivider()
                        FieldBlock(label: String(localized: "出租")) {
                            HStack(spacing: 8) {
                                Chip(text: String(localized: "整套"), on: unitWhole, act: formAct) { unitWhole.toggle() }
                                Chip(text: String(localized: "单间"), on: unitRoom, act: formAct) { unitRoom.toggle() }
                            }
                        }
                        FormDivider()
                        FieldBlock(label: String(localized: "地段")) { placeChips(surface: Theme.fill) }
                        FormDivider()
                        FieldBlock(label: String(localized: "什么时候能住")) {
                            HStack(spacing: 10) {
                                DateTile(label: String(localized: "起"), value: from, empty: String(localized: "选日期"), act: formAct, xun: fromXun) { dateField = .from }
                                DateTile(label: String(localized: "止"), value: to, empty: String(localized: "长租"), act: formAct, xun: toXun) { dateField = .to }
                            }
                        }
                        FormDivider()
                        FieldBlock(label: String(localized: "水电")) {
                            HStack(spacing: 8) {
                                Chip(text: String(localized: "包水电"), on: utilities == true, act: formAct) { utilities = true }
                                Chip(text: String(localized: "不包水电"), on: utilities == false, act: formAct) { utilities = false }
                            }
                        }
                    }
                    GroupHeader(title: String(localized: "选填"), note: String(localized: "填了少来回问"), large: true).padding(.top, 10)
                    FormCard {
                        FieldBlock(label: String(localized: "微信号"), hint: fromProfile(contact, "contact") ? String(localized: "来自我的信息，别人能看到") : String(localized: "填了别人能看到")) { contactField }
                        FormDivider()
                        FieldBlock(label: String(localized: "方便看房的时间"), hint: fromProfile(availTime, "defaultTime") ? String(localized: "来自我的信息") : nil) {
                            inputLine(String(localized: "比如 周末下午"), text: $availTime, field: .time)
                        }
                    }
                    FormCard {
                        FieldBlock(label: String(localized: "房型")) {
                            VStack(alignment: .leading, spacing: 8) {
                                oneOf(["1", "2", "3"], $bedrooms, suffix: String(localized: " 室"))
                                oneOf(["1", "2", "3"], $baths, suffix: String(localized: " 卫"))
                            }
                        }
                        FormDivider()
                        FieldBlock(label: String(localized: "家具")) { oneOf(["有", "部分有", "没有"], $furniture) }
                        FormDivider()
                        FieldBlock(label: String(localized: "独卫")) { yesNo(String(localized: "有"), String(localized: "没有"), $privateBath) }
                    }
                    FormCard {
                        FieldBlock(label: String(localized: "网费")) { yesNo(String(localized: "包"), String(localized: "不包"), $internet) }
                        FormDivider()
                        FieldBlock(label: String(localized: "押金")) { dollarLine("", text: $deposit, field: .deposit) }
                        FormDivider()
                        FieldBlock(label: String(localized: "申请费")) { dollarLine("", text: $appFee, field: .appFee) }
                    }
                    FormCard {
                        FieldBlock(label: String(localized: "室友")) { oneOf(Self.roommateCounts, $roommateCount) }
                        FormDivider()
                        FieldBlock(label: String(localized: "室友情况")) { inputLine(String(localized: "比如都是学生"), text: $roommateNote, field: .note) }
                        FormDivider()
                        NavRow(symbol: "calendar", title: String(localized: "租约到期日"), value: dayText(leaseEnd), empty: leaseEnd == nil) { dateField = .leaseEnd }
                    }
                    FormCard {
                        FieldBlock(label: String(localized: "描述")) { noteEditor(String(localized: "周边、交通、看房时间"), minHeight: 110) }
                    }
                    errorLine
                }
                .environment(\.formLarge, true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture { focus = nil }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focus) { _, field in
                guard let field else { return }
                // 等键盘升起来再滚，免得算错位置
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.snappy) { proxy.scrollTo(field, anchor: .center) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { publishBar }
    }

    @ViewBuilder
    private var rentPhotos: some View {
        if photos.isEmpty, UIImagePickerController.isSourceTypeAvailable(.camera) || Demo.isOn {
            Button { showCamera = true } label: { photoTile("camera") }
                .buttonStyle(.plain)
                .accessibilityLabel("拍照")
        }
        if photos.isEmpty {
            PhotosPicker(selection: $picked, maxSelectionCount: maxPhotos, matching: .images) {
                photoTile("photo.on.rectangle")
            }
            .accessibilityLabel("相册")
        } else {
            photoThumbs
        }
    }

    // MARK: - 小块

    private func oneOf(_ list: [String], _ binding: Binding<String?>, suffix: String = "") -> some View {
        FlowLayout(spacing: 8) {
            ForEach(list, id: \.self) { value in
                Chip(text: value + suffix, on: binding.wrappedValue == value, act: formAct) {
                    binding.wrappedValue = binding.wrappedValue == value ? nil : value
                }
            }
        }
    }

    private func yesNo(_ yes: String, _ no: String, _ binding: Binding<Bool?>) -> some View {
        FlowLayout(spacing: 8) {
            Chip(text: yes, on: binding.wrappedValue == true, act: formAct) { binding.wrappedValue = binding.wrappedValue == true ? nil : true }
            Chip(text: no, on: binding.wrappedValue == false, act: formAct) { binding.wrappedValue = binding.wrappedValue == false ? nil : false }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Text(error).font(.subheadline).foregroundStyle(Theme.warn)
        }
    }

    /// 发布按钮固定在底部；必填没齐时变淡，点了会说缺什么
    private var publishBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 8) {
                    if busy { HoneyLoader(size: 22) }
                    Text(busy ? String(localized: "正在发") : (relist ? String(localized: "重新发布") : (editing == nil ? String(localized: "发布") : String(localized: "保存")))).lineLimit(1)
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink, dimmed: !requiredFilled))
            .disabled(busy)
            // 数字键盘没有回车，打字时这里能收
            if focus != nil {
                Button("完成") { focus = nil }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 72, height: 54)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 17))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    /// 必填里还差哪几样
    private var missingNames: [String] {
        var out: [String] = []
        if photos.isEmpty { out.append(String(localized: "照片")) }
        if title.trimmingCharacters(in: .whitespaces).isEmpty, !aiLoading { out.append(isRent ? String(localized: "标题") : String(localized: "名字")) }
        if Int(price.trimmingCharacters(in: .whitespaces)) == nil { out.append(isRent ? String(localized: "月租") : String(localized: "价格")) }
        return out
    }

    private func lackHint(_ name: String, _ text: String) -> some View {
        Group {
            if tried, missingNames.contains(name) {
                Label(text, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Theme.warn)
            }
        }
    }

    private var requiredFilled: Bool {
        guard !photos.isEmpty, Int(price.trimmingCharacters(in: .whitespaces)) != nil else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty || aiLoading else { return false }
        if isRent { return (unitWhole || unitRoom) && !place.trimmingCharacters(in: .whitespaces).isEmpty && from != nil && utilities != nil }
        return true
    }

    // MARK: - 动作

    private func addPicked(_ items: [PhotosPickerItem]) async {
        if items.count >= 2, canBatch {
            await addBatch(items)
            return
        }
        for item in items where photos.count < maxPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                state.toast(String(localized: "有张照片打不开"))
                continue
            }
            addPhoto(data)
        }
        picked = []
    }

    private func addPhoto(_ data: Data) {
        guard let ready = ImagePrep.prepare(data) else {
            state.toast(String(localized: "有张照片打不开"))
            return
        }
        let first = photos.isEmpty
        photos.append(.fresh(id: UUID(), jpeg: ready.jpeg, preview: ready.preview))
        if first, !isRent, editing == nil { startDescribe(ready.preview) }
    }

    /// 后台让 AI 看第一张；失败就手填名字，不影响发布
    private func startDescribe(_ image: UIImage) {
        // 这个月用完了就不去问 AI，卖家自己填
        guard state.aiDescribe, state.isLoggedIn, aiConsent, state.me?.aiLeft != 0, let jpeg = ImagePrep.forAI(image) else { return }
        aiLoading = true
        describeTask = Task {
            defer { aiLoading = false }
            let result: AIGuess
            do {
                result = try await API.shared.describe(jpeg: jpeg, consent: true)
            } catch {
                if (error as? APIError)?.code == "ai_limit" { state.setAILeft(0) }
                return
            }
            guard !Task.isCancelled else { return }
            let guess = result
            state.setAILeft(guess.aiLeft)
            aiSaidName = guess.name
            aiSaidPrice = guess.price
            if !nameTouched, title.isEmpty {
                title = guess.name
                aiGuessed = true
            }
            if cat == nil, guess.cat != "other" { cat = guess.cat }
            if cond == nil { cond = guess.cond }
            if !priceTouched, price.isEmpty, let suggested = guess.price {
                price = String(suggested)
                priceSuggested = true
            }
        }
    }

    private func markSold(_ price: Int?) async {
        guard let editing, !Demo.isOn || Demo.scene != "sold-ask" else { return }
        do {
            _ = try await API.shared.setStatus(editing.id, "off", soldPrice: price)
            state.changed()
            state.toast(String(localized: "改好了"))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        error = nil
        focus = nil
        // AI 还在认就等它一下（最多十来秒），它失败了才要手填
        if !isRent, title.trimmingCharacters(in: .whitespaces).isEmpty, let task = describeTask {
            busy = true
            let cap = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                task.cancel()
            }
            await task.value
            cap.cancel()
            busy = false
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        tried = true
        let lack = missingNames
        if !lack.isEmpty {
            state.toast(String(localized: "还差") + lack.joined(separator: String(localized: "和")))
            return
        }
        guard let money = Int(price.trimmingCharacters(in: .whitespaces)), money >= 0 else { error = String(localized: "价格要填整数。"); return }
        if isRent {
            if money == 0 { error = String(localized: "租金要大于 0。"); return }
            if !unitWhole, !unitRoom { error = String(localized: "选整套或单间，都可以就都选。"); return }
            if p.isEmpty { error = String(localized: "选一下地段。"); return }
            guard let start = from else { error = String(localized: "选一下起始日期。"); return }
            if let end = to, start > end { error = String(localized: "止要晚于起。"); return }
            if utilities == nil { error = String(localized: "选一下包不包水电。"); return }
        } else if editing == nil, !aiConsent {
            error = String(localized: "要同意发给 AI 打分才能发布。")
            return
        }
        let fee = deliveryFee.trimmingCharacters(in: .whitespaces)
        let delivery: String? = pickup && deliver ? "both" : (pickup ? "pickup" : (deliver ? "deliver" : nil))
        let dep = deposit.trimmingCharacters(in: .whitespaces), app = appFee.trimmingCharacters(in: .whitespaces)
        if !isRent, deliver, !fee.isEmpty, Int(fee) == nil { error = String(localized: "配送费要填整数。"); return }
        if isRent, (!dep.isEmpty && Int(dep) == nil) || (!app.isEmpty && Int(app) == nil) { error = String(localized: "押金和申请费要填整数。"); return }

        busy = true
        defer { busy = false }
        do {
            // 照片多：一次传四张，顺序不变
            let list = photos
            var keys = list.map { photo -> String in
                if case .existing(let e) = photo { return e.key }
                return ""
            }
            let fresh = list.indices.filter { keys[$0].isEmpty }
            var start = 0
            while start < fresh.count {
                try await withThrowingTaskGroup(of: (Int, String).self) { g in
                    for i in fresh[start..<min(start + 4, fresh.count)] {
                        if case .fresh(_, let jpeg, _) = list[i] {
                            g.addTask { (i, try await API.shared.upload(jpeg: jpeg)) }
                        }
                    }
                    for try await (i, key) in g { keys[i] = key }
                }
                start += 4
            }
            var input = ListingInput(kind: kind, title: t, price: money, place: isRent || pickup ? p : "", desc: desc.trimmingCharacters(in: .whitespacesAndNewlines), contact: c, photos: keys)
            let day: (Date?) -> String? = { $0.map { Self.dayFormat.string(from: $0) } }
            if isRent {
                input.from = day(from)
                input.to = day(to)
                input.fromPrec = fromXun ? "xun" : nil
                input.toPrec = toXun && to != nil ? "xun" : nil
                input.longTerm = to == nil
                input.utilities = utilities
                input.leaseEnd = day(leaseEnd)
                input.privateBath = privateBath
                input.internet = internet
                input.furniture = furniture
                input.unitType = unitWhole && unitRoom ? "both" : (unitWhole ? "whole" : "room")
                input.deposit = Int(dep)
                input.appFee = Int(app)
                input.parking = parking
                input.pets = pets
                let room = (bedrooms.map { "\($0)室" } ?? "") + (baths.map { "\($0)卫" } ?? "")
                input.roomType = room.isEmpty ? nil : room
                let note = roommateNote.trimmingCharacters(in: .whitespacesAndNewlines)
                let mates = [roommateCount ?? "", note].filter { !$0.isEmpty }.joined(separator: "；")
                input.roommates = mates.isEmpty ? nil : mates
            } else {
                input.cat = cat
                input.cond = cond
                input.aiConsent = editing == nil ? true : nil
                input.delivery = delivery
                input.deliveryFee = deliver ? Int(fee) : nil
                input.pickupBefore = day(pickupBefore)
                input.pickupAfter = day(pickupAfter)
            }
            if relist { input.relist = true }
            let t = availTime.trimmingCharacters(in: .whitespacesAndNewlines)
            input.availTime = t.isEmpty ? nil : t
            var saved: Listing
            if let editing {
                saved = try await API.shared.update(editing.id, input)
                if status != editing.status {
                    if status == "off", !isRent {
                        // 先存好别的，再问卖了多少钱
                        onSaved?(saved)
                        state.changed()
                        askSold = true
                        return
                    }
                    saved = try await API.shared.setStatus(editing.id, status)
                }
            } else {
                saved = try await API.shared.create(input)
            }
            if !c.isEmpty { UserDefaults.standard.set(c, forKey: "contact") }
            if !isRent, editing == nil, state.me?.aiConsent != true { Task { await state.refreshMe() } }
            onSaved?(saved)
            state.changed()
            if editing == nil {
                postOpen = false
                Events.shared.log(.init(name: "post_done", kind: kind, mode: "single", count: 1))
                if aiSaidName != nil || aiSaidPrice != nil {
                    Events.shared.log(.init(name: "ai_result", aiName: aiSaidName, nameEdited: aiSaidName.map { $0 != saved.title },
                                            aiPrice: aiSaidPrice, priceEdited: aiSaidPrice.map { $0 != saved.price },
                                            priceDiff: aiSaidPrice.map { saved.price - $0 }))
                }
                Haptics.beeBuzz()
                // 没留微信才靠留言，这时问通知，卖家知道为什么
                if c.isEmpty { Notifier.ask() }
            }
            if editing == nil, !isRent {
                var cover = HiveItem(image: nil, url: saved.photos.first?.url, priceText: saved.priceText)
                if case .fresh(_, _, let preview)? = photos.first { cover.image = preview }
                hive.append(cover)
                posted = true
            } else {
                state.toast(editing == nil ? String(localized: "发好了") : String(localized: "改好了"))
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 没有框，只有一条细线
private struct LineField: View {
    let placeholder: String
    @Binding var text: String
    var dollar = false
    /// 填了之后留在前面的字
    var prefix = ""
    @Environment(\.formLarge) private var large

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                if !prefix.isEmpty, !text.isEmpty { Text(prefix).foregroundStyle(Theme.ink) }
                if dollar, !text.isEmpty { Text("$").foregroundStyle(Theme.ink) }
                TextField(placeholder, text: $text)
            }
            .font(.system(size: large ? 17 : 15))
            .frame(minHeight: large ? 32 : nil)
            Theme.line.frame(height: 0.5)
        }
        .padding(.top, 8)
    }
}

/// 表单一行左边的小标签；“选填”里放大
private struct RowLabel: View {
    let text: String
    @Environment(\.formLarge) private var large

    var body: some View {
        Text(text)
            .font(.system(size: large ? 16 : 14))
            .foregroundStyle(Theme.sub)
            .frame(width: large ? 50 : 44, height: large ? 44 : 34, alignment: .leading)
    }
}

/// 卖东西的日期：一行字，选了才是黑的
private struct DateRow: View {
    let label: String
    let value: Date?
    let action: () -> Void
    @Environment(\.formLarge) private var large

    private var text: String {
        guard let value else { return String(localized: "不限") }
        let c = Calendar.current.dateComponents([.month, .day], from: value)
        return String(localized: "\(c.month ?? 0) 月 \(c.day ?? 0) 日")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: large ? 17 : 15)).foregroundStyle(Theme.sub)
                Spacer()
                Text(text)
                    .font(.system(size: large ? 17 : 15, weight: value == nil ? .regular : .semibold))
                    .foregroundStyle(value == nil ? Theme.sub : Theme.ink)
                Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(Theme.sub)
            }
            .frame(height: large ? 44 : 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + " " + text)
    }
}

/// 日期格：没选是灰的，选了涂这一页的颜色；点开日历
private struct DateTile: View {
    let label: String
    let value: Date?
    let empty: String
    let act: Act
    var surface: Color = Theme.fill
    var xun = false
    let action: () -> Void

    private var text: String {
        guard let value else { return empty }
        let c = Calendar.current.dateComponents([.month, .day], from: value)
        if xun { return String(localized: "\(c.month ?? 0) 月") + Listing.xunName(c.day ?? 1) }
        return String(localized: "\(c.month ?? 0) 月 \(c.day ?? 0) 日")
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13)).lineLimit(1)
                    Text(text).font(.system(size: 16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Image(systemName: "calendar").font(.system(size: 17))
            }
            .foregroundStyle(value == nil ? Theme.sub : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(value == nil ? surface : Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + " " + text)
    }
}

/// 自己画的月历：选中的垫六边形；底下的“不限”就是清空。
/// 房子的起止还能点上中下旬：选了就把那几天铺一层浅绿，和点某一天互斥。
private struct CalendarSheet: View {
    let title: String
    let start: Date?
    let clearLabel: String?
    /// 房子的起止可以只选上中下旬
    var allowXun = false
    var xun = false
    /// 止：选旬时取该旬最后一天
    var xunEnd = false
    let pick: (Date?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date = Date()
    /// 弹层里当前选的：某一天，或者某一旬（存该旬的起或止那天）
    @State private var chosen: Date?
    @State private var chosenXun = false
    /// 量出来的：日历本身多高、弹层里能用多高，用来把弹层收到刚好
    @State private var detent: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var boxHeight: CGFloat = 0

    private static let xuns = [(1, String(localized: "上旬")), (11, String(localized: "中旬")), (21, String(localized: "下旬"))]

    private var lastDayOfMonth: Int {
        calendar.range(of: .day, in: .month, for: month)?.count ?? 30
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }

    private var days: [Date?] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let blanks = calendar.component(.weekday, from: first) - 1
        return Array(repeating: nil, count: blanks) + range.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    /// 先估一个高度，弹出来后按量到的改
    private var sheetHeight: CGFloat {
        let rows = CGFloat((days.count + 6) / 7)
        var h: CGFloat = 20 + 44 + 8 + 26 + rows * 46 + 8
        if allowXun { h += 58 + 8 + 18 + 8 }
        if clearLabel != nil { h += 0.5 + 8 + 44 }
        let bottom = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 34
        return h + max(bottom, 8)
    }

    /// 选中的旬在当前这个月里，就返回它的名字
    private var chosenXunName: String? {
        guard chosenXun, let chosen, calendar.isDate(chosen, equalTo: month, toGranularity: .month) else { return nil }
        return Listing.xunName(calendar.component(.day, from: chosen))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                arrow("chevron.left", String(localized: "上个月"), -1)
                Spacer()
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("· \(calendar.component(.month, from: month)) 月")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                Spacer()
                arrow("chevron.right", String(localized: "下个月"), 1)
            }
            if allowXun {
                // 上中下旬三块放在日历顶上，写清是几号到几号
                HStack(spacing: 10) {
                    ForEach(Self.xuns, id: \.0) { first, name in
                        let on = chosenXunName == name
                        Button { pickXun(first) } label: {
                            VStack(spacing: 2) {
                                Text(name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                                Text(first == 21 ? String(localized: "21–\(lastDayOfMonth) 号") : String(localized: "\(first)–\(first + 9) 号")).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                                    .foregroundStyle(on ? Theme.onBuy.opacity(0.75) : Theme.sub)
                            }
                            .foregroundStyle(on ? Theme.onBuy : Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(on ? Theme.accent : Theme.fill, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Text("选一旬，或者点某一天").font(.system(size: 13)).foregroundStyle(Theme.hint).frame(maxWidth: .infinity)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach([String(localized: "日"), String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六")], id: \.self) { d in
                    Text(d).font(.system(size: 13)).foregroundStyle(Theme.sub).frame(height: 26)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            if let clearLabel {
                Theme.line.frame(height: 0.5).padding(.top, 8)
                Button(clearLabel) {
                    pick(nil, false)
                    dismiss()
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; fit() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boxHeight = $0; fit() }
        .background(Theme.bg)
        .presentationDetents([.height(detent > 0 ? detent : sheetHeight)])
        .presentationDragIndicator(.visible)
        .onAppear {
            month = start ?? Date()
            chosen = start
            chosenXun = xun && start != nil
        }
    }

    /// 弹层高度比能用的高度多出来的那截（安全区、圆角）是固定的，补上它刚好装下日历
    private func fit() {
        guard contentHeight > 0, boxHeight > 0 else { return }
        let current = detent > 0 ? detent : sheetHeight
        // 弹出途中量到的可能是过渡中的高度，多出来那截只信 0～60
        let extra = min(max(current - boxHeight, 0), 60)
        let want = (contentHeight + extra).rounded()
        if abs(want - current) > 1 { detent = want }
    }

    /// 选月份加旬。起存该旬第一天，止存最后一天，排序和过期用这个。
    private func pickXun(_ first: Int) {
        let comps = calendar.dateComponents([.year, .month], from: month)
        let startDay = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: first)) ?? month
        let lastInMonth = calendar.range(of: .day, in: .month, for: startDay)?.count ?? 30
        let lastDay = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: first == 21 ? lastInMonth : first + 9)) ?? startDay
        choose(xunEnd ? lastDay : startDay, xun: true)
    }

    /// 先在弹层里显示选中，停一下再收起，看得到选了什么
    private func choose(_ value: Date, xun: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) {
            chosen = value
            chosenXun = xun
        }
        pick(value, xun)
        Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            dismiss()
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let n = calendar.component(.day, from: day)
        let selected = !chosenXun && (chosen.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
        let inXun = chosenXunName == Listing.xunName(n)
        let weekday = calendar.component(.weekday, from: day)
        let last = calendar.range(of: .day, in: .month, for: day)?.count ?? 30
        // 浅绿底连成一条：这一旬的头尾和每行的头尾是圆角
        let lead: CGFloat = n == 1 || n == 11 || n == 21 || weekday == 1 ? 12 : 0
        let trail: CGFloat = n == 10 || n == 20 || n == last || weekday == 7 ? 12 : 0
        return Button {
            choose(day, xun: false)
        } label: {
            ZStack {
                if inXun {
                    UnevenRoundedRectangle(topLeadingRadius: lead, bottomLeadingRadius: lead,
                                           bottomTrailingRadius: trail, topTrailingRadius: trail)
                        .fill(Theme.accentSoft)
                }
                if selected { Hexagon().fill(Theme.accent).frame(width: 40, height: 40) }
                Text("\(n)")
                    .font(.system(size: 16, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Theme.onBuy : Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected || inXun ? .isSelected : [])
    }

    private func arrow(_ symbol: String, _ label: String, _ by: Int) -> some View {
        Button {
            month = calendar.date(byAdding: .month, value: by, to: month) ?? month
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 系统相机
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
