import SwiftUI

struct DownloadRow: View {
    let item: CocoItem
    @EnvironmentObject private var model: AppModel
    @StateObject private var hover = HoverState()

    /// 鼠标悬停时的蓝色强调（macOS List 自带高亮在去掉 selection 后没有了，这里补回来）
    /// 注意：抽屉打开时不能给底层列表加 hover 强调 —— SwiftUI 的 hover 追踪是几何触发的，
    /// 抽屉盖在上面也照样会触发到底下的行，看起来就像“鼠标在抽屉里、搜索列表却亮了”。
    private var rowBackground: Color {
        if model.selection.contains(item.id) { return Color.accentColor.opacity(0.12) }
        if model.showLibraryPanel { return Color.clear }
#if DEVTOOLS
        if hover.hovering || model.debugHoverID == item.id { return Color.accentColor.opacity(0.07) }
#else
        if hover.hovering { return Color.accentColor.opacity(0.07) }
#endif
        return Color.clear
    }

    var body: some View {
        HStack(spacing: Design.spacing) {
            Toggle("", isOn: Binding(
                get: { model.selection.contains(item.id) },
                set: { model.setPageSelected(item.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(t("勾选后可批量下载"))
                .accessibilityLabel("选择 \(item.title)")

            AsyncImage(url: URL(string: item.cover ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: Design.coverSize, height: Design.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(item.artist) · \(item.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Design.spacing)

            Text(item.duration ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            StarButton(isOn: model.isFavorite(item),
                       help: model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                model.toggleFavorite(item)
            }

            if model.previewID == item.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("正在试听")
            }
            if model.doneIDs.contains(item.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已下载")
            }

            Button {
                model.download(item)
            } label: {
                Label(t("下载"), systemImage: "arrow.down.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(t("下载到收件箱"))
            .accessibilityLabel("下载 \(item.title)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .onTapGesture(count: 2) { model.togglePreview(item) }
        .help(t("双击试听 / 暂停"))
        .contextMenu {
            Button(t("播放")) { model.playPreview(item, queue: model.items) }
            Button(model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                model.toggleFavorite(item)
            }
            Button(t("查看整张专辑")) { model.openAlbum(item) }
            Button("\(t("查看")) \(item.artist)") { model.viewArtist(item) }
            Button(t("播放整张专辑")) { model.playAlbum(item) }
            Divider()
            Button(t("下载")) { model.download(item) }
            Button(t("下载整张专辑")) { model.downloadAlbum(item) }
        }
    }
}

struct DownloadView: View {
    @EnvironmentObject private var model: AppModel

    private let providers: [(String, String)] = [("netease", "云音乐"), ("qq", "QQ音乐"), ("kugou", "酷狗")]
    private let qualities: [(String, String)] = [("lossless", "无损"), ("exhigh", "极高 320k"),
                                                ("standard", "标准 128k"), ("hires", "Hi-Res")]

    var body: some View {
        VStack(spacing: 0) {
            if model.artistName != nil {
                artistBar
            }
            selectionBar
            songList
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                previewBar
                statusBar
            }
        }
        .sheet(isPresented: $model.showAlbumView) { AlbumSheetView() }
        .searchable(text: $model.query, placement: .toolbar, prompt: "歌曲 / 歌手 / 专辑")
        .onSubmit(of: .search) { model.search() }
        .navigationTitle(t("下载音乐"))
        .navigationSubtitle(model.status)
        .toolbar { toolbarContent }
    }

    /// 歌手模式横幅：查看 XX（N 首） + 返回搜索结果
    private var artistBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text("\(t("查看")) \(model.artistName ?? "")")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if model.artistLoading {
                ProgressView().controlSize(.small)
                Text(t("正在获取全部歌曲…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.items.count) \(t("首"))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(t("返回搜索结果")) { model.exitArtistMode() }
                .controlSize(.small)
        }
        .padding(.horizontal, Design.spacing + 4)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 批量勾选条
    private var selectionBar: some View {
        HStack(spacing: Design.spacing) {
            Toggle(isOn: Binding(get: { model.allSelectedOnPage },
                                 set: { _ in model.toggleSelectAllOnPage() })) {
                Text(t("全选")).font(.caption)
            }
            .toggleStyle(.checkbox)
            .disabled(model.items.isEmpty)
            .help(t("选中当前页全部曲目"))

            if !model.selection.isEmpty {
                Text("\(t("已选")) \(model.selection.count) \(t("首"))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(t("清除")) { model.selection.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Spacer()

            Text("\(model.items.count) \(t("首"))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.spacing + 4)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var songList: some View {
        List(model.items) { item in
            DownloadRow(item: item)
        }
        .listStyle(.inset)
        .overlay {
            if model.artistLoading {
                ProgressView(t("正在获取全部歌曲…"))
            } else if model.items.isEmpty && !model.busy {
                ContentUnavailableView {
                    Label(t("搜索音乐"), systemImage: "magnifyingglass")
                } description: {
                    Text(t("输入歌名、歌手或专辑名，从云音乐 / QQ音乐 / 酷狗 下载到收件箱。"))
                }
            }
        }
        // 点搜索页内容（含空白处）就收起音乐库抽屉；抽屉在下一层 overlay，点抽屉本身不会触发
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if model.showLibraryPanel { model.showLibraryPanel = false }
        })
        .overlay(alignment: .trailing) {
            if model.showLibraryPanel {
                PlayerDrawer()
                    .environmentObject(model)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.showLibraryPanel)
    }

    private var statusBar: some View {
        HStack(spacing: Design.spacing) {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !model.items.isEmpty && model.artistName == nil {
                pagination
            }
            if model.downloadingID != nil {
                ProgressView(value: model.downloadPercent)
                    .frame(width: 120)
                Text(Int(model.downloadPercent * 100) == 0 && model.downloadDetail.isEmpty
                     ? "准备下载…"
                     : "\(Int(model.downloadPercent * 100))% · \(model.downloadDetail)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.loadingPage {
                ProgressView().controlSize(.small)
            }
            if model.batchTotal > 0 {
                ProgressView(value: Double(model.batchDone), total: Double(max(model.batchTotal, 1))) {
                    Text("\(model.batchDone)/\(model.batchTotal)")
                        .font(.caption.monospacedDigit())
                }
                .frame(width: 160)
            }
            Button(t("打开收件箱")) { model.openInbox() }
                .controlSize(.small)
                .help(t("在 Finder 中打开收件箱"))
        }
        .padding(.horizontal, Design.spacing)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 底部分页：1 2 3 4 …（当前页加粗，可点其他页跳转）
    @ViewBuilder
    private var pagination: some View {
        HStack(spacing: 4) {
            Button {
                model.loadPage(model.page - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(model.page <= 1 || model.loadingPage)
            .help(t("上一页"))
            .accessibilityLabel("上一页")

            if let first = pageNumbers.first, first > 1 {
                Button(t("1")) { model.loadPage(1) }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 18)
                Text(t("…")).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(pageNumbers, id: \.self) { n in
                if n == model.page {
                    Text("\(n)")
                        .fontWeight(.semibold)
                        .frame(minWidth: 18)
                } else {
                    Button("\(n)") { model.loadPage(n) }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 18)
                }
            }

            Button {
                model.loadPage(model.page + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!model.hasMore || model.loadingPage)
            .help(t("下一页"))
            .accessibilityLabel("下一页")
        }
    }

    private var pageNumbers: [Int] {
        let end = model.page + (model.hasMore ? 1 : 0)
        var start = max(1, min(model.page - 2, end - 5))
        if end - start > 5 { start = end - 5 }
        return Array(start...max(end, start))
    }

    /// Apple Music 风格播放条：顶部整宽细进度（无拖块），下方控制行（音量独立细条）
    private var previewBar: some View {
        VStack(spacing: 0) {
            ThinSlider(value: model.previewProgress, height: 3) { fraction in
                model.seekPreview(fraction)
            }
            .disabled(model.previewItem == nil)
            .padding(.horizontal, 0)

            HStack(spacing: 10) {
                previewArtwork

                HoverIconButton(systemName: "music.note.list",
                                help: t("音乐库") + " · " + "\(model.previewQueue.count) " + t("首")) {
                    model.showLibraryPanel.toggle()
                }

                if let item = model.previewItem {
                    StarButton(isOn: model.isFavorite(item),
                               size: 14,
                               help: model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                        model.toggleFavorite(item)
                    }
                }

                Spacer(minLength: 4)

                HoverIconButton(systemName: "backward.fill",
                                enabled: model.canPlayPrev,
                                help: "上一首") { model.playPrev() }

                HoverIconButton(systemName: model.previewPlaying ? "pause.fill" : "play.fill",
                                font: .title2,
                                enabled: model.previewItem != nil,
                                help: model.previewPlaying ? "暂停" : "播放") { model.togglePreviewPlay() }

                HoverIconButton(systemName: "forward.fill",
                                enabled: model.canPlayNext,
                                help: "下一首") { model.playNext() }

                Spacer(minLength: 4)

                Text(previewTime(model.previewCurrent))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text(t(" / "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(previewTime(model.previewDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                HoverIconButton(systemName: volumeSymbol(model.systemVolume),
                                help: model.systemVolume > 0 ? "静音" : "取消静音") { model.toggleMute() }

                ThinSlider(value: model.systemVolume, height: 3) { v in
                    model.setVolume(v)
                }
                .frame(width: 64)

                HoverIconButton(systemName: "arrow.down.circle",
                                enabled: model.previewItem != nil && model.downloadingID == nil,
                                help: "下载正在试听的歌曲") {
                    if let item = model.previewItem { model.download(item) }
                }

                HoverIconButton(systemName: "xmark.circle.fill",
                                enabled: model.previewItem != nil,
                                help: "关闭试听") { model.stopPreview() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity)
        .playerGlassBar()
    }

    @ViewBuilder
    private var previewArtwork: some View {
        if let item = model.previewItem {
            CoverThumbnail(url: imageURL(item.cover), size: model.artworkSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 220, alignment: .leading)
        } else {
            RoundedRectangle(cornerRadius: Design.cornerRadius / 2)
                .fill(.quaternary)
                .frame(width: model.artworkSize, height: model.artworkSize)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(t("未在播放")).font(.subheadline.weight(.medium))
                Text(t("双击搜索结果试听")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
    }

    private func volumeSymbol(_ v: Double) -> String {
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.fill" }
        if v < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func previewTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("渠道", selection: $model.provider) {
                ForEach(Array(providers.enumerated()), id: \.offset) { _, p in
                    Text(p.1).tag(p.0)
                }
            }
            .pickerStyle(.menu)
            .help(t("下载渠道"))

            Picker("音质", selection: $model.quality) {
                ForEach(Array(qualities.enumerated()), id: \.offset) { _, q in
                    Text(q.1).tag(q.0)
                }
            }
            .pickerStyle(.menu)
            .help(t("下载音质"))

            Button(model.selection.isEmpty
                   ? t("下载选中")
                   : "\(t("下载选中")) (\(model.selection.count))") { model.downloadSelected() }
                .disabled(model.selection.isEmpty || model.queueRunning)
                .help(t("下载列表里选中的曲目"))
            Button(t("下载全部")) { model.downloadAll() }
                .disabled(model.items.isEmpty || model.queueRunning)
                .help(t("把当前搜索结果全部加入队列"))
        }
    }
}


/// 无拖块的细滑块（点击/拖动定位），进度与音量共用
struct ThinSlider: View {
    let value: Double
    var height: CGFloat = 3
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.primary)
                    .frame(width: max(2, width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.18), value: value)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onSeek(min(max(v.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: height + 10)
    }
}
