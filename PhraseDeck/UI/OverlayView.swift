import SwiftUI
import AppKit

struct OverlayView: View {
    @ObservedObject var controller: OverlayPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            glassDivider
            content
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

    @ViewBuilder
    private var content: some View {
        switch controller.presentation {
        case .phrases:
            if controller.phrases.isEmpty {
                Text("暂无短语。在飞书或 Cursor 发送消息后等待 AI 总结，或在菜单里手动添加。")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.65))
                    .padding(18)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(controller.phrases.enumerated()), id: \.element.id) { index, phrase in
                        OverlayRow(
                            index: index,
                            title: phrase.text,
                            badge: "×\(phrase.count)",
                            onSelect: { controller.selectPhrase(phrase) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        case .smartReply:
            if !controller.smartStatus.isEmpty, controller.smartSuggestions.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(controller.smartStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.7))
                }
                .padding(18)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = controller.smartNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                    VStack(spacing: 2) {
                        ForEach(Array(controller.smartSuggestions.enumerated()), id: \.element.id) { index, item in
                            OverlayRow(
                                index: index,
                                title: item.text,
                                badge: item.direction,
                                onSelect: { controller.selectSuggestion(item) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: controller.presentation == .smartReply ? "sparkles" : "text.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(controller.presentation == .smartReply ? "智能回复" : "PhraseDeck")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(controller.presentation == .smartReply ? "连按三次 ⌘ · 1–6 插入 · Esc" : "连按两次 ⌘ · 1–0 插入 · Esc")
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
    let title: String
    let badge: String
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

                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(badge)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.4))
                    .lineLimit(1)
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
