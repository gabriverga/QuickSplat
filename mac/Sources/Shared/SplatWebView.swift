import AppKit
import WebKit

/// Keeps track of the scheme tasks that are still running. Thread-safe (used from the file reader queue).
final class ActiveTasks {
    private var ids = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func insert(_ id: ObjectIdentifier) { lock.lock(); ids.insert(id); lock.unlock() }
    @discardableResult
    func remove(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.remove(id) != nil }
    func contains(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

/// Serves the viewer page and the previewed files on a private URL scheme:
///   sqv://app/index.html, sqv://app/viewer.js   -> bundled web viewer
///   sqv://app/file/<id>/<name>                 -> a file registered with `register(_:)`
/// Everything is on one origin, so the page needs no CORS and no file:// access.
final class SplatSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sqv"

    private let webDir: URL
    private var files: [String: URL] = [:]
    private let active = ActiveTasks()
    private let reader = DispatchQueue(label: "sqv.file-reader", qos: .userInitiated)

    init(webDir: URL) {
        self.webDir = webDir
        super.init()
    }

    func register(_ url: URL) -> String {
        let id = UUID().uuidString
        files[id] = url
        return id
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let parts = url.path.split(separator: "/").map { String($0) }

        if parts.count >= 2 && parts[0] == "file" {
            guard let fileURL = files[parts[1]] else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            streamFile(fileURL, requestURL: url, task: urlSchemeTask)
            return
        }

        // bundled viewer files
        let name = parts.last ?? "index.html"
        let fileURL = webDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "text/javascript; charset=utf-8"
        case "css": mime = "text/css; charset=utf-8"
        default: mime = "application/octet-stream"
        }
        let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } else {
            urlSchemeTask.didFailWithError(URLError(.unknown))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    /// Streams a (possibly huge) file in 4 MB chunks read on a background queue.
    private func streamFile(_ fileURL: URL, requestURL: URL, task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task as AnyObject)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let headers = [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(size),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers),
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            task.didFailWithError(URLError(.cannotOpenFile))
            return
        }
        active.insert(id)
        task.didReceive(response)

        let active = self.active
        reader.async {
            defer { try? handle.close() }
            while active.contains(id) {
                let chunk = handle.readData(ofLength: 4 << 20)
                if chunk.isEmpty { break }
                // sync keeps chunks in order and limits memory to one chunk in flight
                DispatchQueue.main.sync {
                    if active.contains(id) { task.didReceive(chunk) }
                }
            }
            DispatchQueue.main.async {
                if active.remove(id) { task.didFinish() }
            }
        }
    }
}

/// A view hosting the web viewer. Call `open(_:)` for each file.
final class SplatWebView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let handler: SplatSchemeHandler
    private(set) var isPageLoaded = false
    private var pendingScript: String?
    var onPageLoaded: (() -> Void)?

    init(webDir: URL) {
        let schemeHandler = SplatSchemeHandler(webDir: webDir)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: SplatSchemeHandler.scheme)
        handler = schemeHandler
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.118, alpha: 1).cgColor

        webView.setValue(false, forKey: "drawsBackground")     // no white flash while loading
        if #available(macOS 13.3, *) { webView.isInspectable = true }   // Safari > Develop for debugging
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        loadPage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func loadPage() {
        isPageLoaded = false
        if let url = URL(string: "\(SplatSchemeHandler.scheme)://app/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    func open(_ url: URL) {
        let id = handler.register(url)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
        let src = "\(SplatSchemeHandler.scheme)://app/file/\(id)/\(encodedName)"
        let script = "window.sqvOpen(\(FileInfo.json(for: url, src: src)))"
        if isPageLoaded {
            webView.evaluateJavaScript(script, completionHandler: nil)
        } else {
            pendingScript = script
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        if let script = pendingScript {
            pendingScript = nil
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onPageLoaded?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }
}

/// Builds the JSON object passed to window.sqvOpen().
enum FileInfo {
    static let splatExtensions: Set<String> = ["splat", "ksplat", "spz", "sog"]
    static let allExtensions: [String] = ["ply", "splat", "ksplat", "spz", "sog"]

    static func json(for url: URL, src: String) -> String {
        let ext = url.pathExtension.lowercased()
        var dict: [String: Any] = [
            "src": src,
            "name": url.lastPathComponent,
            "path": url.path,
            "mainThreadFetch": true,
        ]

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        if let size = values?.fileSize { dict["size"] = size }
        let iso = ISO8601DateFormatter()
        if let created = values?.creationDate { dict["created"] = iso.string(from: created) }
        if let modified = values?.contentModificationDate { dict["modified"] = iso.string(from: modified) }

        if splatExtensions.contains(ext) {
            dict["kind"] = "splat"
        } else {
            let ply = PlyHeader.read(url)
            dict["kind"] = ply.kind == .splat ? "splat" : "points"   // points + meshes go to the PLY loader
            if ply.shDegree >= 0 { dict["shDegree"] = ply.shDegree }
            if ply.vertexCount >= 0 { dict["vertexCount"] = ply.vertexCount }
            if let first = ply.comments.first {
                dict["comment"] = first
                dict["comments"] = ply.comments
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
