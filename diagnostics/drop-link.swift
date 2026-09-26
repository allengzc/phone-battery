// drop-link — close macOS's existing Bluetooth link to one device, so a fresh
// CoreBluetooth central (e.g. Stats, or probe) can establish its own.
//
// Usage: ./drop-link 5c-a0-6c-29-2b-52

import Foundation
import IOBluetooth

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: drop-link <aa-bb-cc-dd-ee-ff>")
    exit(2)
}
let address = args[1]

guard let device = IOBluetoothDevice(addressString: address) else {
    print("no paired device with address \(address)")
    exit(1)
}

print("device:            \(device.nameOrAddress ?? "?")")
print("isPaired:          \(device.isPaired())")
print("isConnected:       \(device.isConnected())")

if !device.isConnected() {
    print("nothing to do — not connected")
    exit(0)
}

let result = device.closeConnection()
print("closeConnection -> \(result)")

// Give bluetoothd a moment to settle before a new central attaches.
Thread.sleep(forTimeInterval: 2.0)
print("isConnected now:   \(device.isConnected())")
