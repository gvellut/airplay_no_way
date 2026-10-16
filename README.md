# AirPlay!? No Way! (AudioMonitor)

*AirPlay!? No Way!* is a macOS utility that monitors audio devices and can revert audio output when AirPlay devices are connected (instead of set to the newly connected AirPlay device).

## Purpose

- Monitors system audio output and display connections.
- Preserves the current audio output (including Bluetooth or MacBook speakers) when an Apple TV display connects through AirPlay.
- Allows switching to the TV speakers manually afterward through the macOS Sound menu.
- Includes a launcher and a helper for background monitoring.

When a new external display connects, the helper watches for an AirPlay audio switch during a five-second setup window and restores the previous output once. After that restoration, or after the window expires, it leaves audio selections alone until another display connects. It also handles an audio switch reported up to five seconds before the display connection notification. Disconnecting the new display clears any remaining protection for that connection. Existing output selections are preserved when the helper starts.

This is a timing heuristic because macOS does not identify manual versus automatic output changes. A manual selection during the setup window may be reverted once; selecting the TV again will then be allowed. A delayed automatic switch outside the window may be allowed. Audio-only AirPlay selections without a display connection are left alone. The helper only restores AirPlay output changes; other output types are unaffected.

## Build

Prerequisites:

- *XCode* or *XCode Command-Line Tools*. For the tools, run `xcode-select --install` in the terminal . Among other things, this will install the Swift command-line compiler. Type `swift –version` in the terminal to check if it was installed correctly. Version 5.9 of the Swift tools is currently used (but a later version should be fine).
- The build process uses a code signing certificate named `My Swift Dev Cert` (by default). If you already have a code signing certificate (official Apple or self-signed), you can update the name in `app_config.env`, variable `SIGNING_CERT`. If you do not have a signing certificate, you need to create one in your Keychain. Follow [How to create code signing certificate in macOS](https://www.simplified.guide/macos/keychain-cert-code-signing-create) for a quick walkthrough of creating a self-signed certificate (for local use).

To build the application, run:

```sh
make
```

## Install

To install the app to your `~/Applications` folder:

```sh
make install
```

After installation, run the app once from your `~/Applications` folder to activate the background service. Manage in *Login Items > Allow in the Background*. The tool will be called **AudioMonitor**.

## Uninstall

To remove the app and disable the helper:

```sh
make uninstall
```

## Note

Log with `console.app` or in command-line:

`log stream --debug --info --predicate "subsystem = 'com.user.audiomonitor'"`
