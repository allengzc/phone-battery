// paired-probe — reports exactly what Stats 3.0.11's Bluetooth module reads
// when it decides which devices to list.
//
// Stats builds its device rows from:
//   IOBluetoothDevice.pairedDevices()                        ← rows come from here
//   /Library/Preferences/com.apple.Bluetooth  DeviceCache ∩ PairedDevices
//                                            + CoreBluetoothCache   ← battery + UUID
// so if the phone never appears below, it can never get a row in Stats —
// regardless of any BLE battery service it advertises.
//
// Build:  swiftc -O paired.swift -o paired
// Run:    ./paired

import Foundation
import IOBluetooth

func section(_ title: String) { print("\n=== \(title) ===") }

section("IOBluetoothDevice.pairedDevices()  [what Stats iterates]")
let paired = IOBluetoothDevice.pairedDevices() ?? []
if paired.isEmpty {
    print("(none)")
}
for case let device as IOBluetoothDevice in paired {
    let name = device.nameOrAddress ?? "(no name)"
    let addr = device.addressString ?? "(no address)"
    print("  \(name)")
    print("      address=\(addr)  paired=\(device.isPaired())  connected=\(device.isConnected())  rssi=\(device.rssi())")
}

section("com.apple.Bluetooth  DeviceCache ∩ PairedDevices  [Stats' battery source]")
if let cache = UserDefaults(suiteName: "/Library/Preferences/com.apple.Bluetooth") {
    let pairedAddrs = cache.object(forKey: "PairedDevices") as? [String] ?? []
    let deviceCache = cache.object(forKey: "DeviceCache") as? [String: [String: Any]] ?? [:]
    let coreCache = cache.object(forKey: "CoreBluetoothCache") as? [String: [String: Any]] ?? [:]
    print("  PairedDevices (\(pairedAddrs.count)): \(pairedAddrs.joined(separator: ", "))")
    print("  DeviceCache entries: \(deviceCache.count)   CoreBluetoothCache entries: \(coreCache.count)")
    for address in pairedAddrs {
        guard let entry = deviceCache[address] else { continue }
        let name = entry["Name"] as? String ?? "(no name)"
        let batteryKeys = ["BatteryPercent", "BatteryPercentCase", "BatteryPercentLeft",
                           "BatteryPercentRight"].filter { entry[$0] != nil }
        let uuid = coreCache.first { ($0.value["DeviceAddress"] as? String) == address }?.key
        print("  - \(name)  [\(address)]  batteryFields=\(batteryKeys.isEmpty ? "NONE" : batteryKeys.joined(separator: ","))  cbUUID=\(uuid ?? "NONE")")
    }
} else {
    print("  (cannot read the Bluetooth preference domain from this process)")
}

section("system_profiler SPBluetoothDataType  [Stats' connected list]")
let profiler = Process()
profiler.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
profiler.arguments = ["SPBluetoothDataType", "-json"]
let pipe = Pipe()
profiler.standardOutput = pipe
profiler.standardError = Pipe()
try? profiler.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
profiler.waitUntilExit()
if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let arr = root["SPBluetoothDataType"] as? [[String: Any]],
   let first = arr.first {
    for key in ["device_connected", "device_not_connected"] {
        let rows = first[key] as? [[String: Any]] ?? []
        var names: [String] = []
        for row in rows {
            for (name, fields) in row {
                let battery = (fields as? [String: Any])
                    .map { dict in
                        dict.keys.filter { $0.lowercased().contains("batterylevel") }
                            .map { "\($0)=\(dict[$0] ?? "")" }.joined(separator: ",")
                    } ?? ""
                names.append(battery.isEmpty ? name : "\(name) {\(battery)}")
            }
        }
        print("  \(key): \(names.isEmpty ? "(none)" : names.joined(separator: " | "))")
    }
}

section("VERDICT")
// Optional argument: a name substring to look for, e.g. `./paired pixel`.
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : nil
let matches = Array(paired).compactMap { $0 as? IOBluetoothDevice }.filter { device in
    let name = (device.nameOrAddress ?? "").lowercased()
    if let needle { return name.contains(needle) }
    return name.contains("phone") || name.contains("iphone") || name.contains("android")
}
print(matches.isEmpty
      ? "  No matching device in the paired list → Stats cannot show it yet."
      : "  \(matches.count) matching device(s) in the paired list → Stats gives them a row;"
        + " a BLE battery service would then supply the level.")
