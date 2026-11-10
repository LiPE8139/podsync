import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("detailPane") private var paneStored = DetailPane.download.rawValue

    private var paneBinding: Binding<DetailPane?> {
        Binding(
            get: { DetailPane(rawValue: paneStored) },
            set: { if let newValue = $0 { paneStored = newValue.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: paneBinding) {
                Section {
                    Label(DetailPane.download.title, systemImage: DetailPane.download.symbol)
                        .tag(DetailPane.download)
                    Label(DetailPane.queue.title, systemImage: DetailPane.queue.symbol)
                        .badge(model.queue.count)
                        .tag(DetailPane.queue)
                } header: {
                    Text(t("音乐"))
                }
                Section {
                    Label(DetailPane.sync.title, systemImage: DetailPane.sync.symbol)
                        .badge(model.pending.filter { $0.status == "new" }.count)
                        .tag(DetailPane.sync)
                } header: {
                    Text(t("设备"))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch DetailPane(rawValue: paneStored) ?? .download {
            case .download:
                DownloadView()
            case .queue:
                QueueView()
            case .sync:
                SyncView()
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .preferredColorScheme(model.preferredScheme)
    }
}
