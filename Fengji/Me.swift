import AuthenticationServices
import SwiftUI
import UIKit

/// “我”：没登录时上面是登录，登录后上面是我发的；卖东西、出租房子固定在底栏上面。
struct MeView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var postingGoods = Demo.scene == "form" || Demo.scene == "form-filled" || Demo.scene == "form-kb-price" || Demo.scene == "form-kb-desc" || Demo.scene == "posted"
    @State private var postingRent = Demo.scene == "rentform" || Demo.scene == "rentform-filled" || Demo.scene == "rent-kb-deposit" || Demo.scene == "rent-kb-desc"
    @State private var claiming = Demo.scene == "claim"
    @State private var editing: Listing?
    @State private var acting: Listing?
    @State private var afterActing: (() -> Void)?
    @State private var pricing: Listing?
    @State private var newPrice = ""
    @State private var path = NavigationPath()

    private var visible: [Listing] { items.filter { $0.id != state.pendingDelete?.id } }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if state.isLoggedIn { list } else { Spacer() }
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) { postButtons }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .navigationDestination(for: String.self) { _ in SettingsView() }
            .task(id: LoadKey(version: state.version, loggedIn: state.isLoggedIn)) { await load() }
            .task {
                if Demo.scene == "settings" { path.append("settings") }
            }
            .onChange(of: path) { _, p in state.setPushed(.me, !p.isEmpty) }
            .onChange(of: items) { _, list in
                if Demo.scene == "mine-actions", acting == nil { acting = list.first }
                if Demo.scene == "undo", state.pendingDelete == nil, let first = list.first { state.softDelete(first) }
            }
            .sheet(isPresented: $postingGoods) { PostForm(kind: "goods") }
            .sheet(isPresented: $postingRent) { PostForm(kind: "rent") }
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
                .presentationDetents([.height(item.status == "off" ? 190 : 380)])
            }
            .alert("改价", isPresented: Binding(get: { pricing != nil }, set: { if !$0 { pricing = nil } }), presenting: pricing) { item in
                TextField("美元", text: $newPrice).keyboardType(.numberPad)
                Button("保存") { Task { await savePrice(item) } }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if state.isLoggedIn {
                Text("我发的")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
            } else {
                SignInBlock()
            }
            NavigationLink(value: "settings") {
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
        ScrollViewReader { proxy in
            List {
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
                        .id(item.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("删除", role: .destructive) { state.softDelete(item) }
                                .tint(Theme.warn)
                        }
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
            .honeyRefresh { await load() }
            .onChange(of: state.topTicks[.me] ?? 0) { _, _ in
                if let first = visible.first {
                    withAnimation(.snappy) { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private var postButtons: some View {
        HStack(spacing: 10) {
            Button("卖东西") {
                if state.needLogin() { postingGoods = true }
            }
            .buttonStyle(PrimaryButtonStyle(act: .sell))
            Button("出租房子") {
                if state.needLogin() { postingRent = true }
            }
            .buttonStyle(PrimaryButtonStyle(act: .rent))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 72)
        .background(Theme.bg)
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
            phase = .ok
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if items.isEmpty { phase = .failed }
        }
    }

    private func run(_ action: MineActions.Action, _ item: Listing) {
        switch action {
        case .status(let status): Task { await setStatus(item, status) }
        case .price:
            newPrice = String(item.price)
            pricing = item
        case .bump: Task { await bump(item) }
        case .edit: editing = item
        case .delete: state.softDelete(item)
        }
    }

    private func setStatus(_ item: Listing, _ status: String) async {
        do {
            _ = try await API.shared.setStatus(item.id, status)
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
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
            if item.status != "hidden" {
                if item.isOn { row("已预订") { pick(.status("reserved")) } }
                if item.isReserved { row("转回在售") { pick(.status("on")) } }
                if item.status == "off" {
                    row("重新上架") { pick(.status("on")) }
                } else {
                    row(item.isRent ? "已租" : "已卖") { pick(.status("off")) }
                    row("改价") { pick(.price) }
                    row("擦亮") { pick(.bump) }
                    row("编辑") { pick(.edit) }
                }
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
