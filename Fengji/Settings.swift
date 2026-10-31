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
    @State private var error: String?

    var body: some View {
        List {
            Group {
                Section {
                    Picker("外观", selection: $appearance) {
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                        Text("跟随手机").tag("system")
                    }
                }
                Section("发布默认，不填也能发") {
                    TextField("默认地点，比如 Monty", text: $defaultPlace)
                    Picker("默认取货", selection: $defaultDelivery) {
                        Text("不写").tag("")
                        Text("自取").tag("pickup")
                        Text("可配送").tag("deliver")
                        Text("都可").tag("both")
                    }
                }
                Section {
                    NavigationLink("用户协议") { TermsView() }
                    if let url = URL(string: Config.base + "/privacy") { Link("隐私政策", destination: url) }
                    if let url = URL(string: Config.base + "/support") { Link("帮助与支持", destination: url) }
                    if !Config.contactEmail.isEmpty, let url = URL(string: "mailto:\(Config.contactEmail)") {
                        Button("联系我们") { withAnimation(.snappy(duration: 0.18)) { showEmail.toggle() } }
                            .foregroundStyle(Theme.ink)
                        if showEmail {
                            HStack {
                                Link(Config.contactEmail, destination: url).buttonStyle(.borderless)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = Config.contactEmail
                                    state.toast("已复制")
                                } label: {
                                    Image(systemName: "doc.on.doc").foregroundStyle(Theme.sub)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("复制邮箱")
                            }
                        }
                    }
                }
                if state.isLoggedIn {
                    Section {
                        NavigationLink("屏蔽名单") { BlockedView() }
                        if state.isAdmin {
                            NavigationLink("举报处理") { AdminReportsView() }
                        }
                    }
                    Section {
                        Button("退出登录") {
                            Task {
                                await state.logout()
                                dismiss()
                            }
                        }
                        .foregroundStyle(Theme.ink)
                        Button("删除账号", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if let error {
                            Text(error).foregroundStyle(Theme.warn)
                        }
                    }
                } else {
                    Section {
                        Button("登录") { state.showLogin = true }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
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
            Text("你发的东西和照片会一起马上删除，不能恢复。")
        }
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

                你的昵称和你发的微信号，所有人都能看到。没留微信时，买家可以点“想要”留言，留言和对方的联系方式只有你能看到，可以删除、举报、屏蔽。

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
                        Text(r.reason + (r.note.isEmpty ? "" : "：\(r.note)")).font(.subheadline).foregroundStyle(Theme.sub)
                        Text(r.listing.statusText).font(.footnote).foregroundStyle(Theme.sub)
                        HStack(spacing: 6) {
                            ActionChip(text: "没问题") { run { try await API.shared.adminRestore(r.listing.id) } }
                            ActionChip(text: "删除", danger: true) { run { try await API.shared.delete(r.listing.id) } }
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
