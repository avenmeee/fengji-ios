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

/// 头像、昵称，和发布时自动带上的默认地点、取货、微信号
struct MyInfoView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPlace") private var defaultPlace = ""
    @AppStorage("defaultDelivery") private var defaultDelivery = ""
    @AppStorage("contact") private var savedContact = ""
    @State private var name = ""
    @State private var place = ""
    @State private var pickup = false
    @State private var deliver = false
    @State private var contact = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var uploading = false
    @State private var error: String?
    @State private var choosing = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picked: PhotosPickerItem?

    private var me: Me? { state.me }

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "我的信息")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 14) {
                        Button { choosing = true } label: {
                            ZStack(alignment: .bottomTrailing) {
                                SellerAvatar(name: me?.name ?? "", color: me?.color, named: me?.named ?? false, size: 104, url: me?.avatar)
                                    .opacity(uploading ? 0.5 : 1)
                                ZStack {
                                    Hexagon().fill(Theme.ink).frame(width: 30, height: 30)
                                    Image(systemName: "camera.fill").font(.system(size: 12)).foregroundStyle(Theme.bg)
                                }
                                if uploading { HoneyLoader(size: 28).frame(width: 104, height: 104) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("换头像")
                        VStack(spacing: 6) {
                            TextField("昵称", text: $name)
                                .font(.system(size: 18, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .autocorrectionDisabled()
                            Theme.line.frame(height: 0.5)
                        }
                        .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ZStack {
                                Hexagon().fill(Theme.buy).frame(width: 24, height: 24)
                                Image(systemName: "mappin").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onBuy)
                            }
                            Text("默认地点").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text("发东西时自动带上").font(.footnote).foregroundStyle(Theme.sub)
                        }
                        FlowLayout(spacing: 6) {
                            ForEach(PLACES, id: \.self) { p in
                                Chip(text: p, on: place == p, act: .buy) { place = place == p ? "" : p }
                            }
                        }
                        LineFieldPlain(placeholder: "手动填地点", text: Binding(
                            get: { PLACES.contains(place) ? "" : place },
                            set: { place = $0 }
                        ))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        GroupLabel(text: "默认取货")
                        HStack(spacing: 6) {
                            Chip(text: "自取", on: pickup, act: .buy) { pickup.toggle() }
                            Chip(text: "可配送", on: deliver, act: .buy) { deliver.toggle() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        GroupLabel(text: "微信号 · 选填")
                        LineFieldPlain(placeholder: "不填买家可以点想要留言", text: $contact)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(Theme.warn)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if busy { HoneyLoader(size: 22) }
                    Text(busy ? "正在保存" : "保存")
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink))
            .disabled(busy)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
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
        .task(id: me?.id) {
            // 资料可能晚一步到，到了再填
            guard !loaded, let me else { return }
            loaded = true
            name = me.name ?? ""
            place = defaultPlace
            pickup = defaultDelivery == "pickup" || defaultDelivery == "both"
            deliver = defaultDelivery == "deliver" || defaultDelivery == "both"
            contact = savedContact
        }
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

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = t.isEmpty || (me?.named != true && t == me?.name)
        do {
            state.setProfile(try await API.shared.updateProfile(nickname: isDefault ? "" : t, color: me?.color ?? 0))
            defaultPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
            defaultDelivery = pickup && deliver ? "both" : (pickup ? "pickup" : (deliver ? "deliver" : ""))
            savedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
            state.toast("保存好了")
            dismiss()
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        if phase == .ok { EmptyBlock(text: "卖掉和删掉的会在这里") } else { PhaseBlock(phase: phase) }
                    }
                    ForEach(items) { item in
                        RecordRow(item: item, relist: { relist(item) }, purge: { purging = item })
                    }
                    Text("只有你看得到。删掉的只留一张小图和文字。")
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: state.version) { await load() }
        .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item, startStatus: "on") }
        .sheet(item: $relisting) { item in
            PostForm(kind: item.kind, prefill: item) { _ in
                // 重新发了，旧记录就不要了
                Task {
                    try? await API.shared.purge(item.id)
                    state.changed()
                }
            }
        }
        .alert("彻底删除？", isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }), presenting: purging) { item in
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await API.shared.purge(item.id)
                        items.removeAll { $0.id == item.id }
                    } catch {
                        state.toast(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("记录和小图都会删掉，不能恢复。")
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

    private var line: String {
        let when = Date(timeIntervalSince1970: Double(item.deletedAt ?? item.updatedAt ?? item.createdAt) / 1000)
        let c = Calendar.current.dateComponents([.month, .day], from: when)
        let status = item.status == "deleted" ? "已删" : (item.isRent ? "已租" : "已卖")
        var parts = [status, "\(c.month ?? 0)月\(c.day ?? 0)日"]
        if let sold = item.soldPrice { parts.append("成交 $\(sold)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 60, height: 60)
                .overlay { ListingImage(item: item, maxPixel: 200) }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.priceText + (item.isRent ? " /月" : "")).font(.subheadline).monospacedDigit().foregroundStyle(Theme.sub)
                Text(line).font(.footnote).foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
            Menu {
                Button("重新上架", systemImage: "arrow.uturn.up", action: relist)
                Button("彻底删除", systemImage: "trash", role: .destructive, action: purge)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        }
    }
}

// MARK: - 举报规则

struct RulesView: View {
    @State private var showEmail = false

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "举报规则")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "可以举报什么", "违规内容、虚假信息、骚扰或诈骗，比如违禁物品、假学历、代写代考、私下换汇、冒用别人的照片，以及不当的昵称和头像。")
                    step(2, "怎么举报", "在东西或房子的详情页，点右上角“…”→ 举报，再选原因；昵称和头像选“举报昵称”“举报头像”。不想再看到这个人，可以同时屏蔽。")
                    step(3, "多久处理", "24 小时内处理。违规的内容会下架，不当的昵称会重置、头像会撤掉，情节严重的停用账号。")
                    Button { withAnimation(.snappy(duration: 0.18)) { showEmail.toggle() } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Hexagon().fill(Theme.fill).frame(width: 30, height: 30)
                                Image(systemName: "envelope").font(.system(size: 13)).foregroundStyle(Theme.sub)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("觉得处理错了").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text("点这里看邮箱，写邮件申诉").font(.subheadline).foregroundStyle(Theme.sub)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    EmailReveal(shown: $showEmail)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Hexagon().fill(Theme.buy).frame(width: 30, height: 30)
                Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onBuy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(.subheadline).foregroundStyle(Theme.sub).lineSpacing(3)
            }
        }
    }
}
