OpenBerg
========

Install
-------
1. Drag OpenBerg to the Applications folder in this window.
2. Open OpenBerg from Applications. It lives in the menu bar (no Dock
   icon). The Setup window opens on first launch. Paste the API key and
   refresh token from the Atomberg Home app (Settings -> Developer Mode).

First launch is blocked by macOS
--------------------------------
This build is not signed with an Apple Developer ID, so a copy that was
downloaded is blocked the first time it is opened:
  1. Try to open the app; macOS refuses.
  2. Open System Settings -> Privacy & Security.
  3. Scroll down to the message about OpenBerg and click "Open Anyway",
     then confirm.
This is needed once; afterwards the app opens normally.

Notes
-----
* Credentials are stored in your login keychain, never in files.
* If you turn on local network control (the wifi button), macOS asks for
  Local Network permission. That is expected. Beacons are then read on
  the LAN and commands are sent there without spending cloud API calls.
* The free Atomberg plan allows 100 cloud calls a day; the app counts
  them and shows the tally in Setup.

OpenBerg is an independent, open-source app, free to use under the MIT
license. Not affiliated with Atomberg Technologies.
