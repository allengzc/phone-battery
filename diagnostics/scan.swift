// scan — list every nearby BLE peripheral with its advertised service UUIDs.
// Unfiltered, so it also proves whether the phone is advertising 0x1812 (HID)
// in addition to 0x180F (battery).
//
// Build: swiftc -O scan.swift -o scan
// Run:   ./scan [seconds]

import CoreBluetooth
import Foundation

final class Scan: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var seen = Set<UUID>()
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
        guard central.state == .poweredOn else {
            print("central state = \(central.state.rawValue) (5 == poweredOn)")
            return
        }
        print("scanning (unfiltered)…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !seen.contains(peripheral.identifier) else { return }
        seen.insert(peripheral.identifier)

        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "(unnamed)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).sorted().joined(separator: ",") ?? "-"
        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        let overflows = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).sorted().joined(separator: ",") ?? "-"
        print(String(format: "  %-28@ rssi=%-5d connectable=%@ services=[%@] overflow=[%@]",
                     name as NSString, RSSI.intValue,
                     (connectable.map { $0 ? "yes" : "no" } ?? "?") as NSString,
                     services as NSString, overflows as NSString))
    }

    var isDone: Bool { Date() > deadline }
}

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 15) : 15
let scan = Scan(seconds: seconds)
scan.start()
while !scan.isDone {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
print("done")
