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
                default: SettingsView()
                }
            }
            .reloads(model, version: state.version)
            .onChange(of: model.items) { _, items in
                if Demo.scene == "detail" || Demo.scene == "guest-detail" || Demo.scene == "group" || Demo.scene == "want-detail" || Demo.scene == "pop-check" || Demo.scene == "live-detail" || Demo.scene == "detail-panel" || Demo.scene == "detail-report", !demoOpened, let first = items.first {
                    demoOpened = true
                    path.append(first)
                }
                // 截图：卖家主页，自己发的取第二条（有昵称的），群帖取第一条
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

    private func card(_ item: Listing) -> some View {
        NavigationLink(value: item) { GoodsCard(item: item) }
            .buttonStyle(.plain)
            .task { await model.loadMoreIfNeeded(item) }
    }
}

/// 卡片（C 版）：浅色卡纸留一圈边，像装裱；价格和蜜蜂做成价签贴在照片左下，照片下面只放名字，卖家最淡
struct GoodsCard: View {
    let item: Listing

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
                SellerLine(item: item, avatarSize: 15, fontSize: 12)
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
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9))
            } else {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(item.priceText)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                        if item.isRent {
                            Text("/月").font(.system(size: 11.5)).foregroundStyle(Theme.sub)
                        }
                    }
                    if item.isReserved {
                        Text("已预订").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.warn)
                    }
                    ScoreBadge(score: item.score, size: 15, playID: item.id, labelSize: 11.5)
                }
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
                            if model.items.isEmpty {
                                if model.phase == .ok {
                                    EmptyBlock(text: model.isFiltered ? "没找到" : "还没有房源")
                                } else {
                                    PhaseBlock(phase: model.phase)
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
}

/// 房子的卡片：同一张卡纸，照片 1.6:1，标题一行，地段和日期一行
struct RentRow: View {
    let item: Listing

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
                    Text(facts).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1)
                }
                SellerLine(item: item, avatarSize: 15, fontSize: 12)
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
