import AppKit
import RegulusCore
import SwiftUI

/// ⌘ + 滚轮向上步进放大、向下步进缩小；只在只按 ⌘、鼠标位于这个视图上且窗口没有弹出面板时生效，其他滚动照常
/// ⌘ + scroll up steps bigger, down steps smaller; only with ⌘ alone, the pointer over this view and no sheet open,
/// other scrolling is untouched.
struct ModifierScrollZoom: ViewModifier {
    /// +1 放大，-1 缩小 / +1 bigger, -1 smaller.
    let onStep: (Int) -> Void
    @State private var state = ScrollZoomState()

    func body(content: Content) -> some View {
        content
            // 背后放一个透明 NSView，直接用它判断鼠标在不在这个视图上，不依赖 SwiftUI 坐标系；
            // 每次刷新都把最新的回调交给它，避免回调里读到旧的状态
            // A transparent NSView behind the content tells whether the pointer is over it, without SwiftUI coordinate
            // spaces; each update hands it the latest callback so the callback never reads stale state
            .background(ScrollZoomAnchor(state: state, onStep: onStep))
            .onAppear {
                // onAppear 可能不止一次，只注册一个监听，否则一次滚动会被处理多次
                // onAppear can run more than once; register a single monitor, or one scroll is handled several times
                guard state.monitor == nil else { return }
                let state = state
                state.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // 本地监听总在主线程回调 / local monitors are always called on the main thread
                    nonisolated(unsafe) let event = event
                    let consumed = MainActor.assumeIsolated {
                        guard let step = state.step(for: event) else { return false }
                        if step != 0 { state.onStep?(step) }
                        return true
                    }
                    // ⌘ 滚动被拿来缩放，不再滚动 / ⌘ scrolling zooms instead of scrolling
                    return consumed ? nil : event
                }
            }
            .onDisappear {
                if let monitor = state.monitor { NSEvent.removeMonitor(monitor) }
                state.monitor = nil
            }
    }
}

/// 不接收点击的透明视图，只用来定位 / A transparent view that takes no clicks; used only for locating.
struct ScrollZoomAnchor: NSViewRepresentable {
    let state: ScrollZoomState
    let onStep: (Int) -> Void

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        state.view = view
        state.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        state.onStep = onStep
    }
}

@MainActor
final class ScrollZoomState {
    /// 与目标视图同大小的透明视图 / The transparent view the size of the target view.
    weak var view: NSView?
    var monitor: Any?
    /// 最新的缩放回调 / The latest zoom callback.
    var onStep: ((Int) -> Void)?
    /// 触控板连续滚动累计的距离 / Distance accumulated from continuous trackpad scrolling.
    private var accumulated: CGFloat = 0
    private static let trackpadStep: CGFloat = 40

    /// nil：不是给这里的缩放滚动，原样放行；0：吞掉但不缩放；±1：缩放一步
    /// nil: not a zoom scroll for this view, pass it on; 0: swallow without zooming; ±1: zoom one step.
    func step(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags == .command, let view, let window = view.window, event.window === window,
              window.attachedSheet == nil,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        else {
            accumulated = 0
            return nil
        }
        // 松手后的惯性滚动不算 / ignore momentum after the fingers lift
        guard event.momentumPhase.isEmpty else { return 0 }
        // 换算成物理方向：开了「自然滚动」时系统给的 delta 是反的 / physical direction: natural scrolling flips the delta
        var delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // 鼠标滚轮每格一步；触控板累计一段距离才走一步 / a wheel notch is one step; a trackpad must travel a distance
        if event.hasPreciseScrollingDeltas {
            accumulated += delta
            guard abs(accumulated) >= Self.trackpadStep else { return 0 }
            delta = accumulated
            accumulated = 0
        }
        if delta > 0 { return 1 }
        if delta < 0 { return -1 }
        return 0
    }
}
