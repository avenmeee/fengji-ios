import SwiftUI

/// 从哪条帖子点进卖家主页。群帖没有账号，靠这条帖子找同一个发帖人。
struct SellerRef: Hashable {
    let listing: Listing
}

/// 卖家主页：只有他现在在架上的，不带记录、不带联系方式
struct SellerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let ref: SellerRef
    @State private var page: SellerPage?
    @State private var failed = false
    @State private var confirmBlock = false

    private var item: Listing { ref.listing }
    private var goods: [Listing] { (page?.items ?? []).filter { !$0.isRent } }
    private var rents: [Listing] { (page?.items ?? []).filter { $0.isRent } }
    private var isGroup: Bool { page?.seller.group ?? item.isGroup }
    private var name: String { page?.seller.name ?? item.sellerLabel }
    private var avatar: String? { page?.seller.avatar ?? item.sellerAvatar }

    /// “在卖 N 件 · 出租 N 套”，只算在卖的，是 0 的不写
    private var counts: String {
        let g = goods.filter { !$0.isSold }.count, r = rents.filter { !$0.isSold }.count
        return [g == 0 ? "" : "在卖 \(g) 件", r == 0 ? "" : "出租 \(r) 套"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageTop(title: "")
                .overlay(alignment: .trailing) {
                    if !isGroup { moreMenu.padding(.trailing, 8) }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if failed {
                        EmptyBlock(text: "看不到这个人的主页")
                    } else if let page {
                        if page.items.isEmpty {
                            EmptyBlock(text: "现在没有在架上的")
                        } else {
                            if !goods.isEmpty {
                                section(rents.isEmpty ? nil : "在卖") { goodsGrid }
                            }
                            if !rents.isEmpty {
                                section(goods.isEmpty ? nil : "出租") {
                                    ForEach(rents) { r in
                                        NavigationLink(value: r) { RentRow(item: r) }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, Theme.barSpace)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: state.version) { await load() }
        .alert("屏蔽这个人？", isPresented: $confirmBlock) {
            Button("屏蔽", role: .destructive) { Task { await block() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你不会再看到他发的东西。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SellerAvatar(name: name, color: page?.seller.color ?? item.sellerColor, named: isGroup || (page?.seller.named ?? item.sellerNamed ?? false), size: 64, url: avatar)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if isGroup {
                    Text(["来自群", page?.seller.groupName ?? item.sourceGroup ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Theme.sub)
                }
                if !counts.isEmpty {
                    Text(counts).font(.subheadline).foregroundStyle(Theme.sub)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { GroupLabel(text: title) }
            content()
        }
    }

    /// 和买东西页一样：一行两个，一样大
    private var goodsGrid: some View {
        LazyVStack(spacing: 14) {
            ForEach(Array(stride(from: 0, to: goods.count, by: 2)), id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    card(goods[i])
                    if i + 1 < goods.count {
                        card(goods[i + 1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func card(_ l: Listing) -> some View {
        NavigationLink(value: l) { GoodsCard(item: l) }.buttonStyle(.plain)
    }

    private var moreMenu: some View {
        Menu {
            if avatar != nil {
                Button("举报头像", systemImage: "photo.badge.exclamationmark") {
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
            Button("举报昵称", systemImage: "person.crop.circle.badge.exclamationmark") {
                Task {
                    do {
                        try await API.shared.reportName(item.id)
                        state.toast("收到了，会尽快处理")
                    } catch {
                        state.toast(error.localizedDescription)
                    }
                }
            }
            Button("屏蔽这个人", systemImage: "hand.raised") {
                if state.needLogin() { confirmBlock = true }
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

    private func load() async {
        do {
            page = try await API.shared.poster(item.id)
            failed = false
        } catch {
            if page == nil { failed = true }
        }
    }

    private func block() async {
        do {
            try await API.shared.block(page?.seller.id ?? item.uid)
            state.changed()
            state.toast("已屏蔽")
            dismiss()
        } catch {
            state.toast(error.localizedDescription)
        }
    }
}
