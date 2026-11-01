import PhotosUI
import SwiftUI
import UIKit

// MARK: - 设置页的小块：不用系统 List，和发布页一个样子

/// 页顶：返回加标题
struct PageTop: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

/// 组标题：13 点灰字
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
    }
}

/// 一行：左边浅底六边形加线条图标
struct SettingRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var color: Color = Theme.ink
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Hexagon().fill(Theme.fill).frame(width: 30, height: 30)
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.sub)
            }
            Text(title).font(.system(size: 16)).foregroundStyle(color)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }
}

extension SettingRow where Trailing == EmptyView {
    init(symbol: String, title: String, color: Color = Theme.ink) {
        self.init(symbol: symbol, title: title, color: color) { EmptyView() }
    }
}

/// 点一下在下面展开邮箱，带复制
struct EmailReveal: View {
    @EnvironmentObject var state: AppState
    @Binding var shown: Bool

    var body: some View {
        if shown, !Config.contactEmail.isEmpty, let url = URL(string: "mailto:\(Config.contactEmail)") {
            HStack(spacing: 8) {
                Link(Config.contactEmail, destination: url)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Button {
                    UIPasteboard.general.string = Config.contactEmail
                    state.toast("已复制")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(Theme.sub)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制邮箱")
                Spacer()
            }
            .padding(.leading, 42)
            .transition(.opacity)
        }
    }
}

// MARK: - 我的信息

/// 我的信息（B 版）：上面名片，下面“发布时自动带上”一行一项，点一行弹出来改，改完就存
struct MyInfoView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("defaultPlace") private var defaultPlace = ""
    @AppStorage("defaultDelivery") private var defaultDelivery = ""
    @AppStorage("defaultTime") private var defaultTime = ""
    @AppStorage("contact") private var savedContact = ""
    @State private var editing: InfoField? = Demo.scene == "myinfo-edit" ? .place : nil
    @State private var draft = Demo.scene == "myinfo-edit" ? "Monty 楼下" : ""
    @State private var draftPickup = false
    @State private var draftDeliver = false
    @State private var uploading = false
    @State private var error: String?
    @State private var choosing = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picked: PhotosPickerItem?
    @State private var claiming = false

    private var me: Me? { state.me }

    enum InfoField: String, Identifiable {
        case name, delivery, place, time, wechat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "昵称"
            case .delivery: return "取货方式"
            case .place: return "自取地点"
            case .time: return "方便的时间"
            case .wechat: return "微信号"
            }
        }
        var note: String {
            switch self {
            case .name: return "别人看到的你"
            case .wechat: return "填了别人能看到；不填，别人点“想要”联系你"
            default: return "发东西时自动带上，发之前还能改"
            }
        }
        var placeholder: String {
            switch self {
            case .place: return "比如 Monty 楼下"
            case .time: return "比如 工作日晚上、周末"
            case .wechat: return "微信号"
            default: return "昵称"
            }
        }
    }

    private var pickup: Bool { defaultDelivery == "pickup" || defaultDelivery == "both" }
    private var deliveryText: String {
        switch defaultDelivery {
        case "pickup": return "自取"
        case "deliver": return "可配送"
        case "both": return "自取、可配送"
        default: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "我的信息")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card
                    GroupHeader(title: "发布时自动带上", note: "发东西时自动填好").padding(.top, 14)
                    FormCard {
                        infoRow("shippingbox", "取货方式", deliveryText, .delivery)
                        if pickup {
                            FormDivider()
                            infoRow("mappin", "自取地点", defaultPlace, .place)
                        }
                        FormDivider()
                        infoRow("clock", "方便的时间", defaultTime, .time)
                        FormDivider()
                        infoRow("message", "微信号", savedContact, .wechat)
                    }
                    Text("微信号别人能看到。不填微信号，别人点“想要”联系你。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.hint)
                        .padding(.horizontal, 4)
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(Theme.warn)
                    }
                    // 认领入口：送审时 OPS_WECHAT 删掉就不显示
                    if state.opsWechat != nil {
                        Text("不常用").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.hint).padding(.top, 16).padding(.horizontal, 4)
                        Button { claiming = true } label: {
                            SettingRow(symbol: "hand.raised", title: "认领我在群里发的") {
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
                            }
                            .frame(minHeight: 54)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            BottomPanel(shown: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let field = editing { editor(field) }
            }
        }
        .sheet(isPresented: $claiming) { ClaimView() }
        .confirmationDialog("换头像", isPresented: $choosing, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照") { showCamera = true }
            }
            Button("从相册选") { showLibrary = true }
            if me?.avatar != nil {
                Button("用默认头像") { Task { await removeAvatar() } }
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await upload(image)
                }
                picked = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await upload(image) } }
                .ignoresSafeArea()
        }
    }

    /// 名片：头像（右下角蜂蜜色相机）、昵称和一支小笔
    private var card: some View {
        HStack(spacing: 18) {
            Button { choosing = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    SellerAvatar(name: me?.name ?? "", color: me?.color, named: me?.named ?? false, size: 92, url: me?.avatar)
                        .opacity(uploading ? 0.5 : 1)
                    ZStack {
                        Hexagon().fill(Theme.accent).frame(width: 32, height: 32)
                        Image(systemName: "camera.fill").font(.system(size: 13)).foregroundStyle(Theme.onBuy)
                    }
                    .offset(x: 4, y: 2)
                    if uploading { HoneyLoader(size: 28).frame(width: 92, height: 92) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("换头像")
            Button { open(.name) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(me?.name ?? "").font(.system(size: 25, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(Theme.hint)
                    }
                    Text("别人看到的你").font(.system(size: 13)).foregroundStyle(Theme.hint)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("改昵称，现在是 " + (me?.name ?? ""))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ symbol: String, _ title: String, _ value: String, _ field: InfoField) -> some View {
        Button { open(field) } label: {
            SettingRow(symbol: symbol, title: title) {
                HStack(spacing: 6) {
                    Text(value.isEmpty ? (field == .delivery ? "没选" : "选填") : value)
                        .font(.system(size: 15))
                        .foregroundStyle(value.isEmpty ? Theme.hint : Theme.sub)
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
                }
            }
            .frame(minHeight: 54)
        }
        .buttonStyle(.plain)
    }

    private func open(_ field: InfoField) {
        switch field {
        case .name: draft = me?.named == true ? (me?.name ?? "") : ""
        case .delivery:
            draftPickup = pickup
            draftDeliver = defaultDelivery == "deliver" || defaultDelivery == "both"
        case .place: draft = defaultPlace
        case .time: draft = defaultTime
        case .wechat: draft = savedContact
        }
        error = nil
        editing = field
    }

    /// 改一项的弹层：标题、一句说明、输入框、“好”
    private func editor(_ field: InfoField) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                Text(field.note).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            if field == .delivery {
                HStack(spacing: 8) {
                    Chip(text: "自取", on: draftPickup) { draftPickup.toggle() }
                    Chip(text: "可配送", on: draftDeliver) { draftDeliver.toggle() }
                }
                .environment(\.formLarge, true)
            } else {
                TextField(field.placeholder, text: $draft)
                    .font(.system(size: 17))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.warn)
            }
            Button("好") { Task { await save(field) } }
                .buttonStyle(PrimaryButtonStyle(act: .ink))
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func save(_ field: InfoField) async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .name:
            do {
                state.setProfile(try await API.shared.updateProfile(nickname: t, color: me?.color ?? 0))
            } catch {
                self.error = error.localizedDescription
                return
            }
        case .delivery:
            defaultDelivery = draftPickup && draftDeliver ? "both" : (draftPickup ? "pickup" : (draftDeliver ? "deliver" : ""))
        case .place: defaultPlace = t
        case .time: defaultTime = t
        case .wechat: savedContact = t
        }
        editing = nil
        state.toast("存好了")
    }

    /// 裁成正方形、缩到 512，去掉定位
    private static func avatarJPEG(_ image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        let target = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let k = 512 / max(side, 1)
            let w = image.size.width * k, h = image.size.height * k
            image.draw(in: CGRect(x: (512 - w) / 2, y: (512 - h) / 2, width: w, height: h))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }

    private func upload(_ image: UIImage) async {
        guard let jpeg = Self.avatarJPEG(image) else { return }
        uploading = true
        defer { uploading = false }
        do {
            state.setProfile(try await API.shared.uploadAvatar(jpeg: jpeg))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeAvatar() async {
        do {
            state.setProfile(try await API.shared.removeAvatar())
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 一条横线的输入框
struct LineFieldPlain: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(spacing: 6) {
            TextField(placeholder, text: $text).font(.system(size: 15))
            Theme.line.frame(height: 0.5)
        }
        .padding(.top, 8)
    }
}

// MARK: - 记录

/// 卖掉的和删掉的，只有本人看得到
struct RecordsView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var editing: Listing?
    @State private var relisting: Listing?
    @State private var purging: Listing?

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "记录")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("只有你看得到。照片保留 30 天，之后只留文字。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .padding(.horizontal, 4)
                    if items.isEmpty {
                        if phase == .ok { EmptyBlock(text: "删掉的会在这里") } else { PhaseBlock(phase: phase) }
                    }
                    ForEach(items) { item in
                        RecordRow(item: item, relist: { relist(item) }, purge: { purging = item })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: state.version) { await load() }
        .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item, startStatus: "on") }
        // 删掉的：照片 30 天内都在，打开填好的发布页，点“重新发布”就回到在售
        .sheet(item: $relisting) { item in
            PostForm(kind: item.kind, editing: item, startStatus: "on", relist: true) { _ in
                Task {
                    state.changed()
                }
            }
        }
        .overlay {
            BottomPanel(shown: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } })) {
                if let item = purging {
                    PanelConfirm(title: "永久删除？", message: "记录和照片都会删掉，不能恢复。", confirm: "永久删除") {
                        purging = nil
                        Task {
                            do {
                                try await API.shared.purge(item.id)
                                items.removeAll { $0.id == item.id }
                            } catch {
                                state.toast(error.localizedDescription)
                            }
                        }
                    } onCancel: { purging = nil }
                }
            }
        }
    }

    private func relist(_ item: Listing) {
        if item.status == "deleted" { relisting = item } else { editing = item }
    }

    private func load() async {
        do {
            let all = try await API.shared.mine()
            // 记录里只放删掉的；卖完的留在“我发的”
            items = all.filter { $0.status == "deleted" }
                .sorted { ($0.deletedAt ?? $0.updatedAt ?? $0.createdAt) > ($1.deletedAt ?? $1.updatedAt ?? $1.createdAt) }
            phase = .ok
        } catch {
            if items.isEmpty { phase = .failed }
        }
    }
}

struct RecordRow: View {
    let item: Listing
    let relist: () -> Void
    let purge: () -> Void

    private var deletedDate: Date {
        Date(timeIntervalSince1970: Double(item.deletedAt ?? item.updatedAt ?? item.createdAt) / 1000)
    }

    private var line: String {
        let c = Calendar.current.dateComponents([.month, .day], from: deletedDate)
        return item.priceText + (item.isRent ? " /月" : "") + " · \(c.month ?? 0)月\(c.day ?? 0)日删掉"
    }

    /// 照片还留几天：30 天减去删了几天
    private var keepText: String {
        if item.photos.isEmpty { return "照片过了 30 天，已删掉" }
        let days = Int(Date().timeIntervalSince(deletedDate) / 86400)
        return "照片还留 \(max(1, 30 - days)) 天"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 74, height: 92)
                    .overlay {
                        if item.photos.isEmpty {
                            ZStack {
                                Theme.fill
                                Hexagon().fill(Theme.bg).frame(width: 34, height: 34)
                                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Theme.sub)
                            }
                        } else {
                            ListingImage(item: item, maxPixel: 300).grayscale(1).opacity(0.8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(line).font(.system(size: 15)).tracking(-0.2).foregroundStyle(Theme.sub)
                    Text(keepText).font(.system(size: 13)).foregroundStyle(Theme.hint)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)
            FormDivider()
            HStack(spacing: 10) {
                Button(action: relist) {
                    Label("重新上架", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Button(action: purge) {
                    Text("永久删除")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.warn)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 举报规则

struct RulesView: View {
    @EnvironmentObject var state: AppState

    private let steps: [(String, String)] = [
        ("可以举报什么", "违规内容、虚假信息、骚扰或诈骗，比如违禁物品、假学历、代写代考、私下换汇、冒用别人的照片，以及不当的昵称和头像。"),
        ("怎么举报", "在东西或房子的详情页，点右上角“…”→ 举报，再选举报这条帖子、昵称还是头像。不想再看到这个人，可以同时屏蔽。"),
        ("多久处理", "24 小时内处理。违规的内容会下架，不当的昵称会重置、头像会撤掉，情节严重的停用账号。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "举报规则")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FormCard {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            if i > 0 { FormDivider() }
                            HStack(alignment: .top, spacing: 14) {
                                NumberHex(n: i + 1)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(step.0).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                                    Text(step.1).font(.system(size: 15)).foregroundStyle(Theme.sub).lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 14)
                        }
                    }
                    if !Config.contactEmail.isEmpty {
                        GroupHeader(title: "觉得处理错了").padding(.top, 12)
                        FormCard {
                            SettingRow(symbol: "envelope", title: "写邮件申诉").frame(minHeight: 54)
                            HStack {
                                if let url = URL(string: "mailto:\(Config.contactEmail)") {
                                    Link(Config.contactEmail, destination: url).font(.system(size: 16)).foregroundStyle(Theme.ink)
                                }
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = Config.contactEmail
                                    state.toast("已复制")
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.system(size: 15)).foregroundStyle(Theme.sub).frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("复制邮箱")
                            }
                            .padding(.leading, 42)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
    }
}
