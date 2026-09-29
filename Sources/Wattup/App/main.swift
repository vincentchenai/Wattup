import AppKit

// Wattup 入口。
//
// 这里刻意不用 SwiftUI 的 `MenuBarExtra`：在 SwiftPM 手工组装的 .app bundle 下
// 实测状态栏项不会出现，而 `NSStatusItem` + `NSPopover` 完全可控、不依赖 bundle 细节。
// 界面本身仍然是 SwiftUI，通过 NSHostingController 承载。

MainActor.assumeIsolated {
    let application = NSApplication.shared
    // 顶层 `let` 在进程生命周期内一直存活，保证 delegate 不被释放（NSApplication.delegate 是 weak）
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
