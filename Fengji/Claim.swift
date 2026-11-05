import SwiftUI
import UIKit

/// 认领：用自己的微信发验证码，核对发送者后，他名下的帖子一次转过来；然后填愿意公开的微信号。
struct ClaimView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code: ClaimCode?
    @State private var status: ClaimStatus? = Demo.scene == "claim-done" ? ClaimStatus(claimed: true, count: 5, contact: "wx_linxia") : nil
    @State private var contact = UserDefaults.standard.string(forKey: "contact") ?? ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if status?.claimed == true {
                claimedView
            } else {
                codeView
            }
            if let error {
                Text(error).font(.subheadline).foregroundStyle(Theme.warn)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationCornerRadius(28)
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .presentationDragIndicator(.visible)
        .task { await start() }
        .task(id: code?.code) { await watch() }
    }

    private var codeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("认领你在群里发的东西").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
                Text("认领以后，群里搬来的帖子就是你的，可以改、可以下架。").font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            // 代码放大在卡纸里，下面黑色“复制代码”
            VStack(spacing: 7) {
                VStack(spacing: 6) {
                    Text("你的代码").font(.system(size: 14)).foregroundStyle(Theme.sub)
                    if let code {
                        Text(code.code.map(String.init).joined(separator: " "))
                            .font(.system(size: 40, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    } else {
                        HoneyLoader().frame(height: 48)
                    }
                    Text("24 小时内有效").font(.system(size: 13)).foregroundStyle(Theme.hint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                Button {
                    guard let code else { return }
                    UIPasteboard.general.string = code.code
                    state.toast(String(localized: "已复制"))
                } label: {
                    Label("复制代码", systemImage: "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle(act: .ink))
            }
            .padding(7)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16))
            GroupHeader(title: String(localized: "怎么做")).padding(.top, 8)
            FormCard {
                HStack(spacing: 12) {
                    NumberHex(n: 1, size: 26)
                    Text("在微信里加 \(state.opsWechat ?? "运营微信") 为好友").font(.system(size: 16)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if let ops = state.opsWechat {
                        Button {
                            UIPasteboard.general.string = ops
                            state.toast(String(localized: "已复制"))
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
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
                }
                .padding(.vertical, 12)
                FormDivider()
                step(2, String(localized: "通过后，私聊把代码发给他"))
                FormDivider()
                step(3, String(localized: "一般当天完成，这里会显示认领了几件"))
            }
            HStack(spacing: 8) {
                ZStack {
                    Hexagon().fill(Theme.accentSoft).frame(width: 28, height: 28)
                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.tint)
                }
                Text("等核对…").font(.system(size: 15)).foregroundStyle(Theme.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            NumberHex(n: n, size: 26)
            Text(text).font(.system(size: 16)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    /// 认领好了：小蜂巢 + 认领了几件 + 公开的微信号
    private var claimedView: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3) { i in
                    Hexagon().fill(i == 1 ? Theme.accent : Theme.paper)
                        .frame(width: 46, height: 46)
                        .offset(x: CGFloat(i - 1) * 42, y: i == 1 ? 18 : 0)
                }
                BeeIcon(level: 3, size: 22).offset(y: 18)
            }
            .frame(height: 80)
            VStack(spacing: 4) {
                Text("认领了 \(status?.count ?? 0) 件").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("都在“我发的”里了").font(.system(size: 15)).foregroundStyle(Theme.sub)
            }
            FormCard {
                FieldBlock(label: String(localized: "公开的微信号 · 选填"), hint: String(localized: "买家能看到，直接加你。不填，买家还是去群里找你。")) {
                    TextField("微信号", text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 17))
                }
            }
            .padding(.top, 6)
            Button(saving ? "正在存…" : "保存") { Task { await save() } }
                .buttonStyle(PrimaryButtonStyle(act: .ink))
                .disabled(saving)
        }
    }

    private func start() async {
        do {
            let s = try await API.shared.claimStatus()
            status = s
            if s.claimed {
                if let c = s.contact { contact = c }
            } else if let saved = Self.savedCode() {
                code = saved
            } else {
                let fresh = try await API.shared.claimCode()
                code = fresh
                UserDefaults.standard.set(fresh.code, forKey: "claimCode")
                UserDefaults.standard.set(fresh.expiresAt, forKey: "claimCodeExpires")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 没过期的码接着用，免得重开一次就换了个码、发出去的那个白发
    private static func savedCode() -> ClaimCode? {
        let d = UserDefaults.standard
        guard let c = d.string(forKey: "claimCode") else { return nil }
        let exp = Int64(d.integer(forKey: "claimCodeExpires"))
        // 有效期内一直用这个；服务器那边新码也不会让旧码作废
        guard exp > Int64(Date().timeIntervalSince1970 * 1000) + 60_000 else { return nil }
        return ClaimCode(code: c, expiresAt: exp)
    }

    /// 等导入流程核对
    private func watch() async {
        guard code != nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            if let s = try? await API.shared.claimStatus(), s.claimed {
                status = s
                state.changed()
                return
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await API.shared.setPublicContact(c)
            if !c.isEmpty { UserDefaults.standard.set(c, forKey: "contact") }
            state.changed()
            state.toast(String(localized: "存好了"))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
