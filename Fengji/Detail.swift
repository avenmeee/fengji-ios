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
    @State private var panel = Demo.scene == "detail-panel" || Demo.scene == "detail-report" || Demo.scene == "owner-ask"
    @State private var stage: PanelStage = Demo.scene == "detail-report" ? .reportWhat : (Demo.scene == "owner-ask" ? .ownerAsk : .main)
    /// 点开看大图：从第几张开始
    @State private var viewing: PhotoIndex?
    @State private var wanting = Demo.scene == "want-sheet" || Demo.scene == "want-empty"
    @State private var popCheck = ""
    @State private var goSeller = false
    @State private var showHint = false
    @State private var tipOpen = false
    /// 原帖人弹层里刚复制的是哪一行
    @State private var copied: String?
    /// 点价签：讲清楚蜜蜂分怎么来的
    @State private var scoreInfo = Demo.scene == "detail-score"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if item.isSold { soldTag }
                Spacer()
                moreMenu
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            ScrollView {
                if gone {
                    EmptyCard(symbol: "tag", title: "这条已经没有了", note: "可能卖掉了，或者卖家删了", action: ("回首页", { dismiss() }))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    sellerRow
                    label
                    if !item.isSold { scamTip }
                    photos
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .contentShape(Rectangle())
                .simultaneousGesture(swipeToSeller())
                }
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
        .overlay { BottomPanel(shown: $scoreInfo) { ScoreInfo(score: item.score) } }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(item: item, start: start.index)
        }
    }

    /// 照片：一律 4:5 居中裁切，每张装进一样的卡纸；点开看原图比例
    private var photos: some View {
        VStack(spacing: 12) {
            ForEach(Array((item.photos.isEmpty ? [0] : Array(item.photos.indices)).enumerated()), id: \.offset) { _, i in
                Button { if !item.photos.isEmpty { viewing = PhotoIndex(index: i) } } label: {
                    Color.clear
                        .aspectRatio(0.8, contentMode: .fit)
                        .overlay { ListingImage(item: item, index: i, maxPixel: 1600).soldCover(item) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(7)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(i + 1) 张照片，点开看大图")
            }
        }
    }

    private var soldTag: some View {
        Text(item.isRent ? "已租出" : "已卖出")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9))
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

    /// 卖家一行：头像、昵称，群帖后面跟“来自群 · 群名”，只占一行；放不下先截群名，昵称不截
    private var sellerLine: some View {
        HStack(spacing: 10) {
            SellerAvatar(name: item.sellerLabel, color: item.sellerColor, named: item.isGroup || (item.sellerNamed ?? false), size: 44, url: item.sellerAvatar)
            Text(item.sellerLabel)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
            if item.isGroup {
                Text(["来自群", item.sourceGroup ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            // 群帖这一行挤，提示先收掉，只留箭头
            if showHint, !item.isGroup {
                Text("左滑看主页 ›").font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sub)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("看他发的其他东西")
    }

    /// 卡纸：上面名字和价签、发布日期，下面一块白底装信息
    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .center, spacing: 8) {
                    // 东西的价签能点开看评分怎么来的；房子没有分，自己的看不到分，卖完的也不点
                    if !item.isRent, !item.mine, !item.isSold {
                        Button { scoreInfo = true } label: { detailPriceTag }
                            .buttonStyle(.plain)
                            .accessibilityHint("看蜜蜂价格分怎么来的")
                    } else {
                        detailPriceTag
                    }
                    Spacer(minLength: 8)
                    Text(statusLine)
                        .font(.system(size: 13))
                        .foregroundStyle(gone || item.status == "hidden" || item.isReserved ? Theme.warn : Theme.sub)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
            if !item.desc.isEmpty || !item.infoRows.isEmpty {
                infoBlock
            }
        }
        .padding(7)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    /// 价签右边那行：发布日期；已预订、审核中、没了的也写在这里
    private var statusLine: String {
        if gone { return "这条已经没有了" }
        if item.isReserved || item.status == "hidden" { return [item.statusText, postedText].filter { !$0.isEmpty }.joined(separator: " · ") }
        return postedText
    }

    private var detailPriceTag: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(item.priceText)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .strikethrough(item.isSold)
                    .foregroundStyle(item.isSold ? Theme.sub : Theme.ink)
                if item.isRent { Text("/月").font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize() }
            }
            if !item.isSold {
                ScoreBadge(score: item.score, size: 18, labelSize: 13)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Theme.priceTagDetail, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
    }

    /// 信息白块：东西先备注再一行一项；房子先一行一项再描述
    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.isRent, !item.desc.isEmpty { descText }
            if !item.isRent, !item.desc.isEmpty, !item.infoRows.isEmpty { Theme.line.frame(height: 0.5) }
            if !item.infoRows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(item.infoRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: row.icon)
                                .font(.system(size: 15, weight: .light))
                                .foregroundStyle(Theme.sub)
                                .frame(width: 20)
                            Text(row.label).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1).fixedSize().frame(minWidth: 30, alignment: .leading)
                            Text(row.value).font(.system(size: 15)).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if item.isRent, !item.desc.isEmpty, !item.infoRows.isEmpty { Theme.line.frame(height: 0.5) }
            if item.isRent, !item.desc.isEmpty { descText }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
    }

    private var descText: some View {
        Text(item.desc)
            .font(.system(size: 16))
            .foregroundStyle(Theme.ink)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 防骗：一行灰字，点开再说两三句
    private var scamTip: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { tipOpen.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.shield").font(.system(size: 13))
                    Text(item.isRent ? "先看房再交钱，到 leasing office 核实房东，看房前别交押金或申请费。" : "当面验货再付款，别提前转账。")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: tipOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                if tipOpen {
                    Text("别信“先转定金才给你留着”。到账截图可以作假，以账户里实际到账为准。对方多付了让你退差价，多半是骗局。遇到可疑的，点右上角“…”举报。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            .foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityHint(tipOpen ? "收起" : "展开看怎么防骗")
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
                        PanelRow(symbol: "person.badge.minus", title: "我是原帖人，想删除") {
                            stage = .ownerAsk
                            Task { try? await API.shared.report(item.id, reason: OWNER_ASK) }
                        }
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
                        do {
                            try await API.shared.reportName(item.id)
                            state.toast("收到了，会尽快处理")
                        } catch {
                            state.toast(error.localizedDescription)
                        }
                    }
                }
                if item.sellerAvatar != nil {
                    PanelRow(symbol: "photo", title: "头像") {
                        panel = false
                        Task {
                            do {
                                try await API.shared.reportAvatar(item.id)
                                state.toast("收到了，会尽快处理")
                            } catch {
                                state.toast(error.localizedDescription)
                            }
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
        case .ownerAsk:
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我是原帖人，想删除").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("联系我们，说一下是哪条，24 小时内删除。").font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                FormCard {
                    if let wx = state.contactWechat {
                        copyRow("message", "微信", wx)
                        FormDivider()
                    }
                    copyRow("envelope", "邮箱", Config.contactEmail)
                }
                Button("好") { panel = false }
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
            }
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

    /// 一行：图标、标签、内容、“复制”；复制后变“已复制”
    private func copyRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Hexagon().fill(Theme.fill).frame(width: 30, height: 30)
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(1)
                Text(value).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 6)
            Button {
                UIPasteboard.general.string = value
                copied = label
                state.toast("已复制")
            } label: {
                Label(copied == label ? "已复制" : "复制", systemImage: copied == label ? "checkmark" : "doc.on.doc")
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    private var ownerAskText: String {
        let wx = state.contactWechat.map { "加微信 \($0)，或者" } ?? ""
        return "\(wx)发邮件到 \(Config.contactEmail)，说一下是哪条，我们 24 小时内删除。"
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
    case main, reportWhat, reasons, block, ownerAsk, adminDelete
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
    @State private var contact = Demo.scene == "want-empty" ? "" : (UserDefaults.standard.string(forKey: "wantContact") ?? UserDefaults.standard.string(forKey: "contact") ?? "")
    @State private var error: String?
    @State private var busy = false
    /// 点过发送才提示缺联系方式
    @State private var tried = Demo.scene == "want-empty"

    private var missing: Bool { contact.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 56, height: 70)
                    .overlay { ListingImage(item: item, maxPixel: 240) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text("想要 " + item.title).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.85)
                    PriceTag(item: item).padding(-8)
                }
                Spacer(minLength: 0)
            }
            FormCard {
                FieldBlock(label: "说一句 · 选填") {
                    TextField("比如 今晚能去拿吗", text: $message).font(.system(size: 17))
                }
                FormDivider()
                FieldBlock(label: "你的联系方式", hint: tried && missing ? "留个联系方式，卖家才联系得上你" : "只有卖家看得到", hintColor: tried && missing ? Theme.warn : Theme.hint) {
                    TextField("微信号或手机号", text: $contact)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            if let error {
                Text(error).font(.subheadline).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
            Button {
                tried = true
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if busy { HoneyLoader(size: 22) }
                    Text(busy ? "正在发" : "发给卖家")
                }
            }
            .buttonStyle(PrimaryButtonStyle(act: .ink, dimmed: missing))
            .disabled(busy)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .presentationDetents([.height(420)])
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
    }

    private func send() async {
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
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

/// 蜜蜂价格分的说明卡：四档，这件所在的那档高亮
struct ScoreInfo: View {
    let score: Int?

    private let levels: [(Int, String)] = [
        (4, "远低于同类二手价"), (3, "比同类便宜"), (2, "符合同类二手价"), (1, "明显高于同类二手价")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("蜜蜂价格分").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(score == nil ? "这件还没打分，通常半天内会有。" : "由 AI 打分，仅供参考。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
            VStack(spacing: 4) {
                ForEach(levels, id: \.0) { level, text in
                    let on = score.map { max(1, min(4, $0)) } == level
                    HStack(spacing: 10) {
                        BeeIcon(level: level, size: 22).frame(width: 28)
                        Text(scoreLabel(level))
                            .font(.system(size: 15, weight: on ? .semibold : .regular))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 70, alignment: .leading)
                        Text(text).font(.system(size: 14)).foregroundStyle(on ? Theme.ink : Theme.sub)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(on ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("依据：参考蜂集上同类东西的价格、公开二手平台的价格，再结合照片看成色。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text("卖家看不到、也改不了这个分。价格改了会重新打分。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}
