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

/// 收起键盘，不管焦点在哪
@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
    @State private var loaded: FeedKey?

    func body(content: Content) -> some View {
        let key = FeedKey(q: model.q, filter: model.filter, version: version)
        return content.task(id: key) {
            // 列表页重新出现（往回滑一开始就会）也会走到这里，内容没变就别重新查，免得滑动时整页重绘
            if key == loaded, model.phase == .ok { return }
            loaded = key
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
    @State private var searching = Demo.scene == "search-kb"
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
        .onAppear {
            if searching { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { focused = true } }
        }
    }
}

/// 租房的筛选：几个词，选中变粗加下划线
struct TextTabs: View {
    @Binding var selected: String
    let options: [Option]
    @Namespace private var line

    var body: some View {
        HStack(spacing: 24) {
            ForEach(options, id: \.key) { opt in
                let on = selected == opt.key
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { selected = opt.key }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 17, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.sub)
                        .frame(height: 44)
                        .overlay(alignment: .bottom) {
                            if on {
                                Capsule()
                                    .fill(Theme.ink)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "line", in: line)
                                    .padding(.bottom, 4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// 分类：只有图标。选中的垫六边形，并展开写出名字，一屏放下。
struct CategoryBar: View {
    @Binding var selected: String
    var options: [Option] = [ALL_OPTION] + CATS
    var act: Act = .buy
    /// 选项对应的图标
    var icon: (String) -> String = { $0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.key) { opt in
                let on = selected == opt.key
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { selected = opt.key }
                } label: {
                    HStack(spacing: 4) {
                        ZStack {
                            if on { Hexagon().fill(act.fill).frame(width: 36, height: 36) }
                            CategoryIcon(key: icon(opt.key), size: on ? 20 : 24)
                                .foregroundStyle(on ? act.on : Theme.sub)
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

/// 一行两个，一样大；单数时最后一个靠左
private struct GalleryRow: Identifiable {
    let a: Listing
    let b: Listing?
    var id: String { a.id }
}

struct BuyView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FeedModel(kind: "goods")
    @State private var path = NavigationPath()
    @State private var demoOpened = false

    private var rows: [GalleryRow] {
        let items = model.items.filter { $0.id != state.pendingDelete?.id }
        return stride(from: 0, to: items.count, by: 2).map { i in
            GalleryRow(a: items[i], b: i + 1 < items.count ? items[i + 1] : nil)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TopBar(placeholder: "搜东西", query: $model.q) {
                    CategoryBar(selected: $model.filter)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 22) {
                            Color.clear.frame(height: 0).id("top")
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    EmptyBlock(text: model.isFiltered ? "没找到" : "还没人发")
                                } else {
                                    PhaseBlock(phase: model.phase)
                                }
                            } else {
                                LazyVStack(spacing: 22) {
                                    ForEach(rows) { row in
                                        HStack(alignment: .top, spacing: 16) {
                                            card(row.a)
                                            if let b = row.b {
                                                card(b)
                                            } else {
                                                Color.clear.frame(maxWidth: .infinity)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, Theme.barSpace)
                        .contentShape(Rectangle())
                        .onTapGesture { hideKeyboard() }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .honeyRefresh { await model.load() }
                    .onChange(of: state.topTicks[.buy] ?? 0) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
            .background(Theme.bg)
            .background(PopGestureHook())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "me": MeView(path: $path)
                case "myinfo": MyInfoView()
                case "records": RecordsView()
                case "rules": RulesView()
                default: SettingsView()
                }
            }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "detail" || Demo.scene == "guest-detail" || Demo.scene == "group" || Demo.scene == "want-detail" || Demo.scene == "pop-check" || Demo.scene == "live-detail", !demoOpened, let first = items.first {
                    demoOpened = true
                    path.append(first)
                }
            }
            .onChange(of: path) { _, p in state.setPushed(.buy, !p.isEmpty) }
            .onChange(of: state.meRequests) { _, _ in
                if state.tab == .buy { path.append("me") }
            }
            .onChange(of: state.popRequests) { _, _ in path = NavigationPath() }
            .task {
                if Demo.opensMe, path.isEmpty { path.append("me") }
            }
        }
    }

    private func card(_ item: Listing) -> some View {
        NavigationLink(value: item) { GoodsCard(item: item) }
            .buttonStyle(.plain)
            .task { await model.loadMoreIfNeeded(item) }
    }
}

struct GoodsCard: View {
    let item: Listing
    var aspect: CGFloat = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 900) }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .background(CardShadow(radius: 10, y: 4))
            HStack(spacing: 6) {
                Text(item.priceText)
                    .font(.system(size: 16, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if item.isReserved {
                    Text("已预订").font(.footnote).foregroundStyle(Theme.sub)
                }
                Spacer(minLength: 4)
                ScoreBadge(score: item.score, playID: item.id)
            }
            SellerLine(item: item)
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
    @State private var path = NavigationPath()
    @State private var demoOpened = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                TopBar(placeholder: "搜地段", query: $model.q) {
                    TextTabs(selected: $model.filter, options: [ALL_OPTION] + UNIT_OPTIONS)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 22) {
                            Color.clear.frame(height: 0).id("top")
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    EmptyBlock(text: model.isFiltered ? "没找到" : "还没有房源")
                                } else {
                                    PhaseBlock(phase: model.phase)
                                }
                            } else {
                                LazyVStack(spacing: 22) {
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
                        .contentShape(Rectangle())
                        .onTapGesture { hideKeyboard() }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .honeyRefresh { await model.load() }
                    .onChange(of: state.topTicks[.rent] ?? 0) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
            .background(Theme.bg)
            .background(PopGestureHook())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Listing.self) { DetailView(item: $0) }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "me": MeView(path: $path)
                case "myinfo": MyInfoView()
                case "records": RecordsView()
                case "rules": RulesView()
                default: SettingsView()
                }
            }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "rentdetail" || Demo.scene == "live-rentdetail", !demoOpened, let first = items.first {
                    demoOpened = true
                    path.append(first)
                }
            }
            .onChange(of: path) { _, p in state.setPushed(.rent, !p.isEmpty) }
            .onChange(of: state.meRequests) { _, _ in
                if state.tab == .rent { path.append("me") }
            }
            .onChange(of: state.popRequests) { _, _ in path = NavigationPath() }
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
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .background(CardShadow(radius: 10, y: 4))
                .padding(.bottom, 6)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.priceText)
                    .font(.system(size: 19, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("/月").font(.footnote).foregroundStyle(Theme.sub)
                if item.isReserved {
                    Text("已预订").font(.footnote).foregroundStyle(Theme.sub).padding(.leading, 6)
                }
            }
            SellerLine(item: item, extra: [item.place, item.shortPeriod])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}
