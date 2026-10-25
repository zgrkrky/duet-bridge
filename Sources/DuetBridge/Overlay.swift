import AppKit

@MainActor
final class OverlayWindow {
    private let window: NSWindow
    private let fillLayer = CALayer()
    private let titleField = NSTextField(labelWithString: "Duet")
    private let valueField = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 300, height: 92)

    init() {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        window.contentView = content

        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.frame = NSRect(x: 22, y: 54, width: 180, height: 20)
        content.addSubview(titleField)

        valueField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        valueField.alignment = .right
        valueField.frame = NSRect(x: 196, y: 54, width: 82, height: 20)
        content.addSubview(valueField)

        let trackLayer = CALayer()
        trackLayer.frame = CGRect(x: 22, y: 26, width: 256, height: 8)
        trackLayer.cornerRadius = 4
        trackLayer.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        content.layer?.addSublayer(trackLayer)

        fillLayer.frame = CGRect(x: 22, y: 26, width: 0, height: 8)
        fillLayer.cornerRadius = 4
        content.layer?.addSublayer(fillLayer)
    }

    func show(target: OutputTarget, output: OutputState) {
        let range = GlueClient.gainRange
        let normalized = (output.gain - range.lowerBound) / (range.upperBound - range.lowerBound)
        titleField.stringValue = "Duet \(target.label)" + (output.dimmed ? " · Dim" : "")
        valueField.stringValue = output.muted ? L("Muted", "Sessiz") : String(format: "%.0f dB", output.gain)
        valueField.textColor = output.muted ? .systemRed : .labelColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame.size.width = CGFloat(normalized.clamped(to: 0...1)) * 256
        fillLayer.backgroundColor = (output.muted ? NSColor.systemRed.withAlphaComponent(0.5) : NSColor.controlAccentColor).cgColor
        CATransaction.commit()

        position()
        window.alphaValue = 1
        window.orderFrontRegardless()
        scheduleHide()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 120))
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                if self?.window.alphaValue == 0 { self?.window.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
