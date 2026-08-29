import SwiftUI
import AppKit

struct OverlayView: View {
    let phrases: [Phrase]
    let onSelect: (Phrase, Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PhraseDeck")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥⌘Space · 1–0 插入 · Esc 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if phrases.isEmpty {
                Text("暂无短语。复制一段文字，或在菜单里手动添加。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(Array(phrases.enumerated()), id: \.element.id) { index, phrase in
                    OverlayRow(
                        index: index,
                        phrase: phrase,
                        onSelect: { onSelect(phrase, index) }
                    )
                    if index < phrases.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}

private struct OverlayRow: View {
    let index: Int
    let phrase: Phrase
    let onSelect: () -> Void

    private var keyLabel: String {
        index == 9 ? "0" : "\(index + 1)"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(keyLabel)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(phrase.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("×\(phrase.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
