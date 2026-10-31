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
        .presentationDragIndicator(.visible)
        .task { await start() }
        .task(id: code?.code) { await watch() }
    }

    private var codeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用你的微信发这个验证码").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            if let code {
                Text(code.code)
                    .font(.system(size: 40, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                Button("复制验证码") {
                    UIPasteboard.general.string = code.code
                    state.toast("已复制")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Text("正在取…").foregroundStyle(Theme.sub)
            }
            Text("发给运营小号。15 分钟内有效。对上后，你在群里发的东西会一次转到这个账号。")
                .font(.subheadline)
                .foregroundStyle(Theme.sub)
            if let ops = state.opsWechat {
                HStack {
                    Text("运营小号 " + ops).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    Spacer()
                    ActionChip(text: "复制") {
                        UIPasteboard.general.string = ops
                        state.toast("已复制")
                    }
                }
            }
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
            } else {
                code = try await API.shared.claimCode()
            }
        } catch {
            self.error = error.localizedDescription
        }
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
