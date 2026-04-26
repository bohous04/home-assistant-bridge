// macbook-ha-bridge — single binary, two modes:
//   no args  → GUI installer/status window
//   --daemon → background poller (run by launchd)

import Foundation
import AppKit
import CoreGraphics
import QuartzCore

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
    // Daemon binary lives outside the .app so LaunchServices does not treat the running
    // daemon process as an instance of the GUI bundle (which would block reopening the .app).
    static let daemonDir = ("~/Library/Application Support/macbook-ha-bridge" as NSString).expandingTildeInPath
    static var daemonBinaryPath: String { daemonDir + "/macbook-ha-bridge-daemon" }

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

    /// Elapsed seconds since `pid` was spawned (via `ps -p <pid> -o etime=`).
    static func processElapsedSeconds(pid: Int) -> TimeInterval? {
        let p = Process()
        p.launchPath = "/bin/ps"
        p.arguments = ["-p", String(pid), "-o", "etime="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return parseEtime(raw)
    }

    /// Parse `ps -o etime` format: `[[DD-]HH:]MM:SS`.
    static func parseEtime(_ s: String) -> TimeInterval? {
        var rest = s
        var days: Int = 0
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        var h = 0, m = 0, sec = 0
        switch parts.count {
        case 3: h = parts[0]; m = parts[1]; sec = parts[2]
        case 2: m = parts[0]; sec = parts[1]
        default: return nil
        }
        return TimeInterval(days * 86400 + h * 3600 + m * 60 + sec)
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
        try installDaemonBinary(from: binaryPath)
        try writePlist(binaryPath: daemonBinaryPath)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(plistLabel)"])
        Thread.sleep(forTimeInterval: 0.8)
        let rc = runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if rc != 0 {
            throw NSError(domain: "InstallManager", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap returned \(rc)"])
        }
    }

    static func installDaemonBinary(from sourcePath: String) throws {
        try FileManager.default.createDirectory(
            atPath: daemonDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Stage to a temp path in the same directory then atomic-rename over the
        // destination. Avoids the TOCTOU window between remove/copy and prevents
        // a hostile symlink at the destination from being followed.
        let tmpPath = daemonDir + "/.macbook-ha-bridge-daemon.\(getpid()).tmp"
        try? FileManager.default.removeItem(atPath: tmpPath)
        try FileManager.default.copyItem(atPath: sourcePath, toPath: tmpPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpPath)

        if rename(tmpPath, daemonBinaryPath) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey:
                            "rename(\(tmpPath) → \(daemonBinaryPath)) failed: \(String(cString: strerror(code)))"])
        }
    }

    static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(plistLabel)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: configPath)
        try? FileManager.default.removeItem(atPath: daemonDir)
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

    static func recentLog(lines: Int = 20) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
              let s = String(data: data, encoding: .utf8) else { return "" }
        let all = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: "\n")
    }

    static func logModified() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        return attrs?[.modificationDate] as? Date
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

// MARK: - Theme

enum Theme {
    /// Brand teal — derived from logo. Maps to oklch(0.66 0.10 195) in the mockup.
    static let brandTeal = NSColor(red: 0.27, green: 0.74, blue: 0.71, alpha: 1.0)
    static let brandTealHover = NSColor(red: 0.20, green: 0.70, blue: 0.66, alpha: 1.0)

    static let pillBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.06)
    }

    static let cardBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.20, alpha: 1.0)
            : NSColor.white
    }

    static let logBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.094, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)
    }

    static let separator = NSColor.separatorColor
}

// MARK: - Status pill

final class StatusPillView: NSView {
    enum Tone { case orange, green, red }

    private let dotView = NSView()
    private let labelField = NSTextField(labelWithString: "")
    private var pulseTimer: Timer?
    private var currentTone: Tone = .orange

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 999
        layer?.backgroundColor = Theme.pillBackground.cgColor

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 5
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        labelField.font = .systemFont(ofSize: 13.5, weight: .semibold)
        labelField.textColor = .labelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 10),
            dotView.heightAnchor.constraint(equalToConstant: 10),
            labelField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 9),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.pillBackground.cgColor
        applyTone(currentTone)
    }

    func configure(text: String, tone: Tone) {
        labelField.stringValue = text
        currentTone = tone
        applyTone(tone)
        if tone == .green { startPulse() } else { stopPulse() }
    }

    private func applyTone(_ tone: Tone) {
        let color: NSColor
        switch tone {
        case .orange: color = NSColor.systemOrange
        case .green:  color = NSColor.systemGreen
        case .red:    color = NSColor.systemRed
        }
        dotView.layer?.backgroundColor = color.cgColor
        dotView.layer?.shadowColor = color.cgColor
        dotView.layer?.shadowOpacity = 0.0
        dotView.layer?.shadowRadius = 0.0
        dotView.layer?.shadowOffset = .zero
        dotView.layer?.masksToBounds = false
    }

    private func startPulse() {
        stopPulse()
        let layer = dotView.layer!
        layer.masksToBounds = false
        let anim = CABasicAnimation(keyPath: "shadowOpacity")
        anim.fromValue = 0.55
        anim.toValue = 0.18
        anim.duration = 1.2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 2.5
        radius.toValue = 6.0
        radius.duration = 1.2
        radius.autoreverses = true
        radius.repeatCount = .infinity
        radius.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        layer.shadowOpacity = 0.4
        layer.shadowRadius = 4.0
        layer.add(anim, forKey: "pulseOpacity")
        layer.add(radius, forKey: "pulseRadius")
    }

    private func stopPulse() {
        dotView.layer?.removeAllAnimations()
        dotView.layer?.shadowOpacity = 0.0
    }
}

// MARK: - Data card

final class DataCardView: NSView {
    struct Row {
        let key: String
        let value: String
        let mono: Bool
        let badgeTone: StatusPillView.Tone?

        init(key: String, value: String, mono: Bool = false, badgeTone: StatusPillView.Tone? = nil) {
            self.key = key
            self.value = value
            self.mono = mono
            self.badgeTone = badgeTone
        }
    }

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.cardBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.04
        layer?.shadowRadius = 1
        layer?.shadowOffset = NSSize(width: 0, height: -0.5)
        layer?.masksToBounds = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.cardBackground.cgColor
    }

    func setRows(_ rows: [Row]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let sep = makeSeparator()
                stack.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            let r = makeRow(row)
            stack.addArrangedSubview(r)
            r.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func makeSeparator() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.separator.cgColor
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func makeRow(_ row: Row) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let key = NSTextField(labelWithString: row.key)
        key.font = .systemFont(ofSize: 12.5, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(key)

        let valueView: NSView
        if let tone = row.badgeTone {
            valueView = makeBadge(text: row.value, tone: tone)
        } else {
            let val = NSTextField(labelWithString: row.value)
            val.lineBreakMode = .byTruncatingTail
            val.cell?.truncatesLastVisibleLine = true
            val.toolTip = row.value
            if row.mono {
                val.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            } else {
                val.font = .systemFont(ofSize: 12.5, weight: .medium)
            }
            val.textColor = .labelColor
            val.alignment = .right
            val.translatesAutoresizingMaskIntoConstraints = false
            valueView = val
        }
        container.addSubview(valueView)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            key.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            key.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            valueView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            valueView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            valueView.leadingAnchor.constraint(greaterThanOrEqualTo: key.trailingAnchor, constant: 16),
        ])
        if let val = valueView as? NSTextField { val.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        return container
    }

    private func makeBadge(text: String, tone: StatusPillView.Tone) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = Theme.pillBackground.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        let color: NSColor = {
            switch tone {
            case .orange: return .systemOrange
            case .green:  return .systemGreen
            case .red:    return .systemRed
            }
        }()
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(dot)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return badge
    }
}

// MARK: - Error block

final class ErrorBlockView: NSView {
    private let bg = NSView()
    private let bar = NSView()
    private let textField = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.systemRed.cgColor
        bar.layer?.cornerRadius = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(bar)

        textField.font = .systemFont(ofSize: 12.5)
        textField.textColor = .labelColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        bg.addSubview(textField)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),

            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            bar.topAnchor.constraint(equalTo: bg.topAnchor),
            bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 2),

            textField.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            textField.topAnchor.constraint(equalTo: bg.topAnchor, constant: 11),
            textField.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -11),
        ])
    }

    func setMessage(_ heading: String, body: String) {
        let attr = NSMutableAttributedString()
        let head = NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
        ])
        let rest = NSAttributedString(string: " " + body, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
        ])
        attr.append(head)
        attr.append(rest)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
        textField.attributedStringValue = attr
    }
}

// MARK: - Log panel

final class LogPanelView: NSView {
    private let header = NSTextField(labelWithString: "RECENT LOG")
    private let meta = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let logContainer = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        meta.font = .systemFont(ofSize: 10.5)
        meta.textColor = .tertiaryLabelColor
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.lineBreakMode = .byTruncatingMiddle
        addSubview(meta)

        logContainer.wantsLayer = true
        logContainer.layer?.cornerRadius = 6
        logContainer.layer?.backgroundColor = Theme.logBackground.cgColor
        logContainer.layer?.borderWidth = 0.5
        logContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.09).cgColor
        logContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logContainer)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 0)
        textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.55)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scroll.documentView = textView
        logContainer.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),

            meta.trailingAnchor.constraint(equalTo: trailingAnchor),
            meta.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),

            logContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            logContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            logContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            logContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: logContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor),
        ])

        // Track the uppercase look with tracking instead of CSS letter-spacing.
        let para = NSMutableParagraphStyle()
        header.attributedStringValue = NSAttributedString(string: "RECENT LOG", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
            .paragraphStyle: para,
        ])
    }

    override func updateLayer() {
        super.updateLayer()
        logContainer.layer?.backgroundColor = Theme.logBackground.cgColor
    }

    func setLog(_ text: String, meta metaText: String) {
        meta.stringValue = metaText
        let attributed = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let baseColor = NSColor.labelColor.withAlphaComponent(0.62)
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            let lower = line.lowercased()
            let color: NSColor
            if lower.contains("[event]") || lower.contains("didwake") || lower.contains("willsleep") {
                color = NSColor.systemTeal.withAlphaComponent(0.85)
            } else if lower.contains("error") || lower.contains("warn") || lower.contains("throttling")
                        || lower.contains("respawn failed") || lower.contains("terminated")
                        || lower.contains("http 5") || lower.contains("http 4") {
                color = NSColor.systemOrange.withAlphaComponent(0.85)
            } else {
                color = baseColor
            }
            // Try to dim the leading "HH:MM:SS" timestamp, if present.
            if line.count > 9, let space = line.firstIndex(of: " "), line.distance(from: line.startIndex, to: space) >= 8 {
                let ts = String(line[..<space])
                let rest = String(line[space...])
                attributed.append(NSAttributedString(string: ts, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
                attributed.append(NSAttributedString(string: rest, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: color,
                ]))
            } else {
                attributed.append(NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: color,
                ]))
            }
            if i < lines.count - 1 {
                attributed.append(NSAttributedString(string: "\n"))
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        attributed.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attributed.length))
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Custom buttons

final class PrimaryButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        bezelStyle = .regularSquare
        isBordered = false
        contentTintColor = .white
        font = .systemFont(ofSize: 13, weight: .semibold)
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.brandTeal.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        layer?.shadowRadius = 1.5
    }

    override var title: String {
        didSet { applyTitleAttributes() }
    }

    private func applyTitleAttributes() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .paragraphStyle: style,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = (isHighlighted ? Theme.brandTealHover : Theme.brandTeal).cgColor
        super.draw(dirtyRect)
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 24
        s.height = 28
        return s
    }
}

final class LinkButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12.5, weight: .medium)
        contentTintColor = Theme.brandTeal
    }

    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: Theme.brandTeal,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            ])
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return "\(h) h \(m) m" }
    if m > 0 { return "\(m) m" }
    return "\(sec) s"
}

func formatPID(_ pid: Int) -> String {
    let n = NumberFormatter()
    n.numberStyle = .decimal
    n.groupingSeparator = " "
    return n.string(from: NSNumber(value: pid)) ?? String(pid)
}

func hostFromURL(_ s: String) -> String {
    if let url = URL(string: s), let host = url.host {
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
    return s
}

func defaultPrefix() -> String {
    let user = NSUserName().lowercased()
    return sanitizePrefix(user) + "_macbook"
}

func defaultName() -> String {
    return Host.current().localizedName ?? (NSUserName() + "'s MacBook")
}

func sanitizePrefix(_ s: String) -> String {
    return s.lowercased()
        .unicodeScalars
        .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" }
        .reduce(into: "") { $0.append($1) }
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

// MARK: - GUI mode

class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var bodyContainer: NSView!
    var bodyStack: NSStackView!
    var refreshTimer: Timer?
    var installSheet: InstallSheetController?

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
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "macbook-ha-bridge"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        window.delegate = self

        // The window's content view holds a vibrant background and a body stack.
        let content = NSView(frame: rect)
        content.wantsLayer = true

        bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bodyContainer)

        bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.spacing = 18
        bodyStack.alignment = .leading
        bodyStack.distribution = .fill
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(bodyStack)

        // Leave room (38pt) for the translucent titlebar.
        NSLayoutConstraint.activate([
            bodyContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            bodyContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            bodyStack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 24),
            bodyStack.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -24),
            bodyStack.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 22),
            bodyStack.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -20),
        ])

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    /// Replace the body stack contents with views appropriate for the current install state.
    func refreshUI() {
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let status = InstallManager.currentStatus()
        let cfg = loadConfig()

        switch status {
        case .notInstalled:
            renderNotInstalled()

        case .running(let pid):
            renderRunning(pid: pid, cfg: cfg)

        case .stopped:
            renderStopped(cfg: cfg)
        }
    }

    // MARK: render: not installed

    private func renderNotInstalled() {
        let pill = StatusPillView()
        pill.configure(text: "Not installed", tone: .orange)
        bodyStack.addArrangedSubview(pill)

        let headline = NSTextField(labelWithString: "Connect this Mac to Home Assistant.")
        headline.font = .systemFont(ofSize: 19, weight: .semibold)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 0
        bodyStack.addArrangedSubview(headline)
        bodyStack.setCustomSpacing(10, after: pill)

        let explainer = NSTextField(wrappingLabelWithString:
            "The bridge runs as a small background agent and pushes the active display name and the screen-lock state every 2 seconds. Two HA entities will be created.")
        explainer.font = .systemFont(ofSize: 13)
        explainer.textColor = .secondaryLabelColor
        explainer.maximumNumberOfLines = 0
        explainer.preferredMaxLayoutWidth = 480
        bodyStack.addArrangedSubview(explainer)
        bodyStack.setCustomSpacing(6, after: headline)

        // Spacer that pushes the button row + footnote to the bottom.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        bodyStack.addArrangedSubview(spacer)
        spacer.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Action row — Install + Learn more
        let install = PrimaryButton(title: "Install…", target: self, action: #selector(onInstallClicked))
        let learn = LinkButton(title: "Learn more", target: self, action: #selector(onLearnMoreClicked))

        let actions = NSStackView(views: [install, learn])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        bodyStack.addArrangedSubview(actions)

        let footnote = NSTextField(labelWithString: "")
        let attr = NSMutableAttributedString(string: "No config file at ", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        attr.append(NSAttributedString(string: "~/.config/macbook-ha-bridge/", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        attr.append(NSAttributedString(string: " yet.", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        footnote.attributedStringValue = attr
        bodyStack.addArrangedSubview(footnote)
        bodyStack.setCustomSpacing(8, after: actions)

        install.target = self
        install.action = #selector(onInstallClicked)
        learn.target = self
        learn.action = #selector(onLearnMoreClicked)
    }

    // MARK: render: running

    private func renderRunning(pid: Int, cfg: Config?) {
        let pill = StatusPillView()
        pill.configure(text: "Running", tone: .green)

        let uptime = NSTextField(labelWithString: uptimeString(pid: pid))
        uptime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        uptime.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [pill, NSView(), uptime])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12
        let spacer = header.arrangedSubviews[1]
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Live data card
        let state = currentState()
        let card = DataCardView()
        card.setRows([
            .init(key: "PID", value: formatPID(pid), mono: true),
            .init(key: "Active display", value: state.activeDisplayName),
            .init(key: "Locked", value: state.locked ? "Yes" : "No",
                  badgeTone: state.locked ? .red : .green),
            .init(key: "Entity prefix", value: cfg?.entityPrefix ?? "—", mono: true),
            .init(key: "Home Assistant", value: hostFromURL(cfg?.haURL ?? "—"), mono: true),
        ])
        bodyStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Action row
        let reinstall = makeSecondaryButton("Reinstall / Settings…", action: #selector(onInstallClicked))
        let openLog = makeSecondaryButton("Open log", action: #selector(onOpenLogClicked))
        let pad = NSView()
        pad.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let uninstall = makeDangerButton("Uninstall", action: #selector(onUninstallClicked))

        let actions = NSStackView(views: [reinstall, openLog, pad, uninstall])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.distribution = .fill
        bodyStack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Log section — fills the remaining space.
        let log = LogPanelView()
        log.setLog(InstallManager.recentLog(lines: 18),
                   meta: "~/Library/Logs/macbook-ha-bridge.log · last 18 lines")
        bodyStack.addArrangedSubview(log)
        log.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        log.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: render: stopped

    private func renderStopped(cfg: Config?) {
        let pill = StatusPillView()
        pill.configure(text: "Stopped", tone: .red)

        let down = NSTextField(labelWithString: downtimeString())
        down.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        down.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [pill, NSView(), down])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12
        header.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        let err = ErrorBlockView()
        err.setMessage("The agent isn't running.",
                       body: "The launchd plist exists, but `launchctl print` returned no PID. Try Reinstall to refresh the plist and restart the agent.")
        bodyStack.addArrangedSubview(err)
        err.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Last known config card
        let card = DataCardView()
        card.setRows([
            .init(key: "Last seen", value: lastSeenString(), mono: true),
            .init(key: "Entity prefix", value: cfg?.entityPrefix ?? "—", mono: true),
            .init(key: "Home Assistant", value: hostFromURL(cfg?.haURL ?? "—"), mono: true),
            .init(key: "Plist", value: "~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist", mono: true),
        ])
        bodyStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        // Action row — primary "Reinstall", "Open log", spacer, "Uninstall"
        let reinstall = PrimaryButton(title: "Reinstall / Settings…", target: self, action: #selector(onInstallClicked))
        let openLog = makeSecondaryButton("Open log", action: #selector(onOpenLogClicked))
        let pad = NSView()
        pad.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let uninstall = makeDangerButton("Uninstall", action: #selector(onUninstallClicked))

        let actions = NSStackView(views: [reinstall, openLog, pad, uninstall])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.distribution = .fill
        bodyStack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        let log = LogPanelView()
        log.setLog(InstallManager.recentLog(lines: 18),
                   meta: "tail of last log")
        bodyStack.addArrangedSubview(log)
        log.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        log.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: helpers

    private func makeSecondaryButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12.5, weight: .medium)
        return b
    }

    private func makeDangerButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12.5, weight: .medium)
        b.contentTintColor = .systemRed
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        ])
        return b
    }

    private func uptimeString(pid: Int) -> String {
        if let s = InstallManager.processElapsedSeconds(pid: pid) {
            return "Uptime " + formatDuration(s)
        }
        return ""
    }

    private func downtimeString() -> String {
        guard let mod = InstallManager.logModified() else { return "" }
        let elapsed = Date().timeIntervalSince(mod)
        if elapsed < 0 { return "" }
        return "Down for " + formatDuration(elapsed)
    }

    private func lastSeenString() -> String {
        guard let mod = InstallManager.logModified() else { return "—" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(mod) {
            f.dateFormat = "'Today,' HH:mm:ss"
        } else if cal.isDateInYesterday(mod) {
            f.dateFormat = "'Yesterday,' HH:mm:ss"
        } else {
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        return f.string(from: mod)
    }

    // MARK: actions

    @objc func onInstallClicked() {
        let initial = loadConfig() ?? Config.default
        let sheet = InstallSheetController(initial: initial) { [weak self] cfg in
            guard let self = self, let cfg = cfg else { return }
            self.performInstall(cfg)
        }
        sheet.present(over: window)
        installSheet = sheet
    }

    private func performInstall(_ cfg: Config) {
        // Synchronously test HA reachability before writing config.
        let test = testHA(config: cfg)
        if !test.ok {
            alert(text: "HA nereaguje:\n\n\(test.message)\n\nZkontroluj URL a token a zkus to znovu.",
                  style: .warning)
            return
        }

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

    @objc func onLearnMoreClicked() {
        let a = NSAlert()
        a.messageText = "macbook-ha-bridge"
        a.informativeText = """
        Two Home Assistant entities are created:

          • sensor.<prefix>_active_display
              Name of the display showing the menu bar
              (e.g. "Built-in", "Studio Display").

          • binary_sensor.<prefix>_locked
              "on" when the screen is locked.

        The daemon polls every 2s and force-pushes on sleep / wake. \
        Config lives at ~/.config/macbook-ha-bridge/config.json (mode 600). \
        Logs at ~/Library/Logs/macbook-ha-bridge.log.
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.runModal()
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

// MARK: - Install sheet

final class InstallSheetController: NSObject {
    private let sheetWindow: NSWindow
    private let initial: Config
    private let completion: (Config?) -> Void

    private let urlField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let prefixField = NSTextField()
    private let nameField = NSTextField()

    init(initial: Config, completion: @escaping (Config?) -> Void) {
        self.initial = initial
        self.completion = completion
        self.sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        sheetWindow.titleVisibility = .hidden
        sheetWindow.titlebarAppearsTransparent = true
        sheetWindow.isMovableByWindowBackground = false
        sheetWindow.backgroundColor = .clear
        sheetWindow.isOpaque = false
        sheetWindow.standardWindowButton(.closeButton)?.isHidden = true
        sheetWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sheetWindow.standardWindowButton(.zoomButton)?.isHidden = true
        buildContent()
    }

    private func buildContent() {
        let blur = NSVisualEffectView()
        blur.material = .sheet
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.maskImage = roundedMask(cornerRadius: 12)
        blur.translatesAutoresizingMaskIntoConstraints = false

        sheetWindow.contentView = blur

        let title = NSTextField(labelWithString: "Install & configure bridge")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let lede = NSTextField(wrappingLabelWithString:
            "The bridge will write a launchd plist into ~/Library/LaunchAgents and start the daemon immediately.")
        lede.font = .systemFont(ofSize: 12.5)
        lede.textColor = .secondaryLabelColor
        lede.maximumNumberOfLines = 0
        lede.translatesAutoresizingMaskIntoConstraints = false

        // Form
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false

        urlField.stringValue = initial.haURL
        urlField.placeholderString = "http://homeassistant.local:8123"
        tokenField.stringValue = initial.token
        tokenField.placeholderString = "Long-Lived Access Token"
        prefixField.stringValue = initial.entityPrefix.isEmpty ? defaultPrefix() : initial.entityPrefix
        prefixField.placeholderString = "muj_macbook"
        nameField.stringValue = initial.deviceName.isEmpty ? defaultName() : initial.deviceName
        nameField.placeholderString = "Můj MacBook"
        for f in [urlField, prefixField, nameField] {
            f.font = .systemFont(ofSize: 12.5)
            f.controlSize = .small
        }
        tokenField.font = .systemFont(ofSize: 12.5)
        tokenField.controlSize = .small

        form.addArrangedSubview(makeFieldRow(label: "HA URL", control: urlField))
        form.addArrangedSubview(makeFieldRow(label: "Token", control: tokenField))
        form.addArrangedSubview(makeHelperRow(text: "Stored at ~/.config/macbook-ha-bridge/config.json with mode 600."))
        form.addArrangedSubview(makeFieldRow(label: "Entity prefix", control: prefixField))
        form.addArrangedSubview(makeHelperRow(text: "Sanitized to [a-z0-9_]."))
        form.addArrangedSubview(makeFieldRow(label: "Device name", control: nameField))

        let hint = NSTextField(wrappingLabelWithString:
            "The token is created in HA → Profile → Security → Long-Lived Access Tokens.")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(onCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1B}"
        cancel.controlSize = .regular

        let save = PrimaryButton(title: "Save & Install", target: self, action: #selector(onSave))
        save.keyEquivalent = "\r"

        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 9
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, lede, form, hint, separator, actions] {
            blur.addSubview(v)
        }

        let pad: CGFloat = 26
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: blur.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),

            lede.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            lede.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad),
            lede.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),

            form.topAnchor.constraint(equalTo: lede.bottomAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad),
            form.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),

            hint.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad + 122),
            hint.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),

            separator.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad),
            separator.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),

            actions.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: pad),
            actions.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -pad),
            actions.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -22),
        ])

        // Resize the sheet window to fit the content via Auto Layout.
        blur.layoutSubtreeIfNeeded()
    }

    private func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                     bottom: cornerRadius, right: cornerRadius)
        img.resizingMode = .stretch
        return img
    }

    private func makeFieldRow(label: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: label)
        lbl.alignment = .right
        lbl.font = .systemFont(ofSize: 12.5, weight: .medium)
        lbl.textColor = .labelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(lbl)

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            lbl.widthAnchor.constraint(equalToConstant: 110),
            lbl.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),

            control.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func makeHelperRow(text: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let helper = NSTextField(wrappingLabelWithString: text)
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .tertiaryLabelColor
        helper.maximumNumberOfLines = 0
        helper.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(helper)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            helper.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 122),
            helper.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            helper.topAnchor.constraint(equalTo: row.topAnchor, constant: -2),
            helper.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: 2),
        ])
        return row
    }

    func present(over parent: NSWindow) {
        parent.beginSheet(sheetWindow) { _ in }
        // Focus the URL field (or token if URL pre-filled).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let target: NSTextField = self.initial.token.isEmpty ? self.tokenField : self.urlField
            self.sheetWindow.makeFirstResponder(target)
        }
    }

    @objc private func onCancel() {
        if let parent = sheetWindow.sheetParent { parent.endSheet(sheetWindow) }
        completion(nil)
    }

    @objc private func onSave() {
        var c = initial
        c.haURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.entityPrefix = sanitizePrefix(prefixField.stringValue)
        c.deviceName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.entityPrefix.isEmpty { c.entityPrefix = defaultPrefix() }
        if c.deviceName.isEmpty { c.deviceName = defaultName() }
        c.pollInterval = 2.0
        c.heartbeatInterval = 60.0

        if let parent = sheetWindow.sheetParent { parent.endSheet(sheetWindow) }
        completion(c)
    }
}

// MARK: - Entry

let app = NSApplication.shared

if isDaemon {
    app.setActivationPolicy(.prohibited)
    DaemonRuntime.run()
    RunLoop.main.run()
} else {
    let controller = AppController()
    app.delegate = controller
    app.run()
}
