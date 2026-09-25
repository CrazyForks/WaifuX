//  WallpaperExtensionAgentHealer.swift
//  扩展保活（App 内置，无额外常驻服务）——参考 Phosphene 的自愈设计
//
//  背景（2026-09-24 18:23 日志实锤）：macOS 27 的 pkd 会自发
//  「remove all extension instances: caller = pkd」，杀掉
//  WaifuXWallpaperExtension（宿主 App 在跑也会发生）；WallpaperAgent 收到
//  interruption 后 runtime-resolver 判「Computed lifecycle action nothing」，
//  ≥3 小时不重新拉载，桌面静默死掉。
//
//  旧的 WallpaperExtensionKeeper（独立 LaunchAgent + lsregister/pluginkit
//  序列）退役：注册工具操作本身可能唤醒 pkd 清点插件库，且 revive 验证窗口
//  实测不稳定（150s 内经常拉不起来）。macOS 26 时代「不 killall WallpaperAgent」
//  的铁律针对的是「扩展还活着时重启会回收健康实例」；如今扩展已被 pkd 杀死，
//  重启 agent 是唯一出路，且 agent 启动必然重新 acquire 扩展，不碰 pluginkit。
//
//  新方案（Phosphene 验证的路线，全部在 App 进程内）：
//  1. 30s 周期检查：系统壁纸仍选中我们的扩展 && 扩展进程连续 2 个周期不存在
//     → killall WallpaperAgent。launchd 立即拉起新 agent，新 agent 重建壁纸
//     管线时必然重新 acquire 扩展（全程不做任何 lsregister/pluginkit 写操作）。
//  2. 监听扩展侧 SpiralRecovery 的 agentStuck Darwin 通知（agent 空连接螺旋，
//     扩展还活着但被晾死）→ 同样 killall WallpaperAgent。
//  3. 20s 冷却 + 验证窗口 90s（keeper 实测 agent 重拉载 75–90s）+
//     失败指数退避（30s → 600s 封顶）。
//
//  参考：kageroumado/phosphene (MIT) —— SpiralRecovery 的 Darwin 通知 +
//  README「auto-heals by restarting the agent」。

import Foundation
import os

/// @unchecked Sendable：全部可变状态由 stateLock 保护；Darwin 回调可能从
/// 任意线程触发 heal，锁已覆盖。
final class WallpaperExtensionAgentHealer: @unchecked Sendable {
    static let shared = WallpaperExtensionAgentHealer()

    /// 与扩展侧 SpiralRecovery.agentStuckNotification 保持一致。
    private static let agentStuckDarwinNotification = "com.waifux.app.wallpaper.agentStuck"

    private let log = OSLog(subsystem: "com.waifux.app", category: "ExtensionHealer")

    // MARK: 参数（对齐 Phosphene SpiralRecovery 与 keeper 实测值）
    private let pollInterval: TimeInterval = 30
    private let confirmTicks = 2                 // 连续 2 个周期进程都缺失才动手（防 proc 表抖动）
    private let healCooldown: TimeInterval = 20  // Phosphene 同款最小信号间隔
    private let verifyWindow: TimeInterval = 90  // agent 重启后等待扩展重新拉载的窗口
    private let backoffBase: TimeInterval = 30
    private let backoffCap: TimeInterval = 600

    // MARK: 状态
    private let stateLock = NSLock()
    private var started = false
    private var consecutiveMissing = 0
    private var lastHealAt: Date?
    private var pendingVerifySince: Date?
    private var backoffDelay: TimeInterval = 0

    private init() {}

    // MARK: - 启动（幂等；主线程调用，Timer 挂 main RunLoop）

    func start() {
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        installDarwinObserver()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        os_log(.info, log: log, "ExtensionHealer started (poll=%{public}llds)", Int(pollInterval))
    }

    // MARK: - Darwin 通知（扩展 agentStuck）

    private func installDarwinObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let healer = Unmanaged<WallpaperExtensionAgentHealer>.fromOpaque(observer).takeUnretainedValue()
                healer.handleAgentStuckSignal()
            },
            Self.agentStuckDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    fileprivate func handleAgentStuckSignal() {
        // 扩展侧已连续 4 次空连接实锤 agent 螺旋，无需防抖确认
        heal(reason: "spiral-signal-from-extension")
    }

    // MARK: - 周期检查

    private func tick() {
        let selection = WallpaperStoreSelectionProbe.currentSelection()
        guard selection == .selected else {
            // 用户没选我们（或读不到 Index.plist），一切归零
            stateLock.lock()
            consecutiveMissing = 0
            stateLock.unlock()
            return
        }

        let pids = extensionProcessPids()
        if !pids.isEmpty {
            verifySuccessIfPending()
            stateLock.lock()
            consecutiveMissing = 0
            stateLock.unlock()
            return
        }

        verifyTimeoutIfPending()

        stateLock.lock()
        consecutiveMissing += 1
        let shouldHeal = consecutiveMissing >= confirmTicks
        stateLock.unlock()

        if shouldHeal {
            heal(reason: "extension-process-missing")
        }
    }

    // MARK: - 自愈动作

    private func heal(reason: String) {
        stateLock.lock()
        if let last = lastHealAt {
            let elapsed = Date().timeIntervalSince(last)
            let cooldown = healCooldown + backoffDelay
            if elapsed < cooldown {
                stateLock.unlock()
                os_log(.info, log: log, "heal skipped (%{public}@): cooldown %{public}lld/%{public}lld", reason, Int64(elapsed), Int64(cooldown))
                return
            }
        }
        let now = Date()
        lastHealAt = now
        pendingVerifySince = now
        stateLock.unlock()

        os_log(.info, log: log, "extension dead while selected (%{public}@) → killall WallpaperAgent", reason)
        let ok = killWallpaperAgent()
        os_log(.info, log: log, "killall WallpaperAgent %{public}@", ok ? "done" : "failed")
    }

    private func verifySuccessIfPending() {
        stateLock.lock()
        guard pendingVerifySince != nil else {
            stateLock.unlock()
            return
        }
        pendingVerifySince = nil
        backoffDelay = 0
        stateLock.unlock()
        os_log(.info, log: log, "extension relaunched after heal — backoff reset")
    }

    private func verifyTimeoutIfPending() {
        stateLock.lock()
        guard let since = pendingVerifySince else {
            stateLock.unlock()
            return
        }
        guard Date().timeIntervalSince(since) > verifyWindow else {
            stateLock.unlock()
            return
        }
        pendingVerifySince = nil
        backoffDelay = min(backoffDelay == 0 ? backoffBase : backoffDelay * 2, backoffCap)
        let delay = backoffDelay
        stateLock.unlock()
        os_log(.error, log: log, "extension NOT relaunched within %{public}llds — backing off %{public}llds", Int64(verifyWindow), Int64(delay))
    }

    // MARK: - 系统探查

    private func killWallpaperAgent() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 扩展进程枚举（与 keeper 同款 libproc 实现）。桌面实例与锁屏实例共用同一
    /// 可执行名，任何实例存活都算活着——绝不误杀健康 agent。
    private func extensionProcessPids() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 8)
        // buffersize 单位是字节（libproc 语义），返回值是实际填充的 pid 个数
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result: [pid_t] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) {
            var buf = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            if String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("WaifuXWallpaperExtension") {
                result.append(pid)
            }
        }
        return result
    }
}
