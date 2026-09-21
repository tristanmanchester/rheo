# Rheo rename — 21 September 2026

Rheo is the new name of the supplied Strafe Next Rust project. This is an identity
and packaging update, not a second language port or a claim of new performance.
Version remains **0.2.0**. The stale native CLI/help/status version was corrected
from 0.1.0 to match the existing Cargo and bundle version.

## Current names

| Component | Name |
| --- | --- |
| Source directory | `rheo/` |
| macOS bundle | `Rheo.app` |
| Executable / command | `rheo` |
| Safe core crate | `rheo-core` (`rheo_core` in Rust) |
| Foreign interface crate | `rheo-ffi` (`rheo_ffi` in Rust) |
| Static library | `librheo_ffi.a` |
| Public C header | `src/core/rheo_core.h` |
| Bundle identifier / preferences domain | `dev.rheo.app` |
| Resident IPC name | `dev.rheo.control.<effective-user-id>` |
| Monitor queue | `dev.rheo.monitor` |
| Synthetic-event marker | `RHEOEVT1` / `0x5248454f45565431` |
| Hotkey signature | `RHEO` / `0x5248454f` |

The menu, tooltips, accessibility description, logs, thread name, Objective-C
classes, Cargo imports/dependencies/lockfile, build/install/launch scripts,
CMake targets, CI app paths and current documentation use the new names.

The low-level `sn_*` C symbols, structs and `SN_*` constants intentionally retain
their established spelling. They are an internal compatibility interface, not
product branding. Keeping them avoids an unnecessary ABI break and lets the
unchanged C oracle remain usable. The event-marker value changes consistently
in the current Rust implementation and C header; the frozen historical C header
remains untouched. The private gesture protocol and switching logic are unchanged.

## First launch after renaming

Quit Strafe Next and any other Space-swipe interceptor first. The renamed launch
script sends shutdown requests to Rheo only; it cannot stop the previous app via
its different IPC name. Existing Strafe Next settings are not automatically
imported: Rheo uses a separate preferences domain. Complete Accessibility setup
for the Rheo bundle before physical testing.

```sh
cd rheo
./scripts/check.sh
./script/build_and_run.sh --verify
./dist/Rheo.app/Contents/MacOS/rheo status
```

The scripts do not install `rheo` on your shell's PATH. The full executable path
above works after the native build. `--verify` checks resident IPC, not physical
Space switching. No binary, notarization or native build result is supplied.
These identifiers do not imply a registered domain, reserved crate name or
trademark clearance.

## Attribution and historical evidence

Original licenses, upstream credits and the prior contributor copyright remain.
The previous C implementation, original Swift fixture/reproducer, historical audit
and original validation logs were preserved byte-for-byte. The current LICENSE
adds Rheo contributors without removing its existing copyright. References to
Strafe in those records describe the actual source material, not missed renames.

## Executed checks

See `results/rename-checks.txt`:

- Cargo TOML and lockfile consistency; Rust import and library-name checks.
- Bundle/executable, CLI version, IPC/preferences and C/Rust marker consistency.
- No stale product identifiers in current production/build files; local includes resolve.
- Shell syntax/executable permissions, Python parsing, C driver syntax and C/C++ header checks.
- 31 historical/reference/upstream/result files verified unchanged.
- Frozen C-reference suite: all 33 groups passed under Clang ASan/UBSan.
- C-versus-C differential harness self-check passed (1,000,000 gesture inputs,
  200,000 prediction steps, 100,000 payload cases, 22 batch cases).

**Neither Rust nor the macOS app was compiled or executed here.** This Linux
host has no Rust toolchain or macOS SDK/runtime. The C-only results do not prove
Rust correctness, cross-language equivalence, native gesture behavior or speed.
The native validation obligations in `VALIDATION.md` and `NATIVE-HANDOFF.md` remain.
