import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    /// 邮箱点一下才显示
    @State private var showEmail = Demo.scene == "settings-contact"
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("defaultPlace") private var defaultPlace = ""
    @AppStorage("defaultDelivery") private var defaultDelivery = ""
    @AppStorage("contact") private var savedContact = ""
    @State private var blockedCount: Int?
    @State private var error: String?

    private var infoLine: String {
        let pickup = ["pickup": "默认自取", "deliver": "默认可配送", "both": "默认自取或配送"][defaultDelivery] ?? "取货不限"
        return pickup + " · " + (savedContact.isEmpty ? "微信没填" : "微信已填")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "设置")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if state.isLoggedIn {
                        NavigationLink(value: "myinfo") { myInfo }.buttonStyle(.plain)
                    } else {
                        SignInBlock()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        GroupLabel(text: "外观")
                        HStack(spacing: 6) {
                            ForEach([("light", "浅色"), ("dark", "深色"), ("system", "跟随手机")], id: \.0) { key, label in
                                Chip(text: label, on: appearance == key, act: .buy) { appearance = key }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        GroupLabel(text: "规则")
                        NavigationLink { TermsView() } label: { SettingRow(symbol: "doc.text", title: "用户协议") }.buttonStyle(.plain)
                        NavigationLink(value: "rules") { SettingRow(symbol: "flag", title: "举报规则") }.buttonStyle(.plain)
                        if let url = URL(string: Config.base + "/privacy") {
                            Link(destination: url) { SettingRow(symbol: "checkmark.shield", title: "隐私政策") }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        GroupLabel(text: "帮助")
                        if let url = URL(string: Config.base + "/support") {
                            Link(destination: url) { SettingRow(symbol: "questionmark.circle", title: "帮助与支持") }.buttonStyle(.plain)
                        }
                        if !Config.contactEmail.isEmpty {
                            Button { withAnimation(.snappy(duration: 0.18)) { showEmail.toggle() } } label: {
                                SettingRow(symbol: "envelope", title: "联系我们")
                            }
                            .buttonStyle(.plain)
                            EmailReveal(shown: $showEmail)
                        }
                        if state.isLoggedIn {
                            NavigationLink { BlockedView() } label: {
                                SettingRow(symbol: "nosign", title: "屏蔽名单") {
                                    if let blockedCount, blockedCount > 0 {
                                        Text("\(blockedCount)").font(.subheadline).monospacedDigit().foregroundStyle(Theme.sub)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if state.isAdmin {
                            NavigationLink { AdminReportsView() } label: { SettingRow(symbol: "tray", title: "举报处理") }.buttonStyle(.plain)
                        }
                    }
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(Theme.warn)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            if state.isLoggedIn {
                HStack {
                    Button("退出登录") {
                        Task {
                            await state.logout()
                            dismiss()
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("删除账号") { confirmDelete = true }
                        .foregroundStyle(Theme.warn)
                }
                .font(.system(size: 16, weight: .medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 52)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: state.version) {
            guard state.isLoggedIn else { return }
            blockedCount = (try? await API.shared.blocks())?.count
        }
        .alert("删除账号？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await state.deleteAccount()
                        state.toast("账号已删除")
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你发的东西、记录、头像和照片会一起马上删除，不能恢复。")
        }
    }

    /// 头像、昵称、默认地点，点整块进“我的信息”
    private var myInfo: some View {
        HStack(spacing: 14) {
            SellerAvatar(name: state.me?.name ?? "", color: state.me?.color, named: state.me?.named ?? false, size: 68, url: state.me?.avatar)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.me?.name ?? "").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "mappin").font(.system(size: 10, weight: .semibold))
                    Text(defaultPlace.isEmpty ? "没设默认地点" : defaultPlace).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.onBuy)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.buy, in: Capsule())
                Text(infoLine).font(.footnote).foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("我的信息，" + (state.me?.name ?? ""))
    }
}

struct TermsView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("用户协议").font(.title2.weight(.semibold))
                Text("""
                这是同学自办的二手信息平台，不是学校官方。这里不经手钱，不担保交易，交易风险自己负责。

                不许发：违法或违禁物品、色情、暴力、仇恨、诈骗、虚假信息；不许骚扰别人。对这些内容零容忍。

                你可以举报内容、屏蔽用户。收到举报后 24 小时内处理，违规内容会删除，账号可能被封。

                只限萨凡纳，当面交易。看货再付，看房前别转押金，合同和房东身份自己核对。

                你的昵称、头像和你发的微信号，所有人都能看到。删掉的帖子只留小图和文字在你自己的记录里，可以彻底删除。没留微信时，买家可以点“想要”留言，留言和对方的联系方式只有你能看到，可以删除、举报、屏蔽。

                放上的照片会发给 AI（Anthropic 的 Claude）自动填名字、分类和成色；东西的名字、价格、分类、成色、地点和第一张照片也会发给 AI 打分。

                举报在详情页右上角“…”里。

                发房源要遵守美国 Fair Housing 法：整套出租不能写种族、肤色、宗教、性别、残障、家庭状况、国籍方面的限制。

                你可以随时在设置里删除账号，发过的内容和照片会一起删除。
                """)
                .lineSpacing(4)
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct BlockedView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Blocked] = []
    @State private var loaded = false

    var body: some View {
        List {
            Group {
                if loaded, items.isEmpty {
                    Text("没有").foregroundStyle(Theme.sub)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, b in
                    HStack {
                        Text("已屏蔽 \(index + 1)").foregroundStyle(Theme.ink)
                        Spacer()
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
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            items = (try? await API.shared.blocks()) ?? []
            loaded = true
        }
    }
}

struct AdminReportsView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [AdminReport] = []
    @State private var loaded = false
    @State private var stats: Stats?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if let stats {
                    Text("近 30 天：发布 \(stats.posts)，浏览 \(stats.views)，成交 \(stats.sold)，复制微信 \(stats.copies)，去群里 \(stats.groupClicks)")
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                }
                if loaded, items.isEmpty {
                    EmptyBlock(text: "没有待处理的")
                }
                ForEach(items) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            DetailView(item: r.listing)
                        } label: {
                            Text(r.listing.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        Text(r.reason + ((r.count ?? 1) > 1 ? " 等 \(r.count ?? 1) 条" : "") + (r.note.isEmpty ? "" : "：\(r.note)")).font(.subheadline).foregroundStyle(Theme.sub)
                        Text(r.listing.statusText).font(.footnote).foregroundStyle(Theme.sub)
                        HStack(spacing: 6) {
                            let isPost = (r.type ?? "listing") == "listing"
                            ActionChip(text: "没问题") {
                                run { if isPost { try await API.shared.adminRestore(r.listing.id) } else { try await API.shared.adminClose(r.id) } }
                            }
                            if isPost {
                                ActionChip(text: "删除", danger: true) { run { try await API.shared.adminRemove(r.listing.id) } }
                            }
                            if r.reason == "头像不当", let uid = r.reportedUser {
                                ActionChip(text: "撤头像") { run { try await API.shared.adminRemoveAvatar(uid) } }
                            }
                            if r.reason == "昵称不当", let uid = r.reportedUser {
                                ActionChip(text: "重置昵称") { run { try await API.shared.adminResetName(uid) } }
                            }
                            if r.reportedUser != nil || !r.listing.isGroup {
                                ActionChip(text: "封号", danger: true) { run { try await API.shared.adminBan(r.reportedUser ?? r.listing.uid) } }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
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
