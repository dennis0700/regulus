import ImageCaptureCore
import Testing
@testable import RegulusCore

/// ICDeviceBrowser 的 delegate 不持有对象：CameraBrowser 释放后必须已经停止浏览并清空 delegate，
/// 否则之后的设备插拔会回调已释放的内存（实际发生过的崩溃）。
/// ICDeviceBrowser does not retain its delegate: once CameraBrowser is gone, browsing must have stopped
/// and the delegate must be cleared, or a later plug/unplug calls into freed memory (a crash we hit).
@MainActor
@Test func releasingCameraBrowserStopsBrowsingAndClearsDelegate() async {
    var owner: CameraBrowser? = CameraBrowser()
    weak let weakOwner = owner
    let deviceBrowser = owner!.browser
    #expect(deviceBrowser.delegate === owner)
    owner = nil
    // isolated deinit 可能被调度到主线程稍后执行 / an isolated deinit may be scheduled on the main actor
    for _ in 0..<50 where deviceBrowser.delegate != nil || weakOwner != nil {
        await Task.yield()
    }
    #expect(weakOwner == nil)
    #expect(deviceBrowser.delegate == nil)
    // 不检查 isBrowsing：实测它在 start() 之后也可能一直是 false，不能反映 stop() 是否生效
    // isBrowsing is not checked: measured, it can stay false even after start(), so it says nothing about stop().
}
