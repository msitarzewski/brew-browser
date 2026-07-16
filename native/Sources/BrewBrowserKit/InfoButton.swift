import SwiftUI

/// Small inline (i) icon that opens a popover explaining how a field was
/// generated, with a "Report an issue on GitHub" button. The native port of the
/// Tauri `InfoButton.svelte` — used on each AI/curated field in the package
/// detail panel instead of a loud "Wrong?" label. Stock SwiftUI `.popover`.
struct InfoButton: View {
    let title: String
    /// Provenance copy (named `message`, not `body`, to avoid colliding with
    /// `View.body`).
    let message: String
    var label: String = "About this field"
    /// Invoked when the user clicks "Report an issue on GitHub" (the popover
    /// closes first).
    let onReport: () -> Void

    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .help(label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    open = false
                    onReport()
                } label: {
                    Label(L10n.string("Report an issue on GitHub"), systemImage: "exclamationmark.bubble")
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}
