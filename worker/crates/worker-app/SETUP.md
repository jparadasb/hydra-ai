# Running the hydra-worker desktop app

This crate is **excluded from the Rust workspace** because the Tauri runtime links the system
WebView (webkit2gtk on Linux). `cargo build --workspace` therefore stays buildable on headless
machines; build the GUI explicitly here.

## System dependencies

**Linux (Debian/Ubuntu):**
```sh
sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev
```
**Linux (Arch/Manjaro):**
```sh
sudo pacman -S webkit2gtk-4.1 base-devel curl wget file openssl \
  libayatana-appindicator librsvg
```
**macOS:** Xcode Command Line Tools. **Windows:** WebView2 (preinstalled on Win11) + MSVC.

The Tauri CLI is already used here (`cargo tauri --version`); otherwise `cargo install tauri-cli --version '^2'`.

## Icons (one-time)

`tauri.conf.json` references `icons/`. Generate them from any square PNG:
```sh
cargo tauri icon path/to/logo.png   # writes icons/ used by the bundle
```
`cargo tauri dev` runs without bundling and tolerates missing bundle icons.

## Run

```sh
cd worker/crates/worker-app
cargo tauri dev      # dev window with the worker/ui frontend
cargo tauri build    # production bundle (needs icons)
```

## What it wraps

The UI calls `#[tauri::command]` handlers in `src/main.rs`, which delegate to
`worker-tauri` (`commands::Commands` + `support`). That command layer is in the workspace and
unit-tested without the GUI — the app crate is a thin shell. Raw tokens enter `add_provider` /
`rotate_provider` and go straight to the encrypted vault; the UI only ever receives masked
fingerprints.
