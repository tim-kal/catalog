# DC-010 — Release-Pipeline: Notarisierung, periodischer Update-Check, Build-Automation

## Goal
Harden the update pipeline so that new releases can be built, signed, notarized, and distributed to users who get automatic update notifications — without Gatekeeper blocking the downloaded app.

## Acceptance Criteria

### Code signing & notarization
- [ ] `scripts/build-release.sh` that:
  1. Builds the app in Release configuration via `xcodebuild`
  2. Signs with Developer ID Application certificate (reads identity from env var `DEVELOPER_ID_APPLICATION`)
  3. Embeds the Python runtime in the app bundle (existing `scripts/` should have this — verify and integrate)
  4. Creates a ZIP for distribution
  5. Submits to Apple notarization via `xcrun notarytool submit --wait`
  6. Staples the notarization ticket via `xcrun stapler staple`
  7. Re-creates the ZIP after stapling
  8. Outputs the final ZIP path and SHA256 hash
- [ ] Script fails early with clear error if `DEVELOPER_ID_APPLICATION` is not set or keychain doesn't have the cert
- [ ] Script accepts `--version` and `--build` arguments to set in Info.plist before building

### Update manifest automation
- [ ] `scripts/publish-release.sh` that:
  1. Takes the ZIP from build-release.sh
  2. Creates a GitHub Release via `gh release create` with the ZIP attached
  3. Updates `updates/latest.json` with new version, build number, download URL, and release notes
  4. Commits and pushes `updates/latest.json`
- [ ] Release notes can be passed as argument or read from a file (e.g. `updates/notes.md`)

### Periodic update check in app
- [ ] `UpdateService.swift`: add periodic background check every 4 hours while app is running (not just on launch)
- [ ] Use a Timer that fires on the main run loop — no background threads needed
- [ ] If update found during periodic check: show a non-intrusive banner/badge in the sidebar (not a modal)
- [ ] The existing "Check for Updates..." menu item triggers an immediate check

### GitHub Action (optional but recommended)
- [ ] `.github/workflows/release.yml` that runs on tag push (`v*`):
  1. Builds on macOS runner
  2. Signs and notarizes (secrets: `DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD`)
  3. Creates GitHub Release with ZIP
  4. Updates `updates/latest.json` on main branch
- [ ] Manual trigger option (`workflow_dispatch`) for testing

## Relevant Files
- `DriveCatalog/Services/UpdateService.swift` — existing update check and self-replacement logic
- `updates/latest.json` — update manifest (currently points to v1.2.0 build 1)
- `project.yml` — XcodeGen project definition
- `DriveCatalog/DriveCatalogApp.swift` — app entry point where update check is triggered
- `DriveCatalog/Navigation/Sidebar.swift` — for update badge placement
- `scripts/` — build scripts directory

## Context
The app already has a working self-update mechanism: check manifest JSON on GitHub → download ZIP → replace .app → relaunch. But the pipeline from "code is ready" to "user has the update" is fully manual and lacks notarization.

Without notarization, macOS Gatekeeper blocks the downloaded app. The current workaround (`xattr -cr` in the replacer script) removes quarantine but this is fragile and won't work if the user has strict security settings.

The developer wants to send updates to beta testers (starting with one friend) and have them receive updates automatically. The current on-launch-only check means users who leave the app open for days won't see updates.

**Important**: The Developer ID certificate requires an Apple Developer Program membership ($99/year). The scripts should detect its absence and give a clear error rather than failing cryptically. For local development without a cert, the build script should have a `--skip-sign` flag that produces an unsigned build (useful for testing the pipeline).

**Scope note**: This task does NOT change the self-replacement mechanism (that already works). It focuses on: building a signed+notarized ZIP, automating the manifest update, and checking for updates periodically.
