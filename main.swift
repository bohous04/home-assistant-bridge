// macbook-ha-bridge — single binary, two modes:
//   no args  → GUI installer/status window
//   --daemon → background poller (run by launchd)

import Foundation
import AppKit
import CoreGraphics

// MARK: - Mode dispatch

let args = CommandLine.arguments
let isDaemon = args.contains("--daemon")

// MARK: - Config

struct Config: Codable, Equatable {
    var haURL: String
    var token: String
    var entityPrefix: String
    var deviceName: String
    var pollInterval: Double
    var heartbeatInterval: Double

    static let `default` = Config(
        haURL: "http://homeassistant.local:8123",
        token: "",
        entityPrefix: "muj_macbook",
        deviceName: "Můj MacBook",
        pollInterval: 2.0,
        heartbeatInterval: 60.0
    )
}

let configDir = ("~/.config/macbook-ha-bridge" as NSString).expandingTildeInPath
let configPath = configDir + "/config.json"

func loadConfig() -> Config? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

func saveConfig(_ config: Config) throws {
    try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.outputFormatting.insert(.withoutEscapingSlashes)
    let data = try enc.encode(config)
    try data.write(to: URL(fileURLWithPath: configPath))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                            ofItemAtPath: configPath)
}

// MARK: - Detection

struct DeviceState: Equatable {
    var activeDisplayName: String
    var locked: Bool
}

func detectActiveDisplayName() -> String {
    let mainID = CGMainDisplayID()
    if CGDisplayIsBuiltin(mainID) != 0 { return "Built-in" }
    for screen in NSScreen.screens {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           id == mainID {
            return screen.localizedName
        }
    }
    return "External"
}

func detectLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

func currentState() -> DeviceState {
    DeviceState(activeDisplayName: detectActiveDisplayName(), locked: detectLocked())
}

// MARK: - HA client

final class HAClient {
    let baseURL: String
    let token: String
    let prefix: String
    let deviceName: String
    let session: URLSession

    init(config: Config) {
        self.baseURL = config.haURL.hasSuffix("/") ? String(config.haURL.dropLast()) : config.haURL
        self.token = config.token
        self.prefix = config.entityPrefix
        self.deviceName = config.deviceName
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: cfg)
    }

    func setState(entity: String, state: String, attributes: [String: Any]) {
        guard let url = URL(string: "\(baseURL)/api/states/\(entity)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["state": state, "attributes": attributes]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { _, response, error in
            if let error = error {
                fputs("[ha] \(entity) error: \(error.localizedDescription)\n", stderr)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                fputs("[ha] \(entity) HTTP \(http.statusCode)\n", stderr)
            }
        }.resume()
    }

    func push(_ state: DeviceState) {
        setState(
            entity: "sensor.\(prefix)_active_display",
            state: state.activeDisplayName,
            attributes: [
                "friendly_name": "\(deviceName) Active Display",
                "icon": "mdi:monitor"
            ]
        )
        setState(
            entity: "binary_sensor.\(prefix)_locked",
            state: state.locked ? "on" : "off",
            attributes: [
                "friendly_name": "\(deviceName) Locked",
                "icon": state.locked ? "mdi:lock" : "mdi:lock-open"
            ]
        )
    }
}

// MARK: - Daemon mode

enum DaemonRuntime {
    static var lastState: DeviceState?
    static var lastFullPush = Date(timeIntervalSince1970: 0)
    static var client: HAClient!
    static var pollInterval: Double = 2.0
    static var heartbeatInterval: Double = 60.0

    static func tick(force: Bool = false) {
        let state = currentState()
        let stateChanged = state != lastState
        let heartbeatDue = Date().timeIntervalSince(lastFullPush) >= heartbeatInterval

        if stateChanged || heartbeatDue || force {
            if stateChanged {
                fputs("[state] active=\(state.activeDisplayName) locked=\(state.locked)\n", stderr)
            }
            client.push(state)
            lastState = state
            lastFullPush = Date()
        }
    }

    static func run() {
        guard let config = loadConfig() else {
            fputs("Cannot read config at \(configPath)\n", stderr)
            exit(1)
        }
        client = HAClient(config: config)
        pollInterval = config.pollInterval
        heartbeatInterval = config.heartbeatInterval

        tick(force: true)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            fputs("[event] willSleep\n", stderr)
            var sleeping = currentState()
            sleeping.locked = true
            client.push(sleeping)
            lastState = sleeping
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            fputs("[event] didWake\n", stderr)
            lastState = nil
            tick(force: true)
        }

        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            tick()
        }

        fputs("[start] macbook-ha-bridge running, poll=\(pollInterval)s heartbeat=\(heartbeatInterval)s\n", stderr)
    }
}

// MARK: - Install manager

enum InstallStatus: Equatable {
    case notInstalled
    case running(pid: Int)
    case stopped
}

enum InstallManager {
    static let plistLabel = "cz.lnrt.macbook-ha-bridge"
    static let plistPath = ("~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist" as NSString).expandingTildeInPath
    static let logDir = ("~/Library/Logs" as NSString).expandingTildeInPath
    static let logPath = ("~/Library/Logs/macbook-ha-bridge.log" as NSString).expandingTildeInPath

    static func currentStatus() -> InstallStatus {
        guard FileManager.default.fileExists(atPath: plistPath) else { return .notInstalled }
        if let pid = launchctlPID() { return .running(pid: pid) }
        return .stopped
    }

    static func launchctlPID() -> Int? {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["print", "gui/\(getuid())/\(plistLabel)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8) ?? ""
        for raw in str.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = ") {
                return Int(t.dropFirst("pid = ".count))
            }
        }
        return nil
    }

    static func writePlist(binaryPath: String) throws {
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let plistDir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
        try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    static func install(config: Config, binaryPath: String) throws {
        try saveConfig(config)
        try writePlist(binaryPath: binaryPath)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(plistLabel)"])
        Thread.sleep(forTimeInterval: 0.8)
        let rc = runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if rc != 0 {
            throw NSError(domain: "InstallManager", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap returned \(rc)"])
        }
    }

    static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(plistLabel)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: configPath)
    }

    static func kickstart() {
        _ = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(plistLabel)"])
    }

    @discardableResult
    static func runLaunchctl(_ a: [String]) -> Int32 {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = a
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func recentLog(lines: Int = 30) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
              let s = String(data: data, encoding: .utf8) else { return "(log file empty / not yet created)" }
        let all = s.components(separatedBy: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }
}

func testHA(config: Config) -> (ok: Bool, message: String) {
    guard let url = URL(string: "\(config.haURL)/api/") else {
        return (false, "Invalid URL")
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var msg = "no response"
    URLSession.shared.dataTask(with: req) { _, response, error in
        if let error = error {
            msg = error.localizedDescription
        } else if let http = response as? HTTPURLResponse {
            if http.statusCode == 200 { ok = true; msg = "OK" }
            else if http.statusCode == 401 { msg = "HTTP 401 — token rejected" }
            else { msg = "HTTP \(http.statusCode)" }
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 8)
    return (ok, msg)
}

// MARK: - GUI mode

class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var detailsLabel: NSTextField!
    var installButton: NSButton!
    var reinstallButton: NSButton!
    var uninstallButton: NSButton!
    var openLogButton: NSButton!
    var logView: NSTextView!
    var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        buildWindow()
        refreshUI()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            self.refreshUI()
        }
    }

    func windowWillClose(_ n: Notification) {
        // Quit GUI when window closes (background daemon — pokud installed — pokračuje dál).
        NSApp.terminate(nil)
    }

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 580, height: 520)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "macbook-ha-bridge"
        window.center()
        window.delegate = self

        let v = NSView(frame: rect)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 470, width: 540, height: 32)
        statusLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        v.addSubview(statusLabel)

        detailsLabel = NSTextField(labelWithString: "")
        detailsLabel.frame = NSRect(x: 24, y: 340, width: 540, height: 124)
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        v.addSubview(detailsLabel)

        installButton = NSButton(title: "Install…", target: self, action: #selector(onInstallClicked))
        installButton.frame = NSRect(x: 24, y: 290, width: 170, height: 32)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        v.addSubview(installButton)

        reinstallButton = NSButton(title: "Reinstall / Settings…", target: self, action: #selector(onInstallClicked))
        reinstallButton.frame = NSRect(x: 24, y: 290, width: 200, height: 32)
        reinstallButton.bezelStyle = .rounded
        v.addSubview(reinstallButton)

        uninstallButton = NSButton(title: "Uninstall", target: self, action: #selector(onUninstallClicked))
        uninstallButton.frame = NSRect(x: 234, y: 290, width: 130, height: 32)
        uninstallButton.bezelStyle = .rounded
        v.addSubview(uninstallButton)

        openLogButton = NSButton(title: "Open log in Console", target: self, action: #selector(onOpenLogClicked))
        openLogButton.frame = NSRect(x: 374, y: 290, width: 180, height: 32)
        openLogButton.bezelStyle = .rounded
        v.addSubview(openLogButton)

        let logHeader = NSTextField(labelWithString: "Recent log:")
        logHeader.frame = NSRect(x: 24, y: 254, width: 200, height: 18)
        logHeader.font = .systemFont(ofSize: 12, weight: .medium)
        logHeader.textColor = .secondaryLabelColor
        v.addSubview(logHeader)

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 540, height: 224))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.font = NSFont.userFixedPitchFont(ofSize: 11)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = logView
        v.addSubview(scroll)

        window.contentView = v
        window.makeKeyAndOrderFront(nil)
    }

    func refreshUI() {
        let status = InstallManager.currentStatus()
        let cfg = loadConfig()

        switch status {
        case .notInstalled:
            statusLabel.stringValue = "● Not installed"
            statusLabel.textColor = .systemOrange
            detailsLabel.stringValue = "Klikni 'Install…' a zadej URL svého Home Assistantu + Long-Lived Access Token.\nDaemon se nainstaluje, spustí se a začne posílat stav Macu do HA."
            installButton.isHidden = false
            reinstallButton.isHidden = true
            uninstallButton.isHidden = true
            openLogButton.isHidden = !FileManager.default.fileExists(atPath: InstallManager.logPath)

        case .running(let pid):
            statusLabel.stringValue = "● Running"
            statusLabel.textColor = .systemGreen
            let s = currentState()
            let cfgInfo = cfg.map { "URL: \($0.haURL)\nPrefix: \($0.entityPrefix)    Device: \($0.deviceName)" } ?? ""
            detailsLabel.stringValue = """
            PID \(pid)
            Active display: \(s.activeDisplayName)
            Locked: \(s.locked ? "Yes" : "No")
            \(cfgInfo)
            """
            installButton.isHidden = true
            reinstallButton.isHidden = false
            uninstallButton.isHidden = false
            openLogButton.isHidden = false

        case .stopped:
            statusLabel.stringValue = "● Installed but stopped"
            statusLabel.textColor = .systemRed
            detailsLabel.stringValue = "Plist existuje, ale agent neběží.\nZkus 'Reinstall / Settings…' — restartuje agenta a (případně) opraví config."
            installButton.isHidden = true
            reinstallButton.isHidden = false
            uninstallButton.isHidden = false
            openLogButton.isHidden = false
        }

        logView.string = InstallManager.recentLog(lines: 60)
        logView.scrollRangeToVisible(NSRange(location: logView.string.count, length: 0))
    }

    @objc func onInstallClicked() {
        let initial = loadConfig() ?? Config.default
        guard let cfg = ConfigDialog.run(initial: initial, window: window) else { return }

        // Synchronously test HA reachability before writing config.
        let test = testHA(config: cfg)
        if !test.ok {
            alert(text: "HA nereaguje:\n\n\(test.message)\n\nZkontroluj URL a token a zkus to znovu.",
                  style: .warning)
            return
        }

        // Resolve binary path. If launched from .app bundle, use Bundle.main.executablePath.
        let binaryPath = Bundle.main.executablePath ?? CommandLine.arguments[0]

        do {
            try InstallManager.install(config: cfg, binaryPath: binaryPath)
        } catch {
            alert(text: "Instalace selhala:\n\n\(error.localizedDescription)", style: .critical)
            return
        }

        // Wait for daemon start, then kickstart once for clean second run, then refresh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            InstallManager.kickstart()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                self.refreshUI()
                self.alert(text: "✓ Hotovo!\n\nV HA uvidíš entity:\n• sensor.\(cfg.entityPrefix)_active_display\n• binary_sensor.\(cfg.entityPrefix)_locked",
                           style: .informational)
            }
        }
    }

    @objc func onUninstallClicked() {
        let a = NSAlert()
        a.messageText = "Opravdu odinstalovat?"
        a.informativeText = "Daemon se zastaví, smaže se config a launchd plist.\nEntity v Home Assistantu zůstanou (smaž je z HA UI nebo Developer Tools)."
        a.alertStyle = .warning
        a.addButton(withTitle: "Odinstalovat")
        a.addButton(withTitle: "Zrušit")
        if a.runModal() != .alertFirstButtonReturn { return }
        InstallManager.uninstall()
        refreshUI()
    }

    @objc func onOpenLogClicked() {
        let url = URL(fileURLWithPath: InstallManager.logPath)
        NSWorkspace.shared.open(url)
    }

    func alert(text: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = "macbook-ha-bridge"
        a.informativeText = text
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// MARK: - Config dialog

enum ConfigDialog {
    static func run(initial: Config, window: NSWindow?) -> Config? {
        let alert = NSAlert()
        alert.messageText = "macbook-ha-bridge — Nastavení"
        alert.informativeText = "Vyplň URL Home Assistantu a Long-Lived Access Token (HA → profil → Security → Long-Lived Access Tokens → Create Token)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save & Install")
        alert.addButton(withTitle: "Cancel")

        let cont = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))

        func mkLabel(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 130, height: 22)
            l.alignment = .right
            l.font = .systemFont(ofSize: 12)
            return l
        }
        func mkField(_ text: String, y: CGFloat, secure: Bool = false) -> NSTextField {
            let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
            f.frame = NSRect(x: 138, y: y, width: 322, height: 24)
            f.stringValue = text
            f.font = .systemFont(ofSize: 12)
            return f
        }

        let urlField = mkField(initial.haURL, y: 144)
        urlField.placeholderString = "http://homeassistant.local:8123"
        let tokenField = mkField(initial.token, y: 110, secure: true)
        tokenField.placeholderString = "Long-Lived Access Token"
        let prefixField = mkField(initial.entityPrefix.isEmpty ? defaultPrefix() : initial.entityPrefix, y: 76)
        prefixField.placeholderString = "muj_macbook"
        let nameField = mkField(initial.deviceName.isEmpty ? defaultName() : initial.deviceName, y: 42)
        nameField.placeholderString = "Můj MacBook"

        cont.addSubview(mkLabel("HA URL:", y: 145))
        cont.addSubview(urlField)
        cont.addSubview(mkLabel("Token:", y: 111))
        cont.addSubview(tokenField)
        cont.addSubview(mkLabel("Entity prefix:", y: 77))
        cont.addSubview(prefixField)
        cont.addSubview(mkLabel("Device name:", y: 43))
        cont.addSubview(nameField)

        let hint = NSTextField(labelWithString: "Prefix = jen [a-z0-9_], beze diakritiky.   Device name = libovolný (ukáže se v HA jako friendly_name).")
        hint.frame = NSRect(x: 0, y: 8, width: 460, height: 28)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        cont.addSubview(hint)

        alert.accessoryView = cont

        // Focus first empty / token field
        DispatchQueue.main.async {
            (initial.token.isEmpty ? tokenField : urlField).becomeFirstResponder()
        }

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }

        var c = initial
        c.haURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.entityPrefix = sanitizePrefix(prefixField.stringValue)
        c.deviceName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.entityPrefix.isEmpty { c.entityPrefix = defaultPrefix() }
        if c.deviceName.isEmpty { c.deviceName = defaultName() }
        c.pollInterval = 2.0
        c.heartbeatInterval = 60.0
        return c
    }

    static func sanitizePrefix(_ s: String) -> String {
        return s.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func defaultPrefix() -> String {
        let user = NSUserName().lowercased()
        return sanitizePrefix(user) + "_macbook"
    }

    static func defaultName() -> String {
        return Host.current().localizedName ?? (NSUserName() + "'s MacBook")
    }
}

// MARK: - Entry

// `NSApp` is a global that's nil until `NSApplication.shared` is touched —
// always go through NSApplication.shared first.
let app = NSApplication.shared

if isDaemon {
    // Daemon mode: no dock icon, no menu bar, just RunLoop.
    app.setActivationPolicy(.prohibited)
    DaemonRuntime.run()
    RunLoop.main.run()
} else {
    // GUI mode: regular app with window.
    let controller = AppController()
    app.delegate = controller
    app.run()
}
