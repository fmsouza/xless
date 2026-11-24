import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    @State private var status = "Built, signed and shipped by xless"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.fill").font(.system(size: 96)).foregroundStyle(.blue)
            Text("Hello from Linux").font(.largeTitle.bold())
            Text(status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Allow notifications") { Task { await allow() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .onReceive(NotificationCenter.default.publisher(for: .registeredForPush)) { note in
            status = note.object == nil ? "Registered for push notifications" : "Push registration failed"
        }
    }

    @MainActor
    private func allow() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        status = granted ? "Notifications allowed" : "Notifications not allowed"
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }
}
