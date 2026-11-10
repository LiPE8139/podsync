import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private let providers: [(String, String)] = [("netease", "云音乐"), ("qq", "QQ音乐"), ("kugou", "酷狗")]
    private let qualities: [(String, String)] = [("lossless", "无损"), ("exhigh", "极高 320k"),
                                                ("standard", "标准 128k"), ("hires", "Hi-Res")]

    var body: some View {
        Form {
            Section {
                Picker(t("语言"), selection: Binding(
                    get: { model.appLanguage },
                    set: { v in
                        model.appLanguage = v
                        UserDefaults.standard.set(v, forKey: "appLanguage")
                        model.savePrefs()
                    })) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
            } header: {
                Text(t("通用"))
            }

            Section {
                Picker(t("主题"), selection: $model.appearanceMode) {
                    Text(t("跟随系统")).tag("system")
                    Text(t("浅色")).tag("light")
                    Text(t("深色")).tag("dark")
                }
                Picker(t("播放条封面大小"), selection: $model.playerCoverSize) {
                    Text(t("小")).tag("small")
                    Text(t("中")).tag("medium")
                    Text(t("大")).tag("large")
                }
            } header: {
                Text(t("外观"))
            }

            Section {
                LabeledContent {
                    HStack(spacing: Design.spacing) {
                        TextField(t("收件箱路径"), text: $model.inbox)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button(t("选择…")) { model.chooseInbox() }
                            .controlSize(.small)
                    }
                } label: {
                    Text(t("位置"))
                }
                Text(t("下载的音乐先落到这里，再由「同步到 iPod」写入设备。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("收件箱"))
            }

            Section {
                Picker(t("默认渠道"), selection: $model.provider) {
                    ForEach(Array(providers.enumerated()), id: \.offset) { _, p in
                        Text(t(p.1)).tag(p.0)
                    }
                }
                Picker(t("默认音质"), selection: $model.quality) {
                    ForEach(Array(qualities.enumerated()), id: \.offset) { _, q in
                        Text(t(q.1)).tag(q.0)
                    }
                }
            } header: {
                Text(t("下载"))
            }

            Section {
                Picker(t("设备外观"), selection: $model.deviceColorOverride) {
                    Text(t("自动识别")).tag("")
                    Text(t("黑色")).tag("black")
                    Text(t("银色")).tag("silver")
                }
                .help(t("自动按型号判断颜色；识别不准时可手动指定"))
                Toggle(t("单份 ALAC 曲库（Rockbox + 原厂共用同一批文件）"), isOn: $model.singleAlac)
                Toggle(t("同步完成后清理收件箱源文件"), isOn: $model.cleanInbox)
                Toggle(t("同步完成后自动推出 iPod"), isOn: $model.ejectAfterSync)
                LabeledContent {
                    HStack(spacing: Design.spacing) {
                        Text(model.toolDir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(t("选择…")) { model.chooseToolDir() }
                            .controlSize(.small)
                    }
                } label: {
                    Text(t("工具目录"))
                }
                Button(t("打开工具目录")) { model.openToolDir() }
                    .controlSize(.small)
            } header: {
                Text(t("同步"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onChange(of: model.inbox) { _, _ in model.savePrefs() }
        .onChange(of: model.provider) { _, _ in model.savePrefs() }
        .onChange(of: model.quality) { _, _ in model.savePrefs() }
        .onChange(of: model.ejectAfterSync) { _, _ in model.savePrefs() }
        .onChange(of: model.cleanInbox) { _, _ in model.savePrefs() }
        .onChange(of: model.singleAlac) { _, _ in model.savePrefs() }
        .onChange(of: model.deviceColorOverride) { _, _ in model.savePrefs() }
        .onChange(of: model.appearanceMode) { _, _ in model.savePrefs() }
        .onChange(of: model.playerCoverSize) { _, _ in model.savePrefs() }
        .onChange(of: model.appLanguage) { _, _ in model.savePrefs() }
    }
}
