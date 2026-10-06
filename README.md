# NotchAway

A small native macOS menu-bar utility that visually hides the MacBook display notch by generating a wallpaper with a black top band.

## Requirements

- macOS 13 Ventura or newer
- Xcode 15 or newer recommended
- A MacBook with a built-in display (notch auto-detection uses `NSScreen.safeAreaInsets`)

## Run

1. Open `NotchAway.xcodeproj` in Xcode.
2. Select the **NotchAway** scheme and **My Mac** as the run destination.
3. In **Signing & Capabilities**, choose your Apple Development team if Xcode asks for signing.
4. Press **Run** (⌘R).
5. A NotchAway icon appears in the macOS menu bar.
6. Turn **Hide the MacBook notch** on.

## Test checklist on a notched MacBook

1. Note your current wallpaper before starting.
2. Enable NotchAway and verify the top menu-bar/wallpaper region becomes black and the notch blends into it.
3. Open a normal app window and verify menu-bar text/icons remain usable.
4. In Settings, disable automatic height and try 34–45 pt if the black band is too short/tall.
5. Click **Restore Wallpaper** and confirm the original wallpaper and scaling return.
6. Quit and relaunch with NotchAway enabled; verify it re-applies the effect.
7. Test **Launch at Login** if desired.
8. Connect an external display; the app should only modify the built-in display.

## Notes

- This is visual masking; software cannot remove the physical camera/sensor cutout.
- Dynamic wallpapers are flattened while the effect is active. Restoring returns to the original wallpaper URL and stored desktop-image options.
- The project intentionally does not enable App Sandbox for this local MVP because it needs reliable access to the current wallpaper. App Store distribution would need additional sandbox/distribution work.
