<!-- Write what changed in this release here, then publish. -->

## Install
1. Download **DozzleDesk-{{VERSION}}.zip** below, unzip it, and move `DozzleDesk.app` to Applications.
2. **The app isn't notarized** (it's ad-hoc signed), so macOS blocks the first launch. Try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. Or run this in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/DozzleDesk.app
   ```
3. Enter your Dozzle address, e.g. `http://192.168.1.20:8080`.

**Requirements:** macOS 14 or later, Apple silicon or Intel (universal binary). Your Dozzle server must not require login (`DOZZLE_AUTH_PROVIDER=none`).

## Verify the download
This zip was built by GitHub Actions from the tagged commit, not on anyone's laptop. To check:
```bash
shasum -a 256 -c DozzleDesk-{{VERSION}}.zip.sha256
gh attestation verify DozzleDesk-{{VERSION}}.zip --repo {{REPO}}
```
SHA-256: `{{SHA256}}`
