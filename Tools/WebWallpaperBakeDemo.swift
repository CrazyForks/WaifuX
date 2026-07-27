import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import WebKit

enum DemoError: LocalizedError {
    case invalidArguments(String)
    case wallpaperNotFound(String)
    case missingEntryFile(String)
    case loadFailed(String)
    case mediaNotReady
    case snapshotFailed
    case writerFailed(String)
    case ffprobeFailed(String)
    case ffmpegFailed(String)
    case probeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .wallpaperNotFound(let message),
             .missingEntryFile(let message),
             .loadFailed(let message),
             .writerFailed(let message),
             .ffprobeFailed(let message),
             .ffmpegFailed(let message),
             .probeFailed(let message):
            return message
        case .mediaNotReady:
            return "Wallpaper media never became ready"
        case .snapshotFailed:
            return "WKWebView failed to produce a snapshot"
        }
    }
}

enum ParticipationMode: String, CaseIterable {
    case orderedOut = "ordered-out"
    case frontInvisible = "front-invisible"

    var label: String { rawValue }
}

struct CLIOptions {
    let wallpaperURL: URL
    let outputURL: URL
    let duration: Double
    let requestedFPS: Double?
    let requestedSize: CGSize?
    let probeOnly: Bool
    let forcedMode: ParticipationMode?
    let logDirectoryURL: URL

    static func parse(arguments: [String]) throws -> CLIOptions {
        var wallpaperPath: String?
        var outputPath = "tmp/web-bake-demo/output.mp4"
        var duration = 12.0
        var requestedFPS: Double?
        var requestedSize: CGSize?
        var probeOnly = false
        var forcedMode: ParticipationMode?
        var logDirPath: String?

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--wallpaper":
                wallpaperPath = iterator.next()
            case "--out":
                if let value = iterator.next() { outputPath = value }
            case "--duration":
                if let value = iterator.next(), let parsed = Double(value), parsed > 0 {
                    duration = parsed
                } else {
                    throw DemoError.invalidArguments("`--duration` must be a positive number")
                }
            case "--fps":
                guard let value = iterator.next() else {
                    throw DemoError.invalidArguments("Missing value for `--fps`")
                }
                if value == "auto" {
                    requestedFPS = nil
                } else if let parsed = Double(value), parsed >= 1 {
                    requestedFPS = parsed
                } else {
                    throw DemoError.invalidArguments("`--fps` must be `auto` or a positive number")
                }
            case "--size":
                guard let value = iterator.next() else {
                    throw DemoError.invalidArguments("Missing value for `--size`")
                }
                if value == "native" {
                    requestedSize = nil
                } else {
                    let parts = value.lowercased().split(separator: "x")
                    guard parts.count == 2,
                          let width = Double(parts[0]),
                          let height = Double(parts[1]),
                          width >= 2,
                          height >= 2 else {
                        throw DemoError.invalidArguments("`--size` must be `native` or `WIDTHxHEIGHT`")
                    }
                    requestedSize = CGSize(width: width, height: height)
                }
            case "--probe-only":
                probeOnly = true
            case "--participation":
                guard let value = iterator.next() else {
                    throw DemoError.invalidArguments("Missing value for `--participation`")
                }
                forcedMode = ParticipationMode(rawValue: value)
                if forcedMode == nil {
                    throw DemoError.invalidArguments("`--participation` must be `ordered-out` or `front-invisible`")
                }
            case "--log-dir":
                logDirPath = iterator.next()
            case "--help":
                throw DemoError.invalidArguments(Self.usage)
            default:
                throw DemoError.invalidArguments("Unknown argument: \(argument)\n\n\(Self.usage)")
            }
        }

        guard let wallpaperPath else {
            throw DemoError.invalidArguments("Missing required `--wallpaper`\n\n\(Self.usage)")
        }

        let wallpaperURL = URL(fileURLWithPath: wallpaperPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let logDirectoryURL: URL = {
            if let logDirPath {
                return URL(fileURLWithPath: logDirPath).standardizedFileURL
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            return URL(fileURLWithPath: "tmp/web-bake-demo/\(stamp)")
                .standardizedFileURL
        }()

        return CLIOptions(
            wallpaperURL: wallpaperURL,
            outputURL: outputURL,
            duration: duration,
            requestedFPS: requestedFPS,
            requestedSize: requestedSize,
            probeOnly: probeOnly,
            forcedMode: forcedMode,
            logDirectoryURL: logDirectoryURL
        )
    }

    static let usage = """
    Usage:
      WebWallpaperBakeDemo --wallpaper /path/to/project [--out /path/to/output.mp4]
                           [--duration 12] [--fps auto|60] [--size native|1920x1080]
                           [--probe-only] [--participation ordered-out|front-invisible]
                           [--log-dir /path/to/logs]
    """
}

struct EntryFileResolution {
    let rootURL: URL
    let entryFileURL: URL
    let defaultPropertiesJSON: String?
}

struct MediaElementState: Decodable {
    let tag: String
    let id: String
    let src: String
    let paused: Bool
    let muted: Bool
    let volume: Double
    let currentTime: Double
    let duration: Double
    let loop: Bool
    let readyState: Int
    let videoWidth: Int
    let videoHeight: Int
}

struct LocalMediaAsset {
    let url: URL
    let width: Int
    let height: Int
    let fps: Double?
    let duration: Double?
    let hasAudio: Bool
}

struct AudioPlan {
    let sourceURL: URL
    let volume: Double
}

struct ImageMetrics {
    let alphaMean: Double
    let lumaMean: Double
    let lumaVariance: Double
}

final class WebWallpaperSession: NSObject, WKNavigationDelegate {
    private let resolution: EntryFileResolution
    private let mode: ParticipationMode
    private let canvasSize: CGSize
    private let logDirectoryURL: URL

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pendingLoadCompletion: ((Result<Void, Error>) -> Void)?

    init(
        resolution: EntryFileResolution,
        mode: ParticipationMode,
        canvasSize: CGSize,
        logDirectoryURL: URL
    ) {
        self.resolution = resolution
        self.mode = mode
        self.canvasSize = canvasSize
        self.logDirectoryURL = logDirectoryURL
        super.init()
    }

    func load(completion: @escaping (Result<Void, Error>) -> Void) {
        pendingLoadCompletion = completion

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        let window = NSWindow(
            contentRect: NSRect(origin: screenFrame.origin, size: canvasSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.level = .normal
        window.isReleasedWhenClosed = false

        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        let userContentController = WKUserContentController()
        userContentController.addUserScript(Self.localFileCompatScript)
        userContentController.addUserScript(Self.silentMediaGuardScript)
        userContentController.addUserScript(Self.offlineBakeClockScript)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: NSRect(origin: .zero, size: canvasSize), configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.contentsScale = 1

        window.contentView = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.layer?.contentsScale = 1
        window.contentView?.addSubview(webView)
        webView.frame = window.contentView?.bounds ?? webView.frame
        webView.autoresizingMask = [.width, .height]

        self.window = window
        self.webView = webView

        switch mode {
        case .orderedOut:
            window.orderOut(nil)
        case .frontInvisible:
            window.alphaValue = 0.001
            window.orderFrontRegardless()
        }

        webView.loadFileURL(
            resolution.entryFileURL,
            allowingReadAccessTo: resolution.rootURL
        )
    }

    func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.close()
        window = nil
    }

    func bootstrapAndAwaitReady(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let propsBlock: String = {
            guard let json = resolution.defaultPropertiesJSON,
                  let data = json.data(using: .utf8) else {
                return ""
            }
            let encoded = data.base64EncodedString()
            return "try{var props=JSON.parse(atob(\"\(encoded)\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);}}catch(e){}"
        }()
        let source = "(function(){try{document.documentElement.style.cssText='width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';document.body.style.setProperty('width','100%');document.body.style.setProperty('height','100%');window.dispatchEvent(new Event('resize'));if(window.__demoSilenceAllMedia)window.__demoSilenceAllMedia();}catch(e){}\(propsBlock)return true;})();"
        webView.evaluateJavaScript(source) { [weak self] _, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            self.waitUntilMediaReady(deadline: Date().addingTimeInterval(10)) { result in
                switch result {
                case .success:
                    self.reapplyPropertiesIfNeeded()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func inspectMediaState(completion: @escaping (Result<[MediaElementState], Error>) -> Void) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let js = """
        (function() {
          try {
            return JSON.stringify(Array.from(document.querySelectorAll('video,audio')).map(function(el) {
              return {
                tag: String(el.tagName || '').toLowerCase(),
                id: String(el.id || ''),
                src: String(el.currentSrc || el.src || ''),
                paused: !!el.paused,
                muted: !!el.muted,
                volume: Number(el.volume || 0),
                currentTime: Number(el.currentTime || 0),
                duration: Number(el.duration || 0),
                loop: !!el.loop,
                readyState: Number(el.readyState || 0),
                videoWidth: Number(el.videoWidth || 0),
                videoHeight: Number(el.videoHeight || 0)
              };
            }));
          } catch (e) {
            return "[]";
          }
        })();
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8) else {
                completion(.success([]))
                return
            }
            do {
                let decoded = try JSONDecoder().decode([MediaElementState].self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func probeMediaFrameRate(completion: @escaping (Double?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        let js = """
        (function() {
          try {
            if (!window.__wxBakeClock || typeof window.__wxBakeClock.probeMediaFrameRate !== 'function') {
              return Promise.resolve(null);
            }
            return window.__wxBakeClock.probeMediaFrameRate();
          } catch (e) {
            return Promise.resolve(null);
          }
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            completion((result as? NSNumber)?.doubleValue)
        }
    }

    func captureImage(
        at seconds: Double,
        paintFrames: Int = 2,
        completion: @escaping (Result<NSImage, Error>) -> Void
    ) {
        setContentTime(seconds, paintFrames: paintFrames) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.takeSnapshot(completion: completion)
            }
        }
    }

    private func setContentTime(
        _ seconds: Double,
        paintFrames: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let js = String(
            format: """
            (function(){
              try {
                if (!window.__wxBakeClock || typeof window.__wxBakeClock.advanceAndPaint !== 'function') return false;
                if (window.__demoSilenceAllMedia) window.__demoSilenceAllMedia();
                window.__wxBakeClock.advanceAndPaint(%.3f, %d, '%@');
                return true;
              } catch (e) {
                return false;
              }
            })();
            """,
            max(0, seconds) * 1000.0,
            max(1, paintFrames),
            token
        )
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard (result as? Bool) == true else {
                completion(.failure(DemoError.loadFailed("Failed to advance the virtual clock")))
                return
            }
            self.pollReadyToken(token, deadline: Date().addingTimeInterval(5), completion: completion)
        }
    }

    private func pollReadyToken(
        _ token: String,
        deadline: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let escaped = token.replacingOccurrences(of: "'", with: "\\'")
        let js = "Boolean(window.__wxBakeClock && window.__wxBakeClock.lastReadyToken === '\(escaped)');"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            if (result as? Bool) == true {
                completion(.success(()))
                return
            }
            if Date() >= deadline {
                completion(.failure(DemoError.loadFailed("Timed out waiting for frame readiness token \(token)")))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.pollReadyToken(token, deadline: deadline, completion: completion)
            }
        }
    }

    private func takeSnapshot(completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: canvasSize)
        configuration.snapshotWidth = NSNumber(value: Double(canvasSize.width))
        webView.takeSnapshot(with: configuration) { image, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let image else {
                completion(.failure(DemoError.snapshotFailed))
                return
            }
            completion(.success(image))
        }
    }

    private func waitUntilMediaReady(
        deadline: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let webView else {
            completion(.failure(DemoError.loadFailed("Web view was not created")))
            return
        }
        let js = """
        (function() {
          try {
            if (window.__demoSilenceAllMedia) window.__demoSilenceAllMedia();
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return false;
            return media.some(function(el) {
              var src = el.currentSrc || el.src || '';
              return !!src && Number(el.readyState || 0) >= 2;
            });
          } catch (e) {
            return false;
          }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true {
                completion(.success(()))
                return
            }
            if Date() >= deadline {
                completion(.failure(DemoError.mediaNotReady))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitUntilMediaReady(deadline: deadline, completion: completion)
            }
        }
    }

    private func reapplyPropertiesIfNeeded() {
        guard let json = resolution.defaultPropertiesJSON,
              let webView,
              let data = json.data(using: .utf8) else {
            return
        }
        let encoded = data.base64EncodedString()
        let js = "(function(){try{var props=JSON.parse(atob(\"\(encoded)\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);}if(window.__demoSilenceAllMedia)window.__demoSilenceAllMedia();}catch(e){}})();"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingLoadCompletion?(.success(()))
        pendingLoadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingLoadCompletion?(.failure(error))
        pendingLoadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingLoadCompletion?(.failure(error))
        pendingLoadCompletion = nil
    }

    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;

            function resolveFetchURL(input) {
              if (typeof input === "string") return input;
              if (!input) return "";
              if (typeof input.href === "string" && input.href) return input.href;
              if (typeof input.url === "string" && input.url) return input.url;
              try { return String(input); } catch (e) { return ""; }
            }

            function isLocalNonHTTPURL(url) {
              if (!url) return false;
              var lower = String(url).toLowerCase();
              if (lower.indexOf("http:") === 0 || lower.indexOf("https:") === 0) return false;
              if (lower.indexOf("data:") === 0 || lower.indexOf("blob:") === 0) return false;
              return true;
            }

            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (isLocalNonHTTPURL(s)) this.removeAttribute("crossorigin");
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }

            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = resolveFetchURL(input);
                if (isLocalNonHTTPURL(url)) {
                  return new Promise(function(resolve, reject) {
                    try {
                      var xhr = new XMLHttpRequest();
                      xhr.open("GET", String(url), true);
                      xhr.responseType = "arraybuffer";
                      xhr.onload = function() {
                        if (xhr.status === 200 || xhr.status === 0) {
                          var headers = new Headers();
                          try {
                            var contentType = xhr.getResponseHeader("Content-Type");
                            if (contentType) headers.set("Content-Type", contentType);
                          } catch (e) {}
                          if (!headers.has("Content-Type")) {
                            headers.set("Content-Type", "application/octet-stream");
                          }
                          resolve(new Response(xhr.response || new ArrayBuffer(0), {
                            status: 200,
                            statusText: "OK",
                            headers: headers
                          }));
                        } else {
                          reject(new Error("HTTP " + xhr.status + " Unable to load " + url));
                        }
                      };
                      xhr.onerror = function() { reject(new Error("0 Unable to load " + url)); };
                      xhr.onabort = function() { reject(new Error("Aborted loading " + url)); };
                      xhr.send();
                    } catch (e) {
                      reject(e);
                    }
                  });
                }
                return origFetch.call(this, input, init);
              };
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let silentMediaGuardScript = WKUserScript(
        source: """
        (function() {
          'use strict';
          if (window.__demoSilenceInstalled) return;
          window.__demoSilenceInstalled = true;

          function hush(el) {
            try {
              el.defaultMuted = true;
              el.muted = true;
            } catch (e) {}
          }

          function hushAll() {
            try {
              document.querySelectorAll('video,audio').forEach(hush);
            } catch (e) {}
          }

          var origPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function() {
            hush(this);
            return origPlay.apply(this, arguments);
          };

          var origSetAttribute = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function(name, value) {
            var result = origSetAttribute.apply(this, arguments);
            if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src') hush(this);
            return result;
          };

          window.__demoSilenceAllMedia = hushAll;
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
              hushAll();
              try {
                var observer = new MutationObserver(hushAll);
                observer.observe(document.documentElement || document, { childList: true, subtree: true });
              } catch (e) {}
            }, { once: true });
          } else {
            hushAll();
          }
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let offlineBakeClockScript = WKUserScript(
        source: """
        (function() {
          'use strict';
          if (window.__wxBakeClock) return;
          var contentMs = 0;
          var startMs = 0;
          var epochAtStart = 0;
          var running = false;
          var timerId = 1;
          var timers = Object.create(null);
          var origRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
          var origSTO = window.setTimeout.bind(window);
          var origCTO = window.clearTimeout.bind(window);
          var origDateNow = Date.now.bind(Date);
          var origPerfNow = (window.performance && performance.now) ? performance.now.bind(performance) : function() { return origDateNow(); };
          var videoTargets = typeof WeakMap === 'function' ? new WeakMap() : null;

          function nowMs() { return running ? contentMs : origPerfNow(); }
          function epochNowMs() { return running ? (epochAtStart + (contentMs - startMs)) : origDateNow(); }

          function flushTimers() {
            var ids = Object.keys(timers);
            for (var i = 0; i < ids.length; i++) {
              var id = ids[i];
              var t = timers[id];
              if (!t) continue;
              if (contentMs + 1e-6 < t.fireAt) continue;
              try { t.fn.apply(null, t.args || []); } catch (e) {}
              if (t.interval > 0) {
                t.fireAt = contentMs + t.interval;
                while (t.fireAt <= contentMs) t.fireAt += t.interval;
              } else {
                delete timers[id];
              }
            }
          }

          function waitForVideoFrame(el) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 800);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                resolve();
              }
              try {
                if (typeof el.requestVideoFrameCallback === 'function') {
                  el.requestVideoFrameCallback(function() { finish(); });
                  return;
                }
              } catch (e) {}
              if (origRAF) origRAF(function() { finish(); });
              else origSTO(finish, 0);
            });
          }

          function seekVideo(el, target) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 1200);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                try { el.removeEventListener('seeked', onSeeked); } catch (e) {}
                waitForVideoFrame(el).then(resolve, resolve);
              }
              function onSeeked() { finish(); }
              try {
                el.pause();
                if (!isFinite(el.duration) || el.duration <= 0) {
                  resolve();
                  return;
                }
                if (isFinite(el.currentTime) && Math.abs(el.currentTime - target) <= 0.0005 && !el.seeking) {
                  finish();
                  return;
                }
                el.addEventListener('seeked', onSeeked, { once: true });
                el.currentTime = target;
                if (!el.seeking && isFinite(el.currentTime) && Math.abs(el.currentTime - target) <= 0.0005) {
                  finish();
                }
              } catch (e) {
                resolve();
              }
            });
          }

          function lastVideoTarget(el) {
            try { return videoTargets ? videoTargets.get(el) : el.__wxBakeLastTarget; }
            catch (e) { return undefined; }
          }

          function rememberVideoTarget(el, target) {
            try {
              if (videoTargets) videoTargets.set(el, target);
              else el.__wxBakeLastTarget = target;
            } catch (e) {}
          }

          function playVideoUntil(el, target) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 1800);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                try { el.pause(); } catch (e) {}
                rememberVideoTarget(el, target);
                waitForVideoFrame(el).then(resolve, resolve);
              }
              function poll() {
                if (finished) return;
                try {
                  if (isFinite(el.currentTime) && el.currentTime + 0.0005 >= target) {
                    finish();
                    return;
                  }
                } catch (e) {}
                if (origRAF) origRAF(poll);
                else origSTO(poll, 8);
              }
              try {
                el.playbackRate = 1;
                var p = el.play();
                if (p && typeof p.catch === 'function') p.catch(function(){});
              } catch (e) {}
              poll();
            });
          }

          function synchronizeVideo(el, target) {
            var prior = lastVideoTarget(el);
            var current = NaN;
            try { current = el.currentTime; } catch (e) {}
            var needsSeek = !isFinite(prior) || target + 0.001 < prior || !isFinite(current) || Math.abs(current - prior) > 0.12;
            if (needsSeek) {
              return seekVideo(el, target).then(function() { rememberVideoTarget(el, target); });
            }
            return playVideoUntil(el, target);
          }

          function syncMedia() {
            var sec = (contentMs - startMs) / 1000.0;
            var waits = [];
            try {
              var nodes = document.querySelectorAll('video,audio');
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                try {
                  var target = (isFinite(el.duration) && el.duration > 0) ? (sec % el.duration) : sec;
                  if (el.tagName === 'VIDEO') waits.push(synchronizeVideo(el, target));
                  else {
                    el.pause();
                    if (!isFinite(el.currentTime) || Math.abs(el.currentTime - target) > 0.0005) el.currentTime = target;
                  }
                } catch (e) {}
              }
            } catch (e) {}
            return Promise.all(waits);
          }

          if (origRAF) {
            window.requestAnimationFrame = function(cb) {
              return origRAF(function(realT) {
                var t = running ? contentMs : realT;
                try { cb(t); } catch (e) {}
              });
            };
          }

          window.__wxBakeClock = {
            enable: function() {
              if (running) return true;
              contentMs = origPerfNow();
              startMs = contentMs;
              epochAtStart = origDateNow();
              running = true;
              try {
                if (window.performance && typeof Object.defineProperty === 'function') {
                  Object.defineProperty(window.performance, 'now', {
                    configurable: true,
                    writable: true,
                    value: function() { return nowMs(); }
                  });
                }
              } catch (e) {
                try { performance.now = function() { return nowMs(); }; } catch (e2) {}
              }
              try { Date.now = function() { return Math.floor(epochNowMs()); }; } catch (e) {}
              window.setTimeout = function(fn, delay) {
                var id = timerId++;
                var ms = (typeof delay === 'number' && isFinite(delay)) ? Math.max(0, delay) : 0;
                var args = [].slice.call(arguments, 2);
                timers[id] = { fn: fn, fireAt: contentMs + ms, interval: 0, args: args };
                return id;
              };
              window.clearTimeout = function(id) { delete timers[id]; };
              window.setInterval = function(fn, delay) {
                var id = timerId++;
                var ms = (typeof delay === 'number' && isFinite(delay) && delay > 0) ? delay : 1;
                var args = [].slice.call(arguments, 2);
                timers[id] = { fn: fn, fireAt: contentMs + ms, interval: ms, args: args };
                return id;
              };
              window.clearInterval = function(id) { delete timers[id]; };
              return true;
            },
            setContentTime: function(ms) {
              if (!running) this.enable();
              var offset = Math.max(0, Number(ms) || 0);
              contentMs = startMs + offset;
              flushTimers();
              return syncMedia().then(function() { return contentMs - startMs; }, function() { return contentMs - startMs; });
            },
            afterFrames: function(count, token) {
              count = Math.max(1, count | 0);
              return new Promise(function(resolve) {
                if (!origRAF) {
                  origSTO(function() { resolve(token || 0); }, 16);
                  return;
                }
                var left = count;
                function step() {
                  left -= 1;
                  if (left <= 0) {
                    resolve(token || 0);
                    return;
                  }
                  origRAF(step);
                }
                origRAF(step);
              });
            },
            advanceAndPaint: function(ms, count, token) {
              var self = this;
              return Promise.resolve(self.setContentTime(ms))
                .then(function() { return self.afterFrames(count, token); })
                .then(function() {
                  self.lastReadyToken = String(token || '');
                  return true;
                }, function() {
                  self.lastReadyToken = String(token || '');
                  return false;
                });
            },
            probeMediaFrameRate: function() {
              return new Promise(function(resolve) {
                var videos = [];
                try {
                  videos = Array.prototype.slice.call(document.querySelectorAll('video'))
                    .filter(function(el) { return el.readyState >= 2 && isFinite(el.duration) && el.duration > 0; })
                    .sort(function(a, b) {
                      var scoreA = (a.paused ? 0 : 1000000) + a.videoWidth * a.videoHeight;
                      var scoreB = (b.paused ? 0 : 1000000) + b.videoWidth * b.videoHeight;
                      return scoreB - scoreA;
                    });
                } catch (e) {}
                var video = videos[0];
                if (!video || typeof video.requestVideoFrameCallback !== 'function') {
                  resolve(null);
                  return;
                }

                var done = false;
                var first = null;
                var last = null;
                var timeout = origSTO(function() { finish(null); }, 2200);
                function finish(rate) {
                  if (done) return;
                  done = true;
                  try { origCTO(timeout); } catch (e) {}
                  resolve(rate);
                }
                function sample(_, metadata) {
                  if (done) return;
                  var mediaTime = Number(metadata && metadata.mediaTime);
                  var presented = Number(metadata && metadata.presentedFrames);
                  if (isFinite(mediaTime) && isFinite(presented)) {
                    if (!first) first = { mediaTime: mediaTime, presented: presented };
                    last = { mediaTime: mediaTime, presented: presented };
                    var dt = last.mediaTime - first.mediaTime;
                    var frames = last.presented - first.presented;
                    if (dt >= 0.45 && frames >= 12) {
                      var rate = frames / dt;
                      finish(isFinite(rate) && rate >= 10 ? rate : null);
                      return;
                    }
                  }
                  try { video.requestVideoFrameCallback(sample); } catch (e) { finish(null); }
                }
                try {
                  if (video.paused) {
                    var p = video.play();
                    if (p && typeof p.catch === 'function') p.catch(function(){});
                  }
                  video.requestVideoFrameCallback(sample);
                } catch (e) {
                  finish(null);
                }
              });
            },
            lastReadyToken: ''
          };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}

final class DemoRunner: NSObject, NSApplicationDelegate {
    private let options: CLIOptions
    private var exitCode = 0

    private var resolution: EntryFileResolution?
    private var selectedMode: ParticipationMode?
    private var selectedSize: CGSize = .zero
    private var selectedFPS: Double = 60
    private var selectedAudioPlan: AudioPlan?

    init(options: CLIOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(
                at: options.logDirectoryURL,
                withIntermediateDirectories: true
            )
            resolution = try resolveEntryFile(for: options.wallpaperURL)
            begin()
        } catch {
            finish(with: error)
        }
    }

    private func begin() {
        guard let resolution else {
            finish(with: DemoError.loadFailed("Failed to resolve wallpaper entry"))
            return
        }

        do {
            let assetHints = try inspectLocalMediaAssets(in: resolution.rootURL)
            let baseSize = options.requestedSize ?? inferCanvasSize(from: assetHints)
            selectedSize = baseSize
            let logicalCanvasSize = logicalCanvasSize(for: baseSize)
            chooseParticipationMode(resolution: resolution, canvasSize: logicalCanvasSize) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.finish(with: error)
                case .success(let mode):
                    self.selectedMode = mode
                    if self.options.probeOnly {
                        self.log("Probe succeeded with mode=\(mode.label)")
                        self.finishSuccessfully()
                        return
                    }
                    self.prepareBake(resolution: resolution, canvasSize: logicalCanvasSize, assetHints: assetHints)
                }
            }
        } catch {
            finish(with: error)
        }
    }

    private func prepareBake(
        resolution: EntryFileResolution,
        canvasSize: CGSize,
        assetHints: [LocalMediaAsset]
    ) {
        guard let selectedMode else {
            finish(with: DemoError.probeFailed("Participation mode was not selected"))
            return
        }

        let session = WebWallpaperSession(
            resolution: resolution,
            mode: selectedMode,
            canvasSize: canvasSize,
            logDirectoryURL: options.logDirectoryURL
        )
        session.load { [weak self] loadResult in
            guard let self else { return }
            switch loadResult {
            case .failure(let error):
                session.tearDown()
                self.finish(with: error)
            case .success:
                session.bootstrapAndAwaitReady { readyResult in
                    switch readyResult {
                    case .failure(let error):
                        session.tearDown()
                        self.finish(with: error)
                    case .success:
                        self.resolveBakeParameters(session: session, assetHints: assetHints) { result in
                            switch result {
                            case .failure(let error):
                                session.tearDown()
                                self.finish(with: error)
                            case .success:
                                self.startBake(session: session)
                            }
                        }
                    }
                }
            }
        }
    }

    private func resolveBakeParameters(
        session: WebWallpaperSession,
        assetHints: [LocalMediaAsset],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        session.inspectMediaState { [weak self] inspectResult in
            guard let self else { return }
            switch inspectResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let mediaStates):
                self.resolveAudioPlan(mediaStates: mediaStates, assetHints: assetHints)
                session.probeMediaFrameRate { [weak self] probed in
                    guard let self else { return }
                    if let requested = self.options.requestedFPS {
                        self.selectedFPS = requested
                    } else if let probed, probed.isFinite, probed >= 10 {
                        self.selectedFPS = probed
                    } else if let firstVideo = mediaStates.first(where: { $0.videoWidth > 0 && $0.videoHeight > 0 }),
                              firstVideo.duration > 0,
                              let hint = matchAsset(from: firstVideo.src, hints: assetHints),
                              let fps = hint.fps {
                        self.selectedFPS = fps
                    } else {
                        self.selectedFPS = 60
                    }
                    completion(.success(()))
                }
            }
        }
    }

    private func resolveAudioPlan(mediaStates: [MediaElementState], assetHints: [LocalMediaAsset]) {
        let candidates = mediaStates
            .filter { !$0.src.isEmpty }
            .sorted { lhs, rhs in
                let lhsScore = (lhs.paused ? 0 : 1_000_000) + lhs.videoWidth * lhs.videoHeight
                let rhsScore = (rhs.paused ? 0 : 1_000_000) + rhs.videoWidth * rhs.videoHeight
                return lhsScore > rhsScore
            }

        for candidate in candidates {
            guard let asset = matchAsset(from: candidate.src, hints: assetHints),
                  asset.hasAudio else {
                continue
            }
            selectedAudioPlan = AudioPlan(
                sourceURL: asset.url,
                volume: max(0, min(1, candidate.volume))
            )
            return
        }

        if let fallback = assetHints.first(where: \.hasAudio) {
            selectedAudioPlan = AudioPlan(sourceURL: fallback.url, volume: 1)
        }
    }

    private func startBake(session: WebWallpaperSession) {
        let frameRate = max(1, selectedFPS)
        let size = selectedSize
        let totalFrames = max(1, Int(ceil(options.duration * frameRate)))
        let tempVideoURL = options.logDirectoryURL.appendingPathComponent("video-only.mp4")

        do {
            try FileManager.default.createDirectory(
                at: options.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: tempVideoURL)
            try? FileManager.default.removeItem(at: options.outputURL)
        } catch {
            session.tearDown()
            finish(with: error)
            return
        }

        let bitrate = Int(min(max(Double(Int(size.width) * Int(size.height)) * frameRate * 0.10, 8_000_000), 100_000_000))

        do {
            let writer = try AVAssetWriter(outputURL: tempVideoURL, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(size.width),
                    AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoExpectedSourceFrameRateKey: frameRate,
                        AVVideoAllowFrameReorderingKey: false,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ] as [String: Any]
                ]
            )
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height)
                ]
            )
            guard writer.canAdd(input) else {
                throw DemoError.writerFailed("Could not add video input to AVAssetWriter")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw DemoError.writerFailed(writer.error?.localizedDescription ?? "AVAssetWriter failed to start")
            }
            writer.startSession(atSourceTime: .zero)

            log("Bake start mode=\(selectedMode?.label ?? "?") size=\(Int(size.width))x\(Int(size.height)) fps=\(String(format: "%.3f", frameRate)) duration=\(String(format: "%.2f", options.duration))")
            if let selectedAudioPlan {
                log("Audio plan source=\(selectedAudioPlan.sourceURL.path) volume=\(String(format: "%.3f", selectedAudioPlan.volume))")
            } else {
                log("Audio plan source=<none>")
            }

            captureFrame(
                index: 0,
                totalFrames: totalFrames,
                frameRate: frameRate,
                session: session,
                writer: writer,
                input: input,
                adaptor: adaptor,
                tempVideoURL: tempVideoURL
            )
        } catch {
            session.tearDown()
            finish(with: error)
        }
    }

    private func captureFrame(
        index: Int,
        totalFrames: Int,
        frameRate: Double,
        session: WebWallpaperSession,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        tempVideoURL: URL
    ) {
        if index >= totalFrames {
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    session.tearDown()
                    if writer.status == .completed {
                        do {
                            try self.finalizeOutput(from: tempVideoURL)
                            self.finishSuccessfully()
                        } catch {
                            self.finish(with: error)
                        }
                    } else {
                        self.finish(with: DemoError.writerFailed(writer.error?.localizedDescription ?? "AVAssetWriter failed to finish"))
                    }
                }
            }
            return
        }

        let contentTime = Double(index) / frameRate
        session.captureImage(at: contentTime) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                session.tearDown()
                writer.cancelWriting()
                self.finish(with: error)
            case .success(let image):
                autoreleasepool {
                    do {
                        try self.append(
                            image: image,
                            frameIndex: index,
                            frameRate: frameRate,
                            input: input,
                            adaptor: adaptor
                        )
                    } catch {
                        session.tearDown()
                        writer.cancelWriting()
                        self.finish(with: error)
                        return
                    }

                    if index == 0 || index == totalFrames - 1 || index % max(1, Int(round(frameRate))) == 0 {
                        self.log("Frame \(index + 1)/\(totalFrames) content=\(String(format: "%.3f", contentTime))s")
                    }
                    self.captureFrame(
                        index: index + 1,
                        totalFrames: totalFrames,
                        frameRate: frameRate,
                        session: session,
                        writer: writer,
                        input: input,
                        adaptor: adaptor,
                        tempVideoURL: tempVideoURL
                    )
                }
            }
        }
    }

    private func append(
        image: NSImage,
        frameIndex: Int,
        frameRate: Double,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws {
        guard let pool = adaptor.pixelBufferPool else {
            throw DemoError.writerFailed("Pixel buffer pool was unavailable")
        }
        if !input.isReadyForMoreMediaData {
            while !input.isReadyForMoreMediaData {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw DemoError.writerFailed("Could not create a pixel buffer")
        }
        guard draw(image: image, into: pixelBuffer) else {
            throw DemoError.writerFailed("Could not draw a snapshot into the pixel buffer")
        }

        let presentationTime = CMTime(
            value: CMTimeValue((Double(frameIndex) / frameRate * 1_000_000).rounded()),
            timescale: 1_000_000
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw DemoError.writerFailed("Failed to append video frame \(frameIndex)")
        }
    }

    private func finalizeOutput(from tempVideoURL: URL) throws {
        if let selectedAudioPlan {
            try muxAudio(
                videoURL: tempVideoURL,
                audioPlan: selectedAudioPlan,
                outputURL: options.outputURL,
                duration: options.duration
            )
            try? FileManager.default.removeItem(at: tempVideoURL)
        } else {
            try FileManager.default.moveItem(at: tempVideoURL, to: options.outputURL)
        }
    }

    private func chooseParticipationMode(
        resolution: EntryFileResolution,
        canvasSize: CGSize,
        completion: @escaping (Result<ParticipationMode, Error>) -> Void
    ) {
        if let forcedMode = options.forcedMode {
            probe(mode: forcedMode, resolution: resolution, canvasSize: canvasSize, completion: completion)
            return
        }

        probe(mode: .orderedOut, resolution: resolution, canvasSize: canvasSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                completion(.success(.orderedOut))
            case .failure(let firstError):
                self.log("ordered-out probe failed: \(firstError.localizedDescription)")
                self.probe(mode: .frontInvisible, resolution: resolution, canvasSize: canvasSize, completion: completion)
            }
        }
    }

    private func probe(
        mode: ParticipationMode,
        resolution: EntryFileResolution,
        canvasSize: CGSize,
        completion: @escaping (Result<ParticipationMode, Error>) -> Void
    ) {
        let session = WebWallpaperSession(
            resolution: resolution,
            mode: mode,
            canvasSize: canvasSize,
            logDirectoryURL: options.logDirectoryURL
        )
        session.load { [weak self] loadResult in
            guard let self else { return }
            switch loadResult {
            case .failure(let error):
                session.tearDown()
                completion(.failure(error))
            case .success:
                session.bootstrapAndAwaitReady { readyResult in
                    switch readyResult {
                    case .failure(let error):
                        session.tearDown()
                        completion(.failure(error))
                    case .success:
                        self.captureProbeFrames(session: session, mode: mode) { probeResult in
                            session.tearDown()
                            switch probeResult {
                            case .success:
                                completion(.success(mode))
                            case .failure(let error):
                                completion(.failure(error))
                            }
                        }
                    }
                }
            }
        }
    }

    private func captureProbeFrames(
        session: WebWallpaperSession,
        mode: ParticipationMode,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let probeTimes = [0.0, 5.0, min(options.duration - 0.001, 11.0)].filter { $0 >= 0 }
        var images: [NSImage] = []

        func step(_ index: Int) {
            if index >= probeTimes.count {
                do {
                    try evaluateProbe(mode: mode, images: images)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
                return
            }

            let t = probeTimes[index]
            session.captureImage(at: t) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let image):
                    images.append(image)
                    let fileURL = self.options.logDirectoryURL.appendingPathComponent("probe-\(mode.label)-\(index).png")
                    try? savePNG(image: image, to: fileURL)
                    self.log("Probe \(mode.label) t=\(String(format: "%.3f", t)) saved=\(fileURL.lastPathComponent)")
                    step(index + 1)
                }
            }
        }

        step(0)
    }

    private func evaluateProbe(mode: ParticipationMode, images: [NSImage]) throws {
        guard images.count >= 2 else {
            throw DemoError.probeFailed("Probe for \(mode.label) did not capture enough frames")
        }
        let metrics = try images.map(imageMetrics)
        let diffs = try zip(images, images.dropFirst()).map(meanAbsLumaDifference)
        let minAlpha = metrics.map(\.alphaMean).min() ?? 0
        let maxVariance = metrics.map(\.lumaVariance).max() ?? 0
        let maxDiff = diffs.max() ?? 0

        log("Probe \(mode.label) alphaMin=\(String(format: "%.4f", minAlpha)) varianceMax=\(String(format: "%.6f", maxVariance)) diffMax=\(String(format: "%.6f", maxDiff))")

        guard minAlpha > 0.30 else {
            throw DemoError.probeFailed("Probe for \(mode.label) produced transparent frames")
        }
        guard maxVariance > 0.001 else {
            throw DemoError.probeFailed("Probe for \(mode.label) produced nearly blank frames")
        }
        guard maxDiff > 0.004 else {
            throw DemoError.probeFailed("Probe for \(mode.label) did not show time-varying content")
        }
    }

    private func finishSuccessfully() {
        exitCode = 0
        terminateApp()
    }

    private func finish(with error: Error) {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        exitCode = 1
        terminateApp()
    }

    private func terminateApp() {
        NSApp.stop(nil)
        NSApp.postEvent(
            NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            )!,
            atStart: false
        )
    }

    private func log(_ message: String) {
        let line = "[demo] \(message)\n"
        fputs(line, stdout)
        fflush(stdout)
    }

    func exitStatus() -> Int32 { Int32(exitCode) }
}

@main
struct WebWallpaperBakeDemoMain {
    static func main() {
        do {
            let options = try CLIOptions.parse(arguments: CommandLine.arguments)
            let app = NSApplication.shared
            let runner = DemoRunner(options: options)
            app.setActivationPolicy(.prohibited)
            app.delegate = runner
            app.run()
            Foundation.exit(runner.exitStatus())
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private func resolveEntryFile(for wallpaperURL: URL) throws -> EntryFileResolution {
    let rootURL: URL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: wallpaperURL.path, isDirectory: &isDirectory) else {
        throw DemoError.wallpaperNotFound("Wallpaper path does not exist: \(wallpaperURL.path)")
    }

    if isDirectory.boolValue {
        rootURL = wallpaperURL
    } else {
        rootURL = wallpaperURL.deletingLastPathComponent()
    }

    let projectURL = rootURL.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DemoError.missingEntryFile("Could not read \(projectURL.path)")
    }
    let fileName = (json["file"] as? String) ?? "index.html"
    let entryFileURL = rootURL.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: entryFileURL.path) else {
        throw DemoError.missingEntryFile("Entry file is missing: \(entryFileURL.path)")
    }

    let defaultPropertiesJSON: String? = {
        guard let general = json["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any],
              !properties.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: properties),
              let string = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return string
    }()

    return EntryFileResolution(
        rootURL: rootURL,
        entryFileURL: entryFileURL,
        defaultPropertiesJSON: defaultPropertiesJSON
    )
}

private func inspectLocalMediaAssets(in rootURL: URL) throws -> [LocalMediaAsset] {
    let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    let allowedExtensions = Set(["webm", "mp4", "m4v", "mov", "mp3", "m4a", "wav", "ogg"])
    var assets: [LocalMediaAsset] = []

    while let url = enumerator?.nextObject() as? URL {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { continue }
        if let asset = try? ffprobeAsset(url: url) {
            assets.append(asset)
        }
    }

    return assets.sorted { lhs, rhs in
        let lhsScore = (lhs.hasAudio ? 1_000_000 : 0) + lhs.width * lhs.height
        let rhsScore = (rhs.hasAudio ? 1_000_000 : 0) + rhs.width * rhs.height
        return lhsScore > rhsScore
    }
}

private func ffprobeAsset(url: URL) throws -> LocalMediaAsset {
    let output = try runProcess(
        executable: "/opt/homebrew/bin/ffprobe",
        arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            url.path
        ]
    )
    guard let data = output.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = json["streams"] as? [[String: Any]] else {
        throw DemoError.ffprobeFailed("ffprobe returned unreadable JSON for \(url.path)")
    }

    let video = streams.first { ($0["codec_type"] as? String) == "video" }
    let audio = streams.first { ($0["codec_type"] as? String) == "audio" }
    let format = json["format"] as? [String: Any]

    let width = (video?["width"] as? NSNumber)?.intValue ?? 0
    let height = (video?["height"] as? NSNumber)?.intValue ?? 0
    let fps: Double? = {
        guard let rate = video?["avg_frame_rate"] as? String,
              !rate.isEmpty else {
            return nil
        }
        return parseRational(rate)
    }()
    let duration: Double? = {
        if let string = format?["duration"] as? String, let parsed = Double(string) {
            return parsed
        }
        if let string = video?["duration"] as? String, let parsed = Double(string) {
            return parsed
        }
        return nil
    }()

    return LocalMediaAsset(
        url: url,
        width: width,
        height: height,
        fps: fps,
        duration: duration,
        hasAudio: audio != nil
    )
}

private func inferCanvasSize(from hints: [LocalMediaAsset]) -> CGSize {
    if let video = hints.first(where: { $0.width > 0 && $0.height > 0 }) {
        return CGSize(width: video.width, height: video.height)
    }
    return CGSize(width: 1920, height: 1080)
}

private func logicalCanvasSize(for outputSize: CGSize) -> CGSize {
    let scale = max(1, NSScreen.main?.backingScaleFactor ?? 1)
    return CGSize(
        width: max(2, (outputSize.width / scale).rounded(.up)),
        height: max(2, (outputSize.height / scale).rounded(.up))
    )
}

private func matchAsset(from source: String, hints: [LocalMediaAsset]) -> LocalMediaAsset? {
    guard !source.isEmpty else { return nil }
    let normalized: String = {
        if let url = URL(string: source), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: source).standardizedFileURL.path
    }()
    return hints.first { $0.url.standardizedFileURL.path == normalized }
}

private func draw(image: NSImage, into pixelBuffer: CVPixelBuffer) -> Bool {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return false
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
          let context = CGContext(
            data: baseAddress,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else {
        return false
    }

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)))
    context.interpolationQuality = .high
    context.draw(
        cgImage,
        in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    )
    return true
}

private func savePNG(image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw DemoError.snapshotFailed
    }
    try png.write(to: url, options: .atomic)
}

private func imageMetrics(_ image: NSImage) throws -> ImageMetrics {
    guard let bitmap = bitmapRGBA(from: image) else {
        throw DemoError.snapshotFailed
    }
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let bytesPerRow = bitmap.bytesPerRow
    guard let data = bitmap.bitmapData else {
        throw DemoError.snapshotFailed
    }

    var alphaSum = 0.0
    var lumaSum = 0.0
    var lumaSquaredSum = 0.0
    let count = Double(width * height)

    for y in 0..<height {
        let row = data.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let pixel = row.advanced(by: x * 4)
            let b = Double(pixel[0]) / 255.0
            let g = Double(pixel[1]) / 255.0
            let r = Double(pixel[2]) / 255.0
            let a = Double(pixel[3]) / 255.0
            let luma = (0.299 * r) + (0.587 * g) + (0.114 * b)
            alphaSum += a
            lumaSum += luma
            lumaSquaredSum += luma * luma
        }
    }

    let mean = lumaSum / count
    let variance = max(0, (lumaSquaredSum / count) - (mean * mean))
    return ImageMetrics(
        alphaMean: alphaSum / count,
        lumaMean: mean,
        lumaVariance: variance
    )
}

private func meanAbsLumaDifference(_ lhs: NSImage, _ rhs: NSImage) throws -> Double {
    guard let lhsBitmap = bitmapRGBA(from: lhs),
          let rhsBitmap = bitmapRGBA(from: rhs),
          lhsBitmap.pixelsWide == rhsBitmap.pixelsWide,
          lhsBitmap.pixelsHigh == rhsBitmap.pixelsHigh,
          let lhsData = lhsBitmap.bitmapData,
          let rhsData = rhsBitmap.bitmapData else {
        throw DemoError.snapshotFailed
    }

    let width = lhsBitmap.pixelsWide
    let height = lhsBitmap.pixelsHigh
    let lhsStride = lhsBitmap.bytesPerRow
    let rhsStride = rhsBitmap.bytesPerRow
    var sum = 0.0
    let count = Double(width * height)

    for y in 0..<height {
        let lhsRow = lhsData.advanced(by: y * lhsStride)
        let rhsRow = rhsData.advanced(by: y * rhsStride)
        for x in 0..<width {
            let lp = lhsRow.advanced(by: x * 4)
            let rp = rhsRow.advanced(by: x * 4)
            let ll = (0.299 * Double(lp[2]) + 0.587 * Double(lp[1]) + 0.114 * Double(lp[0])) / 255.0
            let rl = (0.299 * Double(rp[2]) + 0.587 * Double(rp[1]) + 0.114 * Double(rp[0])) / 255.0
            sum += abs(ll - rl)
        }
    }

    return sum / count
}

private func bitmapRGBA(from image: NSImage) -> NSBitmapImageRep? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }
    let width = cgImage.width
    let height = cgImage.height
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func parseRational(_ value: String) -> Double? {
    let parts = value.split(separator: "/")
    if parts.count == 2,
       let numerator = Double(parts[0]),
       let denominator = Double(parts[1]),
       denominator != 0 {
        return numerator / denominator
    }
    return Double(value)
}

private func muxAudio(
    videoURL: URL,
    audioPlan: AudioPlan,
    outputURL: URL,
    duration: Double
) throws {
    let filter = String(format: "[1:a]volume=%.6f,apad[a]", audioPlan.volume)
    do {
        _ = try runProcess(
            executable: "/opt/homebrew/bin/ffmpeg",
            arguments: [
                "-y",
                "-i", videoURL.path,
                "-i", audioPlan.sourceURL.path,
                "-filter_complex", filter,
                "-map", "0:v:0",
                "-map", "[a]",
                "-c:v", "copy",
                "-c:a", "aac",
                "-t", String(format: "%.3f", duration),
                outputURL.path
            ]
        )
    } catch {
        throw DemoError.ffmpegFailed("ffmpeg failed to mux audio from \(audioPlan.sourceURL.lastPathComponent): \(error.localizedDescription)")
    }
}

@discardableResult
private func runProcess(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        let message = stderr.isEmpty ? stdout : stderr
        throw DemoError.ffprobeFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return stdout
}
