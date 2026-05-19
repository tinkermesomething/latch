import AppKit
import UserNotifications

enum NotificationManager {

    /// Request permission lazily — only prompts once; subsequent calls are no-ops if already determined.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            log("NotificationManager: authorizationStatus=\(settings.authorizationStatus.rawValue)")
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error {
                        log("NotificationManager: requestAuthorization error — \(error)")
                    } else {
                        log("NotificationManager: permission \(granted ? "granted" : "denied")")
                    }
                }
            case .denied:
                log("NotificationManager: denied — prompting user once per version")
                let version   = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let shownFor  = UserDefaults.standard.string(forKey: "notifDeniedAlertVersion")
                guard shownFor != version else { return }
                UserDefaults.standard.set(version, forKey: "notifDeniedAlertVersion")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText     = "Notifications are disabled"
                    alert.informativeText = "latch notifications are off. Go to System Settings → Notifications → latch to enable them."
                    alert.alertStyle      = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                        )
                    }
                }
            case .authorized, .provisional, .ephemeral:
                log("NotificationManager: already authorised (\(settings.authorizationStatus.rawValue))")
            @unknown default:
                log("NotificationManager: unknown authorizationStatus \(settings.authorizationStatus.rawValue)")
            }
        }
    }

    static func send(title: String, body: String) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content:    content,
            trigger:    nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("NotificationManager: failed — \(error)") }
        }
    }
}
