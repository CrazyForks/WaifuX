import Foundation
import Security

enum SteamServiceLoginState: Equatable {
    case idle
    case loggingIn
    case waitingForMobileConfirmation
    case waitingForCode
    case success
    case failed(String)
}

enum SteamServiceError: LocalizedError {
    case unavailable(String)
    case busy
    case notAuthenticated
    case authenticationFailed(String, String?)
    case downloadFailed(String, String?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .busy: return "Steam 登录正在进行中。"
        case .notAuthenticated: return "Steam 会话尚未登录。"
        case .authenticationFailed(let message, _): return message
        case .downloadFailed(let message, _): return message
        case .cancelled: return "Steam 下载已取消。"
        }
    }

    var errorCode: String? {
        switch self {
        case .authenticationFailed(_, let code), .downloadFailed(_, let code):
            return code
        default:
            return nil
        }
    }
}

/// Owns one long-lived SteamKit2 process and keeps its refresh-token session
/// alive across Workshop downloads and app launches.
final class SteamServiceManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = SteamServiceManager()

    @Published private(set) var isAvailable = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var accountName = ""
    @Published private(set) var steamID = ""
    @Published private(set) var loginState: SteamServiceLoginState = .idle

    private let ioQueue = DispatchQueue(label: "com.waifux.app.steam-service", qos: .userInitiated)
    private let keychainService = "com.waifux.app.SteamService"
    private let usernameKey = "steam_service_username"
    private let loginIDKey = "steam_service_login_id"
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var requestHandlers: [String: (Bool, String?, String?, [String: Any]?) -> Void] = [:]
    private var downloadHandlers: [String: (String, String?, String?, [String: Any]?) -> Void] = [:]
    private var loginContinuation: CheckedContinuation<Void, Error>?
    private var loginRequestID: String?
    private var loginUsername = ""
    private var restoringSession = false
    private var restoreWaiters: [CheckedContinuation<Bool, Never>] = []
    private var explicitShutdown = false
    private var restartWorkItem: DispatchWorkItem?
    private var restartCount = 0
    private var loginID: UInt32
    private var sessionIsLoggedIn = false

    private override init() {
        loginID = Self.loadLoginID(forKey: loginIDKey)
        super.init()
    }

    func start() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.explicitShutdown = false
            self.startOnQueue()
        }
    }

    func shutdown() {
        ioQueue.sync {
            explicitShutdown = true
            restartWorkItem?.cancel()
            restartWorkItem = nil
            sendCommandOnQueue("shutdown")
            try? input?.close()
            let deadline = Date().addingTimeInterval(1.5)
            while process?.isRunning == true && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process?.isRunning == true {
                process?.terminate()
            }
            process = nil
            input = nil
            updateOnMain {
                self.isAvailable = false
                self.isLoggedIn = false
                self.accountName = ""
                self.steamID = ""
                self.loginState = .idle
            }
        }
    }

    /// Returns false only when the helper is not embedded in the current app
    /// build. It does not perform a network request.
    var canUseEmbeddedService: Bool {
        serviceLaunchConfiguration() != nil
    }

    func login(username: String, password: String, guardCode: String? = nil) async throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            throw SteamServiceError.authenticationFailed("Steam 用户名和密码不能为空。", "MISSING_CREDENTIALS")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamServiceError.unavailable("Steam 服务已释放。"))
                    return
                }
                guard self.loginContinuation == nil else {
                    continuation.resume(throwing: SteamServiceError.busy)
                    return
                }
                guard self.ensureStartedOnQueue() else {
                    continuation.resume(throwing: SteamServiceError.unavailable(
                        "WaifuX Steam 服务不可用，请重新构建应用。"
                    ))
                    return
                }

                self.loginContinuation = continuation
                self.loginUsername = username
                self.restoringSession = false
                self.updateOnMain {
                    self.loginState = .loggingIn
                }
                var fields: [String: Any] = [
                    "username": username,
                    "password": password,
                    "loginId": self.loginID
                ]
                if case .value(let guardData) = self.keychainRead(
                    account: self.guardDataAccount(username)
                ) {
                    fields["guardData"] = guardData
                }
                if let guardCode = guardCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !guardCode.isEmpty {
                    fields["guardCode"] = guardCode
                }
                self.sendCommandOnQueue("loginPassword", fields: fields) { [weak self] success, message, errorCode, _ in
                    guard let self, !success else { return }
                    self.finishLoginOnQueue(.failure(
                        SteamServiceError.authenticationFailed(
                            message ?? "Steam 登录失败。",
                            errorCode
                        )
                    ))
                }
            }
        }
    }

    func submitGuardCode(_ code: String) {
        ioQueue.async { [weak self] in
            guard let self, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sendCommandOnQueue("submitChallenge", fields: ["code": code])
        }
    }

    func cancelLogin() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            sendCommandOnQueue("cancelLogin")
            finishLoginOnQueue(.failure(SteamServiceError.cancelled))
        }
    }

    func logout() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let username = UserDefaults.standard.string(forKey: usernameKey) ?? accountName
            sendCommandOnQueue("logout")
            if !username.isEmpty {
                _ = deleteKeychainValue(account: refreshTokenAccount(username))
                _ = deleteKeychainValue(account: guardDataAccount(username))
            }
            UserDefaults.standard.removeObject(forKey: usernameKey)
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            updateOnMain {
                self.isLoggedIn = false
                self.accountName = ""
                self.steamID = ""
                self.loginState = .idle
            }
        }
    }

    func downloadItem(
        workshopID: String,
        outputRoot: URL,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !workshopID.isEmpty else {
            throw SteamServiceError.downloadFailed("Workshop ID 不能为空。", "INVALID_WORKSHOP_ID")
        }
        guard await waitForRestoredSessionIfNeeded() else {
            throw SteamServiceError.notAuthenticated
        }

        let taskID = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                ioQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: SteamServiceError.unavailable("Steam 服务已释放。"))
                        return
                    }
                    guard self.ensureStartedOnQueue() else {
                        continuation.resume(throwing: SteamServiceError.unavailable(
                            "WaifuX Steam 服务不可用，请重新构建应用。"
                        ))
                        return
                    }
                    guard self.sessionIsLoggedIn else {
                        continuation.resume(throwing: SteamServiceError.notAuthenticated)
                        return
                    }

                    self.downloadHandlers[taskID] = { state, message, errorCode, payload in
                        switch state {
                        case "downloading":
                            if let received = payload?["receivedBytes"] as? NSNumber,
                               let total = payload?["totalBytes"] as? NSNumber,
                               total.doubleValue > 0 {
                                progressHandler?(min(1, max(0, received.doubleValue / total.doubleValue)))
                            }
                        case "completed":
                            guard let path = payload?["outputPath"] as? String else {
                                continuation.resume(throwing: SteamServiceError.downloadFailed(
                                    "Steam 服务未返回下载路径。",
                                    "MISSING_OUTPUT_PATH"
                                ))
                                return
                            }
                            continuation.resume(returning: URL(fileURLWithPath: path))
                        case "cancelled":
                            continuation.resume(throwing: SteamServiceError.cancelled)
                        case "failed":
                            continuation.resume(throwing: SteamServiceError.downloadFailed(
                                message ?? "Workshop 下载失败。",
                                errorCode
                            ))
                        default:
                            break
                        }
                        if state == "completed" || state == "cancelled" || state == "failed" {
                            self.downloadHandlers.removeValue(forKey: taskID)
                        }
                    }

                    self.sendCommandOnQueue("download", fields: [
                        "taskId": taskID,
                        "workshopId": workshopID,
                        "outputRoot": outputRoot.path
                    ]) { [weak self] success, message, errorCode, _ in
                        guard let self, !success else { return }
                        let handler = self.downloadHandlers.removeValue(forKey: taskID)
                        handler?("failed", message, errorCode, nil)
                    }
                }
            }
        }, onCancel: {
            self.cancelDownload(taskID: taskID)
        })
    }

    func cancelDownload(taskID: String) {
        ioQueue.async { [weak self] in
            self?.sendCommandOnQueue("cancelDownload", fields: ["taskId": taskID])
        }
    }

    private func startOnQueue() {
        guard process?.isRunning != true else {
            restoreSessionOnQueue()
            return
        }
        guard let launch = serviceLaunchConfiguration() else {
            updateOnMain {
                self.isAvailable = false
                self.loginState = .failed("WaifuX Steam 服务组件不可用。")
            }
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.ioQueue.async {
                self.handleTerminationOnQueue(
                    status: terminatedProcess.terminationStatus,
                    reason: terminatedProcess.terminationReason
                )
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ioQueue.async { self?.consumeOutputOnQueue(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[WaifuXSteamService] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            restartCount = 0
            updateOnMain {
                self.isAvailable = true
            }
            sendCommandOnQueue("hello")
            restoreSessionOnQueue()
        } catch {
            handleServiceFailureOnQueue("Steam 服务启动失败：\(error.localizedDescription)")
        }
    }

    private func ensureStartedOnQueue() -> Bool {
        if process?.isRunning != true {
            startOnQueue()
        }
        return process?.isRunning == true
    }

    private func restoreSessionOnQueue() {
        guard loginContinuation == nil,
              !restoringSession,
              let username = UserDefaults.standard.string(forKey: usernameKey),
              !username.isEmpty,
              case .value(let token) = keychainRead(account: refreshTokenAccount(username)) else {
            return
        }
        restoringSession = true
        loginUsername = username
        updateOnMain {
            self.loginState = .loggingIn
        }
        sendCommandOnQueue("restoreSession", fields: [
            "username": username,
            "refreshToken": token,
            "loginId": loginID
        ])
    }

    private func waitForRestoredSessionIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                if self.sessionIsLoggedIn {
                    continuation.resume(returning: true)
                    return
                }
                if !self.restoringSession {
                    self.restoreSessionOnQueue()
                }
                if self.restoringSession {
                    self.restoreWaiters.append(continuation)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func resolveRestoreWaitersOnQueue(isLoggedIn: Bool) {
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0.resume(returning: isLoggedIn) }
    }

    private func consumeOutputOnQueue(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = object as? [String: Any] else {
                continue
            }
            handleEventOnQueue(event)
        }
    }

    private func handleEventOnQueue(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "response":
            let requestID = event["requestId"] as? String
            let success = (event["success"] as? Bool) ?? false
            let handler = requestID.flatMap { requestHandlers.removeValue(forKey: $0) }
            handler?(
                success,
                event["message"] as? String,
                event["errorCode"] as? String,
                event["data"] as? [String: Any]
            )
        case "authState":
            handleAuthEventOnQueue(event)
        case "downloadState":
            guard let taskID = event["taskId"] as? String,
                  let state = event["state"] as? String,
                  let handler = downloadHandlers[taskID] else { return }
            handler(
                state,
                event["message"] as? String,
                event["errorCode"] as? String,
                event
            )
        default:
            break
        }
    }

    private func handleAuthEventOnQueue(_ event: [String: Any]) {
        guard let state = event["state"] as? String else { return }
        let username = event["accountName"] as? String
        let resolvedUsername = username?.isEmpty == false ? username! : loginUsername
        switch state {
        case "connecting", "authenticating", "reconnecting":
            if state == "reconnecting" {
                sessionIsLoggedIn = false
            }
            updateOnMain {
                self.loginState = .loggingIn
                if state == "reconnecting" {
                    self.isLoggedIn = false
                }
            }
        case "waitingMobile":
            updateOnMain {
                self.loginState = .waitingForMobileConfirmation
            }
        case "mobileCode", "emailCode":
            updateOnMain {
                self.loginState = .waitingForCode
            }
        case "loggedIn":
            let resolvedSteamID = event["steamId"] as? String ?? steamID
            if let token = event["refreshToken"] as? String, !token.isEmpty {
                _ = setKeychainValue(token, account: refreshTokenAccount(resolvedUsername))
            }
            if let guardData = event["guardData"] as? String, !guardData.isEmpty {
                _ = setKeychainValue(guardData, account: guardDataAccount(resolvedUsername))
            }
            UserDefaults.standard.set(resolvedUsername, forKey: usernameKey)
            restoringSession = false
            restartCount = 0
            sessionIsLoggedIn = true
            resolveRestoreWaitersOnQueue(isLoggedIn: true)
            updateOnMain {
                self.isLoggedIn = true
                self.accountName = resolvedUsername
                self.steamID = resolvedSteamID
                self.loginState = .success
            }
            if loginContinuation != nil {
                finishLoginOnQueue(.success(()))
            }
        case "loggedOut":
            let wasRestoring = restoringSession
            restoringSession = false
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            updateOnMain {
                self.isLoggedIn = false
                self.steamID = ""
                self.loginState = wasRestoring ? .failed("保存的 Steam 会话已失效，请重新登录。") : .idle
            }
            if wasRestoring, let username = UserDefaults.standard.string(forKey: usernameKey) {
                _ = deleteKeychainValue(account: refreshTokenAccount(username))
                _ = deleteKeychainValue(account: guardDataAccount(username))
            }
        case "failed":
            let message = event["message"] as? String ?? "Steam 登录失败。"
            let errorCode = event["errorCode"] as? String
            let wasRestoring = restoringSession
            restoringSession = false
            sessionIsLoggedIn = false
            resolveRestoreWaitersOnQueue(isLoggedIn: false)
            if wasRestoring, errorCode == "AUTH_FAILED",
               let username = UserDefaults.standard.string(forKey: usernameKey) {
                _ = deleteKeychainValue(account: refreshTokenAccount(username))
                _ = deleteKeychainValue(account: guardDataAccount(username))
            }
            updateOnMain {
                self.isLoggedIn = false
                self.loginState = .failed(message)
            }
            if loginContinuation != nil {
                finishLoginOnQueue(.failure(SteamServiceError.authenticationFailed(message, errorCode)))
            }
        default:
            break
        }
    }

    private func finishLoginOnQueue(_ result: Result<Void, Error>) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil
        loginRequestID = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func sendCommandOnQueue(
        _ command: String,
        fields: [String: Any] = [:],
        completion: ((Bool, String?, String?, [String: Any]?) -> Void)? = nil
    ) {
        guard let input, process?.isRunning == true else {
            completion?(false, "Steam 服务未运行。", "SERVICE_UNAVAILABLE", nil)
            return
        }
        let requestID = UUID().uuidString
        var payload: [String: Any] = ["command": command, "requestId": requestID]
        fields.forEach { payload[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion?(false, "Steam 服务命令编码失败。", "ENCODE_FAILED", nil)
            return
        }
        if let completion {
            requestHandlers[requestID] = completion
        }
        var line = data
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            requestHandlers.removeValue(forKey: requestID)
            completion?(false, error.localizedDescription, "WRITE_FAILED", nil)
        }
        if command == "loginPassword" {
            loginRequestID = requestID
        }
    }

    private func handleTerminationOnQueue(status: Int32, reason: Process.TerminationReason) {
        process = nil
        input = nil
        sessionIsLoggedIn = false
        resolveRestoreWaitersOnQueue(isLoggedIn: false)
        updateOnMain {
            self.isAvailable = false
        }
        if loginContinuation != nil {
            finishLoginOnQueue(.failure(SteamServiceError.unavailable(
                "Steam 服务已退出（\(status)，\(reason.rawValue)）。"
            )))
        }
        let pendingDownloads = downloadHandlers
        downloadHandlers.removeAll()
        pendingDownloads.values.forEach { $0("failed", "Steam 服务已退出。", "SERVICE_TERMINATED", nil) }
        guard !explicitShutdown, restartCount < 5 else { return }
        let delay = min(30.0, pow(2.0, Double(restartCount)))
        restartCount += 1
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startOnQueue()
        }
        restartWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleServiceFailureOnQueue(_ message: String) {
        updateOnMain {
            self.isAvailable = false
            self.loginState = .failed(message)
        }
        finishLoginOnQueue(.failure(SteamServiceError.unavailable(message)))
    }

    private struct LaunchConfiguration {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private func serviceLaunchConfiguration() -> LaunchConfiguration? {
        if let configured = ProcessInfo.processInfo.environment["WAIFUX_STEAM_SERVICE_PATH"],
           !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return LaunchConfiguration(executableURL: url, arguments: [], environment: ProcessInfo.processInfo.environment)
            }
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return nil
        #endif

        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("WaifuXSteamService/\(architecture)") ,
            Bundle.main.resourceURL?.appendingPathComponent("Resources/WaifuXSteamService/\(architecture)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/SteamService/\(architecture)")
        ].compactMap { $0 }

        for root in candidates {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let executable = runtime.appendingPathComponent("dotnet")
            let assembly = root.appendingPathComponent("app/WaifuXSteamService.dll")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  FileManager.default.fileExists(atPath: assembly.path) else { continue }
            var environment = ProcessInfo.processInfo.environment
            environment["DOTNET_ROOT"] = runtime.path
            return LaunchConfiguration(
                executableURL: executable,
                arguments: [assembly.path],
                environment: environment
            )
        }
        return nil
    }

    private static func loadLoginID(forKey key: String) -> UInt32 {
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber,
           number.uint32Value != 0 {
            return number.uint32Value
        }
        let value = UInt32.random(in: 1...UInt32.max)
        UserDefaults.standard.set(Int(value), forKey: key)
        return value
    }

    private func refreshTokenAccount(_ username: String) -> String {
        "refresh-token:\(username.lowercased())"
    }

    private func guardDataAccount(_ username: String) -> String {
        "guard-data:\(username.lowercased())"
    }

    private enum KeychainRead {
        case value(String)
        case notFound
        case failure(OSStatus)
    }

    private func keychainRead(account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return .failure(errSecDecode)
        }
        return .value(value)
    }

    private func setKeychainValue(_ value: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil)
        }
        return updateStatus
    }

    private func deleteKeychainValue(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private func updateOnMain(_ block: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            block()
        }
    }
}
