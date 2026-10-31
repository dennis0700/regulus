import AVKit
import RegulusCore
import SwiftUI

/// 视频预览，铺满主窗口，打开就播放：进度条、音量、全屏用系统的悬浮控件；工具栏有上一个 / 下一个视频（← →，跳过照片）、
/// 后退 / 快进 10 秒（J / L）、播放 / 暂停（空格）和倍速；离开时停止
/// Video preview filling the main window, playing on open: progress bar, volume and full screen come from the system's
/// floating controls; the toolbar has previous / next video (← →, skipping photos), back / forward 10 s (J / L),
/// play / pause (space) and speed; it stops when left.
struct VideoPreview: View {
    let library: LibraryModel
    let photo: LibraryPhoto
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var speed: Float = 1

    private static let seekStep: Double = 10
    private static let speeds: [Float] = [0.5, 1, 1.5, 2]

    var body: some View {
        PlayerView(player: player)
            .contextMenu { PhotoContextMenu(library: library, photo: photo) }
            .toolbar { ToolbarItemGroup(placement: .principal) { controls } }
            .task(id: photo.url) {
                player.replaceCurrentItem(with: AVPlayerItem(url: photo.url))
                player.play()
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { isPlaying = $0 != .paused }
            .onDisappear { player.replaceCurrentItem(with: nil) }
    }

    @ViewBuilder
    private var controls: some View {
        Button { library.stepVideo(by: -1) } label: { Label("上一个视频", systemImage: "backward.end.fill") }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!library.canStepVideo(by: -1))
            .help("上一个视频（←）")
        Button { seek(by: -Self.seekStep) } label: { Label("后退 10 秒", systemImage: "gobackward.10") }
            .keyboardShortcut("j", modifiers: [])
            .help("后退 10 秒（J）")
        Button { isPlaying ? player.pause() : player.play() } label: {
            Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(isPlaying ? "暂停（空格）" : "播放（空格）")
        Button { seek(by: Self.seekStep) } label: { Label("快进 10 秒", systemImage: "goforward.10") }
            .keyboardShortcut("l", modifiers: [])
            .help("快进 10 秒（L）")
        Button { library.stepVideo(by: 1) } label: { Label("下一个视频", systemImage: "forward.end.fill") }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!library.canStepVideo(by: 1))
            .help("下一个视频（→）")
        Picker("倍速", selection: $speed) {
            ForEach(Self.speeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("播放速度")
        .onChange(of: speed) {
            // defaultRate 决定之后 play() 的速度，播放中的同时改当前速度 / defaultRate sets the speed of later play()
            // calls; while playing, change the current rate too
            player.defaultRate = speed
            if isPlaying { player.rate = speed }
        }
    }

    /// 前后跳 seconds 秒，限制在 0 到片长之间 / Jump by seconds, clamped to the clip.
    private func seek(by seconds: Double) {
        let now = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        var target = max(now + seconds, 0)
        if duration.isFinite { target = min(target, duration) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// AVPlayerView 的悬浮控件自带可拖动的进度条、音量和全屏 / AVPlayerView's floating controls come with a scrubbable
/// progress bar, volume and full screen.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
