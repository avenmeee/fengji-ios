import SwiftUI
import UIKit

/// 详情：照片像挂在墙上，下面是展签。颜色只给六边形。
struct DetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var item: Listing
    @State private var gone = false
    @State private var editing = false
    @State private var confirmAdminDelete = false
    @State private var confirmBlock = false
    @State private var choosingReason = false
    @State private var shareImage: ShareImage?
    @State private var confirmTakedown = false
    @State private var claiming = false
    @State private var page = 0
    @State private var wanting = false
    @State private var popCheck = ""

    /// 展签第二行：分类、成色或房子的情况
    private var line1: String {
        // 分类和成色是 AI 后台用的，不显示
        let parts = item.isRent ? [item.rentFacts] : []
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 第三行：地点和时间
    private var line2: String {
        let parts = item.isRent ? [item.place, item.period] : [item.place, item.pickupText]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
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
                    photo
                    label
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
        .task {
            if !item.mine { try? await API.shared.countView(item.id) }
        }
        .sheet(item: $shareImage) { ShareSheet(image: $0.image) }
        .sheet(isPresented: $editing) {
            PostForm(kind: item.kind, editing: item) { item = $0 }
        }
        .sheet(isPresented: $claiming) { ClaimView() }
        .sheet(isPresented: $wanting) { WantSheet(item: item) }
        .confirmationDialog("举报这条", isPresented: $choosingReason, titleVisibility: .visible) {
            ForEach(REASONS, id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        }
        .alert("删除这条？", isPresented: $confirmAdminDelete) {
            Button("删除", role: .destructive) { Task { await adminRemove() } }
            Button("取消", role: .cancel) {}
        }
        .alert("要求下架？", isPresented: $confirmTakedown) {
            Button("下架", role: .destructive) { Task { await takedown() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("立刻下架，照片一起删除。")
        }
        .alert("屏蔽这个人？", isPresented: $confirmBlock) {
            Button("屏蔽", role: .destructive) { Task { await block() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你不会再看到他发的东西。")
        }
    }

    private var photo: some View {
        VStack(spacing: 10) {
            Color.clear
                .aspectRatio(0.78, contentMode: .fit)
                .overlay {
                    if item.photos.count > 1 {
                        TabView(selection: $page) {
                            ForEach(item.photos.indices, id: \.self) { i in
                                ListingImage(item: item, index: i, maxPixel: 1600)
                                    .clipped()
                                    .background(NoScrollsToTop())
                                    .tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    } else {
                        ListingImage(item: item, maxPixel: 1600)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .background(CardShadow(radius: 14, y: 6))
            if item.photos.count > 1 {
                HStack(spacing: 6) {
                    ForEach(item.photos.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Theme.ink : Theme.line)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
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
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.sub)
        }
        .padding(.top, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("看他发的其他东西")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if !line1.isEmpty {
                Text(line1).font(.subheadline).foregroundStyle(Theme.sub)
            }
            if !line2.isEmpty {
                Text(line2).font(.subheadline).foregroundStyle(Theme.sub)
            }
            if gone {
                Text("这条已经没有了").font(.subheadline).foregroundStyle(Theme.warn)
            } else if !item.isOn {
                Text(item.statusText).font(.subheadline).foregroundStyle(Theme.warn)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.priceText)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if item.isRent { Text("/月").font(.subheadline).foregroundStyle(Theme.sub) }
                Spacer(minLength: 8)
                ScoreBadge(score: item.score, size: 26)
            }
            .padding(.top, 6)
            sellerRow
            if !item.desc.isEmpty {
                Text(item.desc)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 所有次要动作都收在这里
    private var moreMenu: some View {
        Menu {
            if !gone {
                Button("分享图片", systemImage: "photo") {
                    Task { shareImage = await ShareImage.make(item) }
                }
                Button("复制链接", systemImage: "link") {
                    UIPasteboard.general.string = item.shareURL
                    state.toast("链接已复制")
                }
                if item.contact?.isEmpty == false {
                    Button("打开微信", systemImage: "message") { openWeChat(copying: item.contact ?? "", click: "copy") }
                }
            }
            if item.mine, !gone {
                Button("改", systemImage: "pencil") { editing = true }
                Button("删除", systemImage: "trash", role: .destructive) {
                    state.softDelete(item)
                    dismiss()
                }
            }
            if item.isGroup, !gone {
                if state.opsWechat != nil {
                    Button("是我的，认领", systemImage: "person.badge.plus") {
                        if state.needLogin() { claiming = true }
                    }
                    Button("没进群？复制运营微信", systemImage: "person.2") {
                        UIPasteboard.general.string = state.opsWechat
                        state.toast("已复制")
                    }
                }
                Button("要求下架", systemImage: "trash", role: .destructive) { confirmTakedown = true }
            }
            if !item.mine, !gone {
                Button("举报", systemImage: "flag") { choosingReason = true }
                if !item.isGroup, item.sellerAvatar != nil {
                    Button("举报头像", systemImage: "photo.badge.exclamationmark") {
                        Task {
                            try? await API.shared.reportAvatar(item.id)
                            state.toast("收到了，会尽快处理")
                        }
                    }
                }
                if !item.isGroup {
                    Button("举报昵称", systemImage: "person.crop.circle.badge.exclamationmark") {
                        Task {
                            try? await API.shared.reportName(item.id)
                            state.toast("收到了，会尽快处理")
                        }
                    }
                }
                if !item.isGroup {
                    Button("屏蔽这个人", systemImage: "hand.raised") {
                        if state.needLogin() { confirmBlock = true }
                    }
                }
            }
            if state.isAdmin, !item.mine, !gone {
                Button("管理员删除", systemImage: "trash", role: .destructive) { confirmAdminDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    @ViewBuilder
    private var contactBar: some View {
        if let contact = item.contact, !contact.isEmpty {
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
            try await API.shared.delete(item.id)
            state.changed()
            state.toast("删掉了")
            dismiss()
        } catch {
            state.toast(error.localizedDescription)
        }
    }
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
