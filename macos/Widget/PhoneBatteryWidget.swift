// PhoneBatteryWidget — a macOS WidgetKit widget showing battery levels for the
// Mac, the phone (read over Bluetooth by the menu bar app), and whatever
// accessories macOS tracks.
//
// A widget extension cannot run Bluetooth or spawn processes: the system
// renders it from a timeline with a small, infrequent execution budget. So the
// menu bar app does the collecting and publishes the list to a shared file, and
// this extension only reads that file when asked for a new timeline. That is
// also why the numbers can lag — WidgetKit decides when to refresh.
//
// Build: ./build-app.sh    Design preview: ./render-widget-preview.sh

import SwiftUI
import WidgetKit

/// Must stay in sync with `Shared` in PhoneBatteryBLEApp.swift.
private enum SharedFile {
    static var levelFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PhoneBattery/level.json")
    }
}

struct PhoneEntry: TimelineEntry {
    let date: Date
    let devices: [DeviceReading]
    let status: String
}

struct PhoneProvider: TimelineProvider {
    private func read() -> PhoneEntry {
        guard let data = try? Data(contentsOf: SharedFile.levelFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PhoneEntry(date: Date(), devices: [], status: "读取不到数据")
        }

        var devices: [DeviceReading] = []
        if let raw = object["devices"] as? [[String: Any]] {
            for item in raw {
                guard let id = item["id"] as? String,
                      let level = item["level"] as? Int else { continue }
                devices.append(DeviceReading(
                    id: id,
                    name: item["name"] as? String ?? id,
                    kind: item["kind"] as? String ?? "other",
                    level: level,
                    charging: item["charging"] as? Bool ?? false
                ))
            }
        } else if let level = object["level"] as? Int {
            // Older payload: phone only.
            devices = [DeviceReading(id: "phone", name: object["device"] as? String ?? "手机",
                                     kind: "phone", level: level, charging: false)]
        }
        return PhoneEntry(date: Date(), devices: devices,
                          status: object["status"] as? String ?? "")
    }

    func placeholder(in context: Context) -> PhoneEntry {
        PhoneEntry(date: Date(), devices: [
            DeviceReading(id: "mac", name: "Mac", kind: "mac", level: 100, charging: false),
            DeviceReading(id: "acc", name: "Headphones", kind: "headphones", level: 80, charging: false),
            DeviceReading(id: "phone", name: "Phone", kind: "phone", level: 64, charging: false),
        ], status: "已连接")
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneEntry) -> Void) {
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneEntry>) -> Void) {
        // Ask for a refresh in 15 minutes; WidgetKit is free to ignore this and
        // will in practice coalesce refreshes to keep battery cost down.
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct PhoneBatteryWidgetView: View {
    var entry: PhoneEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetContent(devices: entry.devices, compact: family == .systemSmall)
            .containerBackground(for: .widget) {
                WidgetBackground()
            }
    }
}

struct PhoneBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PhoneBatteryWidget", provider: PhoneProvider()) { entry in
            PhoneBatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("电量")
        .description("Mac、手机（蓝牙读取）与配件的电量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PhoneBatteryWidgetBundle: WidgetBundle {
    var body: some Widget {
        PhoneBatteryWidget()
    }
}
