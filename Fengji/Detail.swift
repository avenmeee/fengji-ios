import SwiftUI
import UIKit

struct DetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var item: Listing
    @State private var gone = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var confirmBlock = false
    @State private var choosingReason = false
    @State private var shareImage: ShareImage?
    @State private var confirmTakedown = false
    @State private var claiming = false
    @State private var claimContact = UserDefaults.standard.string(forKey: "contact") ?? ""

    private var line: String {
        let parts = item.isRent ? [item.rtype ?? "", item.place, item.period, item.rentFacts] : [item.cond ?? "", item.catLabel, item.place, item.pickupText]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    info
                }
            }
            .background(Theme.bg)
            .ignoresSafeArea(edges: .top)
            topButtons
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
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
        .confirmationDialog("举报这条", isPresented: $choosingReason, titleVisibility: .visible) {
            ForEach(REASONS, id: \.self) { reason in
                Button(reason) { Task { await report(reason) } }
            }
        }
        .alert("删除这条？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { Task { await remove() } }
            Button("取消", role: .cancel) {}
        }
        .alert("要求下架？", isPresented: $confirmTakedown) {
            Button("下架", role: .destructive) { Task { await takedown() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("立刻下架，照片一起删除。")
        }
        .alert("认领这条", isPresented: $claiming) {
            TextField("你的微信号", text: $claimContact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("提交") { Task { await claim() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认后归你管，微信号所有人能看到。")
        }
        .alert("屏蔽这个人？", isPresented: $confirmBlock) {
            Button("屏蔽", role: .destructive) { Task { await block() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你不会再看到他发的东西。")
        }
    }

    /// 照片是主角：铺满顶部，下面两个圆角
    private var hero: some View {
        Color.clear
            .containerRelativeFrame(.vertical) { height, _ in height * 0.62 }
            .overlay {
                if item.photos.count > 1 {
                    TabView {
                        ForEach(item.photos.indices, id: \.self) { i in
                            ListingImage(item: item, index: i, maxPixel: 1600).clipped()
                        }
                    }
                    .tabViewStyle(.page)
                } else {
                    ListingImage(item: item, maxPixel: 1600)
                }
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.priceText)
                    .font(.system(size: 34, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(item.price == 0 ? Theme.sell : Theme.ink)
                if item.isRent { Text("/月").font(.subheadline).foregroundStyle(Theme.sub) }
                Spacer(minLength: 8)
                ScoreBadge(score: item.score, size: 20)
            }
            Text(item.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(line)
                .font(.subheadline)
                .foregroundStyle(Theme.sub)
            if gone {
                Warn(text: "这条已经没有了。")
            } else if !item.isOn {
                Warn(text: item.statusText)
            }
            if item.isGroup, !gone { groupBlock }
            if !item.desc.isEmpty {
                Text(item.desc)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let contact = item.contact, !gone {
                HStack(spacing: 8) {
                    Hexagon().fill(Theme.accent).frame(width: 18, height: 18)
                    Text("微信 " + contact)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            }
            if item.isRent, !gone { Warn(text: "看房前别转押金，合同和房东身份自己核对。").padding(.top, 6) }
            Text("发布于 " + item.ago)
                .font(.caption)
                .foregroundStyle(Theme.sub)
                .padding(.top, 6)
            if item.mine, !gone {
                HStack(spacing: 6) {
                    ActionChip(text: "改") { editing = true }
                    ActionChip(text: "删除", danger: true) { confirmDelete = true }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 群里搬来的：不给微信号，告诉去哪找；发布者可以认领或下架
    private var groupBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("去 \(item.sourceGroup ?? "") 群找 \(item.sourcePoster ?? "")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("来自微信群，未经发布者确认。")
                .font(.footnote)
                .foregroundStyle(Theme.sub)
            if let ops = state.opsWechat {
                HStack(spacing: 8) {
                    Text("还没进群？加运营微信拉你")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    ActionChip(text: "复制") {
                        UIPasteboard.general.string = ops
                        state.toast("已复制")
                    }
                }
            }
            HStack(spacing: 6) {
                ActionChip(text: "是我的，认领") {
                    if state.needLogin() { claiming = true }
                }
                ActionChip(text: "要求下架", danger: true) { confirmTakedown = true }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
    }

    private var topButtons: some View {
        HStack(spacing: 8) {
            GlassButton(symbol: "chevron.left", label: "返回") { dismiss() }
            Spacer()
            if !gone {
                shareMenu
                if !item.mine || state.isAdmin { moreMenu }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var shareMenu: some View {
        Menu {
            Button("分享图片", systemImage: "photo") {
                Task { shareImage = await ShareImage.make(item) }
            }
            Button("复制链接", systemImage: "link") {
                UIPasteboard.general.string = item.shareURL
                state.toast("链接已复制")
            }
        } label: {
            GlassLabel(symbol: "square.and.arrow.up")
        }
        .accessibilityLabel("分享")
    }

    private var moreMenu: some View {
        Menu {
            if !item.mine {
                Button("举报", systemImage: "flag") { choosingReason = true }
                if !item.isGroup {
                    Button("屏蔽这个人", systemImage: "hand.raised") {
                        if state.needLogin() { confirmBlock = true }
                    }
                }
            }
            if state.isAdmin {
                Button("管理员删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            GlassLabel(symbol: "ellipsis")
        }
        .accessibilityLabel("更多")
    }

    @ViewBuilder
    private var contactBar: some View {
        if let contact = item.contact {
            Button("复制微信号") {
                UIPasteboard.general.string = contact
                state.toast("已复制，去微信加对方")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Theme.bg)
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

    private func claim() async {
        let contact = claimContact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty else {
            state.toast("留个微信号")
            return
        }
        do {
            try await API.shared.claim(item.id, contact: contact)
            UserDefaults.standard.set(contact, forKey: "contact")
            state.toast("提交了，确认后归你")
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

    private func remove() async {
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

struct Warn: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 压在照片上的圆按钮
struct GlassLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.35), in: Circle())
    }
}

struct GlassButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { GlassLabel(symbol: symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
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
