import SwiftUI
import UIKit

/// 认领：用自己的微信发验证码，核对发送者后，他名下的帖子一次转过来；然后填愿意公开的微信号。
struct ClaimView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code: ClaimCode?
    @State private var status: ClaimStatus?
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
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .presentationDragIndicator(.visible)
        .task { await start() }
        .task(id: code?.code) { await watch() }
    }

    private var codeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("认领你在群里发的东西").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            if let code {
                Text(code.code)
                    .font(.system(size: 40, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                Button("复制代码") {
                    UIPasteboard.general.string = code.code
                    state.toast("已复制")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                HoneyLoader()
            }
            VStack(alignment: .leading, spacing: 8) {
                step("①", "复制上面的代码")
                HStack(alignment: .firstTextBaseline) {
                    step("②", "在微信里加 \(state.opsWechat ?? "运营微信") 为好友，备注写“蜂集认领”")
                    if let ops = state.opsWechat {
                        Spacer(minLength: 8)
                        ActionChip(text: "复制") {
                            UIPasteboard.general.string = ops
                            state.toast("已复制")
                        }
                    }
                }
                step("③", "通过后，把代码私聊发过去")
                step("④", "一般当天完成，完成后 App 里会显示认领了几件")
            }
            Text("代码 24 小时内有效。")
                .font(.footnote)
                .foregroundStyle(Theme.sub)
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(n).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var claimedView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("认领了 \(status?.count ?? 0) 条").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            Text("填你愿意公开的微信号。买家会看到，可以直接加你。不填就继续显示“去群里找”。")
                .font(.subheadline)
                .foregroundStyle(Theme.sub)
            TextField("微信号", text: $contact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 17))
            Theme.line.frame(height: 0.5)
            Button(saving ? "正在存…" : "保存") { Task { await save() } }
                .buttonStyle(PrimaryButtonStyle())
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
            state.toast("存好了")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
