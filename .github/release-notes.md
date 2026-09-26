## Downloads

### PhoneBatteryBLE.apk — the Android app

Sideload it, open it, grant the Bluetooth permission, and leave it running.
It advertises this phone's battery as a standard Bluetooth LE Battery Service
(`0x180F` / `0x2A19`) from a foreground service.

### PhoneBattery-macos-adhoc.zip — the Mac app

> **Ad-hoc signed**, because a CI runner has no signing identity. Clear the
> quarantine flag or Gatekeeper will refuse to open it:

```sh
unzip PhoneBattery-macos-adhoc.zip
xattr -cr PhoneBattery.app
cp -R PhoneBattery.app /Applications/
open /Applications/PhoneBattery.app
```

The menu bar item and the desktop card work as-is.

**The widget will not appear in the widget gallery from this build.** macOS
requires a widget extension to be signed with a real Team ID, and ad-hoc
signatures do not have one — this is documented in the README along with the
other traps. To get the widget either re-sign the extension with your own Apple
ID certificate, or build locally:

```sh
./macos/build-app.sh     # uses your own identity, if you have one
```
