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
* Local network control is on by default (the wifi button in the panel)
  and starts once Setup has saved your credentials: the fan is matched by
  the device id from your account, so it cannot be found locally before
  Setup. On first use macOS asks for Local Network permission. That is
  expected. Beacons are then read on the LAN and commands are sent there
  without spending cloud API calls. If the fan cannot be reached locally,
  the app falls back to the cloud on its own.
* OpenBerg only listens on the local network and refreshes status while
  the panel is open. With the panel closed it stays idle.
* The last known state is saved locally and restored instantly at every
  launch, so opening the panel does not refetch what OpenBerg already
  knows. Save & connect spends one call for your fan list, then reads
  status over the local network; one more call (the fan's state) only if
  the fan does not send its status locally. Usage totals are never part
  of Setup; they follow your refresh setting and the Refresh button.
* OpenBerg starts at login by default, so the menu bar icon is back after
  a restart. Turn it off in Setup, or under System Settings -> General ->
  Login Items.
* Setup can update OpenBerg in place: it checks GitHub at launch and once
  a month (or when you press Check now) and installs the new version for
  you. Update checks never use the Atomberg call quota.
* The free Atomberg plan allows 100 cloud calls a day; the app counts
  them and shows the tally in Setup.

OpenBerg is an independent, open-source app, free to use under the MIT
license. Not affiliated with Atomberg Technologies.
