import SwiftUI

/// “我”：发布入口都在这里，下面是我发的和设置。没登录也能进，点发布才登录。
struct MeView: View {
    @EnvironmentObject var state: AppState
    @State private var items: [Listing] = []
    @State private var phase: FeedModel.Phase = .loading
    @State private var postingGoods = Demo.scene == "form" || Demo.scene == "posted"
    @State private var postingRent = Demo.scene == "rentform"
    @State private var editing: Listing?
    @State private var deleting: Listing?
    @State private var pricing: Listing?
    @State private var newPrice = ""
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
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

                    HStack {
                        Text("我发的").font(.footnote).foregroundStyle(Theme.sub)
                        Spacer()
                        NavigationLink(value: "settings") {
                            Image(systemName: "gearshape").foregroundStyle(Theme.sub)
                        }
                        .accessibilityLabel("设置")
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
                                MineRow(item: item, setStatus: { status in Task { await setStatus(item, status) } }, changePrice: { pricing = item; newPrice = String(item.price) }, bump: { Task { await bump(item) } }, edit: { editing = item }, delete: { deleting = item })
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
            .onChange(of: path) { _, p in state.setPushed(.me, !p.isEmpty) }
            .sheet(isPresented: $postingGoods) { PostForm(kind: "goods") }
            .sheet(isPresented: $postingRent) { PostForm(kind: "rent") }
            .sheet(item: $editing) { item in PostForm(kind: item.kind, editing: item) }
            .alert("改价", isPresented: Binding(get: { pricing != nil }, set: { if !$0 { pricing = nil } }), presenting: pricing) { item in
                TextField("美元", text: $newPrice).keyboardType(.numberPad)
                Button("保存") { Task { await savePrice(item) } }
                Button("取消", role: .cancel) {}
            }
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
    let setStatus: (String) -> Void
    let changePrice: () -> Void
    let bump: () -> Void
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
            .opacity(item.status == "off" ? 0.55 : 1)

            FlowLayout {
                if item.status != "hidden" {
                    if item.isOn { ActionChip(text: "已预订") { setStatus("reserved") } }
                    if item.isReserved { ActionChip(text: "转回在售") { setStatus("on") } }
                    if item.status == "off" {
                        ActionChip(text: "重新上架") { setStatus("on") }
                    } else {
                        ActionChip(text: item.isRent ? "已租" : "已卖") { setStatus("off") }
                        ActionChip(text: "改价", action: changePrice)
                        ActionChip(text: "擦亮", action: bump)
                    }
                    ActionChip(text: "改", action: edit)
                }
                ActionChip(text: "删除", danger: true, action: delete)
            }
        }
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18))
    }
}
