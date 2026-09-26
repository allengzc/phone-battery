// PhoneBatteryBLE — reads an Android phone's battery over Bluetooth LE and
// shows it three ways: a menu bar item, a desktop card, and (via the shared
// file it writes) a WidgetKit widget.
//
// Why BLE and not ADB: wireless debugging needs Mac and phone on one WLAN.
// Why not Stats: Stats only shows a Bluetooth battery through its HID
// accessory path, and macOS drops the link as soon as the phone serves a HID
// service because this phone is already bonded to the Mac. An ordinary BLE
// Battery Service read has neither restriction and is verified working here.
//
// Build: ./build-app.sh    Self-check: ./PhoneBattery.app/Contents/MacOS/PhoneBattery --render-preview /tmp/card.png

import AppKit
import CoreBluetooth
import Foundation

private let BATTERY_SERVICE = CBUUID(string: "180F")
private let BATTERY_LEVEL = CBUUID(string: "2A19")

/// Where the app publishes the latest reading.
///
/// The widget extension is required to be sandboxed (macOS silently refuses to
/// register an unsandboxed widget), and an App Group would need a real
/// provisioning profile, so the handoff is a plain file written into the
/// widget's own container: the sandboxed widget reads it as its own
/// Application Support directory.
enum Shared {
    static let widgetBundleID = "com.dsh.phonebattery.menubar.widget"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PhoneBattery", isDirectory: true)
    }

    static var levelFile: URL { directory.appendingPathComponent("level.json") }

    /// Same file as the sandboxed widget sees it: inside its container.
    static var levelFiles: [URL] {
        let container = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/PhoneBattery/level.json")
        return [levelFile, container]
    }

    static func write(level: Int?, device: String?, status: String, devices: [[String: Any]]) {
        let payload: [String: Any] = [
            "level": level as Any,
            "device": device as Any,
            "status": status,
            "updated": Date().timeIntervalSince1970,
            "devices": devices,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        for url in levelFiles {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                // The container path does not exist until the widget has run
                // once; that is not an error worth surfacing.
                NSLog("PhoneBattery: cannot write \(url.path): \(error)")
            }
        }
    }
}

// MARK: - other batteries

/// `pmset -g accps -xml` reports the Mac's own battery plus every accessory
/// macOS tracks a battery for (headphones and friends). It is the same source
/// Stats reads for wireless headphone levels, and it costs one cheap subprocess.
enum Accessories {
    static func readings() -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps", "-xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var results: [[String: Any]] = []
        let text = String(decoding: data, as: UTF8.self)
        for chunk in text.components(separatedBy: "<?xml").dropFirst() {
            guard let plistData = ("<?xml" + chunk).data(using: .utf8),
                  let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let name = dict["Name"] as? String,
                  let capacity = dict["Current Capacity"] as? Int else { continue }

            let charging: Bool
            if let flag = dict["Is Charging"] as? Bool {
                charging = flag
            } else if let number = dict["Is Charging"] as? Int {
                charging = number != 0
            } else {
                charging = (dict["Power Source State"] as? String) == "AC Power"
            }

            if name.hasPrefix("InternalBattery") {
                results.append(["id": "mac", "name": "Mac", "kind": "mac",
                                "level": capacity, "charging": charging])
            } else {
                let category = (dict["Accessory Category"] as? String) ?? ""
                results.append(["id": "acc:\(name)", "name": name,
                                "kind": kind(category: category, name: name),
                                "level": capacity, "charging": charging])
            }
        }
        return results
    }

    private static func kind(category: String, name: String) -> String {
        let category = category.lowercased()
        if category.contains("head") || category.contains("audio") { return "headphones" }
        if category.contains("keyboard") || category.contains("keypad") { return "keyboard" }
        if category.contains("mouse") || category.contains("point") { return "mouse" }
        if category.contains("game") || category.contains("controller") { return "gamepad" }
        if category.contains("watch") { return "watch" }

        let name = name.lowercased()
        if name.contains("airpod") { return "airpods" }
        if name.contains("buds") || name.contains("enco") || name.contains("momentum")
            || name.contains("sony") || name.contains("bose") { return "headphones" }
        return "other"
    }
}

// MARK: - BLE central

final class PhoneBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    var onChange: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private(set) var level: Int?
    private(set) var status = "启动中"
    private var lastSeenName: String?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    var titleText: String { level.map { "📱 \($0)%" } ?? "📱 —" }
    var deviceName: String? { peripheral?.name ?? lastSeenName }

    private var accessoryCache: (at: Date, list: [[String: Any]])?

    /// The Mac's battery first (the reference layout leads with it), then the
    /// phone from Bluetooth, then whatever accessories macOS reports.
    private func deviceList() -> [[String: Any]] {
        var list = accessories()
        if let level {
            let phone: [String: Any] = [
                "id": "phone",
                "name": deviceName ?? "手机",
                "kind": "phone",
                "level": level,
                // The Bluetooth Battery Service carries no charging state.
                "charging": false,
            ]
            list.insert(phone, at: min(1, list.count))
        }
        return list
    }

    private func accessories() -> [[String: Any]] {
        if let cache = accessoryCache, Date().timeIntervalSince(cache.at) < 60 { return cache.list }
        let fresh = Accessories.readings()
        accessoryCache = (Date(), fresh)
        return fresh
    }

    private func publish() {
        Shared.write(level: level, device: deviceName, status: status, devices: deviceList())
        onChange?()
    }

    // MARK: central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScan()
        case .unauthorized: status = "蓝牙权限被拒绝"
        case .poweredOff: status = "蓝牙已关闭"
        case .unsupported: status = "此 Mac 不支持蓝牙 LE"
        default: status = "蓝牙不可用"
        }
        publish()
    }

    private func startScan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        status = "搜索手机中…"
        central.scanForPeripherals(
            withServices: [BATTERY_SERVICE],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        publish()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        lastSeenName = peripheral.name
        peripheral.delegate = self
        status = "连接中…"
        central.stopScan()
        central.connect(peripheral, options: nil)
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "已连接，读取中…"
        peripheral.discoverServices([BATTERY_SERVICE])
        publish()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        status = "连接失败，3 秒后重试"
        publish()
        retryLater()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        level = nil
        status = "已断开，3 秒后重连"
        publish()
        retryLater()
    }

    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startScan() }
    }

    // MARK: peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == BATTERY_SERVICE {
            peripheral.discoverCharacteristics([BATTERY_LEVEL], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == BATTERY_LEVEL {
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BATTERY_LEVEL,
              let data = characteristic.value,
              let value = data.first else { return }
        level = Int(value)
        status = "已连接"
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if error != nil, characteristic.uuid == BATTERY_LEVEL {
            peripheral.readValue(for: characteristic)
        }
    }

    func refresh() {
        if let peripheral, peripheral.state == .connected {
            if let service = peripheral.services?.first(where: { $0.uuid == BATTERY_SERVICE }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == BATTERY_LEVEL }) {
                peripheral.readValue(for: characteristic)
            } else {
                peripheral.discoverServices([BATTERY_SERVICE])
            }
        } else {
            self.peripheral = nil
            startScan()
        }
    }

    func reconnect() {
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        level = nil
        startScan()
    }
}

// MARK: - desktop card

/// The card's face: a progress ring with the percentage in the middle.
final class RingView: NSView {
    var level: Int? { didSet { needsDisplay = true } }
    var statusText: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    private let accent = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.55, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let side = min(bounds.width, bounds.height)
        let lineWidth = max(7, side * 0.075)
        let diameter = side - lineWidth * 2 - 18
        let ringRect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2 + 6,
            width: diameter,
            height: diameter
        )

        // Track
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.stroke()

        // Progress
        if let level {
            let path = NSBezierPath()
            let start = 90.0
            let end = 90.0 - 360.0 * (Double(level) / 100.0)
            path.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY),
                           radius: ringRect.width / 2,
                           startAngle: CGFloat(start), endAngle: CGFloat(end),
                           clockwise: true)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            accent.setStroke()
            path.stroke()
        }

        // Percentage
        let valueText = level.map { "\($0)%" } ?? "—"
        let bigFont = NSFont.systemFont(ofSize: side * 0.26, weight: .semibold)
        let bigAttrs: [NSAttributedString.Key: Any] = [
            .font: bigFont,
            .foregroundColor: NSColor.white,
        ]
        let big = NSAttributedString(string: valueText, attributes: bigAttrs)
        var bigSize = big.size()
        big.draw(at: NSPoint(x: bounds.midX - bigSize.width / 2,
                             y: ringRect.midY - bigSize.height / 2))

        // Caption
        let caption = NSAttributedString(string: "手机", attributes: [
            .font: NSFont.systemFont(ofSize: side * 0.10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ])
        let captionSize = caption.size()
        caption.draw(at: NSPoint(x: bounds.midX - captionSize.width / 2,
                                 y: ringRect.minY - captionSize.height - 4))
    }
}

/// A borderless, draggable panel that behaves like a desktop widget.
final class CardWindow: NSPanel {
    let ring = RingView()

    init(size: CGFloat = 150) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size * 0.18
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        ring.frame = effect.bounds
        ring.autoresizingMask = [.width, .height]
        effect.addSubview(ring)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - app

private let cardOriginKey = "cardOrigin"
private let cardVisibleKey = "cardVisible"

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let battery = PhoneBattery()
    private var card: CardWindow?
    private var keepAlive: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        battery.onChange = { [weak self] in self?.render() }
        render()

        keepAlive = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.battery.refresh()
        }

        if UserDefaults.standard.object(forKey: cardVisibleKey) as? Bool ?? true {
            showCard()
        }
    }

    // MARK: card

    private func showCard() {
        if card == nil {
            let window = CardWindow()
            window.delegate = self
            card = window
        }
        guard let card else { return }
        if let saved = UserDefaults.standard.string(forKey: cardOriginKey) {
            card.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            card.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - card.frame.width - 40,
                                        y: screen.visibleFrame.minY + 40))
        }
        card.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: cardVisibleKey)
        render()
    }

    private func hideCard() {
        card?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: cardVisibleKey)
        render()
    }

    @objc private func toggleCard() {
        if card?.isVisible == true { hideCard() } else { showCard() }
    }

    @objc private func resetCard() {
        UserDefaults.standard.removeObject(forKey: cardOriginKey)
        hideCard()
        showCard()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === card else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: cardOriginKey)
    }

    // MARK: menu

    private func render() {
        DispatchQueue.main.async {
            self.statusItem.button?.title = self.battery.titleText
            self.statusItem.button?.toolTip = self.battery.level
                .map { "手机电量 \($0)%（蓝牙直读）" } ?? "手机电量：\(self.battery.status)"

            self.card?.ring.level = self.battery.level
            self.card?.ring.statusText = self.battery.status

            let menu = NSMenu()

            let header = NSMenuItem(title: self.battery.level.map { "手机电量：\($0)%" }
                                    ?? "手机电量：\(self.battery.status)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if let name = self.battery.deviceName {
                let device = NSMenuItem(title: "设备：\(name)", action: nil, keyEquivalent: "")
                device.isEnabled = false
                menu.addItem(device)
            }

            menu.addItem(.separator())

            let cardItem = NSMenuItem(title: "显示桌面小窗", action: #selector(self.toggleCard), keyEquivalent: "d")
            cardItem.target = self
            cardItem.state = (self.card?.isVisible == true) ? .on : .off
            menu.addItem(cardItem)

            let resetItem = NSMenuItem(title: "小窗归位到右下角", action: #selector(self.resetCard), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)

            menu.addItem(.separator())

            let refresh = NSMenuItem(title: "立即刷新", action: #selector(self.refreshNow), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)

            let reconnect = NSMenuItem(title: "重新连接", action: #selector(self.reconnectNow), keyEquivalent: "")
            reconnect.target = self
            menu.addItem(reconnect)

            menu.addItem(.separator())

            let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)

            self.statusItem.menu = menu
        }
    }

    @objc private func refreshNow() { battery.refresh() }
    @objc private func reconnectNow() { battery.reconnect() }
}

// MARK: - offscreen self-check

/// Renders the card to a PNG so its layout can be inspected without a screen
/// recording permission or a screenshot.
func renderPreview(to path: String) {
    _ = NSApplication.shared
    let size: CGFloat = 150
    let view = RingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
    view.level = 76
    view.statusText = "已连接"

    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
        exit(1)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("cannot encode png\n".utf8))
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index + 1 < CommandLine.arguments.count {
    renderPreview(to: CommandLine.arguments[index + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
