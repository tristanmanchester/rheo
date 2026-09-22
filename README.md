# Rheo

Instant macOS Space switching with trackpad swipes, keyboard shortcuts, and a command-line interface. Rheo lives in your menu bar and combines a Rust core with native Objective-C/AppKit integration.

## Install

On macOS 15–27, install with [Homebrew](https://brew.sh/):

```sh
brew install --cask tristanmanchester/tap/rheo
open -a Rheo
```

Homebrew installs the app and the `rheo` command. The release includes Apple Silicon and Intel builds. On first launch, enable **Rheo** in **System Settings > Privacy & Security > Accessibility** so it can intercept Space swipes. Quit any other Space-swipe interceptor before using Rheo.

## Use Rheo

Swipe between Spaces with your trackpad or press **Control–Option–Left/Right**. Open Rheo's menu bar menu to toggle **Intercept swipes** and **Control–Option–Arrow hotkeys**.

### Mouse utilities and desktop shortcuts

Some mouse utilities implement “Switch between desktops” by sending the macOS
desktop keyboard shortcuts (usually **Control–Left/Right**). To give those actions
Rheo's instant switching, enable **Intercept desktop shortcuts** in Rheo's menu,
or run `rheo desktop-shortcuts on`. This option is off by default and works with
physical keyboards and utilities from any vendor; existing mouse bindings stay unchanged.

Rheo reads the enabled **Move left a space** and **Move right a space** bindings
from **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**.
Only explicitly saved bindings using standard Shift/Control/Option/Command
modifiers are supported. If diagnostics show `desktop_shortcuts_configured: 0`,
configure those shortcuts in System Settings. Changes are picked up within a few
seconds. Shifted variants and other shortcuts remain native unless explicitly
assigned to these two actions.

Each press switches once; key repeats are suppressed until release. When Rheo
cannot safely post a switch, the original shortcut passes through to macOS.
This setting is independent of swipe interception and Rheo's Control–Option hotkeys.

### Command line

With Rheo running:

```sh
rheo status
rheo switch right
rheo switch left
```

`status` returns JSON with the app's runtime state, Accessibility permission, event-tap status, and hotkey registration.

| Command | Action |
| --- | --- |
| `enabled on` / `enabled off` | Enable or disable swipe interception |
| `hotkeys on` / `hotkeys off` | Enable or disable Control–Option–Arrow shortcuts |
| `desktop-shortcuts on` / `desktop-shortcuts off` | Intercept configured macOS desktop shortcuts |
| `show` | Restore the menu bar icon |
| `quit` | Stop Rheo |

For example, run `rheo hotkeys off` to disable the shortcuts. To start Rheo again:

```sh
open -a Rheo
```

### Update an installation

```sh
brew update
brew upgrade --cask tristanmanchester/tap/rheo
open -a Rheo
```

## Develop

Building from source requires Apple Command Line Tools, Rust/Cargo 1.85 or later, and Python 3. Install the tools with `xcode-select --install` and [rustup](https://rustup.rs/), then clone the repository:

```sh
git clone https://github.com/tristanmanchester/rheo.git
cd rheo
```

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

For a source installation, `./scripts/install.sh` builds, copies the app to `~/Applications/Rheo.app`, and opens it. It refuses to overwrite an existing app. The source-built CLI is available at `~/Applications/Rheo.app/Contents/MacOS/rheo`.

See [releasing](docs/RELEASING.md) for the Homebrew packaging and publication steps.

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
