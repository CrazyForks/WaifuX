import SwiftUI
import AppKit

// MARK: - 液态玻璃背景 (macOS 26 超写实玻璃)
struct LiquidGlassBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - 液态玻璃卡片样式 (macOS 26 超写实玻璃)
extension View {
    // 液态玻璃卡片 - 超写实玻璃效果
    func liquidGlassCard(padding: CGFloat = 20, cornerRadius: CGFloat = 28) -> some View {
        self
            .padding(padding)
            .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // 液态玻璃浮动控件样式
    func liquidGlassFloatingStyle() -> some View {
        self
            .liquidGlassSurface(.max, in: Circle())
    }
}

// MARK: - 液态玻璃卡片容器 (使用 DesignSystem 版本)
// LiquidGlassCard 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 胶囊标签按钮 (macOS 26 液态玻璃风格) (使用 DesignSystem 版本)
// LiquidGlassPillButton 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 浮动按钮 (液态玻璃发光效果) (使用 DesignSystem 版本)
// LiquidGlassFloatingButton 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - Section 标题
struct LiquidGlassSectionHeader: View {
    let title: String
    let icon: String?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Spacer()
        }
    }
}

// MARK: - 玻璃分隔线 (液态玻璃效果)
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.2),
                        Color.white.opacity(0.1),
                        Color.white.opacity(0.05)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

// MARK: - 导航按钮 (液态玻璃)
struct LiquidGlassNavButton: View {
    var title: String
    var icon: String
    var isSelected: Bool
    var color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? color : LiquidGlassColors.textSecondary)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(colors: [color.opacity(0.2), color.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                            : (isHovered ? LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - 作者壁纸下载图标按钮
/// hover 提示为自定义气泡（系统 .help 在该窗口环境下不弹出，故完全自绘）：
/// onHover 触发 → 延时 0.55s（模拟系统 tooltip 停留节奏）→ 按钮左侧浮出气泡。
/// 气泡用 overlay + fixedSize 绘制，向左展开时以 alignment: .trailing 锚定不超出面板。
struct AuthorDownloadIconButton: View {
    let systemImage: String
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    isDisabled
                        ? Color.accentColor
                        : (isHovered ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary)
                )
                .frame(width: 32, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isHovered
                                ? Color.white.opacity(0.12)
                                : LiquidGlassColors.glassTint.opacity(0.72)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isDisabled
                                ? Color.accentColor.opacity(0.55)
                                : (isHovered
                                    ? LiquidGlassColors.borderSubtle.opacity(1.35)
                                    : LiquidGlassColors.borderSubtle),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(AuthorDownloadIconButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.82 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            handleHover(hovering)
        }
        .overlay(alignment: .trailing) {
            if showTooltip {
                AuthorTooltipBubble(text: title)
                    .fixedSize()
                    // 锚定后整体左移（按钮宽 32 + 间距 8），气泡完整落在按钮左侧的面板内
                    .offset(x: -40)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
        .accessibilityLabel(title)
    }

    private func handleHover(_ hovering: Bool) {
        tooltipTask?.cancel()
        tooltipTask = nil

        if hovering {
            // 与系统 tooltip 一致的停留延时，避免滑过时闪现
            tooltipTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    showTooltip = true
                }
            }
        } else {
            guard showTooltip else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                showTooltip = false
            }
        }
    }
}

/// 自定义 hover 气泡：深色胶囊 + 小箭头，样式贴近系统 tooltip。
private struct AuthorTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.82))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            )
    }
}

/// 按压缩放走 ButtonStyle 的 isPressed。
private struct AuthorDownloadIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 玻璃加载视图
struct LiquidGlassLoadingView: View {
    var message: String = t("loading")

    var body: some View {
        VStack(spacing: 16) {
            CustomProgressView(tint: LiquidGlassColors.primaryPink)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { RepeatForeverAnimationTracker.shared.enter("LiquidGlassLoading") }
        .onDisappear { RepeatForeverAnimationTracker.shared.exit("LiquidGlassLoading") }
    }
}

// MARK: - 玻璃空状态视图
struct LiquidGlassEmptyState: View {
    var message: String = t("noData")
    var icon: String = "photo.on.rectangle"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(LiquidGlassColors.textTertiary)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FlowLayout (流式布局)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                self.size.width = max(self.size.width, x - spacing)
            }
            self.size.height = y + rowHeight
        }
    }
}
