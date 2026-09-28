import SwiftUI
import AppKit

// MARK: - 显示器选择弹窗 - 液态玻璃风格
struct DisplaySelectorSheet: View {
    let title: String
    let message: String
    let allowsBackgroundDismiss: Bool
    /// 非 nil 时才多出「DeepSeek Harness」目标（装了 DSH 且接口通才会显示）。
    let onSelectDSH: (() -> Void)?
    let onSelect: (NSScreen?) -> Void
    let onCancel: () -> Void

    /// DSH 可用性：弹窗出现时探一次，通了才把 Harness 选项画出来。
    @ObservedObject private var dshBridge = DSHHarnessBridge.shared

    @State private var isVisible = false
    @State private var selectedScreenID: String? = nil
    @State private var isDSHSelected = false

    /// DeepSeek Harness 是否作为目标可选：调用点愿意接管 + DSH 装了且在跑。
    private var showsDSHTarget: Bool {
        onSelectDSH != nil && dshBridge.availability.isAvailable
    }

    private var screens: [NSScreen] {
        // 与设置页「显示器 N」编号一致：主屏优先、从左到右，不跟系统枚举顺序。
        NSScreen.screensOrderedForDisplay
    }

    private var hasMultipleDisplays: Bool {
        screens.count > 1
    }

    /// 根据 ID 获取对应的屏幕
    private func screen(forID id: String?) -> NSScreen? {
        guard let id = id else { return nil }
        return screens.first { $0.screenIdentifier == id }
    }

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black
                .opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    if allowsBackgroundDismiss {
                        dismiss()
                    }
                }

            // 弹窗内容
            VStack(spacing: 20) {
                // 标题
                VStack(spacing: 8) {
                    Image(systemName: "display.2")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.accentColor)

                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }

                // 显示器选择按钮
                VStack(spacing: 12) {
                    // 所有显示器选项（单屏时与「显示器 1」重复，只留后者）
                    if hasMultipleDisplays {
                        DisplayOptionButton(
                            icon: "display",
                            title: t("allDisplays"),
                            subtitle: "\(screens.count) \(t("screensCount"))",
                            isSelected: !isDSHSelected && selectedScreenID == nil,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedScreenID = nil
                                    isDSHSelected = false
                                }
                            }
                        )
                    }

                    // 单个显示器选项
                    ForEach(Array(screens.enumerated()), id: \.element.screenIdentifier) { index, screen in
                        DisplayOptionButton(
                            icon: "display",
                            title: "\(t("display")) \(index + 1)",
                            subtitle: screen.localizedName,
                            isSelected: !isDSHSelected && selectedScreenID == screen.screenIdentifier,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedScreenID = screen.screenIdentifier
                                    isDSHSelected = false
                                }
                            }
                        )
                    }

                    // DeepSeek Harness（DSH 装了且接口通时才出现）
                    if showsDSHTarget {
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 1)
                            Text(t("dshHarness.orTarget"))
                                .font(.system(size: 11))
                                .foregroundStyle(LiquidGlassColors.textQuaternary)
                                .fixedSize()
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 1)
                        }
                        .padding(.vertical, 2)

                        DisplayOptionButton(
                            icon: "sparkles",
                            title: "DeepSeek Harness",
                            subtitle: t("dshHarness.subtitle"),
                            isSelected: isDSHSelected,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isDSHSelected = true
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: 320)
                .animation(.easeInOut(duration: 0.2), value: showsDSHTarget)

                // 操作按钮
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text(t("cancel"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmSelection()
                    } label: {
                        Text(t("confirm"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .liquidGlassSurface(
                                .max,
                                tint: Color.accentColor.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 320)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .liquidGlassSurface(
                .prominent,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .scaleEffect(isVisible ? 1.0 : 0.88)
            .opacity(isVisible ? 1.0 : 0.0)
            .onAppear {
                // 单屏弹窗（只有 DSH 在线时才会出现）没有「所有显示器」项，默认选中唯一的屏幕
                if !hasMultipleDisplays, let onlyScreen = screens.first {
                    selectedScreenID = onlyScreen.screenIdentifier
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isVisible = true
                }
            }
        }
        // Esc 关闭兜底：从库/状态栏触发时没有详情页键盘监听接住 Esc，由卡片自己关闭
        .onExitCommand {
            dismiss()
        }
        // 弹窗出现时探一次 DSH（毫秒级本机 GET，带 20s 缓存）
        .task {
            guard onSelectDSH != nil else { return }
            await dshBridge.refreshAvailability()
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onCancel()
        }
    }

    private func confirmSelection() {
        let selectedDSH = isDSHSelected
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if selectedDSH, let onSelectDSH {
                onSelectDSH()
                return
            }
            onSelect(screen(forID: selectedScreenID))
        }
    }
}

// MARK: - 显示器选项按钮
private struct DisplayOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : LiquidGlassColors.textSecondary)
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(
                        isSelected ? .prominent : .subtle,
                        tint: isSelected ? Color.accentColor.opacity(0.15) : nil,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? LiquidGlassColors.textPrimary : LiquidGlassColors.textSecondary)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LiquidGlassColors.textQuaternary)
                }

                Spacer()

                // 选中指示器
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .liquidGlassSurface(
                isSelected ? .prominent : (isHovered ? .regular : .subtle),
                tint: isSelected ? Color.accentColor.opacity(0.1) : nil,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.3) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 显示器选择弹窗管理器
@MainActor
class DisplaySelectorManager: ObservableObject {
    static let shared = DisplaySelectorManager()

    @Published var isShowingSelector = false
    @Published private(set) var selectorTitle: String = ""
    @Published private(set) var selectorMessage: String = ""
    @Published private(set) var allowsBackgroundDismiss = false
    /// 当前这次弹窗是否允许出现「DeepSeek Harness」目标
    /// （最终可见性还要看 DSH 是否在线，由弹窗自己判断）。
    private(set) var supportsDSHTarget = false

    private var completionHandler: ((NSScreen?) -> Void)?
    private var dshHandler: (() -> Void)?

    private init() {}

    /// 显示显示器选择弹窗
    /// - Parameters:
    ///   - title: 弹窗标题
    ///   - message: 弹窗消息
    ///   - onSelectDSH: 传给弹窗的「DeepSeek Harness」目标回调；nil = 这个入口不提供该目标
    ///   - completion: 选择完成回调，参数为选中的屏幕，nil 表示所有屏幕
    func showSelector(
        title: String,
        message: String,
        allowsBackgroundDismiss: Bool = false,
        onSelectDSH: (() -> Void)? = nil,
        completion: @escaping (NSScreen?) -> Void
    ) {
        self.completionHandler = completion
        self.dshHandler = onSelectDSH
        self.supportsDSHTarget = onSelectDSH != nil
        self.selectorTitle = title
        self.selectorMessage = message
        self.allowsBackgroundDismiss = allowsBackgroundDismiss
        self.isShowingSelector = true
    }

    func handleSelection(_ screen: NSScreen?) {
        isShowingSelector = false
        completionHandler?(screen)
        completionHandler = nil
        dshHandler = nil
        supportsDSHTarget = false
    }

    /// 选中「DeepSeek Harness」：桌面壁纸不动，交给调用点推送到 DSH。
    func handleDSHSelection() {
        isShowingSelector = false
        let handler = dshHandler
        completionHandler = nil
        dshHandler = nil
        supportsDSHTarget = false
        handler?()
    }

    func handleCancel() {
        isShowingSelector = false
        completionHandler = nil
        dshHandler = nil
        supportsDSHTarget = false
    }

    /// 主窗口进入后台极致释放时清掉待执行闭包，避免闭包继续持有详情页或 ViewModel。
    func cancelForMemoryRelease() {
        selectorTitle = ""
        selectorMessage = ""
        allowsBackgroundDismiss = false
        isShowingSelector = false
        completionHandler = nil
        dshHandler = nil
        supportsDSHTarget = false
    }
}

// MARK: - 便捷扩展
extension View {
    /// 添加显示器选择弹窗覆盖层
    func displaySelectorOverlay() -> some View {
        self.overlay {
            DisplaySelectorOverlay()
        }
    }
}

// MARK: - 显示器选择弹窗覆盖层
public struct DisplaySelectorOverlay: View {
    @ObservedObject private var manager = DisplaySelectorManager.shared

    public var body: some View {
        Group {
            if manager.isShowingSelector {
                DisplaySelectorSheet(
                    title: manager.selectorTitle.isEmpty ? t("selectDisplay") : manager.selectorTitle,
                    message: manager.selectorMessage.isEmpty ? t("selectDisplayMessage") : manager.selectorMessage,
                    allowsBackgroundDismiss: manager.allowsBackgroundDismiss,
                    onSelectDSH: manager.supportsDSHTarget ? { manager.handleDSHSelection() } : nil,
                    onSelect: { screen in
                        manager.handleSelection(screen)
                    },
                    onCancel: {
                        manager.handleCancel()
                    }
                )
                .transition(.opacity)
                // 每次弹出时用 id 强制重建 View，确保 selectedScreen 重置为默认值（nil = 所有显示器）
                .id(manager.selectorTitle + manager.selectorMessage)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.isShowingSelector)
    }
}

// MARK: - 私有屏幕标识符扩展
private extension NSScreen {
    var screenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }
}


// MARK: - 预览
#Preview {
    ZStack {
        LiquidGlassColors.deepBackground
            .ignoresSafeArea()

        DisplaySelectorSheet(
            title: t("displaySelector.title"),
            message: t("displaySelector.message"),
            allowsBackgroundDismiss: false,
            onSelectDSH: nil,
            onSelect: { screen in
                print("Selected screen: \(screen?.localizedName ?? "All")")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}
