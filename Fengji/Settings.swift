import SwiftUI

/// 设置：名片卡纸进我的信息；外观、帮助、规则、管理、账号各一张卡纸
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    /// 邮箱点一下才显示
    @State private var showEmail = Demo.scene == "settings-contact"
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("defaultDelivery") private var defaultDelivery = ""
    @AppStorage("contact") private var savedContact = ""
    @State private var blockedCount: Int?
    @State private var pending: Int?
    @State private var error: String?

    private var infoLine: String {
        let pickup = ["pickup": "默认自取", "deliver": "默认可配送", "both": "默认自取或配送"][defaultDelivery]
        return ["我的信息", pickup ?? "", savedContact.isEmpty ? "微信没填" : "微信已填"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "设置")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.isLoggedIn {
                        NavigationLink(value: "myinfo") { myInfo }.buttonStyle(.plain)
                    } else {
                        SignInBlock()
                    }
                    GroupHeader(title: "外观").padding(.top, 12)
                    HStack(spacing: 8) {
                        ForEach([("light", "浅色", "sun.max"), ("dark", "深色", "moon.fill"), ("system", "跟随手机", "iphone")], id: \.0) { key, label, symbol in
                            let on = appearance == key
                            Button { appearance = key } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                                    Text(label).font(.system(size: 16, weight: on ? .semibold : .regular))
                                }
                                .foregroundStyle(on ? Theme.onBuy : Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(on ? Theme.accent : Theme.fill, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                    .padding(7)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))

                    GroupHeader(title: "帮助").padding(.top, 12)
                    FormCard {
                        if let url = URL(string: Config.base + "/support") {
                            Link(destination: url) { row("questionmark.circle", "帮助与支持", external: true) }.buttonStyle(.plain)
                        }
                        if !Config.contactEmail.isEmpty {
                            FormDivider()
                            Button { withAnimation(.snappy(duration: 0.18)) { showEmail.toggle() } } label: {
                                row("envelope", "联系我们")
                            }
                            .buttonStyle(.plain)
                            if showEmail { emailLine.padding(.bottom, 12) }
                        }
                        if state.isLoggedIn {
                            FormDivider()
                            NavigationLink { BlockedView() } label: {
                                row("nosign", "屏蔽名单", value: blockedCount.map { $0 > 0 ? "\($0) 人" : "" } ?? "")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    GroupHeader(title: "规则").padding(.top, 12)
                    FormCard {
                        NavigationLink { TermsView() } label: { row("doc.text", "用户协议") }.buttonStyle(.plain)
                        FormDivider()
                        NavigationLink(value: "rules") { row("flag", "举报规则") }.buttonStyle(.plain)
                        if let url = URL(string: Config.base + "/privacy") {
                            FormDivider()
                            Link(destination: url) { row("checkmark.shield", "隐私政策", external: true) }.buttonStyle(.plain)
                        }
                    }

                    if state.isAdmin {
                        GroupHeader(title: "管理", note: "只有管理员看得到").padding(.top, 12)
                        FormCard {
                            NavigationLink { AdminReportsView() } label: {
                                row("tray", "举报处理", value: pending.map { $0 > 0 ? "\($0) 条待处理" : "" } ?? "")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if state.isLoggedIn {
                        GroupHeader(title: "账号").padding(.top, 12)
                        FormCard {
                            Button {
                                Task {
                                    await state.logout()
                                    dismiss()
                                }
                            } label: { row("rectangle.portrait.and.arrow.right", "退出登录", chevron: false) }
                            .buttonStyle(.plain)
                            FormDivider()
                            Button { confirmDelete = true } label: {
                                SettingRow(symbol: "trash", title: "删除账号", color: Theme.warn).frame(minHeight: 54)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(Theme.warn)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: state.version) {
            guard state.isLoggedIn else { return }
            blockedCount = (try? await API.shared.blocks())?.count
            if state.isAdmin { pending = (try? await API.shared.adminReports())?.count }
        }
        .overlay {
            BottomPanel(shown: $confirmDelete) {
                PanelConfirm(title: "删除账号？", message: "你发的东西、记录、头像和照片会一起马上删除，不能恢复。", confirm: "删除账号") {
                    confirmDelete = false
                    Task {
                        do {
                            try await state.deleteAccount()
                            state.toast("账号已删除")
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } onCancel: { confirmDelete = false }
            }
        }
    }

    /// 一行：图标、标题、右边的值；外链用 ↗
    private func row(_ symbol: String, _ title: String, value: String = "", external: Bool = false, chevron: Bool = true) -> some View {
        SettingRow(symbol: symbol, title: title) {
            HStack(spacing: 6) {
                if !value.isEmpty {
                    Text(value).font(.system(size: 15)).foregroundStyle(Theme.sub)
                }
                if external {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 14)).foregroundStyle(Theme.hint)
                } else if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
                }
            }
        }
        .frame(minHeight: 54)
    }

    private var emailLine: some View {
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
    }

    /// 名片：头像、昵称、默认取货和微信填了没有，点进我的信息
    private var myInfo: some View {
        HStack(spacing: 16) {
            SellerAvatar(name: state.me?.name ?? "", color: state.me?.color, named: state.me?.named ?? false, size: 60, url: state.me?.avatar)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.me?.name ?? "").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(infoLine).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.hint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .accessibilityLabel("我的信息，" + (state.me?.name ?? ""))
    }
}

/// 用户协议：拆成 8 小节加小标题，文字没改
struct TermsView: View {
    private let sections: [(String, String)] = [
        ("这是什么", "这是同学自办的二手信息平台，不是学校官方。这里不经手钱，不担保交易，交易风险自己负责。"),
        ("不许发", "不许发：违法或违禁物品、色情、暴力、仇恨、诈骗、虚假信息；不许骚扰别人。对这些内容零容忍。"),
        ("举报和屏蔽", "你可以举报内容、屏蔽用户。收到举报后 24 小时内处理，违规内容会删除，账号可能被封。\n\n举报在详情页右上角“…”里。"),
        ("当面交易", "只限萨凡纳，当面交易。看货再付，看房前别转押金，合同和房东身份自己核对。"),
        ("谁能看到什么", "你的昵称、头像和你发的微信号，所有人都能看到。删掉的帖子只留小图和文字在你自己的记录里，可以彻底删除。没留微信时，买家可以点“想要”留言，留言和对方的联系方式只有你能看到，可以删除、举报、屏蔽。"),
        ("AI", "放上的照片会发给 AI（Anthropic 的 Claude）自动填名字、分类和成色；东西的名字、价格、分类、成色、地点和第一张照片也会发给 AI 打分。"),
        ("房源", "发房源要遵守美国 Fair Housing 法：整套出租不能写种族、肤色、宗教、性别、残障、家庭状况、国籍方面的限制。"),
        ("删除账号", "你可以随时在设置里删除账号，发过的内容和照片会一起删除。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "用户协议")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("更新于 2026 年 10 月").font(.system(size: 13)).foregroundStyle(Theme.hint).padding(.horizontal, 4)
                    FormCard {
                        ForEach(Array(sections.enumerated()), id: \.offset) { i, item in
                            if i > 0 { FormDivider() }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    NumberHex(n: i + 1, size: 24)
                                    Text(item.0).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                                }
                                Text(item.1).font(.system(size: 15)).foregroundStyle(Theme.sub).lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 14)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 蜂蜜六边形里的编号
struct NumberHex: View {
    let n: Int
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Hexagon().fill(Theme.accent).frame(width: size, height: size)
            Text("\(n)").font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(Theme.onBuy)
        }
    }
}

/// 屏蔽名单：每人一行，头像昵称、屏蔽日期、“解除”
struct BlockedView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Blocked] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "屏蔽名单")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("屏蔽的人发的东西你看不到，也收不到他的“想要”。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .padding(.horizontal, 4)
                    if loaded, items.isEmpty {
                        VStack(spacing: 10) {
                            ZStack {
                                Hexagon().fill(Theme.fill).frame(width: 52, height: 52)
                                Image(systemName: "nosign").font(.system(size: 20)).foregroundStyle(Theme.sub)
                            }
                            Text("还没有屏蔽谁").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("在别人的详情页或主页“…”里可以屏蔽").font(.system(size: 13)).foregroundStyle(Theme.hint)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                    } else if !items.isEmpty {
                        FormCard {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, b in
                                if i > 0 { FormDivider() }
                                row(b)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            items = (try? await API.shared.blocks()) ?? []
            loaded = true
        }
    }

    private func row(_ b: Blocked) -> some View {
        let d = Calendar.current.dateComponents([.month, .day], from: Date(timeIntervalSince1970: Double(b.at) / 1000))
        return HStack(spacing: 12) {
            SellerAvatar(name: b.name ?? "", color: b.color, named: b.named ?? false, size: 32, url: b.avatar)
            Text(b.name ?? "已屏蔽").font(.system(size: 16)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(d.month ?? 0)月\(d.day ?? 0)日屏蔽").font(.system(size: 13)).foregroundStyle(Theme.hint)
            Button("解除") {
                Task {
                    do {
                        try await API.shared.unblock(b.id)
                        items.removeAll { $0.id == b.id }
                        state.changed()
                    } catch {
                        state.toast(error.localizedDescription)
                    }
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
            .buttonStyle(.plain)
        }
        .frame(minHeight: 54)
    }
}

/// 管理员举报页：近 30 天五格数字；每条举报一张卡纸，按钮排在卡底
struct AdminReportsView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [AdminReport] = []
    @State private var loaded = false
    @State private var stats: Stats?

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "举报处理")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let stats {
                        GroupHeader(title: "近 30 天")
                        HStack(spacing: 6) {
                            statCell(stats.posts, "发布")
                            statCell(stats.views, "浏览")
                            statCell(stats.sold, "成交")
                            statCell(stats.copies, "复制微信")
                            statCell(stats.groupClicks, "去群里")
                        }
                        .padding(7)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                    }
                    HStack {
                        Text("待处理").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        Spacer()
                        if loaded { Text("\(items.count) 条").font(.system(size: 13)).foregroundStyle(Theme.hint) }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    if loaded, items.isEmpty {
                        EmptyBlock(text: "没有待处理的")
                    }
                    ForEach(items) { r in card(r) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func statCell(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(n.formatted()).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.sub).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
    }

    private func typeName(_ r: AdminReport) -> String {
        switch r.type ?? "listing" {
        case "want": return "留言"
        case "name": return "昵称"
        case "avatar": return "头像"
        default: return "帖子"
        }
    }

    private func card(_ r: AdminReport) -> some View {
        let isPost = (r.type ?? "listing") == "listing"
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink { DetailView(item: r.listing) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Color.clear
                        .frame(width: 64, height: 80)
                        .overlay { ListingImage(item: r.listing, maxPixel: 240) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(typeName(r))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.sub)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                            Text(r.listing.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                        Text(r.reason + ((r.count ?? 1) > 1 ? " · \(r.count ?? 1) 人举报" : ""))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.warn)
                        if r.type == "want", let c = r.content {
                            Text("“\(c)”").font(.system(size: 14)).foregroundStyle(Theme.ink).lineLimit(2)
                        } else if !r.note.isEmpty, isPost {
                            Text("“\(r.note)”").font(.system(size: 14)).foregroundStyle(Theme.ink).lineLimit(2)
                        }
                        if r.type == "name" || r.type == "avatar" {
                            SellerLine(item: r.listing, avatarSize: 16, fontSize: 13)
                        }
                        Text(r.listing.statusText).font(.system(size: 13)).foregroundStyle(Theme.hint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)
            }
            .buttonStyle(.plain)
            FormDivider()
            HStack(spacing: 8) {
                action("没问题") {
                    if isPost { try await API.shared.adminRestore(r.listing.id) } else { try await API.shared.adminClose(r.id) }
                }
                if isPost {
                    action("删除", danger: true) { try await API.shared.adminRemove(r.listing.id) }
                }
                if r.reason == "头像不当", let uid = r.reportedUser {
                    action("撤头像") { try await API.shared.adminRemoveAvatar(uid) }
                }
                if r.reason == "昵称不当", let uid = r.reportedUser {
                    action("重置昵称") { try await API.shared.adminResetName(uid) }
                }
                if r.reportedUser != nil || !r.listing.isGroup {
                    action("封号", danger: true) { try await API.shared.adminBan(r.reportedUser ?? r.listing.uid) }
                }
            }
            .padding(.top, 8)
        }
        .padding(7)
        .padding(.horizontal, 3)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    /// 卡底的按钮：平时浅底，危险的红字
    private func action(_ title: String, danger: Bool = false, _ work: @escaping () async throws -> Void) -> some View {
        Button { run(work) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(danger ? Theme.warn : Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(danger ? Color.clear : Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        items = (try? await API.shared.adminReports()) ?? []
        stats = try? await API.shared.adminStats()
        loaded = true
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                state.changed()
                await load()
            } catch {
                state.toast(error.localizedDescription)
            }
        }
    }
}
