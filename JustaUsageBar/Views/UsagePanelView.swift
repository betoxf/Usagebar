//
//  UsagePanelView.swift
//  JustaUsageBar
//
//  The panel that opens from the menu bar: one card per provider with its
//  mark, plan, usage meters and reset times. Matches the Windows and Linux
//  flyout in desktop/ui.
//

import AppKit
import Combine
import SwiftUI

struct UsagePanelRow: Identifiable {
    let label: String
    let percent: Int
    let resetText: String
    var id: String { label }
}

struct UsagePanelCard: Identifiable {
    let provider: DisplayProvider
    let detail: String
    let rows: [UsagePanelRow]
    /// An error or "Not connected", shown under the rows.
    var message: String?
    /// A button under the message, e.g. "Connect Claude".
    var actionTitle: String?
    var id: DisplayProvider { provider }
}

/// What the panel shows. `AppDelegate` fills it from the normalized usage
/// models and handles the actions.
final class UsagePanelModel: ObservableObject {
    @Published var cards: [UsagePanelCard] = []
    @Published var currentProvider: DisplayProvider?
    @Published var updatedText = ""
    @Published var updateVersion: String?
    @Published var isRefreshing = false
    /// No provider is signed in; the panel offers setup instead of cards.
    @Published var needsSetup = false

    var cursorMarks: NSImage?
    var zcodeMark: NSImage?

    var onSelect: (DisplayProvider) -> Void = { _ in }
    var onAction: (DisplayProvider) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onMore: (NSView) -> Void = { _ in }
    var onUpdate: () -> Void = {}
    var onSetup: () -> Void = {}
    var onQuit: () -> Void = {}
}

struct UsagePanelView: View {
    @ObservedObject var model: UsagePanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.needsSetup {
                setup
            } else {
                VStack(spacing: 6) {
                    ForEach(model.cards) { card in
                        UsagePanelCardView(
                            card: card,
                            isInMenuBar: card.provider == model.currentProvider,
                            model: model
                        )
                    }
                }
            }
            footer
        }
        .padding(10)
        .frame(width: 340)
        .font(.system(size: 13))
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                // The plain icon, without the tile macOS puts app icons on.
                Image("PanelIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text("Usagebar").fontWeight(.semibold)
            }
            Spacer()
            Text(model.updatedText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            PanelIconButton(systemName: "arrow.clockwise", help: "Refresh", spinning: model.isRefreshing) {
                model.onRefresh()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var setup: some View {
        VStack(spacing: 8) {
            Text("Welcome to Usagebar").fontWeight(.semibold)
            Text("Connect the AI tools you use to see your limits here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set Up Usagebar…") { model.onSetup() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let version = model.updateVersion {
                PanelTextButton(title: "Update to v\(version)", color: Color(nsColor: .usagebarClaudeOrange)) {
                    model.onUpdate()
                }
            } else {
                Text(model.needsSetup ? "" : "Click a provider to show it in the bar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            MoreButton(model: model)
            PanelTextButton(title: "Quit") { model.onQuit() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct UsagePanelCardView: View {
    let card: UsagePanelCard
    let isInMenuBar: Bool
    @ObservedObject var model: UsagePanelModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderMark(provider: card.provider, cursorMarks: model.cursorMarks, zcodeMark: model.zcodeMark)
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 4)
                Circle()
                    .strokeBorder(isInMenuBar ? Color.primary : Color.secondary, lineWidth: 1.5)
                    .background(Circle().fill(isInMenuBar ? Color.primary : Color.clear))
                    .frame(width: 8, height: 8)
            }
            .frame(height: 18)

            ForEach(card.rows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    UsageMeter(percent: row.percent, fill: meterColor)
                    Text("\(row.percent)%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                    Text(row.resetText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }

            if let message = card.message {
                // "Not connected" has no rows and isn't an error.
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(card.rows.isEmpty ? Color.secondary : Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle = card.actionTitle {
                Button(actionTitle) { model.onAction(card.provider) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { model.onSelect(card.provider) }
        .help(isInMenuBar ? "Shown in the menu bar" : "Show in the menu bar")
    }

    private var meterColor: Color {
        card.provider == .claude ? Color(nsColor: .usagebarClaudeOrange) : .primary
    }

    private var cardFill: Color {
        switch (colorScheme, hovering) {
        case (.dark, false): Color.white.opacity(0.05)
        case (.dark, true): Color.white.opacity(0.09)
        case (_, false): Color.white.opacity(0.66)
        case (_, true): Color.white.opacity(0.92)
        }
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }
}

/// A provider's mark, as the panel and the setup window show it.
struct ProviderMark: View {
    let provider: DisplayProvider
    let cursorMarks: NSImage?
    let zcodeMark: NSImage?

    var body: some View {
        switch provider {
        case .claude:
            HStack(spacing: 6) {
                templateImage(NSImage(named: "ClaudeSpark"), height: 15)
                    .foregroundStyle(Color(nsColor: .usagebarClaudeOrange))
                Text("Claude").fontWeight(.semibold)
            }
        case .codex:
            if let lockup = NSImage(named: "CodexLockup") {
                templateImage(lockup, height: 16)
            } else {
                Text("Codex").fontWeight(.semibold)
            }
        case .cursor:
            templateImage(cursorMarks, height: 12)
        case .kimi:
            if NSImage(named: "KimiCodeLogo") != nil {
                Image("KimiCodeLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 13)
            } else {
                Text("Kimi Code").fontWeight(.semibold)
            }
        case .zai:
            HStack(spacing: 1.7) {
                templateImage(zcodeMark, height: 10.6)
                Text("Code").fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder private func templateImage(_ image: NSImage?, height: CGFloat) -> some View {
        if let image, image.size.height > 0 {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: height * image.size.width / image.size.height, height: height)
        }
    }
}

private struct UsageMeter: View {
    let percent: Int
    let fill: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09))
                Capsule()
                    .fill(fill)
                    .frame(width: proxy.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: percent)
    }
}

private struct PanelIconButton: View {
    let systemName: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct PanelTextButton: View {
    let title: String
    var color: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Opens the settings menu (Display, Launch at Login, sign-out, updates) under itself.
private struct MoreButton: View {
    @ObservedObject var model: UsagePanelModel
    @State private var anchor: NSView?

    var body: some View {
        PanelIconButton(systemName: "ellipsis", help: "Settings") {
            if let anchor { model.onMore(anchor) }
        }
        .background(AnchorView(view: $anchor))
    }
}

/// Exposes the AppKit view behind a SwiftUI view, to anchor an `NSMenu` popup.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async { view = nsView }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSColor {
    /// Claude's orange from its spark mark, #D97757.
    static let usagebarClaudeOrange = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
}

/// A borderless panel under the status item that closes on an outside click
/// or Escape. It doesn't activate the app, like a menu.
final class UsagePanel: NSPanel {
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    var onClose: () -> Void = {}

    init(rootView: UsagePanelView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        // The content is a sibling above the blur, not inside it, so text
        // keeps its solid colors instead of turning vibrant (lighter).
        let hosting = NSHostingView(rootView: rootView)
        for view in [effect, hosting] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel centered under `button`, inside the screen.
    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = contentView?.fittingSize ?? NSSize(width: 340, height: 300)
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        let x = min(max(buttonFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonFrame.minY - size.height - 6
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    /// Keeps the top edge in place when the content grows or shrinks.
    func fitContent() {
        guard isVisible, let size = contentView?.fittingSize, size.height != frame.height else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    override func close() {
        stopMonitoring()
        super.close()
        onClose()
    }

    private func startMonitoring() {
        stopMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isKeyWindow == true else { return event }
            self?.close()
            return nil
        }
    }

    private func stopMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }
}
