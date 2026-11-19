import AppKit
import UniformTypeIdentifiers

@main
enum QuickSplatApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let previewExtensionID = "it.gabriverga.QuickSplat.Preview"

    private var viewerWindows: [NSWindow] = []
    private var welcomeWindow: NSWindow?
    private var openedFiles = false

    private var webDir: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("web")
    }

    // MARK: lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerQuickLookExtension()
        NSApp.activate(ignoringOtherApps: true)
        // files passed at launch arrive through application(_:open:); show the welcome window otherwise
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !self.openedFiles && self.viewerWindows.isEmpty { self.showWelcome() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles = true
        for url in urls { openViewer(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        viewerWindows.removeAll { $0 === window }
        if window === welcomeWindow { welcomeWindow = nil }
    }

    // MARK: viewer windows

    func openViewer(_ url: URL) {
        let view = SplatWebView(webDir: webDir)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.setFrameAutosaveName("QuickSplatWindow")
        if viewerWindows.isEmpty { window.center() } else if let last = viewerWindows.last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        viewerWindows.append(window)
        window.makeKeyAndOrderFront(nil)
        view.open(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        welcomeWindow?.close()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileInfo.allExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            openedFiles = true
            for url in panel.urls { openViewer(url) }
        }
    }

    @objc func openExtensionSettings(_ sender: Any?) {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: welcome window

    private func showWelcome() {
        if let w = welcomeWindow { w.makeKeyAndOrderFront(nil); return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "QuickSplat"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let drop = DropView(frame: window.contentRect(forFrameRect: window.frame))
        drop.onDrop = { [weak self] urls in
            self?.openedFiles = true
            for url in urls { self?.openViewer(url) }
        }

        let title = NSTextField(labelWithString: "QuickSplat")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Quick Look is installed: select a .ply, .spz, .splat, .ksplat or .sog file in Finder and press Space.\n\n" +
            "Drop a file here (or use Open…) to view it in a window.\n\n" +
            "If Space shows nothing, enable \u{201C}QuickSplat\u{201D} under System Settings \u{203A} General \u{203A} " +
            "Login Items & Extensions \u{203A} Quick Look.")
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 440

        let openButton = NSButton(title: "Open\u{2026}", target: self, action: #selector(openDocument(_:)))
        openButton.keyEquivalent = "\r"
        let settingsButton = NSButton(title: "Quick Look Settings\u{2026}", target: self, action: #selector(openExtensionSettings(_:)))
        let buttons = NSStackView(views: [settingsButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        drop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: drop.topAnchor),
        ])

        window.contentView = drop
        window.center()
        window.makeKeyAndOrderFront(nil)
        welcomeWindow = window
    }

    // MARK: Quick Look extension registration

    /// The extension is normally picked up when the app is launched from /Applications;
    /// this makes sure it is registered and enabled.
    private func registerQuickLookExtension() {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return }
        let appex = plugins.appendingPathComponent("QuickSplatPreview.appex").path
        let extensionID = AppDelegate.previewExtensionID
        DispatchQueue.global(qos: .utility).async {
            AppDelegate.run("/usr/bin/pluginkit", ["-a", appex])
            AppDelegate.run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID])
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("QuickSplat: failed to run \(path): \(error)")
        }
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About QuickSplat", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quick Look Settings\u{2026}", action: #selector(openExtensionSettings(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide QuickSplat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit QuickSplat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open\u{2026}", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// Accepts files dropped on the welcome window.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
