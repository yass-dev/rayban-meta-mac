import AppKit
import Foundation
import VisorKit

// visor-web: the glasses from a page in the browser. A menu bar app with no window: it serves
// http://127.0.0.1:47392 and opens it.
// With --setup [--repo DIR] it is the guided setup instead: http://127.0.0.1:47393 drives DIR/setup.sh.

let setupMode = CommandLine.arguments.contains("--setup")
let port: UInt16 = setupMode ? 47393 : 47392
let url = URL(string: "http://127.0.0.1:\(port)/")!

/// The repository the setup runs from: --repo, else the package this binary was built from.
func repoDir() -> URL {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--repo"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

func findWebDir() -> URL {
    if let env = ProcessInfo.processInfo.environment["VISOR_WEB_DIR"] { return URL(fileURLWithPath: env) }
    if let res = Bundle.main.resourceURL?.appendingPathComponent("web"), FileManager.default.fileExists(atPath: res.appendingPathComponent("index.html").path) { return res }
    // Run from the build folder: the package's own web/ folder.
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: HTTPServer?
    var controller: Controller?
    var routes: Routes?
    var item: NSStatusItem?
    var setup: SetupRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if setupMode { startSetup(); return }
        let server = HTTPServer(port: port)
        do {
            try server.start()
        } catch {
            // Another copy already serves the page: show it and leave.
            NSWorkspace.shared.open(url)
            NSApp.terminate(nil)
            return
        }
        let controller = Controller()
        let routes = Routes(controller: controller, port: port, webDir: findWebDir())
        installAddOns(controller, routes)
        server.handler = { await routes.handle($0) }
        server.onEventsClient = { controller.addClient($0) }
        self.server = server
        self.controller = controller
        self.routes = routes
        controller.log("Interface prête sur \(url.absoluteString)")
        setUpMenu()
        if !CommandLine.arguments.contains("--no-open") { NSWorkspace.shared.open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSWorkspace.shared.open(url)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.disconnect()
        if setup?.isRunning == true { _ = setup?.stop() }
    }

    /// The guided setup page. Its own port, so Lunettes.app can start beside it at the end.
    private func startSetup() {
        let server = HTTPServer(port: port)
        do {
            try server.start()
        } catch {
            NSWorkspace.shared.open(url)
            NSApp.terminate(nil)
            return
        }
        let runner = SetupRunner(repo: repoDir())
        let routes = SetupRoutes(runner: runner, port: port, webDir: findWebDir())
        server.handler = { await routes.handle($0) }
        server.onEventsClient = { runner.addClient($0) }
        self.server = server
        self.setup = runner
        print("Setup page: \(url.absoluteString)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Setup")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open the setup page", action: #selector(openUI), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit the setup", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        self.item = item
        if !CommandLine.arguments.contains("--no-open") { NSWorkspace.shared.open(url) }
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Lunettes")
            if button.image == nil { button.title = "👓" }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Ouvrir l'interface", action: #selector(openUI), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Ouvrir le dossier d'export", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Lunettes", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        self.item = item
    }

    @objc func openUI() { NSWorkspace.shared.open(url) }
    @objc func openFolder() {
        guard let dir = controller?.exportDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
    @objc func quit() { NSApp.terminate(nil) }
}


setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
