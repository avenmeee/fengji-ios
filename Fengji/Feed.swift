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
    /// 全部翻完了：没有下一页
    var isAtEnd: Bool { next == nil && !items.isEmpty }

    func load() async {
        do {
            let page = try await API.shared.feed(kind: kind, filter: filter, q: q.trimmingCharacters(in: .whitespaces), offset: nil)
            items = page.items
            next = page.next
            phase = .ok
            logSearch(results: page.items.count)
        } catch {
            if isCancel(error) { return }
            phase = .failed  // 有旧内容时顶上出“没连上”那一条
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
    /// 下拉刷新：藏掉系统转圈，顶上放蜂蜜。拉的时候跟手灌满，到位轻触一下，刷新时动，至少显示 0.6 秒
    /// atEnd：全部看完了。这时到底再往上拉，也刷新一次并回到顶部
    func honeyRefresh(atEnd: Bool = false, _ action: @escaping () async -> Void) -> some View {
        modifier(HoneyRefresh(atEnd: atEnd, action: action))
    }
}

private struct HoneyRefresh: ViewModifier {
    let atEnd: Bool
    let action: () async -> Void
    @State private var refreshing = false
    @State private var endRefreshing = false
    @StateObject private var tracker = PullTracker()

    func body(content: Content) -> some View {
        content
            .refreshable { await refresh() }
            .background(PullHook(tracker: tracker, atEnd: atEnd && !refreshing && !endRefreshing) {
                Task { await refreshFromEnd() }
            })
            .overlay(alignment: .top) {
                PullIndicator(tracker: tracker, refreshing: refreshing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                EndIndicator(tracker: tracker, refreshing: endRefreshing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    /// 系统下拉到位时调这里。放进独立的 Task：列表重绘时 SwiftUI 可能取消 refreshable，不能让它把请求也取消了
    @MainActor
    private func refresh() async {
        refreshing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await runAction()
        refreshing = false
    }

    /// 看完了继续上拉，松手后到这里：刷新完回到顶部
    @MainActor
    private func refreshFromEnd() async {
        endRefreshing = true
        await runAction()
        tracker.scrollToTop?()
        endRefreshing = false
    }

    @MainActor
    private func runAction() async {
        let work = Task { @MainActor in
            let started = ContinuousClock.now
            await action()
            let left = Duration.milliseconds(600) - started.duration(to: .now)
            if left > .zero { try? await Task.sleep(for: left) }
        }
        await work.value
    }
}

/// 列表顶部被拉开了多少。只给 PullIndicator 用，拉动时不重绘列表
private final class PullTracker: ObservableObject {
    @Published var pull: CGFloat = 0
    /// 看完以后，底部被往上拉开了多少
    @Published var end: CGFloat = 0
    var scrollToTop: (() -> Void)?
}

/// 系统差不多拉到这么多触发刷新，蜂蜜这时灌满
private let pullFull: CGFloat = 110
/// 底部往上拉这么多算到位，松手刷新
private let endFull: CGFloat = 70

private struct PullIndicator: View {
    @ObservedObject var tracker: PullTracker
    let refreshing: Bool
    private let size: CGFloat = 26

    var body: some View {
        let pull = max(0, tracker.pull)
        ZStack {
            if refreshing {
                HoneyLoader(size: size).padding(.top, 17 + pull / 2)
            } else if pull > 4 {
                HoneyFill(progress: pull / pullFull, size: size)
                    .opacity(min(1, pull / 40))
                    .padding(.top, max(6, (pull - size) / 2))
            }
            if Demo.scene == "refresh-new" {
                Text(verbatim: "pull \(Int(tracker.pull)) end \(Int(tracker.end)) \(refreshing ? "refreshing" : "-")")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white).padding(4).background(.black)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// 随手灌满的蜂蜜六边形
private struct HoneyFill: View {
    let progress: CGFloat
    let size: CGFloat

    var body: some View {
        let p = min(1, max(0, progress))
        ZStack {
            Hexagon().fill(Theme.buy.opacity(0.2))
            Rectangle()
                .fill(Theme.buy)
                .frame(height: size * p)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(Hexagon())
        }
        .frame(width: size, height: size)
        .scaleEffect(0.6 + 0.4 * p)
    }
}

/// 看完以后到底再往上拉：蜂蜜在最后一件下面、底栏上面
private struct EndIndicator: View {
    @ObservedObject var tracker: PullTracker
    let refreshing: Bool
    private let size: CGFloat = 26

    var body: some View {
        let end = max(0, tracker.end)
        Group {
            if refreshing {
                HoneyLoader(size: size)
                    .padding(6)
                    .background(Theme.bg, in: Circle())
                    .padding(.bottom, Theme.barSpace)
            } else if end > 4 {
                HoneyFill(progress: end / endFull, size: size)
                    .opacity(min(1, end / 30))
                    .padding(.bottom, Theme.barSpace + max(0, (end - size) / 2))
            }
        }
    }
}

/// 找到旁边那个带下拉刷新的 UIScrollView，看它拉开了多少。SwiftUI 在 iOS 17 上拿不到这个数
private struct PullHook: UIViewRepresentable {
    let tracker: PullTracker
    let atEnd: Bool
    let onEnd: () -> Void

    final class HookView: UIView {
        var tracker: PullTracker?
        var atEnd = false
        var onEnd: (() -> Void)?
        private var watch: NSKeyValueObservation?
        private weak var target: UIScrollView?
        private var armed = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach(tries: 15)
        }

        private func attach(tries: Int) {
            guard window != nil, target == nil else { return }
            if let found = findScrollView() {
                target = found
                tracker?.scrollToTop = { [weak found] in
                    guard let found else { return }
                    found.setContentOffset(CGPoint(x: 0, y: -found.adjustedContentInset.top), animated: true)
                }
                watch = found.observe(\.contentOffset, options: [.initial, .new]) { [weak self] s, _ in
                    self?.moved(s)
                }
            } else if tries > 0 {
                // refreshable 挂上去比这个视图进窗口晚一点
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attach(tries: tries - 1) }
            }
        }

        private func moved(_ s: UIScrollView) {
            guard let tracker else { return }
            let inset = s.adjustedContentInset
            let pull = -(s.contentOffset.y + inset.top)
            if tracker.pull != pull { tracker.pull = pull }

            // 内容比屏幕短时，也从屏幕底算起
            let visible = s.bounds.height - inset.top - inset.bottom
            let over = s.contentOffset.y + inset.top + visible - max(s.contentSize.height, visible)
            let end = atEnd ? max(0, over) : 0
            if tracker.end != end { tracker.end = end }
            guard atEnd else {
                armed = false
                return
            }
            if s.isTracking {
                // 到位轻触一下；拉回去就不算了
                if over >= endFull {
                    if !armed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    armed = true
                } else {
                    armed = false
                }
            } else if armed {
                armed = false
                onEnd?()
            }
        }

        /// 从近到远往外找，只要和自己盖住同一块地方的
        private func findScrollView() -> UIScrollView? {
            let mine = convert(bounds, to: nil)
            var level = superview
            while let cur = level {
                if let hit = search(cur, near: mine) { return hit }
                level = cur.superview
            }
            return nil
        }

        private func search(_ view: UIView, near rect: CGRect) -> UIScrollView? {
            if let s = view as? UIScrollView, s.refreshControl != nil, s.convert(s.bounds, to: nil).intersects(rect) { return s }
            for sub in view.subviews where sub !== self {
                if let hit = search(sub, near: rect) { return hit }
            }
            return nil
        }
    }

    func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.isUserInteractionEnabled = false
        view.tracker = tracker
        return view
    }

    func updateUIView(_ uiView: HookView, context: Context) {
        uiView.atEnd = atEnd
        uiView.onEnd = onEnd
    }
}

struct PhaseBlock: View {
    let phase: FeedModel.Phase
    var retry: (() -> Void)? = nil

    var body: some View {
        if phase == .failed {
            EmptyCard(symbol: "wifi.exclamationmark", title: String(localized: "没连上"), note: String(localized: "看看网络，下拉也能再试"), action: retry.map { (String(localized: "再试"), $0) })
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
                TopBar(placeholder: String(localized: "搜东西"), query: $model.q) {
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
                    .honeyRefresh(atEnd: model.isAtEnd) { await model.load() }
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
            EmptyCard(symbol: "magnifyingglass", title: String(localized: "没找到“\(model.q)”"), note: String(localized: "换个词，或者看看全部"), action: (String(localized: "清空搜索"), { model.q = "" }))
        } else if model.filter != "all" {
            EmptyCard(symbol: "square.grid.2x2", title: String(localized: "这一类还没有"), note: String(localized: "看看全部"), action: (String(localized: "看全部"), { model.filter = "all" }))
        } else {
            EmptyCard(symbol: "bag", title: String(localized: "还没人发"), note: String(localized: "你可以发第一件"), action: (String(localized: "发第一件"), { state.plusAction(.goods) }))
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
                TopBar(placeholder: String(localized: "搜地段"), query: $model.q) {
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
                    .honeyRefresh(atEnd: model.isAtEnd) { await model.load() }
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
            EmptyCard(symbol: "magnifyingglass", title: String(localized: "没找到“\(model.q)”"), note: String(localized: "换个词，或者看看全部"), action: (String(localized: "清空搜索"), { model.q = "" }))
        } else if model.filter != "all" {
            EmptyCard(symbol: "house", title: String(localized: "这一类还没有"), note: String(localized: "看看全部"), action: (String(localized: "看全部"), { model.filter = "all" }))
        } else {
            EmptyCard(symbol: "house", title: String(localized: "还没有房源"), note: String(localized: "你可以发第一套"), action: (String(localized: "发一套房子"), { state.plusAction(.rent) }))
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
