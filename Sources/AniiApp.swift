// SPDX-License-Identifier: GPL-3.0-only
// Independent iPadOS player, originally authored 2026-10-10.

import SwiftUI

@main
struct AniiApp: App {
    var body: some Scene {
        WindowGroup {
            PlayerView()
                .preferredColorScheme(.dark)
        }
    }
}
