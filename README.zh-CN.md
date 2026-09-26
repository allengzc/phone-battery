# 在 macOS 上显示手机电量

把安卓手机的电量显示到 Mac 上 —— **菜单栏**、**桌面卡片**，以及真正的 **WidgetKit 小组件**。**全程只走蓝牙。**

不需要同一个局域网、不需要云端账号、不需要后台服务、不需要 Gradle。

<p align="center">
  <img src="docs/images/widget-medium-dark.png" width="390" alt="小组件 深色">
  <img src="docs/images/widget-small-light.png" width="175" alt="小组件 浅色">
</p>

---

## 为什么必须自己写

三件事让所有"显而易见的办法"都不成立：

1. **手机从不通过蓝牙广播自己的电量。** 蓝牙上报电量是**外设**的能力：耳机、鼠标、键盘实现标准的 GATT Battery Service（`0x180F` / 特征 `0x2A19`）。Android 不会把本机电量那样暴露出去 —— 必须由一个 App 去做。
2. **macOS 不会为普通 BLE 外设显示电量。** 它只为 HID 和音频配件报电量。想靠"手机伪装成 HID 设备"混进那条路**是行不通的**：macOS 一旦看到 HID 服务就要求加密配对，而手机**已经和 Mac 绑定过**，于是连接刚建立就被断开（实测见 `diagnostics/probe.swift`）。而且这会把**所有** central 都搞坏，包括单纯的电池读取。
3. **ADB 无线调试要求两台设备在同一局域网**，而这常常做不到（网络不同、客户端隔离、公司 Wi‑Fi）。

所以这个项目做的是唯一可行的方案：**手机广播标准电池服务，Mac 上的小 App 直接用 BLE 读它。** 小组件的数据来自这个 App。

---

## 工作原理

```
┌─────────────────────────┐
│ 安卓 App                │  广播 GATT 电池服务 0x180F
│ （前台服务）             │  特征 0x2A19 = 电量百分比，支持 notify
└───────────┬─────────────┘
            │  蓝牙 LE
            ▼
┌─────────────────────────┐        ┌──────────────────────────────┐
│ macOS 菜单栏 App        │◀───────│ pmset -g accps               │
│ （CoreBluetooth 主设备） │        │ Mac 本机 + 配件电量           │
└───────────┬─────────────┘        └──────────────────────────────┘
            │ 写出 JSON（level.json）
            ▼
   ~/Library/Containers/<widget-id>/Data/Library/Application Support/PhoneBattery/
            │
            ▼
┌─────────────────────────┐
│ WidgetKit 扩展          │  每次系统要时间线时读这个文件
└─────────────────────────┘
```

菜单栏 App 还会画一个可拖动的桌面卡片。和小组件不同，**它是实时的** —— 因为它由 BLE 通知驱动，而不是 WidgetKit 的调度。

---

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `android/` | 手机端：`BluetoothGattServer` + `BluetoothLeAdvertiser`，刻意只保留电池服务 |
| `android/build.sh` | 用 `aapt2 → javac → d8 → zipalign → apksigner` 构建并签名 APK（不经 Gradle） |
| `macos/` | 菜单栏 App、桌面卡片，以及共享的小组件视图 |
| `macos/Widget/` | WidgetKit 扩展 |
| `macos/render-widget-preview.sh` | 把小组件离屏渲染成 PNG —— 不用截屏就能检查外观 |
| `diagnostics/` | 当初用来摸清蓝牙行为的几个 Swift 小工具，见 `diagnostics/README.md` |
| `scripts/setup-toolchains.sh` | 下载 Android SDK |

---

## 环境要求

- **macOS 14+**（小组件用到 `containerBackground`），以及 Xcode 命令行工具
- **Android 8.0+**（API 26）
- 一个**代码签名身份**（见下面「签名」）—— 在 Xcode 里登录一个 Apple ID 就够，**不需要付费开发者账号**
- 构建安卓端需要 JDK **17**

---

## 构建

### 安卓端

```sh
./scripts/setup-toolchains.sh    # 约 250 MB，只需一次
./android/build.sh               # 产出 android/PhoneBatteryBLE.apk
```

侧载到手机上，打开，授予蓝牙权限。会出现一条常驻通知 —— 那就是前台服务在广播电池服务。

### macOS 端

```sh
./macos/build-app.sh             # 产出 macos/PhoneBattery.app
open macos/PhoneBattery.app
```

**小组件要被系统发现，App 必须放在标准位置**：

```sh
cp -R macos/PhoneBattery.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PhoneBattery.app
pluginkit -a /Applications/PhoneBattery.app/Contents/PlugIns/PhoneBatteryWidget.appex
```

然后去小组件库添加，**搜 PhoneBattery**（小组件库是按 App 名归类的）。

### 签名

`build-app.sh` 会自动取第一个 `codesign` 身份，先签扩展、再签 App。如果找不到身份就退回 ad-hoc —— **那样小组件永远不会出现在库里**，因为 macOS 要求小组件扩展必须有 Team ID。

创建身份：打开 Xcode → *Settings → Accounts* → `+` → Apple ID → *Manage Certificates* → `+` → **Apple Development**。

---

## 踩过的坑（全部靠读日志才定位到）

下面每一条都**不会**在界面上给出任何错误提示，只能从 `chronod` 的日志里看出来。

1. **小组件扩展必须沙箱化。** 没有 `com.apple.security.app-sandbox` 时，`pluginkit -a` 照样返回 0，但扩展根本没注册：`pluginkit -m -i <id>` 显示 `(no matches)`。
2. **必须有真实 Team ID 的签名。** ad-hoc（`Signature=adhoc`、`TeamIdentifier=not set`）不会出现在小组件库里。
3. **必须声明平台。** `CFBundleSupportedPlatforms=[MacOSX]` 以及 `DTPlatformName` / `DTSDKName`。`swiftc` 不会自动加，Xcode 会。
4. **必须链接 `_NSExtensionMain`。** App Extension 是被当成 XPC 服务拉起的，入口就是它：
   ```sh
   swiftc … -Xlinker -e -Xlinker _NSExtensionMain
   ```
   否则二进制里是普通的 Swift `main`，`chronod` 会一直刷
   `query failed … "The connection to service with pid -1 named (null) was invalidated"`，而界面上一片安静。
5. **`codesign` 可能报 `errSecInternalComponent`**，原因是钥匙串里缺少与你证书签发者匹配的 Apple WWDR 中间证书。看一眼 issuer 再装对应的那个：
   ```sh
   curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
   security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
   ```
6. **`chronod` 会缓存描述符，并且把扩展的时间戳记成 `1970-01-01`**，所以重新构建后它仍然渲染**旧设计**，也学不到新增的小组件尺寸。强制重新发现：
   ```sh
   pluginkit -r /Applications/PhoneBattery.app/Contents/PlugIns/PhoneBatteryWidget.appex
   rm -rf ~/Library/Containers/com.dsh.phonebattery.menubar.widget/Data/SystemData/com.apple.chrono
   pluginkit -a /Applications/PhoneBattery.app/Contents/PlugIns/PhoneBatteryWidget.appex
   killall chronod
   ```
7. **沙箱化的小组件读不到你 App 的文件。** App Group 需要真正的描述文件，所以改成：App 直接写进小组件自己的容器，沙箱里的小组件把它当自己的 Application Support 读。
8. **不要给手机的 GATT server 加 HID 服务。** 原因见开头，它会把所有连接都搞坏。
9. **JDK 21 会让安卓构建失败。** build-tools 34.0.0 里的 `d8`/R8 8.2.2 处理不了 `javac` 21 编译的匿名内部类（`NullPointerException: Cannot invoke "String.length()"`）。`build.sh` 会挑 JDK 17。
10. **从守护进程日志验证，而不是从界面：**
    ```sh
    log show --last 5m --predicate 'process == "chronod"' | grep -i phonebattery
    ```
    出现 `Reload success` 和 `Successfully subscribed to session` 才算真的活了。

---

## 已知限制

- **小组件按系统调度刷新。** 时间线里请求 15 分钟一次，但 macOS 会合并刷新，实际往往更久。把小组件当"瞥一眼"，要实时看菜单栏或桌面卡片。
- **手机是否在充电拿不到。** 蓝牙电池服务只有一个百分比，所以手机那格永远不显示充电闪电；Mac 和配件那格会显示。
- **手机 App 必须保持运行。** 它靠前台服务维持广播；在激进的后台管理下 Android 仍可能停掉广播，数值不更新的话把它加入电池优化白名单。

---

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
