# Security, permissions and failure boundaries

This is an unverified native development implementation, not a security-audited release.

The application requires the user's macOS Accessibility grant to inspect Dock overlay identifiers and filter/post gestures. It does not disable SIP, inject into the Dock, install a privileged helper, or modify system files. The active tap's mask includes gesture/dock-control types 29 and 30, not ordinary keyboard events. Optional shortcuts use explicit Carbon hotkey registration. No keyboard text, screenshots, window contents, passwords or account credentials are stored.

The background monitor reads display geometry, private managed-Space IDs and up to 32 Dock root Accessibility child identifiers. It checks `mc` and `appexpose`, not Dock application names or window text. At most 32 uncommitted gesture events are temporarily held in memory for fail-native replay. Buffers are released on commit, cancellation or recovery. Status exposes aggregate counts and timing, not raw gesture streams.

There is no networking, remote telemetry, updater, remote configuration, downloaded executable, shell evaluation or dynamic plugin loading. `dlsym` resolves two Apple CGS symbols from the current process; it does not load a user-selected library. Settings are local `NSUserDefaults` values under `dev.strafenext.app`.

Local CFMessagePort IPC accepts only fixed commands, limits requests to 64 bytes, and bounds accepted replies to 64 KiB. The endpoint name includes the effective UID to separate ordinary user names. **This is a local same-session convenience endpoint, not an authenticated security boundary.** Another process able to access that bootstrap namespace could issue commands or impersonate the endpoint. It has no file-reading, arbitrary-code or network commands. Do not extend this to remotely exposed control without a proper authorization design.

C does not provide memory safety by construction. The portable core uses fixed-size buffers, checked capacities and byte-wise encoding instead of unaligned packed-struct writes. Clang/GCC ASan+UBSan runs, a bounded fuzz campaign and static analysis passed. They are useful checks, not a proof of memory safety, and do not validate unexecuted native code.

Unknown/stale/contended topology or overlay information declines acceleration and preserves or replays native input when possible. Already committed gestures cannot be undone. Lost callbacks, tap timeouts, permission revocation, crash/quit mid-gesture and undocumented Dock behavior are not perfectly recoverable. No claim is made that every OS or hardware failure can be masked.

All synthetic events are prepared before posting, but CoreGraphics gives no acknowledgement that every event reached or was accepted by the Dock. The macOS 27 real-terminal neutralization workaround still needs physical-device validation. Unknown OS major versions are not enabled optimistically. Never run this alongside another interceptor during validation.

The app build defaults to local ad-hoc signing. It is not Developer-ID notarized. Use the native validation checklist before daily use or redistribution. To stop testing, quit the app, remove its Accessibility grant, and remove its app bundle; nothing else is installed automatically.
