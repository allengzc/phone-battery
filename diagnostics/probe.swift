// phone-battery-probe — reads the standard BLE Battery Service (0x180F /
// 0x2A19) from a nearby peripheral.
//
// Stats 3.0.x uses this same mechanism (its Bluetooth.framework calls
// scanForPeripherals(withServices:) → connect → discoverServices → read), so a
// value this tool can read is a value Stats can read.
//
// Build:  swiftc -O probe.swift -o probe
// Run:    ./probe [seconds]      (default 30)
//
// The first run triggers the macOS Bluetooth permission prompt; grant it.

import CoreBluetooth
import Foundation

let BATTERY_SERVICE = CBUUID(string: "180F")
let BATTERY_LEVEL = CBUUID(string: "2A19")

func stateName(_ state: CBPeripheralState) -> String {
    switch state {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown(\(state.rawValue))"
    }
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var seen = Set<UUID>()
    private var reads = 0
    private var connected: [UUID: CBPeripheral] = [:]
    private let deadline: Date

    init(seconds: Double) {
        deadline = Date().addingTimeInterval(seconds)
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("scanning for Battery Service (0x180F)…")
            central.scanForPeripherals(withServices: [BATTERY_SERVICE],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            print("BLUETOOTH PERMISSION DENIED — grant it in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff:
            print("Bluetooth is off.")
        default:
            print("central state = \(central.state.rawValue), waiting…")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !seen.contains(peripheral.identifier) else { return }
        seen.insert(peripheral.identifier)
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? "-"
        print("FOUND  \(peripheral.name ?? "(unnamed)")  rssi=\(RSSI)  advertised=[\(advertised)]  state=\(stateName(peripheral.state))")
        peripheral.delegate = self
        if peripheral.state == .connected {
            // macOS already holds a link to this device; just walk its services.
            print("  already connected — discovering services directly")
            peripheral.discoverServices([BATTERY_SERVICE])
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("  connected to \(peripheral.name ?? "?") — discovering services")
        connected[peripheral.identifier] = peripheral
        peripheral.discoverServices([BATTERY_SERVICE])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("  CONNECT FAILED: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("  disconnected \(peripheral.name ?? "?")\(error.map { " (\($0.localizedDescription))" } ?? "")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("  discoverServices error: \(error.localizedDescription)") }
        let uuids = (peripheral.services ?? []).map(\.uuid.uuidString)
        print("  services: \(uuids.isEmpty ? "(none)" : uuids.joined(separator: ","))")
        for service in peripheral.services ?? [] where service.uuid == BATTERY_SERVICE {
            peripheral.discoverCharacteristics([BATTERY_LEVEL], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { print("  discoverCharacteristics error: \(error.localizedDescription)") }
        let uuids = (service.characteristics ?? []).map(\.uuid.uuidString)
        print("  characteristics of 180F: \(uuids.isEmpty ? "(none)" : uuids.joined(separator: ","))")
        for characteristic in service.characteristics ?? [] where characteristic.uuid == BATTERY_LEVEL {
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { print("  read error: \(error.localizedDescription)") }
        guard characteristic.uuid == BATTERY_LEVEL, let data = characteristic.value, let level = data.first else {
            return
        }
        reads += 1
        print("BATTERY  \(peripheral.name ?? peripheral.identifier.uuidString) = \(level)%")
    }

    var isDone: Bool { reads > 0 || Date() > deadline }
    var succeeded: Bool { reads > 0 }
}

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 30) : 30
let probe = Probe(seconds: seconds)
probe.start()

while !probe.isDone {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}

print(probe.succeeded
      ? "\nRESULT: read the phone's battery over BLE — the GATT server is correct."
      : "\nRESULT: no readable Battery Level within \(Int(seconds))s.")
exit(probe.succeeded ? 0 : 1)
