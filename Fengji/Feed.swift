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
    private var searchLog: Task<Void, Never>?
    private var lastSearch = ""

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
            logSearch(results: page.items.count)
        } catch {
            if isCancel(error) { return }
            if items.isEmpty { phase = .failed }
        }
    }

    /// 打字停下来才算搜了一次
    private func logSearch(results: Int) {
        searchLog?.cancel()
        let term = q.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, term != lastSearch else { return }
        searchLog = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, q.trimmingCharacters(in: .whitespaces) == term else { return }
            lastSearch = term
            Events.shared.log(.init(name: "search", kind: kind, q: term, results: results))
        }
    }

    func loadMoreIfNeeded(_ item: Listing) async {
        guard item.id == items.last?.id, let offset = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let askedFilter = filter, askedQ = q
        if let page = try? await API.shared.feed(kind: kind, filter: askedFilter, q: askedQ.trimmingCharacters(in: .whitespaces), offset: offset) {
            guard askedFilter == filter, askedQ == q else { return }
            // 翻页时排序可能挪动，已有的不再加
            let seen = Set(items.map(\.id))
            items += page.items.filter { !seen.contains($0.id) }
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
    var retry: (() -> Void)? = nil

    var body: some View {
        if phase == .failed {
            EmptyCard(symbol: "wifi.exclamationmark", title: "没连上", note: "看看网络，下拉也能再试", action: retry.map { ("再试", $0) })
        } else {
            HoneyLoader().frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    }
}

/// 连不上但还有旧内容：顶上一条红浅底，“再试”
struct OfflineBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").font(.system(size: 15, weight: .semibold))
            Text("没连上，下拉也能再试").font(.system(size: 15)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer()
            Button("再试", action: retry).font(.system(size: 15, weight: .bold)).lineLimit(1).fixedSize().buttonStyle(.plain)
        }
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 顶上固定一排：卡纸色圆角条装筛选，右边一个搜索方块。点搜索换成搜索框 + 取消。
struct TopBar<Filters: View>: View {
    let placeholder: String
    @Binding var query: String
    @ViewBuilder var filters: () -> Filters
    @State private var searching = Demo.scene == "search-kb" || Demo.scene?.hasPrefix("search") == true
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if searching {
                SearchBox(placeholder: placeholder, text: $query)
                    .focused($focused)
                Button("取消") {
                    query = ""
                    searching = false
                }
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 17))
                .foregroundStyle(Theme.ink)
                .buttonStyle(.plain)
            } else {
                filters()
                    .padding(5)
                    .frame(height: 54)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: 17))
                Button {
                    searching = true
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 54, height: 54)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            }
        }
        .frame(height: 54)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .onAppear {
            if searching, Demo.scene == "search-kb" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { focused = true } }
        }
    }
}

/// 租房的筛选：全部 / 整套 / 单间，选中的是白底小块
struct TextTabs: View {
    @Binding var selected: String
    let options: [Option]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.key) { opt in
                let on = selected == opt.key
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.2)) { selected = opt.key }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 17, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Theme.ink : Theme.sub)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(on ? Theme.priceTagDetail : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 分类：选中的是白底小块 + 蜂蜜六边形图标 + 名字，其余只有图标
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
                    HStack(spacing: 6) {
                        ZStack {
                            if on { Hexagon().fill(act.fill).frame(width: 32, height: 32) }
                            CategoryIcon(key: icon(opt.key), size: on ? 18 : 22)
                                .foregroundStyle(on ? act.on : Theme.sub)
                        }
                        .frame(width: 34, height: 44)
                        if on {
                            Text(opt.label)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .fixedSize()
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.horizontal, on ? 6 : 0)
                    .frame(height: 44)
                    .background(on ? Theme.priceTagDetail : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
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
    /// 截图：搜索有结果、没找到
    private static let demoQuery = Demo.scene == "search-hit" ? "书桌" : (Demo.scene == "search-none" ? "钢琴" : "")
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
                            if model.phase == .failed, !model.items.isEmpty {
                                OfflineBanner { Task { await model.load() } }
                            }
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    emptyCard
                                } else {
                                    PhaseBlock(phase: model.phase) { Task { await model.load() } }
                                }
                            } else {
                                LazyVStack(spacing: 14) {
                                    ForEach(rows) { row in
                                        HStack(alignment: .top, spacing: 12) {
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
            .navigationDestination(for: SellerRef.self) { SellerView(ref: $0) }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "me": MeView(path: $path)
                case "myinfo": MyInfoView()
                case "records": RecordsView()
                case "rules": RulesView()
                case "blocked": BlockedView()
                case "terms": TermsView()
                case "admin": AdminReportsView()
                default: SettingsView()
                }
            }
            .reloads(model, version: state.version)
            .onAppear { if !Self.demoQuery.isEmpty, model.q.isEmpty { model.q = Self.demoQuery } }
            .onChange(of: model.items) { _, items in
                if Demo.scene == "detail" || Demo.scene == "guest-detail" || Demo.scene == "group" || Demo.scene == "want-detail" || Demo.scene == "pop-check" || Demo.scene == "live-detail" || Demo.scene == "detail-panel" || Demo.scene == "detail-report" || Demo.scene == "detail-score" || Demo.scene == "want-sheet" || Demo.scene == "want-empty", !demoOpened, let first = items.first {
                    demoOpened = true
                    path.append(first)
                }
                // 截图：卖家主页，自己发的取第二条（有昵称的），群帖取第一条
                if Demo.scene == "owner-ask" || Demo.scene == "detail-gone", !demoOpened, let first = items.first {
                    demoOpened = true
                    path.append(first)
                }
                if Demo.scene == "detail-sold", !demoOpened, let sold = items.first(where: \.isSold) {
                    demoOpened = true
                    path.append(sold)
                }
                if Demo.scene == "seller" || Demo.scene == "seller-group", !demoOpened, items.count > 1 {
                    demoOpened = true
                    path.append(SellerRef(listing: Demo.scene == "seller" ? items[1] : items[0]))
                }
            }
            .onChange(of: path) { _, p in state.setPushed(.buy, !p.isEmpty) }
            .onChange(of: state.linked) { _, l in
                if let l, !l.isRent { path.append(l); state.linked = nil }
            }
            .onAppear {
                // 这一页第一次出现前就点了链接
                if let l = state.linked, !l.isRent { path.append(l); state.linked = nil }
            }
            .onChange(of: state.meRequests) { _, _ in
                if state.tab == .buy { path.append("me") }
            }
            .onChange(of: state.popRequests) { _, _ in path = NavigationPath() }
            .task {
                if Demo.opensMe, path.isEmpty { path.append("me") }
            }
        }
    }

    /// 没内容：搜索没找到给清空，没人发给发第一件
    @ViewBuilder
    private var emptyCard: some View {
        if !model.q.isEmpty {
            EmptyCard(symbol: "magnifyingglass", title: "没找到“\(model.q)”", note: "换个词，或者看看全部", action: ("清空搜索", { model.q = "" }))
        } else if model.filter != "all" {
            EmptyCard(symbol: "square.grid.2x2", title: "这一类还没有", note: "看看全部", action: ("看全部", { model.filter = "all" }))
        } else {
            EmptyCard(symbol: "bag", title: "还没人发", note: "你可以发第一件", action: ("发第一件", { state.plusAction(.goods) }))
        }
    }

    private func card(_ item: Listing) -> some View {
        NavigationLink(value: item) { GoodsCard(item: item) }
            .buttonStyle(.plain)
            .task { await model.loadMoreIfNeeded(item) }
    }
}

/// 卡片（C 版）：浅色卡纸留一圈边，像装裱；价格和蜜蜂做成价签贴在照片左下，照片下面只放名字，卖家最淡
struct GoodsCard: View {
    let item: Listing
    /// 卖家主页里不重复写他名字
    var showSeller = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 900).soldCover(item) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) { PriceTag(item: item) }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.isSold ? Theme.sub : Theme.ink)
                    .lineLimit(1)
                if showSeller { SellerLine(item: item, avatarSize: 15, fontSize: 12) }
            }
            .padding(.horizontal, 5)
            .padding(.top, 9)
            .padding(.bottom, 5)
        }
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

/// 照片左下的价签：价格加蜜蜂分；卖完了换成黑底“已卖出 / 已租出”
struct PriceTag: View {
    let item: Listing

    var body: some View {
        Group {
            if item.isSold {
                Text(item.isRent ? "已租出" : "已卖出")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9))
            } else {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(item.priceText)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.3)
                        if item.isRent {
                            Text("/月").font(.system(size: 11.5)).foregroundStyle(Theme.sub)
                        }
                    }
                    if item.isReserved {
                        Text("已预订").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.warn).fixedSize()
                    }
                    ScoreBadge(score: item.score, size: 15, playID: item.id, labelSize: 11.5)
                }
                .lineLimit(1)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Theme.priceTag, in: RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            }
        }
        .padding(8)
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
                            if model.phase == .failed, !model.items.isEmpty {
                                OfflineBanner { Task { await model.load() } }
                            }
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    emptyCard
                                } else {
                                    PhaseBlock(phase: model.phase) { Task { await model.load() } }
                                }
                            } else {
                                LazyVStack(spacing: 14) {
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
            .navigationDestination(for: SellerRef.self) { SellerView(ref: $0) }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "me": MeView(path: $path)
                case "myinfo": MyInfoView()
                case "records": RecordsView()
                case "rules": RulesView()
                case "blocked": BlockedView()
                case "terms": TermsView()
                case "admin": AdminReportsView()
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
            .onChange(of: state.linked) { _, l in
                if let l, l.isRent { path.append(l); state.linked = nil }
            }
            .onAppear {
                // 这一页第一次出现前就点了链接
                if let l = state.linked, l.isRent { path.append(l); state.linked = nil }
            }
            .onChange(of: state.meRequests) { _, _ in
                if state.tab == .rent { path.append("me") }
            }
            .onChange(of: state.popRequests) { _, _ in path = NavigationPath() }
        }
    }

    @ViewBuilder
    private var emptyCard: some View {
        if !model.q.isEmpty {
            EmptyCard(symbol: "magnifyingglass", title: "没找到“\(model.q)”", note: "换个词，或者看看全部", action: ("清空搜索", { model.q = "" }))
        } else if model.filter != "all" {
            EmptyCard(symbol: "house", title: "这一类还没有", note: "看看全部", action: ("看全部", { model.filter = "all" }))
        } else {
            EmptyCard(symbol: "house", title: "还没有房源", note: "你可以发第一套", action: ("发一套房子", { state.plusAction(.rent) }))
        }
    }
}

/// 房子的卡片：同一张卡纸，照片 1.6:1，标题一行，地段和日期一行
struct RentRow: View {
    let item: Listing
    var showSeller = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1.6, contentMode: .fit)
                .overlay { ListingImage(item: item, maxPixel: 1200).soldCover(item) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) { PriceTag(item: item) }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.isSold ? Theme.sub : Theme.ink)
                    .lineLimit(1)
                let facts = [item.place, item.shortPeriod].filter { !$0.isEmpty }.joined(separator: " · ")
                if !facts.isEmpty {
                    Text(facts).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1).truncationMode(.tail)
                }
                if showSeller { SellerLine(item: item, avatarSize: 15, fontSize: 12) }
            }
            .padding(.horizontal, 5)
            .padding(.top, 9)
            .padding(.bottom, 5)
        }
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}
