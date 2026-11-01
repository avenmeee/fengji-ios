import SwiftUI
import UIKit

/// 详情：先文字后照片。从上到下是卖家、名字和价格、文字信息，照片一张接一张排在最下面。
struct DetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var item: Listing
    @State private var gone = false
    @State private var editing = false
    @State private var shareImage: ShareImage?
    @State private var panel = Demo.scene == "detail-panel" || Demo.scene == "detail-report"
    @State private var stage: PanelStage = Demo.scene == "detail-report" ? .reportWhat : .main
    /// 点开看大图：从第几张开始
    @State private var viewing: PhotoIndex?
    @State private var wanting = false
    @State private var popCheck = ""
    @State private var goSeller = false
    @State private var showHint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 文字信息：一行一项。东西是地点和怎么拿，房子是地段、可住日期、房子情况
    private var facts: [(String, String)] {
        let rows: [(String, String)] = item.isRent
            ? [("地段", item.place), ("可住", item.period), ("房子", item.rentFacts)]
            : [("地点", item.place), ("怎么拿", item.pickupText)]
        return rows.filter { !$0.1.isEmpty }
    }

    /// 一周内写“3 天前发布”“今天发布”，再早写日期。群帖写“群里 10月28日发”。重新上架或擦亮按最近一次算。
    private var postedText: String {
        let cal = Calendar.current
        if item.isGroup, let at = item.sourcePostedAt {
            let d = Date(timeIntervalSince1970: Double(at) / 1000)
            return "群里 \(cal.component(.month, from: d))月\(cal.component(.day, from: d))日发"
        }
        let ms = max(item.bumpedAt, item.createdAt)
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "今天发布" }
        if days < 7 { return "\(days) 天前发布" }
        return "\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日发布"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                moreMenu
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sellerRow
                    label
                    photos
                }
                .contentShape(Rectangle())
                .simultaneousGesture(swipeToSeller())
            }
        }
        .background(Theme.bg)
        .overlay {
            if Demo.scene == "pop-check" { Text(popCheck).font(.title).background(Theme.bg) }
        }
        .task {
            guard Demo.scene == "pop-check" else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let nav = PopGestureHook.lastNav
            let g = nav?.interactivePopGestureRecognizer
            popCheck = "nav \(nav != nil) on \(g?.isEnabled == true) vc \(nav?.viewControllers.count ?? 0) begin \(g.flatMap { $0.delegate?.gestureRecognizerShouldBegin?($0) } == true)"
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !gone { contactBar }
        }
        .task(id: state.version) { await reload() }
        .navigationDestination(isPresented: $goSeller) { SellerView(ref: SellerRef(listing: item)) }
        .onAppear {
            // 第一次看别人的帖子时提示一次左滑
            let key = "sellerSwipeHintSeen"
            if !item.mine, !UserDefaults.standard.bool(forKey: key) {
                showHint = true
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        .task {
            if !item.mine { try? await API.shared.countView(item.id) }
        }
        .sheet(item: $shareImage) { ShareSheet(image: $0.image) }
        .sheet(isPresented: $editing) {
            PostForm(kind: item.kind, editing: item) { item = $0 }
        }
        .sheet(isPresented: $wanting) { WantSheet(item: item) }
        .overlay { BottomPanel(shown: $panel) { panelContent } }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(item: item, start: start.index)
        }
    }

    private var photos: some View {
        VStack(spacing: 10) {
            ForEach(item.photos.indices, id: \.self) { i in
                Button { viewing = PhotoIndex(index: i) } label: {
                    DetailPhoto(item: item, index: i)
                        .overlay(alignment: .topLeading) {
                            if i == 0, item.isSold { soldTag }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(i + 1) 张照片，点开看大图")
            }
            if item.photos.isEmpty {
                DetailPhoto(item: item, index: 0)
                    .overlay(alignment: .topLeading) { if item.isSold { soldTag } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var soldTag: some View {
        Text(item.isRent ? "已租出" : "已卖出")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9))
            .padding(12)
    }

    /// 点进卖家主页；自己的就去“我”
    @ViewBuilder
    private var sellerRow: some View {
        if item.mine {
            NavigationLink(value: "me") { sellerLine }.buttonStyle(.plain)
        } else {
            NavigationLink(value: SellerRef(listing: item)) { sellerLine }.buttonStyle(.plain)
        }
    }

    private var sellerLine: some View {
        HStack(spacing: 12) {
            SellerAvatar(name: item.sellerLabel, color: item.sellerColor, named: item.isGroup || (item.sellerNamed ?? false), size: 42, url: item.sellerAvatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sellerLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if item.isGroup {
                    Text(["来自群", item.sourceGroup ?? "", "未确认"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Theme.sub)
                }
            }
            Spacer(minLength: 8)
            if showHint {
                Text("左滑看主页 ›").font(.footnote).foregroundStyle(Theme.sub)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sub)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("看他发的其他东西")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.priceText)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(item.isSold ? Theme.sub : Theme.ink)
                if item.isRent { Text("/月").font(.subheadline).foregroundStyle(Theme.sub) }
                Spacer(minLength: 8)
                ScoreBadge(score: item.score, size: 26)
            }
            if !postedText.isEmpty {
                Text(postedText).font(.subheadline).foregroundStyle(Theme.sub)
            }
            if gone {
                Text("这条已经没有了").font(.subheadline).foregroundStyle(Theme.warn)
            } else if !item.isOn {
                Text(item.statusText).font(.subheadline.weight(.medium)).foregroundStyle(item.isSold ? Theme.ink : Theme.warn)
            }
            if !item.desc.isEmpty {
                Text(item.desc)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(facts, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(label).font(.subheadline).foregroundStyle(Theme.sub).frame(width: 52, alignment: .leading)
                            Text(value).font(.subheadline).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 像抖音左滑进作者主页：手指从右往左，横着滑够远才算。自己的帖子没反应。
    /// 从左边缘往右滑是系统返回，方向相反，不冲突。
    private func swipeToSeller() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                guard !item.mine, !gone, v.translation.width < -70,
                      abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                openSeller()
            }
    }

    private func openSeller() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showHint = false
        if reduceMotion {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { goSeller = true }
        } else {
            goSeller = true
        }
    }

    /// 所有次要动作都收在右上角，点开是自己的底部弹层
    @ViewBuilder
    private var moreMenu: some View {
        if !gone {
            Button {
                stage = .main
                panel = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
        }
    }

    /// 弹层里的几步：主菜单、举报什么、举报理由、各种确认
    @ViewBuilder
    private var panelContent: some View {
        switch stage {
        case .main:
            VStack(spacing: 0) {
                PanelRow(symbol: "photo", title: "分享图片") {
                    panel = false
                    Task { shareImage = await ShareImage.make(item) }
                }
                PanelRow(symbol: "link", title: "复制链接") {
                    UIPasteboard.general.string = item.shareURL
                    panel = false
                    state.toast("已复制")
                }
                if !item.mine {
                    PanelRow(symbol: "flag", title: "举报") { stage = item.isGroup ? .reasons : .reportWhat }
                    if !item.isGroup {
                        PanelRow(symbol: "hand.raised", title: "屏蔽这个人") {
                            if state.isLoggedIn { stage = .block } else { panel = false; state.showLogin = true }
                        }
                    }
                    if item.isGroup {
                        PanelRow(symbol: "trash", title: "这是我的，下架") { stage = .takedown }
                    }
                    if state.isAdmin {
                        PanelRow(symbol: "trash", title: "删除", color: Theme.warn) { stage = .adminDelete }
                    }
                }
            }
        case .reportWhat:
            VStack(alignment: .leading, spacing: 0) {
                GroupLabel(text: "举报什么").padding(.bottom, 4)
                PanelRow(symbol: "doc.text", title: "这条帖子") { stage = .reasons }
                PanelRow(symbol: "person.crop.circle", title: "昵称") {
                    panel = false
                    Task {
                        try? await API.shared.reportName(item.id)
                        state.toast("收到了，会尽快处理")
                    }
                }
                if item.sellerAvatar != nil {
                    PanelRow(symbol: "photo", title: "头像") {
                        panel = false
                        Task {
                            try? await API.shared.reportAvatar(item.id)
                            state.toast("收到了，会尽快处理")
                        }
                    }
                }
            }
        case .reasons:
            VStack(alignment: .leading, spacing: 0) {
                GroupLabel(text: "举报这条").padding(.bottom, 4)
                ForEach(REASONS, id: \.self) { reason in
                    PanelRow(symbol: "flag", title: reason) {
                        panel = false
                        Task { await report(reason) }
                    }
                }
            }
        case .block:
            PanelConfirm(title: "屏蔽这个人？", message: "你不会再看到他发的东西。", confirm: "屏蔽") {
                panel = false
                Task { await block() }
            } onCancel: { panel = false }
        case .takedown:
            PanelConfirm(title: "要求下架？", message: "立刻下架，照片一起删除。", confirm: "下架") {
                panel = false
                Task { await takedown() }
            } onCancel: { panel = false }
        case .adminDelete:
            PanelConfirm(title: "删除这条帖子？", message: "彻底删除，这条的举报一起关掉。", confirm: "删除") {
                panel = false
                Task { await adminRemove() }
            } onCancel: { panel = false }
        }
    }

    @ViewBuilder
    private var contactBar: some View {
        if item.isSold {
            // 卖完了：微信号和“想要”都不显示
            EmptyView()
        } else if let contact = item.contact, !contact.isEmpty {
            Button {
                UIPasteboard.general.string = contact
                state.toast("已复制，去微信加对方")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { try? await API.shared.countClick(item.id, "copy") }
            } label: {
                HStack(spacing: 8) {
                    Text(contact)
                    Image(systemName: "doc.on.doc").font(.system(size: 15))
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink))
            .accessibilityLabel("复制微信号 " + contact)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.bg)
        } else if item.findInGroup {
            Button {
                openWeChat(copying: "\(item.sourceGroup ?? "") \(item.sourcePoster ?? "")", click: "group")
            } label: {
                HStack(spacing: 8) {
                    Text("\(item.sourceGroup ?? "") · \(item.sourcePoster ?? "")")
                    Image(systemName: "arrow.right").font(.system(size: 15))
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink))
            .accessibilityLabel("去 \(item.sourceGroup ?? "") 群找 \(item.sourcePoster ?? "")")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.bg)
        } else if !item.mine, item.isOn || item.isReserved {
            // 卖家没留微信：留一句话和联系方式给他
            Button("想要") {
                if state.needLogin() { wanting = true }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.bg)
        }
    }

    private func openWeChat(copying text: String, click: String) {
        UIPasteboard.general.string = text
        Task { try? await API.shared.countClick(item.id, click) }
        guard let url = URL(string: "weixin://") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { state.toast("已复制") }
        }
    }

    private func reload() async {
        do {
            item = try await API.shared.listing(item.id)
        } catch {
            if (error as? APIError)?.code == "not_found" { gone = true }
        }
    }

    private func takedown() async {
        do {
            try await API.shared.takedown(item.id)
            state.changed()
            state.toast("已下架")
            dismiss()
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func report(_ reason: String) async {
        do {
            try await API.shared.report(item.id, reason: reason)
            state.toast("收到了，会尽快处理")
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func block() async {
        do {
            try await API.shared.block(item.uid)
            state.changed()
            state.toast("已屏蔽")
            dismiss()
        } catch {
            state.toast(error.localizedDescription)
        }
    }

    private func adminRemove() async {
        do {
            try await API.shared.adminRemove(item.id)
            state.changed()
            state.toast("删掉了")
            dismiss()
        } catch {
            state.toast(error.localizedDescription)
        }
    }
}

private enum PanelStage {
    case main, reportWhat, reasons, block, takedown, adminDelete
}

/// 翻照片那个横向滚动不抢点状态栏回顶部
private struct NoScrollsToTop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            var v = view.superview
            while let x = v {
                if let scroll = x as? UIScrollView {
                    scroll.scrollsToTop = false
                    break
                }
                v = x.superview
            }
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// 导航栏藏了以后系统会关掉边缘右滑返回。放在栈的第一页，接上这个手势，动画和跟手都还是系统的。
struct PopGestureHook: UIViewRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var nav: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav else { return false }
            // 转场中再触发会卡住
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }
    }

    final class HookView: UIView {
        var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, coordinator?.nav == nil else { return }
            var r: UIResponder? = self
            while let next = r?.next {
                if let nav = next as? UINavigationController {
                    coordinator?.nav = nav
                    nav.interactivePopGestureRecognizer?.delegate = coordinator
                    PopGestureHook.lastNav = nav
                    return
                }
                r = next
            }
        }
    }

    /// 只给模拟器自查用
    static weak var lastNav: UINavigationController?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: HookView, context: Context) {}
}

/// 想要：一句话（可不写）和自己的联系方式。只有卖家能看到。
struct WantSheet: View {
    let item: Listing
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var contact = UserDefaults.standard.string(forKey: "wantContact") ?? UserDefaults.standard.string(forKey: "contact") ?? ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("想要 " + item.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            line("说一句（可以不写）", $message)
            line("你的联系方式，只有卖家能看到", $contact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let error {
                Text(error).font(.subheadline).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if busy { HoneyLoader(size: 22) }
                    Text(busy ? "正在发" : "发给卖家")
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink, dimmed: contact.trimmingCharacters(in: .whitespaces).isEmpty))
            .disabled(busy)
        }
        .padding(16)
        .padding(.top, 12)
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }

    private func line(_ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(spacing: 6) {
            TextField(placeholder, text: text).font(.system(size: 16))
            Theme.line.frame(height: 0.5)
        }
    }

    private func send() async {
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else {
            error = "留个联系方式，卖家才联系得上你。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await API.shared.want(item.id, message: message.trimmingCharacters(in: .whitespacesAndNewlines), contact: c)
            UserDefaults.standard.set(c, forKey: "wantContact")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            state.toast("发好了，等卖家联系你")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PhotoIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

/// 详情里的一张照片：全宽，按原图比例；没加载出来先占 4:5
struct DetailPhoto: View {
    let item: Listing
    let index: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear.aspectRatio(0.8, contentMode: .fit).overlay { ListingImage(item: item, index: index, maxPixel: 1600) }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: item.photos.indices.contains(index) ? item.photos[index].url : "") { await load() }
    }

    private func load() async {
        guard item.photos.indices.contains(index) else { return }
        let url = item.photos[index].url, key = "\(url)#1600"
        if let hit = ImageCache.shared.get(key) { image = hit; return }
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u), let full = UIImage(data: data) else { return }
        let k = min(1, 1600 / max(full.size.width, full.size.height, 1))
        let thumb = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * k, height: full.size.height * k)) ?? full
        ImageCache.shared.set(key, thumb)
        image = thumb
    }
}

/// 看大图：黑底，左右滑换张，双指或双击放大
struct PhotoViewer: View {
    let item: Listing
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(item.photos.indices, id: \.self) { i in
                    ZoomablePhoto(item: item, index: i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: item.photos.count > 1 ? .always : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .onAppear { page = start }
    }
}

private struct ZoomablePhoto: View {
    let item: Listing
    let index: Int
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        RemoteImage(url: item.photos[index].url, maxPixel: 2400, fill: false)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = min(max(base * $0.magnification, 1), 4) }
                    .onEnded { _ in
                        base = scale
                        if scale <= 1 { withAnimation(.snappy) { offset = .zero; lastOffset = .zero } }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { v in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset },
                including: scale > 1 ? .all : .subviews
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 { scale = 1; base = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; base = 2.5 }
                }
            }
    }
}
