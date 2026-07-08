import SwiftUI

/// In-window transient notifications — the native port of the Tauri toast
/// system (`src/lib/components/Toast.svelte` + `toast.svelte.ts`). The Tauri
/// build can't use macOS user-notifications for in-window feedback, so it grew
/// its own toast stack; the native build keeps system notifications for
/// background job completion (`NotificationService`) and uses these toasts for
/// foreground, in-window feedback (e.g. the GitHub scope/sign-in CTA).
///
/// All stock SwiftUI — a small overlay layered top-trailing over the content via
/// `.overlay` (top-trailing so it never overlaps the bottom Activity drawer).

/// Toast severity — drives the leading SF Symbol, the accent tint, and the
/// auto-dismiss timing (matching the Tauri timing: success/info 4s, warning 7s,
/// errors persist). Mirrors the Tauri `ToastKind`.
enum ToastKind {
    case success, info, warning, error

    /// Auto-dismiss delay in ms, or nil for errors (which persist until the user
    /// dismisses them). Same values as `toast.svelte.ts`.
    var autoDismissMs: Int? {
        switch self {
        case .success, .info: return 4000
        case .warning:        return 7000
        case .error:          return nil
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .info:    return .accentColor
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

/// An optional inline action button on a toast — e.g. "Re-authorize" on a
/// GitHub scope-required toast. The handler runs (then the toast dismisses) when
/// the user clicks it. Mirrors the Tauri `ToastAction`.
struct ToastAction {
    let label: String
    let handler: () -> Void
}

/// One live toast. `id` keys the SwiftUI `ForEach` + the dismiss timer. Not
/// `Equatable`/`Sendable` because `ToastAction` carries a closure — that's fine,
/// the queue is only ever touched on the main actor (AppModel).
struct ToastItem: Identifiable {
    let id = UUID()
    let kind: ToastKind
    let title: String
    let body: String?
    let action: ToastAction?
}

/// The toast stack overlay — top-trailing, layered over the content so it stays
/// clear of the bottom Activity drawer. Stacks newest-last; each card has a
/// manual dismiss (✕) and, when present, the action button. Stock SwiftUI cards
/// on `.regularMaterial`, no chrome overrides.
struct ToastOverlay: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastCard(toast: toast, model: model)
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // The stack is non-interactive except for the cards themselves, so it
        // never swallows clicks meant for the content behind it.
        .allowsHitTesting(!model.toasts.isEmpty)
        .animation(.spring(duration: 0.3), value: model.toasts.map(\.id))
    }
}

private struct ToastCard: View {
    let toast: ToastItem
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind.symbol)
                .foregroundStyle(toast.kind.tint)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.medium))
                if let body = toast.body {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = toast.action {
                    Button(action.label) { model.invokeToastAction(toast.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(toast.kind.tint)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.dismissToast(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.string("Dismiss"))
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#if DEBUG
#Preview("Toasts") {
    let m = AppModel()
    m.toasts = [
        ToastItem(kind: .success, title: "Starred ripgrep", body: nil, action: nil),
        ToastItem(kind: .error, title: "Star needs more access",
                  body: "Needs the \"public_repo\" GitHub permission. Click to grant it without signing out.",
                  action: ToastAction(label: "Re-authorize", handler: {})),
    ]
    return Color.clear.overlay { ToastOverlay(model: m) }
        .frame(width: 600, height: 400)
}
#endif
