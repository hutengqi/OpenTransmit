import SwiftUI

struct SMBConnectionView: View {
    let server: ServerProfile
    let pane: PaneStore
    @Environment(\.dismiss) private var dismiss
    @State private var service = SMBMountService()
    @State private var connecting = false
    @State private var mounts: [URL] = []
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 \(server.name)").font(.title2.bold())
            Text("SMB · \(server.host):\(String(server.port))").foregroundStyle(.secondary)
            Text("由 macOS 安全地处理认证。默认路径为 / 时，系统会列出可用共享供你选择；也可以在服务器配置中指定 /共享名。")
            Text("密码只在系统认证窗口输入，是否保存由该窗口控制。SMB 的签名和加密遵循系统与服务器策略，不等同于 FTPS 证书校验。")
                .font(.caption).foregroundStyle(.secondary)
            Text("共享会挂载到系统并在此文件栏打开。关闭标签不会卸载共享；使用完毕可在 Finder 中推出。文件操作沿用已挂载目录的权限与废纸篓规则。")
                .font(.caption).foregroundStyle(.secondary)
            if !mounts.isEmpty {
                Text("选择在文件栏中打开的共享").font(.headline)
                ForEach(mounts, id: \.self) { url in
                    Button(url.lastPathComponent, systemImage: "externaldrive.connected.to.line.below") { open(url) }
                }
            }
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("请在系统窗口完成认证和共享选择…") }
                Spacer()
                Button("取消") { task?.cancel(); service.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if mounts.isEmpty {
                    Button("连接并选择共享…", action: connect).keyboardShortcut(.defaultAction).disabled(connecting)
                }
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(connecting)
        .onDisappear { task?.cancel(); service.cancel() }
    }

    private func connect() {
        connecting = true; message = nil
        task = Task {
            do {
                let result = try await service.connect(server)
                try Task.checkCancellation()
                if result.count == 1 { open(result[0]) }
                else { mounts = result }
            } catch is CancellationError {} catch { message = error.transferDescription }
            connecting = false
        }
    }
    private func open(_ url: URL) { pane.openRoot(url); dismiss() }
}
