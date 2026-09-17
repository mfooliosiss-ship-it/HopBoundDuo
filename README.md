# HopBoundDuo

HopBoundDuo is an original Android-focused, late-1990s-style 3D road-and-river hopping game built in Godot 4.7.2.

## Current playable prototype

- Low-poly fixed-camera 3D presentation
- Road traffic lanes with moving vehicles
- River lanes with moving logs
- Touch D-pad for Android
- Keyboard controls: Arrow keys or WASD
- Solo practice mode
- True separate-device LAN multiplayer using Godot ENet
- Host and join UI built into the game
- Up to 4 connected players in the networking layer
- Automatic Android APK build through GitHub Actions

## Two-phone play

1. Put both Android phones on the same Wi-Fi network.
2. Open HopBoundDuo on both phones.
3. On phone 1, tap **HOST**.
4. The top-left status line shows the host phone's LAN IP and port `24567`.
5. On phone 2, enter that LAN IP in the text box and tap **JOIN**.
6. Each phone controls its own hopper and both players can see one another.

## Android build

The GitHub Actions workflow `.github/workflows/android-apk.yml` creates a debug APK using Godot 4.7.2 stable and uploads it as a workflow artifact named `HopBoundDuo-Android`.

The project intentionally uses original geometry, names, layouts, and art while targeting the chunky low-poly visual feel and readable arcade movement associated with late-1990s 3D hopping games.
