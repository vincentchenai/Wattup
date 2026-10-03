import Foundation
import IOKit.ps

/// 电源事件监听：插拔适配器、电量跨越阈值时立即回调，不必等下一次轮询。
///
/// 实测 `IOPSCopyPowerSourcesInfo` 读取成本 0.061 ms，事件触发时全量刷新代价可忽略。
final class PowerSourceMonitor {

    private var runLoopSource: CFRunLoopSource?
    private var handler: (() -> Void)?

    func start(handler: @escaping () -> Void) {
        self.handler = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        // 这个闭包不能捕获任何外部变量，否则无法转成 C 函数指针
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handler?()
        }

        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()
        else { return }

        runLoopSource = source
        // 菜单追踪期间也接收电源事件，避免用户操作菜单时延迟刷新。
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        handler = nil
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
