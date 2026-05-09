# Knit icon sources

Drop your icon PNG(s) here; `Scripts/build-app.sh` will pick them up
automatically the next time you build `Knit.app`.

## Required

| File | Used for | Notes |
|---|---|---|
| `app-icon.png` | `Knit.app` icon (Dock, Launchpad, Finder) | Square. **1024 × 1024 px** recommended. Pre-rounded corners are fine — macOS does **not** auto-round non-system icons. Transparent background OK. |

## Optional

| File | Used for | Notes |
|---|---|---|
| `doc-icon.png` | `.knit` file icon in Finder | Square, **1024 × 1024 px**. If omitted, a document icon is auto-derived: `app-icon.png` is composited onto a folded-corner page silhouette with a "KNIT" wordmark below. |

## Workflow

```bash
# 1. Place your image(s)
cp ~/Downloads/my-knit-icon.png Resources/Icons/app-icon.png
# (optionally)
cp ~/Downloads/my-knit-doc.png  Resources/Icons/doc-icon.png

# 2. Rebuild the app + DMG
./Scripts/build-app.sh
./Scripts/package-dmg.sh

# 3. Reinstall to refresh Finder's icon cache
./Scripts/uninstall.sh && open dist/Knit.dmg
# then in /Volumes/Knit:
./install.sh
```

## Resetting to the Swift-drawn defaults

Just delete the PNG(s):

```bash
rm Resources/Icons/app-icon.png Resources/Icons/doc-icon.png
./Scripts/build-app.sh
```

The build falls back to `Scripts/make-icons.swift` (procedural "K" mark on
indigo→teal gradient).

## Tips

- **macOS icon shape**: Apple's HIG icons use a "squircle" (rounded square)
  shape with about 22% corner radius at 1024 px. If you want to match the
  system look, pre-render your image with that mask.
- **Bleed**: Reserve ~5–10% inner padding so important content isn't clipped
  by the system's slight inset when displayed in Dock badges, etc.
- **Alpha**: Transparent backgrounds work; macOS just renders them as-is.
- **Source format**: PNG only (the script uses `CGImageSource` which prefers
  PNG/JPEG/HEIC; PNG is the safest).
