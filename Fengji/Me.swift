import AuthenticationServices
import SwiftUI
import UIKit

/// “我”：从加号进来，靠右滑返回。上面是我发的，发布入口在加号里。
struct MeView: View {
    @EnvironmentObject var state: AppState
    @Binding var path: NavigationPath
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var claiming = Demo.scene == "claim" || Demo.scene == "claim-done"
    @State private var editing: Listing?
    @State private var acting: Listing?
    @State private var afterActing: (() -> Void)?
    @State private var pricing: Listing?
    @State private var newPrice = ""
    @State private var selling: Listing?
    @State private var soldPrice = ""
    @State private var wants: [Want] = []
    @State private var loadedKey: LoadKey?
    @State private var reportingWant: Want?
    @State private var blockingWant: Want?

    /// 在卖的在前，卖完的排后面；删掉的去“记录”
    private var visible: [Listing] {
        let live = items.filter { $0.id != state.pendingDelete?.id && $0.status != "deleted" }
        return live.filter { !$0.isSold } + live.filter(\.isSold)
    }
    private var recordCount: Int { items.filter { $0.status == "deleted" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.isLoggedIn { list } else { Spacer() }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { state.onMe = true }
        .onDisappear { state.onMe = false; state.panelOpen = false }
        .onChange(of: acting?.id) { _, id in state.panelOpen = id != nil }
        .task(id: LoadKey(version: state.version, loggedIn: state.isLoggedIn)) {
            // 从设置滑回来时内容没变，不重新查
            let key = LoadKey(version: state.version, loggedIn: state.isLoggedIn)
            if key == loadedKey, phase == .ok { return }
            loadedKey = key
            await load()
        }
        .task {
            if Demo.scene == "settings" || Demo.scene == "settings-contact" { path.append("settings") }
            if Demo.scene == "profile" || Demo.scene?.hasPrefix("myinfo") == true { path.append("myinfo") }
            if Demo.scene == "records" { path.append("records") }
            if Demo.scene == "rules" { path.append("settings"); path.append("rules") }
            if Demo.scene == "blocked" || Demo.scene == "terms" || Demo.scene == "admin" { path.append("settings"); path.append(Demo.scene ?? "") }
        }
        .onChange(of: items) { _, list in
            if Demo.scene == "mine-actions", acting == nil { acting = list.first }
            if Demo.scene == "sold-ask", editing == nil { editing = list.first }
            if Demo.scene == "undo", state.pendingDelete == nil, let first = list.first { state.softDelete(first) }
        }
        .sheet(isPresented: $claiming) { ClaimView() }
        .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item) }
        .overlay {
            BottomPanel(shown: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } })) {
                if let item = acting {
                    MineActions(item: item) { action in
                        acting = nil
                        run(action, item)
                    }
                }
            }
        }
        .confirmationDialog("举报这条留言", isPresented: Binding(get: { reportingWant != nil }, set: { if !$0 { reportingWant = nil } }), titleVisibility: .visible, presenting: reportingWant) { want in
            ForEach(REASONS, id: \.self) { reason in
                Button(reason) { Task { await reportWant(want, reason) } }
            }
        }
        .alert("屏蔽这个人？", isPresented: Binding(get: { blockingWant != nil }, set: { if !$0 { blockingWant = nil } }), presenting: blockingWant) { want in
            Button("屏蔽", role: .destructive) { Task { await blockWant(want) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("他的留言会删掉，也收不到他的新留言。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if state.isLoggedIn {
                Button { path.append("myinfo") } label: {
                    HStack(spacing: 14) {
                        SellerAvatar(name: state.me?.name ?? "", color: state.me?.color ?? 0, named: state.me?.named ?? false, size: 64, url: state.me?.avatar)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.me?.name ?? "")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text("我的信息")
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            }
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.sub)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("我的信息，现在是 " + (state.me?.name ?? ""))
                Spacer()
            } else {
                SignInBlock()
            }
            Button { path.append("settings") } label: {
                HexGear().frame(width: 26, height: 26).frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// 在卖几件、卖完几件
    private var mineCounts: String {
        let live = visible.filter { !$0.isSold }.count, sold = visible.filter(\.isSold).count
        return ["在卖 \(live)", sold > 0 ? "卖完 \(sold)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func listRow<V: View>(_ v: V) -> some View {
        v.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var list: some View {
        List {
            if !wants.isEmpty {
                listRow(HStack(spacing: 8) {
                    Text("有人想要").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("\(wants.count)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onBuy)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 26, minHeight: 24)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }.padding(.top, 6))
                listRow(FormCard {
                    ForEach(Array(wants.enumerated()), id: \.element.id) { i, want in
                        if i > 0 { FormDivider() }
                        WantRow(want: want, copy: {
                            UIPasteboard.general.string = want.contact
                            state.toast("已复制")
                        }, remove: { Task { await deleteWant(want) } }, report: { reportingWant = want }, block: { blockingWant = want })
                    }
                })
            }
            listRow(HStack(alignment: .firstTextBaseline) {
                Text("我发的").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                if !visible.isEmpty {
                    Text(mineCounts).font(.system(size: 13)).foregroundStyle(Theme.hint)
                }
            }.padding(.top, 10))
            if visible.isEmpty {
                listRow(Group {
                    if phase == .ok {
                        EmptyCard(symbol: "shippingbox", title: "还没发过", note: "点下面的加号也能发", action: ("发第一件", { state.plusAction(.goods) }))
                    } else {
                        PhaseBlock(phase: phase)
                    }
                })
            }
            ForEach(visible) { item in
                listRow(MineRow(item: item, open: { path.append(item) }, more: { acting = item }))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { state.softDelete(item) } label: { Label("删除", systemImage: "trash") }
                            .tint(Theme.warn)
                        if item.isSold {
                            Button { run(.status("on"), item) } label: { Label("重新上架", systemImage: "arrow.uturn.up") }
                                .tint(Theme.sub)
                        } else if item.status != "hidden" {
                            Button { run(.status("off"), item) } label: { Label(item.isRent ? "租出去了" : "卖完了", systemImage: "tag") }
                                .tint(Theme.sub)
                        }
                    }
            }
            if recordCount > 0 {
                listRow(Button { path.append("records") } label: {
                    SettingRow(symbol: "archivebox", title: "记录") {
                        HStack(spacing: 6) {
                            Text("删掉的 \(recordCount) 件").font(.system(size: 15)).foregroundStyle(Theme.sub)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.hint)
                        }
                    }
                    .frame(minHeight: 54)
                }
                .buttonStyle(.plain)
                .padding(.top, 6))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Theme.barSpace) }
        .honeyRefresh { await load() }
    }

    private struct LoadKey: Hashable {
        let version: Int
        let loggedIn: Bool
    }

    private func load() async {
        guard state.isLoggedIn else {
            items = []
            return
        }
        do {
            items = try await API.shared.mine()
            wants = (try? await API.shared.wants()) ?? []
            phase = .ok
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if items.isEmpty { phase = .failed }
        }
    }

    private func deleteWant(_ want: Want) async {
        do {
            try await API.shared.deleteWant(want.id)
            wants.removeAll { $0.id == want.id }
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func reportWant(_ want: Want, _ reason: String) async {
        do {
            try await API.shared.reportWant(want.id, reason: reason)
            wants.removeAll { $0.id == want.id }
            state.toast("收到了，会尽快处理")
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func blockWant(_ want: Want) async {
        do {
            try await API.shared.blockWant(want.id)
            state.changed()
            state.toast("已屏蔽")
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func run(_ action: MineActions.Action, _ item: Listing) {
        switch action {
        case .status("off") where !item.isRent:
            soldPrice = ""
            selling = item
        case .status(let status): Task { await setStatus(item, status) }
        case .price:
            newPrice = String(item.price)
            pricing = item
        case .bump: Task { await bump(item) }
        case .edit: editing = item
        case .delete: state.softDelete(item)
        }
    }

    private func setStatus(_ item: Listing, _ status: String, soldPrice: Int? = nil) async {
        do {
            _ = try await API.shared.setStatus(item.id, status, soldPrice: soldPrice)
            state.changed()
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func savePrice(_ item: Listing) async {
        guard let price = Int(newPrice.trimmingCharacters(in: .whitespaces)), price >= 0 else {
            state.toast("价格要填整数")
            return
        }
        do {
            try await API.shared.setPrice(item.id, price)
            state.changed()
            state.toast("改好了")
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func bump(_ item: Listing) async {
        do {
            try await API.shared.bump(item.id)
            state.changed()
            state.toast("擦亮了")
        } catch {
            state.toast(error.localizedDescription)
        }
    }
}

/// 一条“想要”：哪件东西、什么时候、留言，联系方式是能点的小块
struct WantRow: View {
    let want: Want
    let copy: () -> Void
    let remove: () -> Void
    let report: () -> Void
    let block: () -> Void

    private var when: String {
        let s = max(0, Date().timeIntervalSince1970 - Double(want.createdAt) / 1000)
        if s < 3600 { return "刚刚" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        if s < 2 * 86400 { return "昨天" }
        return "\(Int(s / 86400)) 天前"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 56, height: 56)
                .overlay {
                    if let photo = want.photo {
                        RemoteImage(url: photo, maxPixel: 240)
                    } else {
                        Theme.fill
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(want.title + " · " + when).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1)
                if !want.message.isEmpty {
                    Text(want.message).font(.system(size: 16)).foregroundStyle(Theme.ink)
                }
                Button(action: copy) {
                    HStack(spacing: 6) {
                        Text(want.contact).font(.system(size: 16, weight: .semibold))
                        Image(systemName: "doc.on.doc").font(.system(size: 13))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制联系方式 " + want.contact)
            }
            Spacer(minLength: 0)
            Menu {
                Button("删除", systemImage: "trash", role: .destructive, action: remove)
                Button("举报", systemImage: "flag", action: report)
                Button("屏蔽这个人", systemImage: "hand.raised", action: block)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        }
        .padding(.vertical, 14)
    }
}

/// 我发的一件：一张横卡纸，4:5 照片 + 名字 + 首页同款价签（已预订、已卖出都在价签上）
struct MineRow: View {
    let item: Listing
    let open: () -> Void
    let more: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    Color.clear
                        .frame(width: 74, height: 92)
                        .overlay { ListingImage(item: item, maxPixel: 300).soldCover(item) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(item.isSold ? Theme.sub : Theme.ink)
                            .lineLimit(1)
                        PriceTag(item: item).padding(-8)
                        if item.status == "hidden" {
                            Text(item.statusText).font(.system(size: 13)).foregroundStyle(Theme.warn)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: more) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
        }
        .padding(7)
        .padding(.trailing, 6)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 点“…”弹出来的：上面是这件的小卡，下面一行一项
struct MineActions: View {
    enum Action {
        case status(String), price, bump, edit, delete
    }

    let item: Listing
    let pick: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 56, height: 70)
                    .overlay { ListingImage(item: item, maxPixel: 240).soldCover(item) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    PriceTag(item: item).padding(-8)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)
            FormDivider()
            // 改价、已预订在编辑页里；卖完了的只能重新上架或删除
            if item.isSold {
                PanelRow(symbol: "arrow.uturn.up", title: "重新上架") { pick(.status("on")) }
            } else if item.status != "hidden" {
                PanelRow(symbol: "pencil", title: "编辑") { pick(.edit) }
                PanelRow(symbol: "tag", title: item.isRent ? "租出去了" : "卖完了") { pick(.status("off")) }
            }
            PanelRow(symbol: "trash", title: "删除", color: Theme.warn) { pick(.delete) }
        }
    }
}

/// 设置图标：六边形螺母
struct HexGear: View {
    var body: some View {
        ZStack {
            Hexagon().stroke(Theme.sub, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            Circle().stroke(Theme.sub, lineWidth: 1.6).padding(8)
        }
    }
}

/// 通过 Apple 登录。“我”页和登录弹层共用。
struct SignInBlock: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    /// 登录弹层里居中
    var centered = false
    var onDone: () -> Void = {}
    @State private var error: String?
    @State private var showTerms = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 12) {
            SignInWithAppleButton(.signIn) { req in
                req.requestedScopes = []
            } onCompletion: { result in
                Task { await finish(result) }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: centered ? 54 : 44)
            .clipShape(RoundedRectangle(cornerRadius: centered ? 17 : 8))
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.warn)
            }
            Button { showTerms = true } label: {
                (Text("登录即同意") + Text("用户协议").underline())
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showTerms) {
            NavigationStack { TermsView() }
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) async {
        do {
            try await state.completeSignIn(result)
            onDone()
        } catch let e as ASAuthorizationError where e.code == .canceled {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "登录没成功，再试一次。"
        }
    }
}
