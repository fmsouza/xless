import SwiftUI
import UIKit

@main
struct M7AcceptanceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Receives the APNs device token: the push capability is what the acceptance provisions (#105, step 4).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .registeredForPush, object: nil)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .registeredForPush, object: error)
    }
}

extension Notification.Name {
    static let registeredForPush = Notification.Name("registeredForPush")
}
