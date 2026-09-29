import Foundation

/// 让 Kingfisher 发出的 `*.wallsflow.com` 图片请求绕过系统代理（直连）。
///
/// 背景：Wallsflow 站点的 Cloudflare 挑战按**出口 IP** 下发——本机全局流量走系统代理
/// （FastStunnel）时，封面图会拿到 403 挑战页（`cf-mitigated: challenge`），图片全白；
/// 改直连则放行。Kingfisher 的 `ImageDownloader` 只有全局 `sessionConfiguration`，
/// 无法按 host 分流代理，因此退到传输层用 URLProtocol 分流：
/// 只拦截 wallsflow 域名，先直连，失败（含 403/503 挑战）再回退系统代理。
final class WallsflowDirectURLProtocol: URLProtocol, @unchecked Sendable {

    /// 标记头：避免被自己二次拦截造成无限递归。
    private static let handledHeader = "X-WaifuX-Wallsflow-Direct"

    private static let directSession: URLSession = makeSession(bypassingSystemProxy: true)
    private static let proxySession: URLSession = makeSession(bypassingSystemProxy: false)

    private static func makeSession(bypassingSystemProxy: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        if bypassingSystemProxy {
            // 空字典 = 不使用任何代理（nil 会继续跟随系统设置）。
            config.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: config)
    }

    /// 注意：URLProtocol 基类已有 `task`（URLSessionTask?）属性，这里必须换个名字。
    private var activeTask: URLSessionTask?

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: handledHeader) == nil else { return false }
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == "wallsflow.com" || host.hasSuffix(".wallsflow.com")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("1", forHTTPHeaderField: handledHeader)
        return request
    }

    override func startLoading() {
        start(using: Self.directSession, allowProxyFallback: true)
    }

    override func stopLoading() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// - Parameter allowProxyFallback: 直连失败（网络层错误或 403/503 挑战）时是否回退系统代理重试一次。
    private func start(using session: URLSession, allowProxyFallback: Bool) {
        let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let hitChallenge = statusCode == 403 || statusCode == 503
            if allowProxyFallback, error != nil || hitChallenge {
                // 直连被针对（挑战）或不可达 → 换系统代理再试一次，覆盖「必须靠代理出网」的环境。
                self.start(using: Self.proxySession, allowProxyFallback: false)
                return
            }

            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let response else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            if let data, !data.isEmpty {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.activeTask = dataTask
        dataTask.resume()
    }
}
