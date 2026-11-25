import SwiftUI

struct ContentView: View {
    @State private var taps = 0

    private var accent: Color {
        #if os(iOS)
        Color("AccentBlue")   // from Assets.car (exercises the colorset path)
        #else
        Color.blue            // macOS milestone 1 ships .icns only, no Assets.car
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill").font(.system(size: 64)).foregroundStyle(accent)
            Text("Hello from xless").font(.title.bold())
            Button("Tapped \(taps) times") { taps += 1 }.buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}
