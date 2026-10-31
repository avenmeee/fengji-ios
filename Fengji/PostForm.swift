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

private enum ImagePrep {
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
        case .pickupAfter: return "几号后可取"
        case .pickupBefore: return "几号前取走"
        case .from: return "起"
        case .to: return "止"
        case .leaseEnd: return "租约到期日"
        }
    }

    /// 清空按钮的字；起是必填，没有清空
    var clearLabel: String? {
        switch self {
        case .from: return nil
        case .to: return "长租"
        default: return "不限"
        }
    }
}

/// 发布页能打字的地方：滚到可见、收键盘都靠它
private enum Field: Hashable {
    case price, name, contact, fee, place, desc, deposit, appFee, note
}

struct PostForm: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    let kind: String
    let editing: Listing?
    var onSaved: ((Listing) -> Void)?

    // 必填
    @State private var title: String
    @State private var price: String
    @State private var photos: [FormPhoto]
    @State private var contact: String
    @State private var askContact: Bool
    // 卖东西选填
    @State private var cat: String?
    @State private var cond: String?
    @State private var delivery: String?
    @State private var deliveryFee: String
    @State private var pickupBefore: Date?
    @State private var pickupAfter: Date?
    @State private var place: String
    @State private var placeOther: Bool
    @State private var desc: String
    // 房子
    @State private var from: Date?
    @State private var to: Date?
    @State private var utilities: Bool?
    @State private var bedrooms: String?
    @State private var baths: String?
    @State private var unitWhole: Bool
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
    @State private var posted = Demo.scene == "posted"
    @State private var dateField: DateField?
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?
    @State private var busy = false

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

    init(kind: String, editing: Listing? = nil, onSaved: ((Listing) -> Void)? = nil) {
        self.kind = kind
        self.editing = editing
        self.onSaved = onSaved
        let filled = Demo.scene == "form-filled" || Demo.scene == "rentform-filled"
        let isRent = kind == "rent"

        _title = State(initialValue: editing?.title ?? (filled ? (isRent ? "一室一厅，走路到学校" : "榉木画架") : ""))
        _price = State(initialValue: editing.map { String($0.price) } ?? (filled ? (isRent ? "950" : "25") : ""))
        var startPhotos = (editing?.photos ?? []).map { FormPhoto.existing($0) }
        if filled { startPhotos = (Demo.sampleListing?.photos ?? []).map { FormPhoto.existing($0) } }
        _photos = State(initialValue: startPhotos)
        let savedContact = editing?.contact ?? UserDefaults.standard.string(forKey: "contact") ?? (filled ? "wx_demo" : "")
        _contact = State(initialValue: savedContact)
        _askContact = State(initialValue: savedContact.isEmpty && !filled)

        _cat = State(initialValue: editing?.cat ?? (filled && !isRent ? "art" : nil))
        _cond = State(initialValue: editing?.cond ?? (filled && !isRent ? "几乎全新" : nil))
        let savedDelivery = UserDefaults.standard.string(forKey: "defaultDelivery") ?? ""
        _delivery = State(initialValue: editing?.delivery ?? (filled ? "deliver" : (savedDelivery.isEmpty ? nil : savedDelivery)))
        _deliveryFee = State(initialValue: editing?.deliveryFee.map { String($0) } ?? (filled ? "5" : ""))
        _pickupBefore = State(initialValue: Self.date(editing?.pickupBefore) ?? (filled && !isRent ? Date().addingTimeInterval(20 * 86400) : nil))
        _pickupAfter = State(initialValue: Self.date(editing?.pickupAfter))
        let startPlace = editing?.place ?? (filled ? "Victory Dr" : (isRent ? "" : UserDefaults.standard.string(forKey: "defaultPlace") ?? ""))
        _place = State(initialValue: startPlace)
        _placeOther = State(initialValue: !startPlace.isEmpty && !PLACES.contains(startPlace))
        _desc = State(initialValue: editing?.desc ?? (filled && !isRent ? "搬家出，自己来拿" : ""))

        _from = State(initialValue: Self.date(editing?.from) ?? (filled && isRent ? Date() : nil))
        _to = State(initialValue: Self.date(editing?.to) ?? (filled && isRent ? Date().addingTimeInterval(120 * 86400) : nil))
        _utilities = State(initialValue: editing?.utilities ?? (filled && isRent ? true : nil))
        let room = Self.parseRoom(editing?.roomType)
        _bedrooms = State(initialValue: room.0 ?? (filled && isRent ? "1" : nil))
        _baths = State(initialValue: room.1 ?? (filled && isRent ? "1" : nil))
        let unit = editing?.unitType ?? (filled && isRent ? "room" : nil)
        _unitWhole = State(initialValue: unit == "whole" || unit == "both")
        _unitRoom = State(initialValue: unit == "room" || unit == "both")
        _priceSuggested = State(initialValue: filled && !isRent)
        _internet = State(initialValue: editing?.internet)
        _deposit = State(initialValue: editing?.deposit.map { String($0) } ?? "")
        _appFee = State(initialValue: editing?.appFee.map { String($0) } ?? "")
        _furniture = State(initialValue: editing?.furniture)
        _privateBath = State(initialValue: editing?.privateBath)
        _parking = State(initialValue: editing?.parking)
        _pets = State(initialValue: editing?.pets)
        let mate = Self.parseRoommates(editing?.roommates)
        _roommateCount = State(initialValue: mate.0)
        _roommateNote = State(initialValue: mate.1)
        _leaseEnd = State(initialValue: Self.date(editing?.leaseEnd))

        _aiConsent = State(initialValue: UserDefaults.standard.bool(forKey: "aiConsent") || Demo.isOn)
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

    private static let roommateCounts = ["没有室友", "1 人", "2 人", "3 人以上"]

    /// “2室1卫”拆回两个按钮
    private static func parseRoom(_ text: String?) -> (String?, String?) {
        guard let text, let r = text.range(of: "室") else { return (nil, nil) }
        let rest = text[r.upperBound...]
        return (String(text[..<r.lowerBound]), rest.hasSuffix("卫") ? String(rest.dropLast()) : nil)
    }

    private static func parseRoommates(_ text: String?) -> (String?, String) {
        guard let text else { return (nil, "") }
        let parts = text.components(separatedBy: "；")
        if let first = parts.first, roommateCounts.contains(first) {
            return (first, parts.dropFirst().joined(separator: "；"))
        }
        return (nil, text)
    }

    private var isRent: Bool { kind == "rent" }
    private var formAct: Act { isRent ? .rent : .sell }
    private var maxPhotos: Int { isRent ? 9 : 3 }
    private var tile: CGFloat { 76 }

    var body: some View {
        Group {
            if posted {
                postedView
            } else if isRent {
                rentForm
            } else {
                goodsForm
            }
        }
        .background(Theme.bg)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPicked(items) }
        }
        .onAppear {
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
        .sheet(item: $dateField) { field in
            CalendarSheet(title: field.title, start: dateValue(field), clearLabel: field.clearLabel) { value in
                setDate(field, value)
            }
            .presentationDetents([.height(480)])
        }
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

    // MARK: - 发完

    /// 再发一件时地点、取货、微信号都带上，只填照片、名字、价格
    private var postedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Hexagon().fill(Theme.accent).frame(width: 56, height: 56)
            Text("发好了").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button("再发一件") {
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
                askContact = false
                error = nil
                posted = false
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
            }
            .buttonStyle(PrimaryButtonStyle(act: formAct))
            Button("完成") { dismiss() }
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.ink)
                .frame(height: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 卖东西：一屏

    private var goodsForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    requiredBlock {
                        HStack(spacing: 8) {
                            goodsPhotos
                            aiHint
                            Spacer(minLength: 0)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            priceField.frame(width: 118)
                            nameField
                        }
                        contactField
                    }
                    sectionLabel("选填")
                    row("分类") { categoryChips }
                    row("成色") {
                        FlowLayout(spacing: 6) {
                            ForEach(CONDS, id: \.self) { c in
                                Chip(text: c, on: cond == c, act: formAct) { cond = cond == c ? nil : c }
                            }
                        }
                    }
                    row("取货") {
                        FlowLayout(spacing: 6) {
                            ForEach([(key: "pickup", label: "自取"), (key: "deliver", label: "可配送"), (key: "both", label: "都可")], id: \.key) { opt in
                                Chip(text: opt.label, on: delivery == opt.key, act: formAct) { delivery = delivery == opt.key ? nil : opt.key }
                            }
                            if let delivery, delivery != "pickup" {
                                LineField(placeholder: "$ 配送费", text: $deliveryFee, dollar: true)
                                    .keyboardType(.numberPad)
                                    .focused($focus, equals: .fee)
                                    .id(Field.fee)
                                    .frame(width: 90)
                            }
                        }
                    }
                    row("地点") { placeChips(surface: Theme.fill) }
                    HStack(spacing: 10) {
                        DateTile(label: "几号后可取", value: pickupAfter, empty: "不限", act: formAct) { dateField = .pickupAfter }
                        DateTile(label: "几号前取走", value: pickupBefore, empty: "不限", act: formAct) { dateField = .pickupBefore }
                    }
                    row("备注") {
                        LineField(placeholder: "写一句", text: $desc)
                            .focused($focus, equals: .desc)
                            .id(Field.desc)
                    }
                    errorLine
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
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
            .font(.system(size: 24))
            .foregroundStyle(Theme.ink)
            .frame(width: tile, height: tile)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
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
                .frame(width: tile, height: tile)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: 14))
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
        if state.aiDescribe || Demo.isOn, editing == nil, photos.count < maxPhotos {
            HStack(spacing: 6) {
                if aiLoading {
                    HoneyLoader(size: 26)
                } else {
                    ZStack {
                        Hexagon().fill(Theme.accent).frame(width: 26, height: 26)
                        Image(systemName: "sparkle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onBuy)
                    }
                }
                Text(aiLoading ? "AI 正在认\n也可以自己写" : (aiGuessed ? "AI 填好了\n可以改" : "放上照片\nAI 填名字和分类"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var priceField: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                if !price.isEmpty { Text("$") }
                TextField(isRent ? "$ 月租" : "$ 价格", text: Binding(
                    get: { price },
                    set: {
                        price = $0
                        priceTouched = true
                        priceSuggested = false
                    }
                ))
                .keyboardType(.numberPad)
                .focused($focus, equals: .price)
            }
            .id(Field.price)
            .font(.system(size: 22, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            Theme.line.frame(height: 0.5)
            if priceSuggested {
                Text("AI 建议价，可以改")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nameField: some View {
        VStack(spacing: 6) {
            TextField(isRent ? "标题，比如一室一厅" : "名字", text: Binding(
                get: { title },
                set: {
                    title = $0
                    nameTouched = true
                }
            ))
            .font(.system(size: 17))
            .focused($focus, equals: .name)
            .id(Field.name)
            Theme.line.frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var contactField: some View {
        if askContact {
            LineField(placeholder: "微信号（只填这一次）", text: $contact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .contact)
                .id(Field.contact)
        }
    }

    /// 只选中的写字，其余图标，一行放下
    private var categoryChips: some View {
        HStack(spacing: 6) {
            ForEach(CATS, id: \.key) { opt in
                let on = cat == opt.key
                Button {
                    withAnimation(.snappy(duration: 0.18)) { cat = on ? nil : opt.key }
                } label: {
                    HStack(spacing: 4) {
                        CategoryIcon(key: opt.key, size: 22)
                        if on { Text(opt.label).font(.system(size: 14, weight: .semibold)).fixedSize() }
                    }
                    .foregroundStyle(on ? formAct.on : Theme.ink)
                    .padding(.horizontal, on ? 10 : 0)
                    .frame(minWidth: 44)
                    .frame(height: 34)
                    .background(on ? formAct.fill : Theme.fill, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// 热门地点；点“其他”才输入。存的都是文字，能搜。
    private func placeChips(surface: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(PLACES, id: \.self) { p in
                    Chip(text: p, on: !placeOther && place == p, act: formAct, surface: surface) {
                        placeOther = false
                        place = place == p ? "" : p
                    }
                }
                Chip(text: "其他", on: placeOther, act: formAct, surface: surface) {
                    placeOther.toggle()
                    place = ""
                }
            }
            if placeOther {
                LineField(placeholder: "写地点", text: $place)
                    .focused($focus, equals: .place)
                    .id(Field.place)
            }
        }
    }

    // MARK: - 出租房子：可以长

    private var rentForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    requiredBlock {
                        FlowLayout(spacing: 8) { rentPhotos }
                        HStack(alignment: .bottom, spacing: 14) {
                            priceField.frame(width: 118)
                            nameField
                        }
                        contactField
                        row("出租") {
                            FlowLayout(spacing: 6) {
                                Chip(text: "整套", on: unitWhole, act: formAct, surface: Theme.bg) { unitWhole.toggle() }
                                Chip(text: "单间", on: unitRoom, act: formAct, surface: Theme.bg) { unitRoom.toggle() }
                            }
                        }
                        row("地段") { placeChips(surface: Theme.bg) }
                        HStack(spacing: 10) {
                            DateTile(label: "起", value: from, empty: "选日期", act: formAct, surface: Theme.bg) { dateField = .from }
                            DateTile(label: "止", value: to, empty: "长租", act: formAct, surface: Theme.bg) { dateField = .to }
                        }
                        row("水电") {
                            FlowLayout(spacing: 6) {
                                Chip(text: "包水电", on: utilities == true, act: formAct, surface: Theme.bg) { utilities = true }
                                Chip(text: "不包水电", on: utilities == false, act: formAct, surface: Theme.bg) { utilities = false }
                            }
                        }
                    }
                    sectionLabel("选填")
                    Theme.line.frame(height: 0.5)
                    section("房型") {
                        row("几室") { oneOf(["1", "2", "3", "4+"], $bedrooms) }
                        row("几卫") { oneOf(["1", "2", "3"], $baths) }
                    }
                    section("费用") {
                        row("网费") { yesNo("包", "不包", $internet) }
                        row("押金") { LineField(placeholder: "$", text: $deposit, dollar: true)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .deposit)
                            .id(Field.deposit) }
                        row("申请费") { LineField(placeholder: "$", text: $appFee, dollar: true)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .appFee)
                            .id(Field.appFee) }
                    }
                    section("屋里") {
                        row("家具") { oneOf(["有", "部分有", "没有"], $furniture) }
                        row("独卫") { yesNo("有", "没有", $privateBath) }
                        row("停车") { oneOf(["有车位", "路边", "没有"], $parking) }
                        row("宠物") { oneOf(["可以", "不可以"], $pets) }
                    }
                    section("室友") {
                        row("现在") { oneOf(Self.roommateCounts, $roommateCount) }
                        row("情况") { LineField(placeholder: "比如都是学生", text: $roommateNote)
                            .focused($focus, equals: .note)
                            .id(Field.note) }
                    }
                    section("租约") {
                        DateTile(label: "租约到期日", value: leaseEnd, empty: "不限", act: formAct) { dateField = .leaseEnd }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("描述").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        ZStack(alignment: .topLeading) {
                            if desc.isEmpty {
                                Text("写详细一点：周边、交通、看房时间")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.sub.opacity(0.7))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                            }
                            TextEditor(text: $desc)
                                .focused($focus, equals: .desc)
                                .id(Field.desc)
                                .font(.system(size: 15))
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                        }
                        .frame(minHeight: 130)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
                    }
                    errorLine
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
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

    private func requiredBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("必填")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRent ? Theme.rent : Theme.warn)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(formAct.soft, in: RoundedRectangle(cornerRadius: 20))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            content()
            Theme.line.frame(height: 0.5).padding(.top, 4)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.sub)
                .frame(width: 44, height: 34, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func oneOf(_ list: [String], _ binding: Binding<String?>) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(list, id: \.self) { value in
                Chip(text: value, on: binding.wrappedValue == value, act: formAct) {
                    binding.wrappedValue = binding.wrappedValue == value ? nil : value
                }
            }
        }
    }

    private func yesNo(_ yes: String, _ no: String, _ binding: Binding<Bool?>) -> some View {
        FlowLayout(spacing: 6) {
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
                    Text(busy ? "正在发" : (editing == nil ? "发布" : "保存"))
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: formAct, dimmed: !requiredFilled))
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

    private var requiredFilled: Bool {
        guard !photos.isEmpty, Int(price.trimmingCharacters(in: .whitespaces)) != nil else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty || aiLoading else { return false }
        guard !contact.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isRent { return (unitWhole || unitRoom) && !place.trimmingCharacters(in: .whitespaces).isEmpty && from != nil && utilities != nil }
        return true
    }

    // MARK: - 动作

    private func addPicked(_ items: [PhotosPickerItem]) async {
        for item in items where photos.count < maxPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                state.toast("有张照片打不开")
                continue
            }
            addPhoto(data)
        }
        picked = []
    }

    private func addPhoto(_ data: Data) {
        guard let ready = ImagePrep.prepare(data) else {
            state.toast("有张照片打不开")
            return
        }
        let first = photos.isEmpty
        photos.append(.fresh(id: UUID(), jpeg: ready.jpeg, preview: ready.preview))
        if first, !isRent, editing == nil { startDescribe(ready.preview) }
    }

    /// 后台让 AI 看第一张；失败就手填名字，不影响发布
    private func startDescribe(_ image: UIImage) {
        guard state.aiDescribe, state.isLoggedIn, aiConsent, let jpeg = ImagePrep.forAI(image) else { return }
        aiLoading = true
        describeTask = Task {
            defer { aiLoading = false }
            guard let guess = try? await API.shared.describe(jpeg: jpeg, consent: true), !Task.isCancelled else { return }
            if !nameTouched, title.isEmpty {
                title = guess.name
                aiGuessed = true
            }
            if cat == nil { cat = guess.cat }
            if cond == nil { cond = guess.cond }
            if !priceTouched, price.isEmpty, let suggested = guess.price {
                price = String(suggested)
                priceSuggested = true
            }
        }
    }

    private func submit() async {
        error = nil
        focus = nil
        // AI 还在认就等它一下（最多十来秒），它失败了才要手填
        if !isRent, title.trimmingCharacters(in: .whitespaces).isEmpty, let task = describeTask {
            busy = true
            await task.value
            busy = false
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if photos.isEmpty { error = "要一张实拍照。"; return }
        guard let money = Int(price.trimmingCharacters(in: .whitespaces)), money >= 0 else { error = "价格要填整数。"; return }
        guard !t.isEmpty else { error = isRent ? "写一下标题。" : "写一下卖什么。"; return }
        guard !c.isEmpty else { error = "留个微信号。"; return }
        if isRent {
            if money == 0 { error = "租金要大于 0。"; return }
            if !unitWhole, !unitRoom { error = "选整套或单间，都可以就都选。"; return }
            if p.isEmpty { error = "选一下地段。"; return }
            guard let start = from else { error = "选一下起始日期。"; return }
            if let end = to, start > end { error = "止要晚于起。"; return }
            if utilities == nil { error = "选一下包不包水电。"; return }
        } else if editing == nil, !aiConsent {
            error = "要同意发给 AI 打分才能发布。"
            return
        }
        let fee = deliveryFee.trimmingCharacters(in: .whitespaces)
        let dep = deposit.trimmingCharacters(in: .whitespaces), app = appFee.trimmingCharacters(in: .whitespaces)
        if !isRent, delivery != nil, delivery != "pickup", !fee.isEmpty, Int(fee) == nil { error = "配送费要填整数。"; return }
        if isRent, (!dep.isEmpty && Int(dep) == nil) || (!app.isEmpty && Int(app) == nil) { error = "押金和申请费要填整数。"; return }

        busy = true
        defer { busy = false }
        do {
            var keys: [String] = []
            for photo in photos {
                switch photo {
                case .existing(let e): keys.append(e.key)
                case .fresh(_, let jpeg, _): keys.append(try await API.shared.upload(jpeg: jpeg))
                }
            }
            var input = ListingInput(kind: kind, title: t, price: money, place: p, desc: desc.trimmingCharacters(in: .whitespacesAndNewlines), contact: c, photos: keys)
            let day: (Date?) -> String? = { $0.map { Self.dayFormat.string(from: $0) } }
            if isRent {
                input.from = day(from)
                input.to = day(to)
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
                input.deliveryFee = delivery == nil || delivery == "pickup" ? nil : Int(fee)
                input.pickupBefore = day(pickupBefore)
                input.pickupAfter = day(pickupAfter)
            }
            let saved: Listing
            if let editing {
                saved = try await API.shared.update(editing.id, input)
            } else {
                saved = try await API.shared.create(input)
            }
            UserDefaults.standard.set(c, forKey: "contact")
            if !isRent, editing == nil { UserDefaults.standard.set(true, forKey: "aiConsent") }
            onSaved?(saved)
            state.changed()
            if editing == nil {
                state.tab = .me
                Haptics.beeBuzz()
            }
            if editing == nil, !isRent {
                posted = true
            } else {
                state.toast(editing == nil ? "发好了" : "改好了")
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

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                if dollar, !text.isEmpty { Text("$").foregroundStyle(Theme.ink) }
                TextField(placeholder, text: $text)
            }
            .font(.system(size: 15))
            Theme.line.frame(height: 0.5)
        }
        .padding(.top, 8)
    }
}

/// 日期格：没选是灰的，选了涂这一页的颜色；点开日历
private struct DateTile: View {
    let label: String
    let value: Date?
    let empty: String
    let act: Act
    var surface: Color = Theme.fill
    let action: () -> Void

    private var text: String {
        guard let value else { return empty }
        let c = Calendar.current.dateComponents([.month, .day], from: value)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13))
                    Text(text).font(.system(size: 16, weight: .semibold))
                }
                Spacer(minLength: 4)
                Image(systemName: "calendar").font(.system(size: 17))
            }
            .foregroundStyle(value == nil ? Theme.sub : act.on)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(value == nil ? surface : act.fill, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + " " + text)
    }
}

/// 自己画的月历：选中的垫六边形；底下的“不限”就是清空
private struct CalendarSheet: View {
    let title: String
    let start: Date?
    let clearLabel: String?
    let pick: (Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date = Date()

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

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                arrow("chevron.left", "上个月", -1)
                Spacer()
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("· \(calendar.component(.month, from: month)) 月")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                Spacer()
                arrow("chevron.right", "下个月", 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { d in
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
            Spacer(minLength: 0)
            if let clearLabel {
                Theme.line.frame(height: 0.5)
                Button(clearLabel) {
                    pick(nil)
                    dismiss()
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .presentationDragIndicator(.visible)
        .onAppear { month = start ?? Date() }
    }

    private func dayCell(_ day: Date) -> some View {
        let selected = start.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            pick(day)
            dismiss()
        } label: {
            ZStack {
                if selected { Hexagon().fill(Theme.accent).frame(width: 40, height: 40) }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 16, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Theme.onBuy : Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
private struct CameraPicker: UIViewControllerRepresentable {
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
