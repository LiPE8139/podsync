import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("queueTab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            SlidingTabs(selection: $tab,
                        titles: [t("未完成") + " \(model.queue.count)",
                                 t("已完成") + " \(model.completed.count)"])
                .padding(.horizontal, Design.sectionSpacing)
                .padding(.vertical, Design.spacing)

            Divider()

            Group {
                if tab == 0 {
                    pendingList
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    completedList
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: tab)
        }
        .navigationTitle(t("下载队列"))
        .navigationSubtitle("\(model.queue.count) 首待完成 · \(model.completed.count) 首已完成")
        .toolbar { toolbarContent }
    }

    private var pendingList: some View {
        List {
            ForEach(model.queue) { item in
                QueueRow(item: item)
            }
            .onDelete { indexSet in
                for i in indexSet where i < model.queue.count {
                    model.removeQueueItem(model.queue[i])
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.queue.isEmpty {
                ContentUnavailableView {
                    Label(t("队列为空"), systemImage: "arrow.down.circle")
                } description: {
                    Text(t("在「下载音乐」里搜索并下载，曲目会先进入这里。下载中断后重开 App 会自动续传。"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { progressBar }
    }

    private var completedList: some View {
        List(model.completed) { item in
            CompletedRow(item: item)
        }
        .listStyle(.inset)
        .overlay {
            if model.completed.isEmpty {
                ContentUnavailableView {
                    Label(t("还没有已完成记录"), systemImage: "checkmark.circle")
                } description: {
                    Text(t("下载成功的曲目会出现在这里，可以「重新下载」或在 Finder 里查看。"))
                }
            }
        }
    }

    private var progressBar: some View {
        HStack(spacing: Design.spacing) {
            if model.queueRunning {
                ProgressView(value: model.downloadPercent)
                    .frame(width: 160)
                Text("\(Int(model.downloadPercent * 100))% · \(model.downloadDetail)")
                    .font(.caption.monospacedDigit())
            } else {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.batchTotal > 0 {
                Text("\(model.batchDone)/\(model.batchTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Design.sectionSpacing)
        .padding(.vertical, Design.spacing)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if tab == 0 {
                Button(t("重试全部")) { model.retryQueue() }
                    .disabled(model.queue.isEmpty || model.queueRunning)
                    .help(t("重新下载队列里失败的曲目（支持断点续传）"))
                Button(t("清空队列")) { model.clearQueue() }
                    .disabled(model.queue.isEmpty || model.queueRunning)
            } else {
                Button(t("清空已完成")) { model.clearCompleted() }
                    .disabled(model.completed.isEmpty)
                Button(t("打开收件箱")) { model.openInbox() }
            }
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Design.spacing) {
            CoverThumbnail(url: imageURL(item.cover), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text("\(item.artist) · \(item.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = item.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if model.downloadingID == item.id {
                ProgressView(value: model.downloadPercent)
                    .frame(width: 80)
                Text("\(Int(model.downloadPercent * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                model.removeQueueItem(item)
            } label: {
                Label(t("移除"), systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(t("从队列移除"))
            .accessibilityLabel("从队列移除 \(item.title)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(t("移除")) { model.removeQueueItem(item) }
        }
    }
}

private struct CompletedRow: View {
    let item: CompletedItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Design.spacing) {
            CoverThumbnail(url: imageURL(item.cover), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text("\(item.artist) · \(item.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("完成于 \(item.finishedAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.openInFinder(item.path)
            } label: {
                Label(t("在 Finder 中显示"), systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(t("在 Finder 中显示"))
            .accessibilityLabel("在 Finder 中显示 \(item.title)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(t("重新下载")) { model.reEnqueue(item) }
            Button(t("在 Finder 中显示")) { model.openInFinder(item.path) }
        }
    }
}
