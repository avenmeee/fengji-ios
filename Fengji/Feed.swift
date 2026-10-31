import SwiftUI

@MainActor
final class FeedModel: ObservableObject {
    enum Phase { case loading, ok, failed }

    let kind: String
    @Published var q = ""
    @Published var filter = "all"
    @Published private(set) var items: [Listing] = []
    @Published private(set) var phase: Phase = .loading
    private var next: Int64?
    private var loadingMore = false

    init(kind: String) {
        self.kind = kind
    }

    var isFiltered: Bool { !q.isEmpty || filter != "all" }

    func load() async {
        do {
            let page = try await API.shared.feed(kind: kind, filter: filter, q: q.trimmingCharacters(in: .whitespaces), before: nil)
            items = page.items
            next = page.next
            phase = .ok
        } catch {
            if isCancel(error) { return }
            if items.isEmpty { phase = .failed }
        }
    }

    func loadMoreIfNeeded(_ item: Listing) async {
        guard item.id == items.last?.id, let before = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await API.shared.feed(kind: kind, filter: filter, q: q.trimmingCharacters(in: .whitespaces), before: before) {
            items += page.items
            next = page.next
        }
    }

    private func isCancel(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

private struct FeedKey: Hashable {
    let q: String
    let filter: String
    let version: Int
}

extension View {
    /// 搜索词变了等一下再查，分类和写操作马上查
    func reloads(_ model: FeedModel, version: Int) -> some View {
        modifier(FeedReload(model: model, version: version))
    }
}

private struct FeedReload: ViewModifier {
    @ObservedObject var model: FeedModel
    let version: Int
    @State private var lastQ = ""

    func body(content: Content) -> some View {
        content.task(id: FeedKey(q: model.q, filter: model.filter, version: version)) {
            if model.q != lastQ {
                lastQ = model.q
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            await model.load()
        }
    }
}

struct PhaseBlock: View {
    let phase: FeedModel.Phase

    var body: some View {
        EmptyBlock(text: phase == .failed ? "没连上，下拉再试。" : "正在读取…")
    }
}

/// 顶上一排：分类，右边圆形搜索。点搜索换成搜索框。
struct TopBar<Extra: View>: View {
    let options: [Option]
    @Binding var selected: String
    let act: Act
    let placeholder: String
    @Binding var query: String
    @ViewBuilder var extra: () -> Extra
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if searching {
                SearchBox(placeholder: placeholder, text: $query)
                    .focused($focused)
                Button("取消") {
                    query = ""
                    searching = false
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(options, id: \.key) { opt in
                            Chip(text: opt.label, on: selected == opt.key, act: act, quiet: true) { selected = opt.key }
                        }
                    }
                }
                RoundButton(symbol: "magnifyingglass", label: "搜索") {
                    searching = true
                    focused = true
                }
                extra()
            }
        }
    }
}

// MARK: - 买东西

struct BuyView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FeedModel(kind: "goods")
    @State private var path: [Listing] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    TopBar(options: [ALL_OPTION] + CATS, selected: $model.filter, act: .buy, placeholder: "搜东西", query: $model.q) { EmptyView() }
                    if model.items.isEmpty {
                        if model.phase == .ok {
                            EmptyBlock(text: model.isFiltered ? "没找到。" : "还没人发。")
                        } else {
                            PhaseBlock(phase: model.phase)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.items) { item in
                                NavigationLink(value: item) { GoodsCard(item: item) }
                                    .buttonStyle(.plain)
                                    .task { await model.loadMoreIfNeeded(item) }
                            }
                        }
                    }
                    FootNote(text: "同学自办，非学校官方。当面看货再付。")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, Theme.barSpace)
            }
            .background(Theme.bg)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "detail" || Demo.scene == "guest-detail", path.isEmpty, let first = items.first { path = [first] }
            }
            .onChange(of: path) { _, p in state.setPushed(.buy, !p.isEmpty) }
        }
    }
}

struct GoodsCard: View {
    let item: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(0.87, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 800) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(item.priceText)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(item.price == 0 ? Theme.sell : Theme.ink)
                .padding(.top, 8)
            Text(item.title)
                .font(.footnote)
                .foregroundStyle(Theme.sub)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 租房

struct RentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FeedModel(kind: "rent")
    @State private var path: [Listing] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    TopBar(options: [ALL_OPTION] + plainOptions(RTYPES), selected: $model.filter, act: .rent, placeholder: "搜地段、小区", query: $model.q) { EmptyView() }
                    if model.items.isEmpty {
                        if model.phase == .ok {
                            EmptyBlock(text: model.isFiltered ? "没找到。" : "还没有房源。")
                        } else {
                            PhaseBlock(phase: model.phase)
                        }
                    } else {
                        LazyVStack(spacing: 20) {
                            ForEach(model.items) { item in
                                NavigationLink(value: item) { RentRow(item: item) }
                                    .buttonStyle(.plain)
                                    .task { await model.loadMoreIfNeeded(item) }
                            }
                        }
                    }
                    FootNote(text: "看房前别转押金。这里不核实房东身份。")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, Theme.barSpace)
            }
            .background(Theme.bg)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.load() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "rentdetail", path.isEmpty, let first = items.first { path = [first] }
            }
            .onChange(of: path) { _, p in state.setPushed(.rent, !p.isEmpty) }
        }
    }
}

struct RentRow: View {
    let item: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1.66, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 1200) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(item.priceText)
                        .font(.system(size: 21, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("/月").font(.footnote).foregroundStyle(Theme.sub)
                }
                Spacer()
                Text(item.rtype ?? "")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.rentSoft, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.top, 9)
            Text(item.title)
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text([item.place, item.period].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(Theme.sub)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
