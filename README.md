# OpenBerg

A free, open source macOS menu bar app for Atomberg smart fans.

![OpenBerg control panel](screenshots/panel.png)

OpenBerg lives in your menu bar. Click the fan icon and a small panel opens with everything your fan supports: power, speed, sleep, timer, light, reverse and buzzer. It also shows lifetime energy and runtime, and whether the fan is being reached over your local network or through the cloud.

## What it offers

* Power on and off, and speed from 1 to 6.
* Sleep mode, timer and buzzer, where your fan supports them.
* Light brightness and colour (warm, cool, daylight) for fans with a light.
* Reverse mode for reversible fans.
* Lifetime energy and runtime, read from Atomberg's own analytics.
* Local network control whenever the fan is reachable that way. It is faster and does not use cloud calls, and the app falls back to the cloud on its own.
* A menu bar icon that reflects the fan state, with the current speed beside it if you like.
* Credentials stored in the macOS keychain, never in plain files.
* Stays inside the free plan limit of 100 cloud calls a day, with the count shown in Setup.

Controls for features your fan does not have are simply not shown.

## Requirements

* macOS 27 or later.
* An Atomberg fan with Wi-Fi, on your Atomberg Home account.
* Developer Mode enabled in the Atomberg Home app (Setup walks you through this).

## Setup

1. Open the Atomberg Home app, go to Settings, then Developer Mode, and enable it.
2. Copy the API key and the refresh token shown there.
3. Open OpenBerg. The Setup window opens on first launch. Paste both values and click Save & connect.
4. Pick your fan from the list.

![OpenBerg setup](screenshots/setup.png)

On first use macOS may ask for Local Network permission. Allow it if you want local control, since that is how OpenBerg finds your fan without the cloud. Everything can be changed later from the same Setup window.

## Install

Download from the [Releases page](https://github.com/Harshsanket/open-berg/releases):

* **OpenBerg-1.0.0.dmg**: open it and drag OpenBerg into Applications.
* **OpenBerg-1.0.0.zip**: the app bundle as a zip, if you prefer that.

The app is not notarized by Apple, so the first launch is blocked by macOS. To allow it:

1. Try to open OpenBerg once. macOS refuses.
2. Open System Settings, go to Privacy & Security, scroll to the OpenBerg message and click Open Anyway.
3. Confirm. This is needed once, and the app opens normally after that.

## Notes

* OpenBerg is an independent, open source project. It is not affiliated with Atomberg.
* Thanks to Atomberg for offering Developer Mode, which makes apps like this possible.
* Written in Swift with SwiftUI and AppKit, following Apple's documentation for menu bar apps. No third party dependencies.
* Built with help from DeepSeek.
* Free to use under the MIT License.

## Build from source

```
swift build -c release
scripts/build-app.sh      # app bundle in dist/
scripts/build-release.sh  # app, DMG and zip in dist/
```

---

<p align="center">a <b>Harsh Sanket</b> production</p>
