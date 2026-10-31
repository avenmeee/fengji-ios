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

struct PostForm: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let kind: String
    let editing: Listing?
    var onSaved: ((Listing) -> Void)?

    @State private var title: String
    @State private var price: String
    @State private var cat: String
    @State private var cond: String
    @State private var rtype: String
    @State private var from: Date
    @State private var to: Date
    @State private var place: String
    @State private var desc: String
    @State private var delivery: String
    @State private var utilities: String?
    @State private var deliveryFee: String
    @State private var hasPickupBefore: Bool
    @State private var pickupBefore: Date
    @State private var hasPickupAfter: Bool
    @State private var pickupAfter: Date
    @State private var longTerm: Bool
    @State private var furnished: Bool
    @State private var privateBath: Bool
    @State private var hasLeaseEnd: Bool
    @State private var leaseEnd: Date
    @State private var posted = Demo.scene == "posted"
    @State private var contact: String
    @State private var photos: [FormPhoto]
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

    init(kind: String, editing: Listing? = nil, onSaved: ((Listing) -> Void)? = nil) {
        self.kind = kind
        self.editing = editing
        self.onSaved = onSaved
        _title = State(initialValue: editing?.title ?? "")
        _price = State(initialValue: editing.map { String($0.price) } ?? "")
        _cat = State(initialValue: editing?.cat ?? UserDefaults.standard.string(forKey: "cat") ?? "furn")
        _cond = State(initialValue: editing?.cond ?? "几乎全新")
        _rtype = State(initialValue: editing?.rtype ?? "转租")
        let today = Date()
        _from = State(initialValue: editing?.from.flatMap { Self.dayFormat.date(from: $0) } ?? today)
        _to = State(initialValue: editing?.to.flatMap { Self.dayFormat.date(from: $0) } ?? today.addingTimeInterval(90 * 86400))
        _place = State(initialValue: editing?.place ?? (kind == "goods" ? UserDefaults.standard.string(forKey: "place") ?? "" : ""))
        _desc = State(initialValue: editing?.desc ?? "")
        _delivery = State(initialValue: editing?.delivery ?? UserDefaults.standard.string(forKey: "delivery") ?? "pickup")
        _utilities = State(initialValue: editing?.utilities.map { $0 ? "yes" : "no" })
        _deliveryFee = State(initialValue: editing?.deliveryFee.map { String($0) } ?? "")
        let before = editing?.pickupBefore.flatMap { Self.dayFormat.date(from: $0) }
        let after = editing?.pickupAfter.flatMap { Self.dayFormat.date(from: $0) }
        _hasPickupBefore = State(initialValue: before != nil)
        _pickupBefore = State(initialValue: before ?? today.addingTimeInterval(14 * 86400))
        _hasPickupAfter = State(initialValue: after != nil)
        _pickupAfter = State(initialValue: after ?? today)
        _longTerm = State(initialValue: editing?.longTerm ?? false)
        _furnished = State(initialValue: editing?.furnished ?? false)
        _privateBath = State(initialValue: editing?.privateBath ?? false)
        let lease = editing?.leaseEnd.flatMap { Self.dayFormat.date(from: $0) }
        _hasLeaseEnd = State(initialValue: lease != nil)
        _leaseEnd = State(initialValue: lease ?? today.addingTimeInterval(180 * 86400))
        _contact = State(initialValue: editing?.contact ?? UserDefaults.standard.string(forKey: "contact") ?? "")
        _photos = State(initialValue: (editing?.photos ?? []).map { FormPhoto.existing($0) })
    }

    private var isRent: Bool { kind == "rent" }
    private var formAct: Act { isRent ? .rent : .sell }

    var body: some View {
        NavigationStack {
            if posted {
                postedView
            } else {
                form
            }
        }
        .interactiveDismissDisabled(busy)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPicked(items) }
        }
    }

    /// 发完：再发一件时地点、微信号、分类都带上，只填照片、名字、价格
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
                hasPickupBefore = false
                hasPickupAfter = false
                error = nil
                posted = false
            }
            .buttonStyle(PrimaryButtonStyle(act: formAct))
            Button("完成") { dismiss() }
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.ink)
                .frame(height: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    private var form: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                field(isRent ? "照片（最多 3 张）" : "实拍照（至少 1 张）") { photoRow }
                field(isRent ? "房子" : "卖什么") {
                    Input(placeholder: isRent ? "一室一厅，走路到学校 10 分钟" : "宜家书桌，九成新", text: $title)
                }
                field(isRent ? "每月租金（美元）" : "价格（美元，0 是免费送）") {
                    Input(placeholder: "", text: $price).keyboardType(.numberPad)
                }
                if isRent {
                    field("类型") { options(plainOptions(RTYPES), $rtype) }
                    HStack(spacing: 10) {
                        field("起") { dateBox($from) }
                        if !longTerm { field("止") { dateBox($to) } }
                    }
                    Toggle("长租", isOn: $longTerm).tint(Theme.rent)
                    field("水电") {
                        FlowLayout {
                            Chip(text: "包水电", on: utilities == "yes", act: formAct) { utilities = "yes" }
                            Chip(text: "不包", on: utilities == "no", act: formAct) { utilities = "no" }
                        }
                    }
                    Toggle("可拎包入住", isOn: $furnished).tint(Theme.rent)
                    Toggle("独卫", isOn: $privateBath).tint(Theme.rent)
                    Toggle("写租约到期日", isOn: $hasLeaseEnd).tint(Theme.rent)
                    if hasLeaseEnd { dateBox($leaseEnd) }
                } else {
                    field("分类") { options(CATS, $cat) }
                    field("成色") { options(plainOptions(CONDS), $cond) }
                    field("怎么拿") { options([(key: "pickup", label: "自取"), (key: "deliver", label: "可配送"), (key: "both", label: "都可")], $delivery) }
                    if delivery != "pickup" {
                        field("配送费（美元，选填）") {
                            Input(placeholder: "", text: $deliveryFee).keyboardType(.numberPad)
                        }
                    }
                    Toggle("几号前取走", isOn: $hasPickupBefore).tint(formAct.fill)
                    if hasPickupBefore { dateBox($pickupBefore) }
                    Toggle("几号后可取", isOn: $hasPickupAfter).tint(formAct.fill)
                    if hasPickupAfter { dateBox($pickupAfter) }
                }
                field(isRent ? "地段" : "在哪拿") {
                    Input(placeholder: "monty、downtown、TP", text: $place)
                }
                field("备注（选填）") {
                    TextEditor(text: $desc)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88)
                        .padding(6)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
                }
                field("微信号（所有人能看到）") {
                    Input(placeholder: "", text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("限萨凡纳，当面交易。").font(.footnote).foregroundStyle(Theme.sub)
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.warn)
                }
                Button(busy ? "正在发…" : (editing == nil ? "发布" : "保存")) {
                    Task { await submit() }
                }
                .buttonStyle(PrimaryButtonStyle(act: formAct))
                .disabled(busy)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.disabled(busy)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.footnote).foregroundStyle(Theme.sub)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func options(_ list: [Option], _ binding: Binding<String>) -> some View {
        FlowLayout {
            ForEach(list, id: \.key) { opt in
                Chip(text: opt.label, on: binding.wrappedValue == opt.key, act: formAct) { binding.wrappedValue = opt.key }
            }
        }
    }

    private func dateBox(_ binding: Binding<Date>) -> some View {
        DatePicker("", selection: binding, displayedComponents: .date)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private var photoRow: some View {
        HStack(spacing: 8) {
            ForEach(photos) { photo in
                ZStack(alignment: .topTrailing) {
                    Group {
                        switch photo {
                        case .existing(let p):
                            RemoteImage(url: p.url, maxPixel: 240)
                        case .fresh(_, _, let preview):
                            Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .background(Theme.line)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    Button {
                        photos.removeAll { $0.id == photo.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.bg)
                            .frame(width: 22, height: 22)
                            .background(Theme.ink, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .accessibilityLabel("去掉这张")
                }
            }
            if photos.count < 3 {
                PhotosPicker(selection: $picked, maxSelectionCount: 3 - photos.count, matching: .images) {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.sub)
                        .frame(width: 76, height: 76)
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.sub, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .accessibilityLabel("加照片")
            }
        }
    }

    private func addPicked(_ items: [PhotosPickerItem]) async {
        for item in items where photos.count < 3 {
            guard let data = try? await item.loadTransferable(type: Data.self), let ready = ImagePrep.prepare(data) else {
                state.toast("有张照片打不开")
                continue
            }
            photos.append(.fresh(id: UUID(), jpeg: ready.jpeg, preview: ready.preview))
        }
        picked = []
    }

    private func submit() async {
        error = nil
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { error = isRent ? "写一下房子。" : "写一下卖什么。"; return }
        guard let money = Int(price.trimmingCharacters(in: .whitespaces)), money >= 0 else { error = "价格要填整数。"; return }
        if isRent, money == 0 { error = "租金要大于 0。"; return }
        guard !p.isEmpty else { error = isRent ? "写一下地段。" : "写一下在哪拿。"; return }
        guard !c.isEmpty else { error = "留个微信号。"; return }
        if isRent, !longTerm, from > to { error = "止要晚于起。"; return }
        if isRent, utilities == nil { error = "选一下包不包水电。"; return }
        if !isRent, photos.isEmpty { error = "要一张实拍照。"; return }
        let fee = deliveryFee.trimmingCharacters(in: .whitespaces)
        if !isRent, delivery != "pickup", !fee.isEmpty, Int(fee) == nil { error = "配送费要填整数。"; return }

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
            if isRent {
                input.rtype = rtype
                input.from = Self.dayFormat.string(from: from)
                input.to = longTerm ? nil : Self.dayFormat.string(from: to)
                input.longTerm = longTerm
                input.furnished = furnished
                input.leaseEnd = hasLeaseEnd ? Self.dayFormat.string(from: leaseEnd) : nil
                input.utilities = utilities == "yes"
                input.privateBath = privateBath
            } else {
                input.cat = cat
                input.cond = cond
                input.delivery = delivery
                input.deliveryFee = delivery == "pickup" ? nil : Int(fee)
                input.pickupBefore = hasPickupBefore ? Self.dayFormat.string(from: pickupBefore) : nil
                input.pickupAfter = hasPickupAfter ? Self.dayFormat.string(from: pickupAfter) : nil
            }
            let saved: Listing
            if let editing {
                saved = try await API.shared.update(editing.id, input)
            } else {
                saved = try await API.shared.create(input)
            }
            UserDefaults.standard.set(c, forKey: "contact")
            if !isRent {
                UserDefaults.standard.set(p, forKey: "place")
                UserDefaults.standard.set(cat, forKey: "cat")
                UserDefaults.standard.set(delivery, forKey: "delivery")
            }
            onSaved?(saved)
            state.changed()
            if editing == nil { state.tab = .me }
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

private struct Input: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
    }
}
