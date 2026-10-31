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

    /// 展签第二行：分类、成色或房子的情况
    private var line1: String {
        let parts = item.isRent ? [item.rentFacts] : [item.catLabel, item.cond ?? ""]
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
                .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
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
            if item.isGroup, !gone {
                Text("\(item.groupAge)发在群里 · 未确认")
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.priceText)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if item.isRent { Text("/月").font(.subheadline).foregroundStyle(Theme.sub) }
                Spacer(minLength: 8)
                ScoreBadge(score: item.score, size: 24)
            }
            .padding(.top, 6)
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

/// 导航栏藏了以后，边缘右滑返回还要能用
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
