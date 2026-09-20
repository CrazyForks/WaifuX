import SwiftUI

// MARK: - .glassAlert 修饰符
/// 系统 `.alert` 的玻璃替代品，view-level overlay 呈现（背景压暗 + 居中玻璃卡片）。
/// 调用点迁移 = 把 `.alert(_:isPresented:actions:message:)` 换成
/// `.glassAlert(_:isPresented:message:actions:)`，按钮改用 GlassAlertAction 数组表达。
private struct GlassAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var message: String?
    var icon: String?
    var iconTint: Color
    let actions: [GlassAlertAction]

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    GlassAlertDimmedCard(
                        title: title,
                        message: message,
                        icon: icon,
                        iconTint: iconTint,
                        actions: actions
                    ) { index in
                        let action = actions[index]
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isPresented = false
                        }
                        // 关闭动画之外执行回调，避免 handler 引发的界面变化被卷入 withAnimation
                        if let handler = action.handler {
                            DispatchQueue.main.async(execute: handler)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isPresented)
    }
}

/// 背景压暗 + 玻璃卡片的组合，GlassAlertCenter 也复用
struct GlassAlertDimmedCard: View {
    let title: String
    var message: String?
    var icon: String?
    var iconTint: Color
    var actions: [GlassAlertAction]
    var accessory: AnyView? = nil
    let fire: (Int) -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.38))
                .contentShape(Rectangle())
                .onTapGesture {} // 吞掉背景点击，防止误触弹窗后面的控件

            GlassAlertCard(
                title: title,
                message: message,
                icon: icon,
                iconTint: iconTint,
                actions: actions,
                accessory: accessory,
                fire: fire
            )
        }
        .transition(.opacity)
    }
}

extension View {
    func glassAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        icon: String? = nil,
        iconTint: Color = LiquidGlassColors.primaryPink,
        actions: [GlassAlertAction]
    ) -> some View {
        modifier(
            GlassAlertModifier(
                isPresented: isPresented,
                title: title,
                message: message,
                icon: icon,
                iconTint: iconTint,
                actions: actions
            )
        )
    }
}

// MARK: - GlassAlertCenter
/// 无 SwiftUI 上下文（Service 层）的玻璃 alert 中转：present 入队，窗口根部挂
/// `glassAlertCenterOverlay()` 呈现。同一时刻只显示一条，关闭后自动展示下一条。
@MainActor
final class GlassAlertCenter: ObservableObject {
    static let shared = GlassAlertCenter()

    struct Request: Identifiable {
        let id = UUID()
        let title: String
        var message: String?
        var icon: String?
        var iconTint: Color
        var actions: [GlassAlertAction]
        var accessory: AnyView?
    }

    @Published private(set) var current: Request?

    private var queue: [Request] = []

    private init() {}

    func present(
        title: String,
        message: String? = nil,
        icon: String? = nil,
        iconTint: Color = LiquidGlassColors.primaryPink,
        accessory: AnyView? = nil,
        actions: [GlassAlertAction]
    ) {
        let request = Request(
            title: title,
            message: message,
            icon: icon,
            iconTint: iconTint,
            actions: actions,
            accessory: accessory
        )
        if current == nil {
            current = request
        } else {
            queue.append(request)
        }
    }

    func handleTap(at index: Int) {
        guard let request = current, request.actions.indices.contains(index) else { return }
        let action = request.actions[index]
        current = queue.isEmpty ? nil : queue.removeFirst()
        if let handler = action.handler {
            DispatchQueue.main.async(execute: handler)
        }
    }

    /// 主窗口极致释放等场景清空待处理请求，避免闭包继续持有旧界面上下文
    func cancelAll() {
        queue.removeAll()
        current = nil
    }
}

// MARK: - Center 呈现层
struct GlassAlertCenterOverlay: View {
    @ObservedObject private var center = GlassAlertCenter.shared

    var body: some View {
        ZStack {
            if let request = center.current {
                GlassAlertDimmedCard(
                    title: request.title,
                    message: request.message,
                    icon: request.icon,
                    iconTint: request.iconTint,
                    actions: request.actions,
                    accessory: request.accessory
                ) { index in
                    center.handleTap(at: index)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: center.current?.id)
    }
}

extension View {
    /// 挂在窗口根视图（与 displaySelectorOverlay 同位），GlassAlertCenter.present 的内容在这里呈现
    func glassAlertCenterOverlay() -> some View {
        overlay {
            GlassAlertCenterOverlay()
        }
    }
}
