# Release Rheo through Homebrew

Rheo ships as a Developer ID-signed, notarized universal ZIP on GitHub Releases.
The cask in [tristanmanchester/homebrew-tap](https://github.com/tristanmanchester/homebrew-tap/blob/main/Casks/rheo.rb)
installs the app and links its bundled CLI as `rheo`.

## Package

Use a Mac with both Rust Darwin targets, a Developer ID Application certificate,
and an authenticated `asc` CLI with access to Apple's notarization service.
Keep the Cargo workspace and app plist versions in sync before packaging.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/test.sh
SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAM_ID)" ./scripts/package.sh
```

Replace the signing identity with the exact identity shown by
`security find-identity -v -p codesigning`.
The package command builds both architectures, enables hardened runtime, signs
with a secure timestamp, submits to Apple, staples and validates the ticket,
checks Gatekeeper acceptance, and writes the ZIP and SHA-256 checksum to `dist/`.
It stops if the version's release archive already exists.

## Publish

1. Commit the release source and push it to `main`. Wait for its CI checks to pass.
2. Tag that commit as `vVERSION` and create a GitHub release with
   `dist/Rheo-VERSION-universal.zip` and `dist/Rheo-VERSION-SHA256SUMS.txt`.
3. Update the cask's `version` and `sha256` to match the final stapled ZIP, then
   publish the tap commit. Keep released asset URLs and contents immutable.
4. Verify the published download and install:

   ```sh
   brew update
   brew audit --cask --online tristanmanchester/tap/rheo
   brew install --cask tristanmanchester/tap/rheo
   open -a Rheo
   rheo status
   ```

For an existing Homebrew installation, use `brew upgrade --cask` instead of
`brew install --cask`. Quit and move any source-installed copy aside before
switching to Homebrew so that launch and permission settings identify one app.
