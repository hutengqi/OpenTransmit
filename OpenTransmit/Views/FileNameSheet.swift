import SwiftUI

struct FileEditRequest: Identifiable {
    enum Kind { case path, createDirectory, rename }
    let id = UUID()
    let kind: Kind
    let location: URL
    var title: String { switch kind { case .path: "前往目录"; case .createDirectory: "新建目录"; case .rename: "重命名" } }
}

struct FileNameSheet: View {
    let request: FileEditRequest
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.title2.bold())
            Text(request.location.locationLabel).font(.caption).lineLimit(3).textSelection(.enabled)
            TextField(request.kind == .path ? "绝对或相对目录路径" : "名称", text: $value).focused($focused)
                .disabled(working)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("确定") {
                    working = true; error = nil
                    Task {
                        do { try await submit(value); dismiss() }
                        catch { self.error = error.transferDescription }
                        working = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || value.isEmpty)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(working)
        .onAppear {
            value = request.kind == .path ? request.location.path : (request.kind == .rename ? request.location.lastPathComponent : "")
            focused = true
        }
    }
}
