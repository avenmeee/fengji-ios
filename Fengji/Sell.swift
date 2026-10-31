import SwiftUI

struct SellView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var posting = Demo.scene == "form"
    @State private var editing: Listing?
    @State private var deleting: Listing?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("发一件东西") {
                        if state.needLogin() { posting = true }
                    }
                    .buttonStyle(PrimaryButtonStyle(act: .sell))

                    HStack {
                        Text("我发的").font(.footnote).foregroundStyle(Theme.sub)
                        Spacer()
                        NavigationLink(value: "settings") {
                            Image(systemName: "gearshape").foregroundStyle(Theme.sub)
                        }
                    }
                    .padding(.top, 8)

                    if !state.isLoggedIn {
                        EmptyBlock(text: "登录后看你发的。")
                    } else if items.isEmpty {
                        if phase == .ok {
                            EmptyBlock(text: "还没发过。")
                        } else {
                            PhaseBlock(phase: phase)
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                MineRow(item: item, toggle: { Task { await toggle(item) } }, edit: { editing = item }, delete: { deleting = item })
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, Theme.barSpace)
            }
            .background(Theme.bg)
            .refreshable { await load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .navigationDestination(for: String.self) { _ in SettingsView() }
            .task(id: LoadKey(version: state.version, loggedIn: state.isLoggedIn)) { await load() }
            .task {
                if Demo.scene == "settings" { path.append("settings") }
            }
            .onChange(of: path) { _, p in state.setPushed(.sell, !p.isEmpty) }
            .sheet(isPresented: $posting) { PostForm(kind: "goods") }
            .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item) }
            .alert("删除这条？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
                Button("删除", role: .destructive) { Task { await remove(item) } }
                Button("取消", role: .cancel) {}
            }
        }
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

    private func toggle(_ item: Listing) async {
        do {
            _ = try await API.shared.setStatus(item.id, item.isOn ? "off" : "on")
            state.changed()
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func remove(_ item: Listing) async {
        do {
            try await API.shared.delete(item.id)
            state.changed()
            state.toast("删掉了")
        } catch {
            state.toast(error.localizedDescription)
        }
    }
}

struct MineRow: View {
    let item: Listing
    let toggle: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                HStack(spacing: 10) {
                    Color.clear
                        .frame(width: 56, height: 56)
                        .overlay { ListingImage(item: item, maxPixel: 200) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(item.priceText + (item.isRent ? " /月" : ""))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text("\(item.statusText) · \(item.ago)").font(.caption).foregroundStyle(item.status == "hidden" ? Theme.warn : Theme.sub)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.isOn ? 1 : 0.55)

            HStack(spacing: 6) {
                if item.status != "hidden" {
                    ActionChip(text: item.isOn ? (item.isRent ? "标记已租" : "标记已卖") : "重新上架", action: toggle)
                    ActionChip(text: "改", action: edit)
                }
                ActionChip(text: "删除", danger: true, action: delete)
            }
        }
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18))
    }
}
