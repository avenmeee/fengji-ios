import SwiftUI
import UIKit

@MainActor
final class FeedModel: ObservableObject {
    enum Phase { case loading, ok, failed }

    let kind: String
    @Published var q = ""
    @Published var filter = "all"
    @Published private(set) var items: [Listing] = []
    @Published private(set) var phase: Phase = .loading
    private var next: Int?
    private var loadingMore = false

    init(kind: String) {
        self.kind = kind
    }

    var isFiltered: Bool { !q.isEmpty || filter != "all" }

    func load() async {
        do {
            let page = try await API.shared.feed(kind: kind, filter: filter, q: q.trimmingCharacters(in: .whitespaces), offset: nil)
            items = page.items
            next = page.next
            phase = .ok
        } catch {
            if isCancel(error) { return }
            if items.isEmpty { phase = .failed }
        }
    }

    func loadMoreIfNeeded(_ item: Listing) async {
        guard item.id == items.last?.id, let offset = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await API.shared.feed(kind: kind, filter: filter, q: q.trimmingCharacters(in: .whitespaces), offset: offset) {
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

extension View {
    /// 下拉刷新：藏掉系统转圈，顶上放蜂蜜动画
    func honeyRefresh(_ action: @escaping () async -> Void) -> some View {
        modifier(HoneyRefresh(action: action))
    }
}

private struct HoneyRefresh: ViewModifier {
    let action: () async -> Void
    @State private var refreshing = false

    func body(content: Content) -> some View {
        content
            .refreshable {
                refreshing = true
                await action()
                refreshing = false
            }
            .overlay(alignment: .top) {
                if refreshing {
                    HoneyLoader(size: 26).padding(.top, 10).allowsHitTesting(false)
                }
            }
    }
}

struct PhaseBlock: View {
    let phase: FeedModel.Phase

    var body: some View {
        if phase == .failed {
            EmptyBlock(text: "没连上，下拉再试")
        } else {
            HoneyLoader().frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    }
}

/// 顶上固定一排：左边筛选，右边搜索。点搜索换成搜索框。
struct TopBar<Filters: View>: View {
    let placeholder: String
    @Binding var query: String
    @ViewBuilder var filters: () -> Filters
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
                filters()
                Button {
                    searching = true
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// 分类：只有图标。选中的垫六边形，并展开写出名字，一屏放下。
struct CategoryBar: View {
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach([ALL_OPTION] + CATS, id: \.key) { opt in
                let on = selected == opt.key
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { selected = opt.key }
                } label: {
                    HStack(spacing: 4) {
                        ZStack {
                            if on { Hexagon().fill(Theme.buy).frame(width: 36, height: 36) }
                            CategoryIcon(key: opt.key, size: on ? 20 : 24)
                                .foregroundStyle(on ? Theme.onBuy : Theme.sub)
                        }
                        .frame(width: 36, height: 44)
                        if on {
                            Text(opt.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .fixedSize()
                        }
                    }
                    .frame(maxWidth: on ? nil : .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(on ? .isSelected : [])
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
            VStack(spacing: 0) {
                TopBar(placeholder: "搜东西", query: $model.q) {
                    CategoryBar(selected: $model.filter)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 18) {
                            Color.clear.frame(height: 0).id("top")
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    EmptyBlock(text: model.isFiltered ? "没找到" : "还没人发")
                                } else {
                                    PhaseBlock(phase: model.phase)
                                }
                            } else {
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(model.items.filter { $0.id != state.pendingDelete?.id }) { item in
                                        NavigationLink(value: item) { GoodsCard(item: item) }
                                            .buttonStyle(.plain)
                                            .task { await model.loadMoreIfNeeded(item) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, Theme.barSpace)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .honeyRefresh { await model.load() }
                    .onChange(of: state.topTicks[.buy] ?? 0) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "detail" || Demo.scene == "guest-detail" || Demo.scene == "group" || Demo.scene == "live-detail", path.isEmpty, let first = items.first { path = [first] }
            }
            .onChange(of: path) { _, p in state.setPushed(.buy, !p.isEmpty) }
        }
    }
}

struct GoodsCard: View {
    let item: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(0.87, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 800) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 6) {
                Text(item.priceText)
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(item.price == 0 ? Theme.sell : Theme.ink)
                if item.isReserved {
                    Text("已预订").font(.footnote).foregroundStyle(Theme.sell)
                }
                Spacer(minLength: 4)
                ScoreBadge(score: item.score)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

// MARK: - 租房子

struct RentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FeedModel(kind: "rent")
    @State private var path: [Listing] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TopBar(placeholder: "搜地段", query: $model.q) {
                    Spacer()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            Color.clear.frame(height: 0).id("top")
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    EmptyBlock(text: model.isFiltered ? "没找到" : "还没有房源")
                                } else {
                                    PhaseBlock(phase: model.phase)
                                }
                            } else {
                                LazyVStack(spacing: 20) {
                                    ForEach(model.items.filter { $0.id != state.pendingDelete?.id }) { item in
                                        NavigationLink(value: item) { RentRow(item: item) }
                                            .buttonStyle(.plain)
                                            .task { await model.loadMoreIfNeeded(item) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, Theme.barSpace)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .honeyRefresh { await model.load() }
                    .onChange(of: state.topTicks[.rent] ?? 0) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "rentdetail" || Demo.scene == "live-rentdetail", path.isEmpty, let first = items.first { path = [first] }
            }
            .onChange(of: path) { _, p in state.setPushed(.rent, !p.isEmpty) }
        }
    }
}

struct RentRow: View {
    let item: Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1.5, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 1200) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.priceText)
                    .font(.system(size: 21, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("/月").font(.footnote).foregroundStyle(Theme.sub)
                if item.isReserved {
                    Text("已预订").font(.footnote).foregroundStyle(Theme.sell).padding(.leading, 6)
                }
            }
            Text([item.place, item.shortPeriod].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(Theme.sub)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}
