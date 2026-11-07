import AppKit
import UserNotifications

@MainActor
final class ExportFeedback: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExportFeedback()
    private var authorization: Task<Bool, Never>?
    private var dockView: DockProgressView?

    func begin() {
        if authorization == nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            authorization = Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        }
        let view = DockProgressView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        dockView = view
        NSApp.dockTile.contentView = view
    }

    func update(progress: Double, remaining: Int) {
        dockView?.progress = progress
        dockView?.needsDisplay = true
        NSApp.dockTile.badgeLabel = String(remaining)
        NSApp.dockTile.display()
    }

    func finish(exported: Int, failed: Int, stopped: Bool) {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        dockView = nil
        guard !stopped, !NSApp.isActive else { return }
        Task {
            guard await authorization?.value == true, !NSApp.isActive else { return }
            let content = UNMutableNotificationContent()
            content.title = failed == 0 ? "Exported \(exported) files" : "\(exported) exported, \(failed) failed"
            content.body = "Open Waifu2x-Mac to view your export results."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class DockProgressView: NSView {
    var progress = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let track = CGRect(x: 12, y: 10, width: bounds.width - 24, height: 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
        let fill = CGRect(x: track.minX + 2, y: track.minY + 2,
                          width: (track.width - 4) * min(1, max(0, progress)), height: track.height - 4)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
    }
}
