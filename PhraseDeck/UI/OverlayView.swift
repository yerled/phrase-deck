import SwiftUI
import AppKit

struct OverlayView: View {
    let phrases: [Phrase]
    let onSelect: (Phrase, Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            glassDivider
            if phrases.isEmpty {
                Text("暂无短语。复制一段文字，或在菜单里手动添加。")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.65))
                    .padding(18)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(phrases.enumerated()), id: \.element.id) { index, phrase in
                        OverlayRow(
                            index: index,
                            phrase: phrase,
                            onSelect: { onSelect(phrase, index) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 440)
        .background(GlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.28),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("PhraseDeck")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("连按两次 ⌘ · 1–0 插入 · Esc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

private struct OverlayRow: View {
    let index: Int
    let phrase: Phrase
    let onSelect: () -> Void
    @State private var hovering = false

    private var keyLabel: String {
        index == 9 ? "0" : "\(index + 1)"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(keyLabel)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

                Text(phrase.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("×\(phrase.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Real macOS vibrancy / glass backdrop.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}
