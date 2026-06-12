# Karoo MTB Trail Colors

Build Mapsforge overlay maps that render MTB trail difficulty as colored lines on top of any base map, for use on Hammerhead Karoo devices and other Mapsforge renderers.

## What It Does

Produces an overlay map containing ways with `mtb:scale` tags and `natural=bare_rock` areas. When displayed alongside a base map using the shared `offline_v15.xml` theme, colored trail lines and bare rock areas appear on top without duplicating roads, buildings, or other features.

### MTB Scale Colors

| Scale | Color | Difficulty |
|-------|------|------------|
| S0 | 🟢 Green `#22AA22` | Easy |
| S1 | 🟢 Lime `#88CC00` | Moderate |
| S2 | 🟡 Yellow `#FFCC00` | Difficult |
| S3 | 🟠 Orange `#FF8800` | Very Difficult |
| S4 | 🔴 Red `#DD0000` | Extreme |
| S5 | 🔴 Red `#DD0000` | Extreme |

Each trail renders as a solid color casing (width 0.9) with a dashed black center line (width 0.4, dasharray 5,6).

### Bare Rock / Bedrock

The overlay also includes `natural=bare_rock` areas, shown as sandy-brown filled polygons (`#d5c8af`) with a dark brown outline (`#8b7355`, 0.3px) and a tiled rock-pattern overlay. These highlight exposed bedrock and rocky terrain that is relevant for MTB route planning.

## Supported Regions

Finland, Germany, Norway, Sweden, Estonia, Spain, France, Italy, Austria, Switzerland

Custom bounding boxes are supported via the CLI script.

## Usage

### Windows (GUI)

Double-click **`MTB Overlay Builder.bat`** or run:

```powershell
powershell -ExecutionPolicy Bypass -File mtb-overlay-builder.ps1
```

Select a country, click **Build Map**, then **Push to Karoo**. Everything is auto-downloaded on first run.

### Linux (CLI)

```bash
# Prerequisites
sudo apt install openjdk-17-jre osmium-tool curl

./build-mtb-overlay.sh                  # Build for Finland (default)
./build-mtb-overlay.sh germany          # Build for another country
./build-mtb-overlay.sh --download finland  # Force fresh download
./build-mtb-overlay.sh --push finland    # Build and push to Karoo (restart device after)
./build-mtb-overlay.sh --push-only finland # Push existing map (restart device after)
```

### Linux (TUI)

```bash
sudo apt install whiptail openjdk-17-jre osmium-tool curl
./build-mtb-tui.sh
```

Menu-driven interface with country selection, cached data management, and push-to-Karoo & reboot support.

## Push to Karoo

All scripts support pushing to a Karoo device via ADB:

1. Detects the Karoo's storage path (`/sdcard/offline/maps/`)
2. Detects the actual `offline_vXXX.xml` theme filename on the device (e.g., `offline_v15.xml`, `offline_v16.xml`)
3. Backs up the existing theme file as `<filename>.bak`
4. Pushes the `.map` file, theme file, and icon assets (using the detected device filename)
5. Prompts the user to restart the device (restarting via power menu avoids bug report notifications)

On Windows, ADB is auto-downloaded if missing. On Linux, install it separately (`sudo apt install adb`).

> **Note:** Developer options must be enabled on the Karoo device for ADB push to work. Go to **Settings → Device Info** and tap the build number 7 times to unlock developer options, then enable **USB debugging** under **Settings → Developer Options**.

For manual transfer: copy files from `data/` to the Karoo, then reboot the device. Add the overlay as a second map layer using the shared theme.

## Self-Contained Downloads

All scripts auto-download their dependencies on first run (~71 MB total):

| Component | Source | Size |
|-----------|--------|------|
| JRE 17 | Eclipse Temurin (Adoptium) | ~42 MB |
| Mapsforge map-writer | Maven Central (pre-built JAR) | ~6 MB |
| Osmosis | GitHub releases | ~8 MB |
| Android Platform Tools | Google (Windows only) | ~15 MB |

Cached tools are stored in `build-tools/`. PBF data files are also cached there. Use **Delete Cached Data** (Windows) or option 4 (TUI) to free disk space while keeping tools.

## Theme & Asset Auto-Restore

`offline_v15.xml` and `icons/bare_rock.svg` are embedded in all three scripts. If accidentally deleted from `data/`, they are automatically restored on the next run.

## Build Configuration

| Setting | Value | Reason |
|---------|-------|--------|
| Format | `tag-values=false` (V4) | Maximum device compatibility |
| Tag-mapping | Default Mapsforge + MTB tags merged | Wildcard/minimal mappings produce broken maps |
| Map type | `type=ram` | Filtered PBF fits in memory |
| JVM heap | `-Xmx2g` | Needed for bare_rock polygon data |
| Zoom intervals | `5,0,7,10,8,11,14,12,21` | Must be adjacent |
| Filter | `--tf accept-ways mtb:scale=* natural=bare_rock` | Overlay only — prevents duplication with base map |

## Project Files

| File | Description |
|------|-------------|
| `mtb-overlay-builder.ps1` | Windows PowerShell WinForms GUI |
| `MTB Overlay Builder.bat` | Windows double-click launcher |
| `build-mtb-overlay.sh` | Linux CLI with push support |
| `build-mtb-tui.sh` | Linux interactive TUI |
| `data/offline_v15.xml` | Karoo 3 render theme (shared by both maps); pushed as the detected `offline_vXXX.xml` on device |
| `data/icons/bare_rock.svg` | Tiled rock-pattern overlay for bare_rock areas |
| `data/<region>-mtb-overlay.map` | Built overlay maps (gitignored) |
| `tag-mapping-mtb.xml` | Reference tag-mapping |