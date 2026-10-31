import AuthenticationServices
import SwiftUI
import UIKit

/// “我”：从加号进来，靠右滑返回。上面是我发的，发布入口在加号里。
struct MeView: View {
    @EnvironmentObject var state: AppState
    @Binding var path: NavigationPath
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var claiming = Demo.scene == "claim"
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

    private var visible: [Listing] { items.filter { $0.id != state.pendingDelete?.id && $0.status != "off" && $0.status != "deleted" } }
    private var recordCount: Int { items.filter { $0.status == "off" || $0.status == "deleted" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.isLoggedIn { list } else { Spacer() }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { state.onMe = true }
        .onDisappear { state.onMe = false }
        .task(id: LoadKey(version: state.version, loggedIn: state.isLoggedIn)) {
            // 从设置滑回来时内容没变，不重新查
            let key = LoadKey(version: state.version, loggedIn: state.isLoggedIn)
            if key == loadedKey, phase == .ok { return }
            loadedKey = key
            await load()
        }
        .task {
            if Demo.scene == "settings" || Demo.scene == "settings-contact" { path.append("settings") }
            if Demo.scene == "profile" || Demo.scene == "myinfo" { path.append("myinfo") }
            if Demo.scene == "records" { path.append("records") }
            if Demo.scene == "rules" { path.append("settings"); path.append("rules") }
        }
        .onChange(of: items) { _, list in
            if Demo.scene == "mine-actions", acting == nil { acting = list.first }
            if Demo.scene == "sold-ask", editing == nil { editing = list.first }
            if Demo.scene == "undo", state.pendingDelete == nil, let first = list.first { state.softDelete(first) }
        }
        .sheet(isPresented: $claiming) { ClaimView() }
        .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item) }
        .sheet(item: $acting, onDismiss: {
            afterActing?()
            afterActing = nil
        }) { item in
            MineActions(item: item) { action in
                afterActing = { run(action, item) }
                acting = nil
            }
            .presentationDetents([.height(item.status == "hidden" ? 130 : 190)])
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
        HStack(spacing: 12) {
            if state.isLoggedIn {
                Button { path.append("myinfo") } label: {
                    HStack(spacing: 12) {
                        SellerAvatar(name: state.me?.name ?? "", color: state.me?.color ?? 0, named: state.me?.named ?? false, size: 48, url: state.me?.avatar)
                        Text(state.me?.name ?? "")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.sub)
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

    private var list: some View {
        List {
            if !wants.isEmpty {
                Text("有人想要")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                ForEach(wants) { want in
                    WantRow(want: want, copy: {
                        UIPasteboard.general.string = want.contact
                        state.toast("已复制")
                    }, remove: { Task { await deleteWant(want) } }, report: { reportingWant = want }, block: { blockingWant = want })
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            Text("我发的")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if visible.isEmpty {
                Group {
                    if phase == .ok {
                        EmptyBlock(text: "还没发过")
                    } else {
                        PhaseBlock(phase: phase)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(visible) { item in
                MineRow(item: item, open: { path.append(item) }, more: { acting = item })
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("删除", role: .destructive) { state.softDelete(item) }
                            .tint(Theme.warn)
                    }
            }
            if recordCount > 0 {
                Button { path.append("records") } label: {
                    HStack {
                        Text("记录").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("卖掉和删掉的 \(recordCount) 件").font(.subheadline).foregroundStyle(Theme.sub)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if state.opsWechat != nil {
                Button("认领我在群里发的东西") { claiming = true }
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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

/// 一条“想要”：哪件东西、留言、对方联系方式
struct WantRow: View {
    let want: Want
    let copy: () -> Void
    let remove: () -> Void
    let report: () -> Void
    let block: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 66, height: 66)
                .overlay {
                    if let photo = want.photo {
                        RemoteImage(url: photo, maxPixel: 240)
                    } else {
                        Theme.fill
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(want.title).font(.subheadline).foregroundStyle(Theme.sub).lineLimit(1)
                if !want.message.isEmpty {
                    Text(want.message).font(.subheadline).foregroundStyle(Theme.ink)
                }
                Button(action: copy) {
                    HStack(spacing: 6) {
                        Text(want.contact).font(.system(size: 15, weight: .semibold))
                        Image(systemName: "doc.on.doc").font(.system(size: 13))
                    }
                    .foregroundStyle(Theme.ink)
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        }
    }
}

struct MineRow: View {
    let item: Listing
    let open: () -> Void
    let more: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Color.clear
                        .frame(width: 66, height: 66)
                        .overlay { ListingImage(item: item, maxPixel: 240) }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.priceText + (item.isRent ? " /月" : ""))
                            .font(.system(size: 17, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                        if !item.isOn {
                            Text(item.statusText)
                                .font(.footnote)
                                .foregroundStyle(item.status == "off" ? Theme.sub : Theme.warn)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.status == "off" ? 0.5 : 1)
            Button(action: more) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
        }
    }
}

/// 点“…”弹出的动作：纯文字，没有框
struct MineActions: View {
    enum Action {
        case status(String), price, bump, edit, delete
    }

    let item: Listing
    let pick: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态和改价都在编辑页里
            if item.status != "hidden" {
                row("编辑") { pick(.edit) }
            }
            row("删除", color: Theme.warn) { pick(.delete) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
    }

    private func row(_ text: String, color: Color = Theme.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    var onDone: () -> Void = {}
    @State private var error: String?
    @State private var showTerms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignInWithAppleButton(.signIn) { req in
                req.requestedScopes = []
            } onCompletion: { result in
                Task { await finish(result) }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 44)
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.warn)
            }
            Button("登录即同意用户协议") { showTerms = true }
                .font(.footnote)
                .foregroundStyle(Theme.sub)
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
