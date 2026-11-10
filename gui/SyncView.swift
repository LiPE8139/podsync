import SwiftUI

struct SyncView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            deviceHeader
            Divider()
            actionBar
            Divider()
            trackTable
        }
        .safeAreaInset(edge: .bottom) {
            if showStatusBar { statusBar }
        }
        .searchable(text: $model.filterQuery, placement: .toolbar, prompt: "歌曲 / 歌手 / 专辑")
        .navigationTitle(t("同步到 iPod"))
        .navigationSubtitle("\(model.pending.count) 首 · 未同步 \(unsyncedCount) 首")
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showDuplicates) { DuplicateSheet() }
        .sheet(isPresented: $model.showLog) { logSheet }
        .confirmationDialog("清理已删除歌曲？", isPresented: $model.confirmPrune,
                            titleVisibility: .visible) {
            Button("开始清理", role: .destructive) { model.runPrune() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(t("会移除文件已不存在的曲目记录、删除 iPod 上不在记录中的孤儿文件，并重建原厂数据库。Rockbox 的 /Music 与 .crazypod 不受影响。"))
        }
        .onAppear {
            if model.pending.isEmpty { model.loadPending() }
        }
    }

    private var unsyncedCount: Int {
        model.pending.filter { $0.status == "new" }.count
    }

    private var deviceHeader: some View {
        HStack(alignment: .center, spacing: Design.sectionSpacing) {
            DeviceImage(height: 52,
                        color: model.deviceColorOverride.isEmpty
                            ? model.deviceColor : model.deviceColorOverride)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Design.spacing) {
                    Text(model.deviceMounted ? model.deviceModel
                         : (model.deviceAttached ? "iPod（已推出）" : "未连接"))
                        .font(.title3.weight(.semibold))
                    if model.deviceAttached && !model.deviceMounted {
                        Button {
                            model.mountDevice()
                        } label: {
                            Label(t("挂载"), systemImage: "externaldrive.badge.checkmark")
                        }
                        .controlSize(.small)
                        .disabled(model.running || model.ejecting)
                        .help(t("重新挂载已连接的 iPod"))
                        .accessibilityLabel("挂载 iPod")
                    }
                    Button {
                        model.ejectDevice()
                    } label: {
                        Label(t("推出"), systemImage: "eject.fill")
                    }
                    .controlSize(.small)
                    .disabled(!model.deviceAttached || model.running || model.ejecting)
                    .help(t("安全推出 iPod（拔线前使用）"))
                    .accessibilityLabel("推出 iPod")
                    Button {
                        model.refreshCrazypodCache()
                    } label: {
                        Label(t("Rockbox"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(!model.deviceMounted || model.running || model.ejecting)
                    .help(t("刷新 Rockbox 曲库缓存（同步后新歌在 Rockbox 中可见）"))
                    .accessibilityLabel("刷新 Rockbox 曲库缓存")
                }
                Text(model.deviceMounted
                     ? [model.deviceRockbox.isEmpty ? "" : "CrazyPod / Rockbox \(model.deviceRockbox)",
                        "已同步 \(model.syncedCount) 首"].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                     : (model.deviceAttached
                        ? "设备仍连接但未挂载：点「挂载」继续同步，或直接拔线"
                        : "请连接 iPod"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Design.spacing) {
                    ProgressView(value: model.deviceUsedFraction)
                        .frame(width: 220)
                        .disabled(!model.deviceMounted)
                    Text(model.deviceMounted ? model.capacityText : "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !model.ejectMessage.isEmpty {
                    Text(model.ejectMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    model.openInbox()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(t("收件箱"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(t("打开收件箱"))
                .accessibilityLabel("打开收件箱")
                Text("\(model.inboxFileCount) 首待处理").font(.body)
            }
        }
        .padding(Design.sectionSpacing)
        .background(.bar)
    }

    private var trackTable: some View {
        Table(model.filteredPending, selection: $model.selectedPending) {
            TableColumn("") { track in
                Toggle("", isOn: Binding(
                    get: { model.isSelected(track.id) },
                    set: { model.setSelected(track.id, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("选择 \(track.title)")
                .accessibilityLabel("选择 \(track.title)")
            }
            .width(28)

            TableColumn(t("歌曲名")) { track in
                HStack(spacing: Design.spacing / 2) {
                    CoverThumbnail(url: imageURL(track.cover), size: 24)
                    Text(track.title).lineLimit(1)
                }
            }
            TableColumn(t("歌手")) { track in
                Text(track.artist).lineLimit(1)
            }
            TableColumn(t("专辑")) { track in
                Text(track.album).lineLimit(1).foregroundStyle(.secondary)
            }
            TableColumn(t("同步状态")) { track in
                StatusBadge(status: track.status)
            }
            TableColumn(t("时长")) { track in
                Text(durationText(track.duration)).monospacedDigit()
            }
        }
        .overlay {
            if model.filteredPending.isEmpty {
                ContentUnavailableView {
                    Label(t("没有曲目"), systemImage: "music.note.list")
                } description: {
                    Text(model.pending.isEmpty
                         ? "收件箱里还没有歌。先去「下载音乐」下载，这里会显示待同步曲目。"
                         : "换个关键词或筛选条件试试。")
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Design.spacing) {
            Text("已选 \(model.selectedPending.count) 首（只同步未同步曲目）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.loadPending()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.running)
            .help(t("刷新曲目列表（重新扫描收件箱与曲库）"))
            .accessibilityLabel("刷新曲目列表")
            Button {
                model.confirmPrune = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.running)
            .help(t("清理已删除歌曲（移除失效记录与孤儿文件）"))
            .accessibilityLabel("清理已删除歌曲")
            Button(t("同步选中")) { model.syncSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedPending.isEmpty || model.running)
                .help(t("只把勾选的未同步曲目写入 iPod"))
            Button(t("同步全部未同步")) { model.startSync() }
                .disabled(unsyncedCount == 0 || model.running)
                .help(t("把收件箱里所有未同步曲目写入 iPod（⌘R）"))
            if model.running {
                ProgressView().controlSize(.small)
                Text(model.summary.isEmpty ? "处理中…" : model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !model.cacheMessage.isEmpty {
                Text(model.cacheMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !model.pruneMessage.isEmpty {
                Text(model.pruneMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Design.sectionSpacing)
        .padding(.vertical, Design.spacing)
        .background(.bar)
    }

    private var showStatusBar: Bool {
        model.running || !model.cacheMessage.isEmpty || !model.pruneMessage.isEmpty || !model.summary.isEmpty
    }

    private var statusBar: some View {
        HStack(spacing: Design.spacing) {
            if model.running {
                ProgressView().controlSize(.small)
                Text(model.summary.isEmpty ? "处理中…" : model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !model.cacheMessage.isEmpty {
                Text(model.cacheMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !model.pruneMessage.isEmpty {
                Text(model.pruneMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, Design.sectionSpacing)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("歌手", selection: $model.filterArtist) {
                Text(t("全部歌手")).tag("")
                ForEach(model.pendingArtists.filter { $0 != "全部歌手" }, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .help(t("按歌手筛选"))

            Picker("专辑", selection: $model.filterAlbum) {
                Text(t("全部专辑")).tag("")
                ForEach(model.pendingAlbums.filter { $0 != "全部专辑" }, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .help(t("按专辑筛选"))

            Button(t("全选")) { model.selectAllPending() }
                .disabled(model.filteredPending.isEmpty)
                .help(t("选中当前筛选结果里的全部曲目"))
            Button(t("反选")) { model.invertPendingSelection() }
                .disabled(model.filteredPending.isEmpty)
                .help(t("反转当前筛选结果的选择状态"))
            Button {
                model.showLog = true
            } label: {
                Label(t("日志"), systemImage: "text.alignleft")
            }
            .labelStyle(.iconOnly)
            .help(t("查看同步日志"))
            .accessibilityLabel("查看同步日志")
        }
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: Design.spacing) {
            HStack {
                Text(t("同步日志")).font(.headline)
                Spacer()
                Button(t("关闭")) { model.showLog = false }
            }
            ScrollView {
                Text(model.log.isEmpty ? "还没有日志。" : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Design.sectionSpacing)
        .frame(width: 640, height: 420)
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        let symbol: String = {
            switch status {
            case "synced": return "checkmark.circle"
            case "duplicate": return "exclamationmark.triangle"
            default: return "arrow.down.circle"
            }
        }()
        let text: String = {
            switch status {
            case "synced": return t("已同步")
            case "duplicate": return t("疑似重复")
            default: return t("未同步")
            }
        }()
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct DuplicateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            HStack(spacing: Design.spacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                Text("发现 \(model.duplicates.count) 首疑似重复，已跳过")
                    .font(.headline)
                Spacer()
            }
            Text(t("这些文件没有加入 iPod（收件箱里已有同标题、歌手、时长相近的曲目）。确认不需要可删除收件箱里的源文件。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            List(model.duplicates) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(d.artist) — \(d.title)").font(.body)
                    Text(d.file).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
            .listStyle(.inset)

            HStack(spacing: Design.spacing) {
                Button(t("打开收件箱")) { model.openInbox() }
                Spacer()
                Button(t("知道了")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Design.sectionSpacing)
        .frame(width: 560, height: 400)
    }
}
