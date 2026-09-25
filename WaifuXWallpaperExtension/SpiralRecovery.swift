//  SpiralRecovery.swift
//  WallpaperAgent 死亡螺旋自愈信号（移植自 Phosphene 的同名设计）
//
//  背景（macOS 27 实测）：WallpaperAgent 偶发进入「空连接螺旋」——不断接受
//  XPC 连接却不发任何方法调用就断开（2026-09-24 18:03 同时观察到 snapshot
//  连续 NSCocoaErrorDomain 4101）。正常操作永远不会产生连续空连接：每个真实
//  连接至少服务一个方法，会把计数清零。因此连续 4 次空连接只能是真螺旋。
//
//  动作：发 Darwin 通知给主 App（App 内 WallpaperExtensionAgentHealer 监听
//  后 killall WallpaperAgent；launchd 立即拉起新 agent，新 agent 重建壁纸
//  管线时必然重新 acquire 本扩展）。扩展自己无权重启宿主。
//
//  参考：kageroumado/phosphene PhospheneExtension/SpiralRecovery.swift (MIT)

import Foundation
import os

enum SpiralRecovery {
    /// 主 App 的 WallpaperExtensionAgentHealer 监听此通知后 killall WallpaperAgent。
    static let agentStuckNotification = "com.waifux.app.wallpaper.agentStuck"

    /// 触发自愈的连续空连接数。压低阈值是为了在 RunningBoard 挂起我们之前出手。
    private static let emptyThreshold = 4

    /// 两次自愈信号的最小间隔（agent kill + 重拉需要几秒）。
    private static let recoveryCooldown: TimeInterval = 20.0

    /// 连续空连接计数。withLock 返回自增后的值，决策放锁外。
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    private static var lastRecoveryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("waifux-last-agent-recovery")
    }

    /// 连接至少服务过一个方法 → agent 在正常对话，清零计数。
    static func noteHealthyConnection() {
        counter.withLock { $0 = 0 }
    }

    /// 连接被接受但没调用任何方法就断开。达到阈值时同步发出自愈信号。
    static func noteEmptyConnection(pid: Int32) {
        let count = counter.withLock { n -> Int in n += 1; return n }
        guard count >= emptyThreshold else { return }
        recover(pid: pid, count: count)
    }

    private static func recover(pid: Int32, count: Int) {
        if let data = try? Data(contentsOf: lastRecoveryURL),
           let last = Double((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            let since = Date().timeIntervalSince1970 - last
            if since < recoveryCooldown {
                extLog("  [spiral] STUCK (agent pid \(pid), \(count) empty) but signaled \(Int(since))s ago (< \(Int(recoveryCooldown))s cooldown) — holding off")
                return
            }
        }
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: lastRecoveryURL)
        extLog("  [spiral] STUCK — \(count) consecutive empty connections from agent pid \(pid), no acquire. Signaling app to killall WallpaperAgent.")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(agentStuckNotification as CFString),
            nil, nil, true,
        )
    }
}
