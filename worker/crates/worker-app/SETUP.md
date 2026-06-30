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
sudo pacman -S --needed webkit2gtk-4.1 base-devel pkgconf dbus curl wget file openssl \
  libayatana-appindicator librsvg
```
(`dbus` + `pkgconf` are required by the appindicator/`libdbus-sys` build — omitting them fails
with `Package 'dbus-1' not found`.)
**macOS:** Xcode Command Line Tools. **Windows:** WebView2 (preinstalled on Win11) + MSVC.

The Tauri CLI is already used here (`cargo tauri --version`); otherwise `cargo install tauri-cli --version '^2'`.

### Homebrew/linuxbrew users: `Package 'glib-2.0' not found`

If you have linuxbrew on `PATH`, its `pkg-config` shadows the system one and only searches
brew dirs, so the build can't find the system GTK/WebView `.pc` files even though the packages
are installed. Point pkg-config at the system dir for the build:
```sh
PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig cargo tauri dev
```
or force the system tool for the session: `export PKG_CONFIG=/usr/bin/pkgconf`.

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

## Running jobs from the app

The **Run** tab connects to the coordinator and processes leased jobs in the background:
unlock the vault → optionally enter a coordinator URL (blank uses config/env/default) →
**Start**. A live panel shows running / connected / jobs processed / last error; **Stop** halts
it. This drives the same `worker_core::worker_run` path the CLI's `hydra-worker run` uses, so
behaviour (machine identity, device-key auth, gateway loop) is identical. The device key is
created on first Start under the app's config dir and never leaves the machine.

## What it wraps

The UI calls `#[tauri::command]` handlers in `src/main.rs`, which delegate to `worker-tauri`
(`commands::Commands`, `support`, and `Runner` for Start/Stop). That command layer is in the
workspace and unit-tested without the GUI — the app crate is a thin shell. Raw tokens enter
`add_provider` / `rotate_provider` and go straight to the encrypted vault; the UI only ever
receives masked fingerprints.
