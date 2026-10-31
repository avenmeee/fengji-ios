import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        List {
            Group {
                Section {
                    NavigationLink("用户协议") { TermsView() }
                    if let url = URL(string: Config.base + "/privacy") { Link("隐私政策", destination: url) }
                    if let url = URL(string: Config.base + "/support") { Link("帮助与支持", destination: url) }
                    Text("举报：在详情页右上角“…”。屏蔽的人在下面的屏蔽名单。").font(.footnote).foregroundStyle(Theme.sub)
                    if !Config.contactEmail.isEmpty, let url = URL(string: "mailto:\(Config.contactEmail)") {
                        Link("联系我们：\(Config.contactEmail)", destination: url)
                    }
                }
                if state.isLoggedIn {
                    Section {
                        NavigationLink("屏蔽名单") { BlockedView() }
                        if state.isAdmin {
                            NavigationLink("举报和认领") { AdminReportsView() }
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
            .listRowBackground(Theme.fill)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
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

                你发的微信号，所有人都能看到。

                发房源要遵守美国 Fair Housing 法：整套出租不能写种族、肤色、宗教、性别、残障、家庭状况、国籍方面的限制。

                你可以随时在设置里删除账号，发过的内容和照片会一起删除。
                """)
                .lineSpacing(4)
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
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
                    Text("没有屏蔽任何人。").foregroundStyle(Theme.sub)
                }
                ForEach(items) { b in
                    HStack {
                        Text("用户 " + String(b.id.prefix(6))).foregroundStyle(Theme.ink)
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
            .listRowBackground(Theme.fill)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var claims: [AdminClaim] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if let stats {
                    Text("近 30 天：发布 \(stats.posts)，浏览 \(stats.views)，成交 \(stats.sold)")
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                }
                if loaded, items.isEmpty, claims.isEmpty {
                    EmptyBlock(text: "没有待处理的。")
                }
                ForEach(claims) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("认领：" + c.listing.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("微信 " + c.contact).font(.subheadline).foregroundStyle(Theme.sub)
                        HStack(spacing: 6) {
                            ActionChip(text: "同意") { run { try await API.shared.adminDecideClaim(c.id, approve: true) } }
                            ActionChip(text: "拒绝", danger: true) { run { try await API.shared.adminDecideClaim(c.id, approve: false) } }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18))
                }
                ForEach(items) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            DetailView(item: r.listing)
                        } label: {
                            Text(r.listing.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        Text(r.reason + (r.note.isEmpty ? "" : "：\(r.note)")).font(.subheadline).foregroundStyle(Theme.sub)
                        Text(r.listing.statusText).font(.caption).foregroundStyle(Theme.sub)
                        HStack(spacing: 6) {
                            ActionChip(text: "没问题") { run { try await API.shared.adminRestore(r.listing.id) } }
                            ActionChip(text: "删除", danger: true) { run { try await API.shared.delete(r.listing.id) } }
                            if !r.listing.isGroup {
                                ActionChip(text: "封号", danger: true) { run { try await API.shared.adminBan(r.listing.uid) } }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        items = (try? await API.shared.adminReports()) ?? []
        stats = try? await API.shared.adminStats()
        claims = (try? await API.shared.adminClaims()) ?? []
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
