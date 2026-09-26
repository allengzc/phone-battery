# Diagnostics

Small Swift tools written while working out how macOS and CodeIsland treat
Bluetooth devices. They are not needed to use the project, but they are how
every claim in the main README was verified — and they are the fastest way to
answer "is my phone actually advertising?".

Build any of them with:

```sh
cd diagnostics
swiftc -O probe.swift -o probe
./probe 25
```

The first run triggers the macOS Bluetooth permission prompt; grant it.

| Tool | Answers |
| --- | --- |
| `probe.swift` | Does anything nearby advertise the standard Battery Service (`0x180F`), and what is the value? Connect → discover → read `0x2A19`. |
| `scan.swift` | Unfiltered BLE scan: name, RSSI, connectable flag, and every advertised service UUID. Use it to confirm the phone advertises `180F` (and nothing else, see gotcha 8). |
| `tryconnect.swift` | Connection diagnostics with a properly serviced run loop and periodic `CBPeripheral.state` polling, so a silent stall is distinguishable from a callback bug. Takes an optional service UUID: `./tryconnect 15 1812`. |
| `paired.swift` | Prints exactly what Stats' Bluetooth module reads when deciding which devices to list: `IOBluetoothDevice.pairedDevices()`, and the `DeviceCache`/`PairedDevices`/`CoreBluetoothCache` keys — which are **gone on current macOS**, so Stats' BLE battery path is dead code here. |
| `drop-link.swift` | Closes macOS's existing Bluetooth link to one device (`./drop-link 5c-a0-6c-29-2b-52`) so a fresh central can connect. |

## What they established

- macOS reads the BLE Battery Service from a peripheral fine — `probe` read
  `98%` off an Android phone.
- Serving a HID service (`0x1812`) from the phone makes macOS drop the link
  immediately after connecting, with or without the HID UUID in the
  advertisement. `tryconnect` shows `didConnect` followed by nothing, then
  `didDisconnect`.
- Stats shows Bluetooth batteries only for devices macOS already knows about
  (`pairedDevices` / `pmset -g accps`), so a phone cannot appear there.
