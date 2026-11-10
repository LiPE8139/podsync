import SwiftUI

/// 右侧抽屉：我喜欢的音乐 / 历史
/// Liquid Glass 材质，从右侧滑出（挂在列表区域，不遮挡底部播放条）
struct PlayerDrawer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            SlidingTabs(selection: $model.drawerTab,
                        titles: [t("我喜欢") + " \(model.favorites.count)",
                                 t("历史") + " \(model.history.count)"])
                .padding(.horizontal, 12)
                .padding(.top, 6)
            content
                .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: 376)
        .frame(maxHeight: .infinity)
        // 整块面板参与命中测试：否则鼠标在抽屉空白处移动时会“穿透”到底下的列表，
        // 让搜索列表的行出现 hover 蓝色强调（这一层是透明玻璃时尤其明显）
        .contentShape(Rectangle())
        .glassPanel()
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: Design.spacing) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            Text(t("音乐库"))
                .font(.headline)
            Spacer()
            HoverIconButton(systemName: "xmark", font: .body, help: t("关闭")) {
                model.showLibraryPanel = false
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var content: some View {
        if model.drawerTab == 0 {
            favoritesTab
        } else {
            historyTab
        }
    }

    // MARK: 我喜欢的音乐

    private var favoritesTab: some View {
        VStack(spacing: 0) {
            favoritesSearchBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredFavorites, id: \.favKey) { item in
                        HoverHighlightRow {
                            baseRow(item, isCurrent: model.previewID == item.id) {
                                model.previewQueue = model.filteredFavorites
                                model.playPreview(item, queue: model.filteredFavorites)
                            } trailing: {
                                StarButton(isOn: true, help: t("取消喜欢")) {
                                    model.toggleFavorite(item)
                                }
                                Button {
                                    model.download(item)
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(t("下载这首"))
                                .accessibilityLabel("下载 \(item.title)")
                            }
                            .contextMenu {
                                Button(t("播放这首")) {
                                    model.playPreview(item, queue: model.filteredFavorites)
                                }
                                Button(t("下载这首")) { model.download(item) }
                                Button(t("查看整张专辑")) { model.openAlbum(item) }
                                Button("\(t("查看")) \(item.artist)") { model.viewArtist(item) }
                                Divider()
                                Button(t("取消喜欢")) { model.toggleFavorite(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .overlay {
                if model.filteredFavorites.isEmpty {
                    emptyText(model.favorites.isEmpty ? t("还没有喜欢的歌") : t("没有匹配的歌曲"),
                              systemImage: "star")
                }
            }
        }
    }

    private var favoritesSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(t("搜索喜欢的音乐"), text: $model.favFilter)
                .textFieldStyle(.plain)
                .font(.callout)
            if !model.favFilter.isEmpty {
                Button {
                    model.favFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(t("清除"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: 历史

    private var historyTab: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.history.enumerated()), id: \.element.favKey) { index, item in
                    HoverHighlightRow {
                        baseRow(item, isCurrent: model.previewID == item.id) {
                            model.playHistoryItem(at: index)
                        } trailing: {
                            StarButton(isOn: model.isFavorite(item),
                                       help: model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                                model.toggleFavorite(item)
                            }
                            Button {
                                model.download(item)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(t("下载这首"))
                            .accessibilityLabel("下载 \(item.title)")
                            Button {
                                model.removeFromHistory(item)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(t("从历史移除"))
                            .accessibilityLabel("从历史移除 \(item.title)")
                        }
                        .contextMenu {
                            Button(t("播放这首")) { model.playHistoryItem(at: index) }
                            Button(t("下载这首")) { model.download(item) }
                            Button("\(t("查看")) \(item.artist)") { model.viewArtist(item) }
                            Button(t("查看整张专辑")) { model.openAlbum(item) }
                            Divider()
                            Button(model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                                model.toggleFavorite(item)
                            }
                            Button(t("从历史移除")) { model.removeFromHistory(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .overlay {
            if model.history.isEmpty {
                emptyText(t("还没有播放记录"), systemImage: "clock")
            }
        }
    }

    // MARK: 行 / 底部

    private func baseRow(_ item: CocoItem, isCurrent: Bool,
                         onPlay: @escaping () -> Void,
                         @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: Design.spacing) {
            CoverThumbnail(url: imageURL(item.cover), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("正在试听")
            }
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPlay() }
        .help(t("双击试听 / 暂停"))
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Design.spacing) {
            if model.drawerTab == 0 {
                playAllButton { model.playList(model.filteredFavorites) }
                    .disabled(model.filteredFavorites.isEmpty)
                Button(t("全部下载")) { model.downloadList(model.filteredFavorites) }
                    .controlSize(.small)
                    .disabled(model.filteredFavorites.isEmpty)
                Button(t("清空")) { model.clearFavorites() }
                    .controlSize(.small)
                    .disabled(model.favorites.isEmpty)
            } else {
                playAllButton { model.playList(model.history) }
                    .disabled(model.history.isEmpty)
                Button(t("清空历史")) { model.clearHistory() }
                    .controlSize(.small)
                    .disabled(model.history.isEmpty)
            }
            Spacer()
            Button(t("关闭")) { model.showLibraryPanel = false }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func playAllButton(_ action: @escaping () -> Void) -> some View {
        Button(t("播放全部"), action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    private func emptyText(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

struct AlbumSheetView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
            HStack(spacing: Design.spacing) {
                Image(systemName: "square.stack")
                    .foregroundStyle(.secondary)
                Text(model.albumViewTitle).font(.headline).lineLimit(1)
                Spacer()
                if model.albumViewItems.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Button(t("关闭")) { dismiss() }
            }

            List(model.albumViewItems) { item in
                HStack(spacing: Design.spacing) {
                    CoverThumbnail(url: imageURL(item.cover), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body).lineLimit(1)
                        Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(item.duration ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    StarButton(isOn: model.isFavorite(item),
                               help: model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                        model.toggleFavorite(item)
                    }
                    Button {
                        model.playPreview(item, queue: model.albumViewItems)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(t("播放这首"))
                    .accessibilityLabel("播放 \(item.title)")
                    Button {
                        model.download(item)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(t("下载这首"))
                    .accessibilityLabel("下载 \(item.title)")
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button(t("播放这首")) { model.playPreview(item, queue: model.albumViewItems) }
                    Button(t("下载这首")) { model.download(item) }
                    Button("\(t("查看")) \(item.artist)") { model.viewArtist(item) }
                    Divider()
                    Button(model.isFavorite(item) ? t("取消喜欢") : t("加入喜欢")) {
                        model.toggleFavorite(item)
                    }
                }
            }
            .listStyle(.inset)

            HStack(spacing: Design.spacing) {
                Button(t("播放全部")) {
                    guard let first = model.albumViewItems.first else { return }
                    model.playPreview(first, queue: model.albumViewItems)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.albumViewItems.isEmpty)
                Button(t("下载全部")) {
                    model.enqueue(model.albumViewItems)
                }
                .disabled(model.albumViewItems.isEmpty)
                Button(t("全部加入喜欢")) {
                    for item in model.albumViewItems where !model.isFavorite(item) {
                        model.toggleFavorite(item)
                    }
                }
                .disabled(model.albumViewItems.isEmpty)
                Spacer()
            }
        }
        .padding(Design.sectionSpacing)
        .frame(width: 680, height: 500)
    }
}
