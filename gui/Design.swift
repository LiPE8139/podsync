import SwiftUI

/// 设计常量：8pt 网格、圆角 ≤12、语义字号（不写死字号/颜色）
enum Design {
    static let spacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 16
    static let cornerRadius: CGFloat = 8
    static let coverSize: CGFloat = 44
}

import SwiftUI

/// 设备图片（打包在 Resources 里的 iPod 剪影图，去掉白底）
struct DeviceImage: View {
    var height: CGFloat = 72
    var color: String = "black"

    private var resourceName: String {
        Bundle.main.url(forResource: "ipod_\(color)", withExtension: "png") != nil
            ? "ipod_\(color)" : "ipod"
    }

    var body: some View {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "ipod")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// 歌曲封面缩略图（URL 或本地缓存文件）
struct CoverThumbnail: View {
    let url: URL?
    var size: CGFloat = 24

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "music.note")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius / 2))
        .accessibilityHidden(true)
    }
}


/// 可复用的滑动页签（选中态背景块左右滑动）
struct SlidingTabs: View {
    @Binding var selection: Int
    let titles: [String]

    var body: some View {
        GeometryReader { geo in
            let tabWidth = geo.size.width / CGFloat(max(titles.count, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background)
                    .frame(width: max(0, tabWidth - 4), height: max(0, geo.size.height - 4))
                    .offset(x: 2 + CGFloat(selection) * tabWidth)
                    .animation(.easeInOut(duration: 0.22), value: selection)
                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selection = index
                            }
                        } label: {
                            Text(title)
                                .font(.caption.weight(selection == index ? .semibold : .regular))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                    }
                }
            }
        }
        .frame(height: 28)
    }
}


/// 带 hover 缩放动效的图标按钮（@StateObject 实现，避免宏）
final class HoverState: ObservableObject {
    @Published var hovering = false
}

struct HoverIconButton: View {
    let systemName: String
    var font: Font = .title3
    var enabled: Bool = true
    let help: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .scaleEffect(hover.hovering ? 1.14 : 1.0)
                .opacity(enabled ? (hover.hovering ? 1.0 : 0.9) : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}


extension View {
    /// Liquid Glass（macOS 26+），旧系统回退到系统材质
    @ViewBuilder
    func playerGlassBar() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            self.background(.bar)
        }
    }

    /// 右侧抽屉 / 浮层的 Liquid Glass 背景（圆角，macOS 26 以下用半透明材质）
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}


/// 带蓝色 hover 强调的行容器（和下载列表一致）
struct HoverHighlightRow<Content: View>: View {
    var selected: Bool = false
    @ViewBuilder var content: () -> Content

    @StateObject private var hover = HoverState()

    var body: some View {
        content()
            .background(selected ? Color.accentColor.opacity(0.12)
                        : (hover.hovering ? Color.accentColor.opacity(0.07) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hover.hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hover.hovering)
    }
}

/// 五角星收藏按钮（点亮=已加入「我喜欢的音乐」）
struct StarButton: View {
    var isOn: Bool
    var size: CGFloat = 13
    let help: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .scaleEffect(hover.hovering ? 1.18 : 1.0)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
