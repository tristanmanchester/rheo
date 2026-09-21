# Rheo

Instant macOS Space switching with trackpad swipes, keyboard shortcuts, and a command-line interface. Rheo lives in your menu bar and combines a Rust core with native Objective-C/AppKit integration.

## Install

You need macOS 15–27, Apple Command Line Tools, Rust/Cargo 1.85 or later, and Python 3.

```sh
git clone https://github.com/tristanmanchester/rheo.git
cd rheo
./scripts/install.sh
```

The installer builds Rheo for your Mac, copies it to `~/Applications/Rheo.app`, and opens it. On first launch, enable **Rheo** in **System Settings > Privacy & Security > Accessibility** so it can intercept Space swipes. Quit any other Space-swipe interceptor before using Rheo.

If you need Apple Command Line Tools, run `xcode-select --install`. Install Rust through [rustup](https://rustup.rs/).

## Use Rheo

Swipe between Spaces with your trackpad or press **Control–Option–Left/Right**. Open Rheo's menu bar menu to toggle **Intercept swipes** and **Control–Option–Arrow hotkeys**.

### Command line

With Rheo running, use its bundled executable:

```sh
APP="$HOME/Applications/Rheo.app/Contents/MacOS/rheo"
"$APP" status
"$APP" switch right
"$APP" switch left
```

`status` returns JSON with the app's runtime state, Accessibility permission, event-tap status, and hotkey registration.

| Command | Action |
| --- | --- |
| `enabled on` / `enabled off` | Enable or disable swipe interception |
| `hotkeys on` / `hotkeys off` | Enable or disable Control–Option–Arrow shortcuts |
| `show` | Restore the menu bar icon |
| `quit` | Stop Rheo |

For example, run `"$APP" hotkeys off` to disable the shortcuts. To start Rheo again:

```sh
open "$HOME/Applications/Rheo.app"
```

### Update an installation

Quit Rheo, move the existing `~/Applications/Rheo.app` aside, pull the source changes, and run `./scripts/install.sh` again. The installer preserves an existing installation by refusing to overwrite it.

## Develop

Build the app into `dist/Rheo.app`:

```sh
./scripts/build.sh
```

Quit the installed copy before launching a development build. To build, launch, and check that the resident app responds over IPC:

```sh
./script/build_and_run.sh --verify
```

The default build targets your Mac's architecture and uses an ad-hoc signature. Set `SIGN_IDENTITY` to use another signing identity. For a universal build:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
ARCHS="arm64 x86_64" ./scripts/build.sh
```

The Rust workspace has no third-party Cargo dependencies. Builds use `--locked --offline` after the toolchain and target libraries are installed. CMake wraps the same build and test entrypoints.

### Test

```sh
./scripts/test.sh
./scripts/bench.sh
```

The test pipeline runs Rust tests in debug and release modes, checks the C ABI layout, runs 33 C regression groups, and compares the Rust core against the frozen C reference. On macOS it also tests native geometry and event preparation without posting input.

For formatting, Clippy, and the test pipeline:

```sh
./scripts/check.sh
```

This command requires rustfmt and Clippy and formats Rust files in place. See [validation](docs/VALIDATION.md) and [native acceptance steps](docs/NATIVE-HANDOFF.md) for test coverage and recorded results.

### Source layout

| Location | Purpose |
| --- | --- |
| `crates/rheo-core/` | Gesture decisions, Space prediction, payload encoding, and batch preparation |
| `crates/rheo-ffi/` | C ABI and foreign callbacks |
| `src/core/` | Public C header |
| `src/macos/` | Objective-C/AppKit integration |
| `tests/` | Regression, ABI, differential, and native tests |
| `tests/reference/c/` | Frozen C implementation used by tests and benchmarks |
| `scripts/` | Build, install, test, and benchmark commands |

`rheo-core` uses `no_std`, forbids unsafe code, and keeps its state in fixed-capacity arrays. `rheo-ffi` exports the `sn_*` C interface and produces `librheo_ffi.a` for the native adapter.

## Background

Rheo was formerly Strafe Next. Version 0.2.0 ports its four C17 core modules to Rust 2024 while retaining the native macOS adapter. Read the [architecture](docs/ARCHITECTURE.md), [porting notes](docs/PORTING.md), [rename notes](docs/RENAME.md), and [security and privacy documentation](SECURITY.md) for details.

## License

[MIT](LICENSE). Original Strafe attribution and upstream licenses are preserved in [third-party notices](THIRD_PARTY_NOTICES.md).
