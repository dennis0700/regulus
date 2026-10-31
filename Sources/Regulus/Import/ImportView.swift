import AppKit
import RegulusCore
import SwiftUI

struct ImportView: View {
    let model: ImportModel
    /// 关闭导入面板 / Close the import sheet.
    let onDone: () -> Void
    @State private var pickingSource = false
    @State private var pickingDestination = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导入照片").font(.title2.weight(.semibold))
            sourceSection
            destinationSection
            Divider()
            actionSection
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("完成", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isTransferring)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 520, alignment: .topLeading)
        .interactiveDismissDisabled(model.isTransferring)
        .onAppear { model.refreshCards() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshCards()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshCards()
        }
        .onChange(of: model.cameras) { model.dropRemovedSelection() }
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { model.chooseFolder(url) }
        }
        .fileImporter(isPresented: $pickingDestination, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { model.setDestination(url) }
        }
    }

    private var isBusy: Bool { model.isBusy }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源").font(.headline)
            Picker("来源类型", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
                ForEach(ImportModel.SourceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isBusy)

            switch model.kind {
            case .folder: folderSource
            case .card: cardSource
            case .camera: cameraSource
            }
        }
    }

    private var folderSource: some View {
        HStack {
            Button("选择文件夹…") { pickingSource = true }.disabled(isBusy)
            if case let .folder(url) = model.selection {
                Text(url.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var cardSource: some View {
        if model.cards.isEmpty {
            Text("未检测到存储卡。插入读卡器，或把相机的 USB 连接设为大容量存储模式后会自动出现。")
                .foregroundStyle(.secondary)
        }
        ForEach(model.cards, id: \.self) { card in
            SourceRow(title: card.lastPathComponent, systemImage: "sdcard",
                      isSelected: model.selection == .card(card), isDisabled: isBusy) {
                model.chooseCard(card)
            }
        }
    }

    @ViewBuilder
    private var cameraSource: some View {
        if model.cameras.isEmpty {
            Text("未检测到相机。用 USB 连接相机，并把相机的 USB 连接设为 PTP（部分机型标为 MTP/PTP）。")
                .foregroundStyle(.secondary)
        }
        ForEach(model.cameras, id: \.self) { camera in
            SourceRow(title: camera.name ?? String(localized: "相机"), systemImage: "camera",
                      isSelected: model.selection == .camera(camera), isDisabled: isBusy) {
                model.chooseCamera(camera)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入到照片库").font(.headline)
            HStack {
                Button(model.destination == nil ? "选择文件夹…" : "更改…") { pickingDestination = true }.disabled(isBusy)
                Text(model.destination?.path ?? String(localized: "尚未选择"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text("这个文件夹就是照片库。照片和视频会按「类型 / 年月日」整理（如 Raw/20261025、Video/20261025），原文件不会被修改；只有勾选「导入后删除」时才会删除。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch model.phase {
        case .idle:
            Text("请选择来源。").foregroundStyle(.secondary)
        case .scanning:
            HStack {
                ProgressView().controlSize(.small)
                Text(model.isCameraSource ? "正在读取相机中的照片列表…" : "正在扫描照片…")
            }
        case .ready:
            readyView
        case .importing:
            importingView
        case .deleting:
            HStack {
                ProgressView().controlSize(.small)
                Text(model.isCameraSource ? "正在删除相机里已导入的原文件…" : "正在删除存储卡上已导入的原文件…")
            }
        case .finished:
            finishedView
        }
        if let message = model.errorMessage {
            Text(message).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.files.isEmpty {
                Text("没有找到照片。").foregroundStyle(.secondary)
            } else {
                let size = model.totalBytes.formatted(.byteCount(style: .file))
                Text("找到 \(model.files.count) 个文件，共 \(size)。")
            }
            if !model.files.isEmpty && model.canDeleteSource {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(model.isCameraSource ? "导入后删除相机里的原文件" : "导入后删除存储卡上的原文件",
                           isOn: Binding(get: { model.deletesSourceAfterImport },
                                         set: { model.deletesSourceAfterImport = $0 }))
                    Text("只删除已校验复制到照片库、或照片库里已有的文件；导入失败、取消导入、相机里设了保护的照片都会保留。删除后无法恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("开始导入") {
                if model.deletesSourceAfterImport && model.canDeleteSource {
                    confirmingDelete = true
                } else {
                    model.startImport()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)
            .confirmationDialog("导入后删除原文件？", isPresented: $confirmingDelete) {
                Button("导入并删除原文件", role: .destructive) { model.startImport() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(model.isCameraSource ? "导入完成后，已安全导入的 \(model.files.count) 个文件中的原文件会从相机里删除，无法恢复。"
                     : "导入完成后，已安全导入的 \(model.files.count) 个文件中的原文件会从存储卡里删除，无法恢复。")
            }
            if model.isCameraSource {
                Text("通过 USB 从相机导入通常比读卡器慢。已导入过的同名照片需要重新下载一次来比对内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.destination == nil && !model.files.isEmpty {
                Text("请先选择导入到的文件夹。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var importingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let done = model.progress?.completed ?? 0
            let total = max(model.progress?.total ?? model.files.count, 1)
            ProgressView(value: Double(done), total: Double(total))
                .accessibilityLabel("导入进度")
                .accessibilityValue("\(done) / \(total)")
            Text("正在导入 \(done) / \(total)  \(model.progress?.file ?? "")")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("取消") { model.cancelImport() }
        }
    }

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text("已复制 \(report.copied) 个，已存在跳过 \(report.skipped) 个，失败 \(report.failed) 个。")
                    .font(.headline)
                if !model.failures.isEmpty {
                    DisclosureGroup("失败的文件") {
                        ForEach(model.failures, id: \.name) { failure in
                            Text("\(failure.name)：\(failure.reason)").textSelection(.enabled)
                        }
                    }
                }
            }
            if let deletion = model.deletion {
                Text(deletionSummary(deletion))
                if !deletion.failures.isEmpty {
                    DisclosureGroup("未删除的文件") {
                        ForEach(Array(deletion.failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.name)：\(failure.reason)").textSelection(.enabled)
                        }
                    }
                }
            }
            HStack {
                if let destination = model.destination {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                }
                Button("重新选择来源") { model.reset() }
            }
        }
    }
}

/// 删除原文件的结果 / The outcome of deleting the originals.
private extension ImportView {
    func deletionSummary(_ deletion: DeletionReport) -> String {
        let deleted = model.isCameraSource ? String(localized: "已从相机删除 \(deletion.deleted) 个原文件")
            : String(localized: "已从存储卡删除 \(deletion.deleted) 个原文件")
        guard !deletion.failures.isEmpty else { return String(localized: "\(deleted)。") }
        return String(localized: "\(deleted)，\(deletion.failures.count) 个未能删除（已保留）。")
    }
}

/// 存储卡或相机的一行：选中时高亮并打勾 / One card or camera row; highlighted with a checkmark when selected.
private struct SourceRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 320)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
