# Duet Bridge

**Keyboard volume control for Apogee Duet 2 on modern macOS.**

[Türkçe](README.tr.md)

On recent Macs (tested on a Mac mini M4 with macOS 26) the Duet 2's keyboard
volume integration no longer works: the macOS volume HUD moves, but the Duet's
analog output does not change. There is no official fix.

Duet Bridge is a small menu bar app that restores it. It intercepts the volume
and mute keys while the Duet is the default output and sends the change
straight to **ApogeeGlue**, the background service that Apogee Control 2 itself
talks to. The hardware level and the Duet's OLED update immediately, and turns
of the physical knob are read back.

> **Not affiliated with Apogee Electronics.** "Apogee", "Duet" and "Apogee
> Control" are trademarks of their owners. This is an independent
> interoperability tool; it ships no Apogee code or files. Use at your own risk.

## Features

- Volume up / down and mute act on the Duet's real hardware output.
- Works with Apogee Control 2 closed; it only needs Apogee's background services
  (installed with Apogee Control 2).
- Menu bar icon shows the current level in dB; small on-screen overlay.
- Main Out or headphones as the target, configurable step size, Dim.
- Keys are passed through to macOS when the default output is not the Duet.
- Starts at login and restarts itself if it ever crashes.
- Command line control for scripts and shortcuts.
- English and Turkish UI, following the system language.

| Keys | Action |
| --- | --- |
| Volume up / down | Change the target output (Main Out by default) by 2 dB |
| ⇧⌥ + volume up / down | 1 dB fine steps |
| ⌃ + volume up / down | Control the other output (headphones) |
| Mute | Mute / unmute the target output |
| ⌥ + mute | Toggle Dim |

## Requirements

- Apogee Duet 2 with Apogee Control 2 installed (tested with Apogee Control 2
  1.21.55 / ApogeeGlue 1.21.52).
- macOS 14 or later; developed and tested on macOS 26.4 on Apple Silicon.
- Xcode or the Xcode Command Line Tools (Swift 6) to build.

## Install

There is no prebuilt download: you build and sign the app on your own Mac.

```sh
git clone https://github.com/zgrkrky/duet-bridge.git
cd duet-bridge
Scripts/install.sh
```

This builds the app, installs it to `~/Applications/Duet Bridge.app` and adds a
LaunchAgent (`~/Library/LaunchAgents/com.local.duet-bridge.plist`) so it starts
at login.

On first launch, allow **Duet Bridge** in **System Settings › Privacy &
Security › Accessibility**. This is required to intercept the volume keys. The
app notices the permission by itself within a few seconds; no restart needed.

### If the keys do nothing after granting permission

The app is signed ad hoc, so macOS ties the permission to that exact binary. If
an older build is listed, the switch can look enabled while not applying to the
current one. Reset it and grant it again:

```sh
tccutil reset Accessibility com.local.DuetBridge
```

The menu bar menu has the same action. `Scripts/install.sh` only re-signs the
app when the binary actually changed, so re-running it does not break a working
permission; rebuilding after a code change does.

Check `~/Library/Logs/DuetBridge.log` for the line `event tap installed`.

## Command line

```sh
duet-bridge --status
duet-bridge --set  main -30
duet-bridge --step hp +2
duet-bridge --mute main [on|off|toggle]
duet-bridge --dim  main [on|off|toggle]
```

The binary is at `~/Applications/Duet Bridge.app/Contents/MacOS/duet-bridge`.
These commands do not need any permission.

Service control: `Scripts/duet-bridge-control.sh {install|start|stop|restart|status}`

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.local.duet-bridge
rm ~/Library/LaunchAgents/com.local.duet-bridge.plist
rm -rf ~/Applications/Duet\ Bridge.app
tccutil reset Accessibility com.local.DuetBridge
```

## How it works

Apogee Control 2 does not drive the hardware itself. It talks to ApogeeGlue over
a local TCP connection (`127.0.0.1:53435`) using a JUCE `ValueTree`
synchronisation protocol. Duet Bridge speaks the same protocol: it reads the
device tree once, sets `gain`, `mute` and `dim` on the outputs, and listens for
changes made elsewhere (the knob, Apogee Control 2). See
[PROTOCOL.md](PROTOCOL.md) for the details.

If an Apogee update changes the protocol, `duet-bridge --status` will fail to
connect or read the device, and the menu bar icon shows a warning. Keys then go
back to normal macOS behaviour.

### ApogeeGlue CPU usage

`Scripts/apogee-health.sh` shows the CPU use of Apogee's processes;
`--restart` restarts its services (needs `sudo`, briefly interrupts audio).

## Contributing

Issues and pull requests are welcome, especially reports from other Duet 2
setups, other Apogee interfaces that use ApogeeGlue, and other macOS versions.
Please include the output of `duet-bridge --status` and your Apogee Control 2
version.

## License

[MIT](LICENSE)
