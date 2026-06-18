import UIKit

@MainActor
enum ChatHaptics {
    static func send() {
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    static func error() {
        if UserSettings.haptics {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
