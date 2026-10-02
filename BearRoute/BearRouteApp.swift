//
//  BearRouteApp.swift
//  Bear Route
//
//  Created by Jacob Quion on 7/30/26.
//

import SwiftUI

@main
struct BearRouteApp: App {
    init() {
        // The default shared cache ships with 0 MB memory and ~10 MB disk, so
        // branch and dining photos — which the server marks cacheable for a year
        // — kept re-downloading on every scroll, day change, and relaunch. Give
        // it a real budget so those images come straight from cache.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB
            diskCapacity: 256 * 1024 * 1024     // 256 MB
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
