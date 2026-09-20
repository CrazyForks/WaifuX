import SwiftUI

// MARK: - 统一 sheet 玻璃壳
/// 所有 `.sheet` 弹窗的统一底壳。
/// sheet 窗口内原生 glassEffect 的背后采样受限，内部复用 DarkLiquidGlassBackground 的材质构造，
/// 与输入链接弹窗（WorkshopURLInputSheet）视觉同源：
/// - 紧凑输入类 sheet：卡片模式（默认），圆角玻璃卡浮在 sheet 窗口上
/// - 功能型大 sheet：`fillsSheet: true`，玻璃铺满整个 sheet 窗口（方角）
struct GlassSheetShell<Content: View>: View {
    private let title: String?
    private let showsClose: Bool
    private let onClose: (() -> Void)?
    private let cornerRadius: CGFloat
    private let fillsSheet: Bool
    private let width: CGFloat?
    private let contentPadding: CGFloat
    private let content: () -> Content

    @State private var isCloseHovered = false

    init(
        title: String? = nil,
        showsClose: Bool = false,
        onClose: (() -> Void)? = nil,
        cornerRadius: CGFloat = 16,
        fillsSheet: Bool = false,
        width: CGFloat? = nil,
        contentPadding: CGFloat = 24,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.showsClose = showsClose
        self.onClose = onClose
        self.cornerRadius = cornerRadius
        self.fillsSheet = fillsSheet
        self.width = width
        self.contentPadding = contentPadding
        self.content = content
    }

    var body: some View {
        ZStack {
            if fillsSheet {
                DarkLiquidGlassBackground(cornerRadius: 0, isHovered: false)
                    .ignoresSafeArea()
            } else {
                DarkLiquidGlassBackground(cornerRadius: cornerRadius, isHovered: false)
            }

            VStack(spacing: 0) {
                if let title, !title.isEmpty {
                    headerRow(title)
                }
                content()
            }
            .padding(contentPadding)
        }
        .frame(width: width)
        // 透明化 sheet 窗口背景，让玻璃底材真实采样主窗口内容（材质本身是 behindWindow 混合）
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private func headerRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))

            Spacer()

            if showsClose, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isCloseHovered ? 0.8 : 0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(isCloseHovered ? 0.14 : 0.08)))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCloseHovered = hovering
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }
}
