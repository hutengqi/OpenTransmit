import SwiftUI

struct RevealableSecretField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Group {
                if revealed { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            .focused($focused)
            .autocorrectionDisabled()
            Button {
                revealed.toggle()
                focused = true
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "隐藏\(title)" : "显示\(title)")
            .accessibilityLabel(revealed ? "隐藏\(title)" : "显示\(title)")
        }
        .onDisappear { revealed = false }
    }
}
