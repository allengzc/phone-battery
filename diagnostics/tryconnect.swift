// tryconnect — diagnostic: can this Mac actually establish a connection to the
// peripheral advertising 0x180F, and where does the handshake stall?
//
// Unlike probe, this services the run loop properly (CFRunLoopRun with a timer)
// and polls CBPeripheral.state, so a silent stall is distinguishable from a
// callback-delivery bug.
//
// Build: swiftc -O tryconnect.swift -o tryconnect
// Run:   ./tryconnect [seconds]

import CoreBluetooth
import Foundation

let SERVICE = CBUUID(string: "180F")
let LEVEL = CBUUID(string: "2A19")

func stateName(_ s: CBPeripheralState) -> String {
    switch s {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
}

final class Diag: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripherals: [CBPeripheral] = []
    var sawConnect = false
    var printed = Set<UUID>()
    var value: Int?
    var ticks = 0

    func start() {
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central state = \(central.state.rawValue) (5 == poweredOn)")
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: target.map { [$0] } ?? [SERVICE], options: nil)
            print("scanning…")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !printed.contains(p.identifier) else { return }
        printed.insert(p.identifier)
        peripherals.append(p)
        p.delegate = self
        print("FOUND \(p.name ?? "?") id=\(p.identifier.uuidString) rssi=\(RSSI) state=\(stateName(p.state))")
        if p.state == .disconnected {
            print("  -> calling connect()")
            c.connect(p, options: nil)
        } else {
            print("  -> already \(stateName(p.state)); discovering services")
            p.discoverServices(servicesToDiscover)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        sawConnect = true
        print("didConnect \(p.name ?? "?") state=\(stateName(p.state))")
        p.discoverServices(servicesToDiscover)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("didFailToConnect: \(error?.localizedDescription ?? "no error")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("didDisconnect \(p.name ?? "?") error=\(error?.localizedDescription ?? "none")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { print("discoverServices error: \(e.localizedDescription)") }
        let s = (p.services ?? []).map(\.uuid.uuidString)
        print("services: \(s.isEmpty ? "(none)" : s.joined(separator: ","))")
        for svc in p.services ?? [] where svc.uuid == SERVICE {
            p.discoverCharacteristics([LEVEL], for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if let e = error { print("discoverCharacteristics error: \(e.localizedDescription)") }
        let c = (svc.characteristics ?? []).map(\.uuid.uuidString)
        print("characteristics of 180F: \(c.isEmpty ? "(none)" : c.joined(separator: ","))")
        for ch in svc.characteristics ?? [] where ch.uuid == LEVEL {
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("read error: \(e.localizedDescription)") }
        if ch.uuid == LEVEL, let d = ch.value, let l = d.first {
            value = Int(l)
            print("BATTERY = \(l)%")
        }
    }

    @objc func tick() {
        ticks += 1
        if ticks % 3 == 0 {
            let states = peripherals.map { "\($0.name ?? "?"):\(stateName($0.state))" }
            print("  [\(ticks)s] \(states.isEmpty ? "no peripheral yet" : states.joined(separator: " "))")
        }
    }
}

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 30) : 30
let target = CommandLine.arguments.count > 2 ? CBUUID(string: CommandLine.arguments[2]) : nil
let servicesToDiscover: [CBUUID]? = target.map { [$0] }
let diag = Diag()
diag.start()

let timer = Timer.scheduledTimer(timeInterval: 1, target: diag, selector: #selector(Diag.tick), userInfo: nil, repeats: true)
RunLoop.current.add(timer, forMode: .default)

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print(diag.value != nil
          ? "\nRESULT: read \(diag.value!)% over BLE — GATT server works."
          : "\nRESULT: connect/handshake did not complete in \(Int(seconds))s (didConnect=\(diag.sawConnect)).")
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()
