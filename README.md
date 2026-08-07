# Bears

A native macOS menu-bar app for cycling through the Explore.org Brooks Falls bear cameras.

## Controls

- Left-click the paw to advance to the next camera.
- Press Control-Option-B from anywhere to show or hide the current camera.
- Press Control-Option-N from anywhere to advance to the next camera.
- Right-click the paw to choose a camera, open Explore.org, change launch-at-login, or quit.
- Toggle Large View in the right-click menu to switch between 640x360 and 960x540 playback.
- Drag the left, right, or bottom edge of the video to resize it. The size sticks until you toggle Large View, which puts you back on a preset.
- Clicking elsewhere closes the video popover and stops playback. Uncheck Minimize on un-focus in the right-click menu to keep the camera open while you work in other apps; close it with the paw, Control-Option-B, or Hide Bears.

## Build

```sh
chmod +x build.sh
./build.sh
```

The app is written to `dist/Bears.app`.
