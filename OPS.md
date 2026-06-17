# TranscribeMachine — Ops Runbook

Everything needed to build, ship, and update TranscribeMachine. No private credentials here.

---

## Repo & source locations

| Thing | Path |
|---|---|
| Xcode project | `~/Documents/TranscribeMachine_src/` |
| Build/ship script | `~/Documents/TranscribeMachine_src/ship.sh` |
| App Store entitlements | `~/Documents/transcribemachine/entitlements_mas.plist` |
| Direct-download working files | `~/Documents/transcribemachine/` |
| 1hSaved website source | `~/Documents/1hSaved/` |
| TranscribeMachine page HTML | `~/Documents/1hSaved/worker-embedded.js` (search `PAGES['transcribemachine.html']`) |

GitHub repos:
- App source: `https://github.com/dssdave/transcribemachine`
- Website: `https://github.com/dssdave/1hsaved`

---

## Apple Developer credentials

- **Apple ID:** support@getcashflow.co
- **Team:** Cash Flow Crescendo Inc.
- **Team ID:** D7LK7963NP
- **App-specific password:** stored in `~/Documents/transcribemachine/upload_tm2.py` (do not commit)
- **Bundle ID:** com.dssdave.TranscribeMachine

Signing certificates (in Keychain):
- `Developer ID Application: Cash Flow Crescendo Inc. (D7LK7963NP)` — for direct download
- `3rd Party Mac Developer Application: Cash Flow Crescendo Inc. (D7LK7963NP)` — for App Store

---

## Build & ship the direct-download DMG

### One-time setup
`ship.sh` uses `ExportOptions.plist` (developer-id method, manual signing, Team D7LK7963NP).

### Build steps

**1. Pull latest code**
```bash
cd ~/Documents/TranscribeMachine_src && git pull
```

**2. Clear old build artifacts** (prevents stale version from being shipped)
```bash
rm -rf /tmp/TranscribeMachine.xcarchive /tmp/TranscribeMachine-export
```
Run via: `do shell script "rm -rf /tmp/TranscribeMachine.xcarchive /tmp/TranscribeMachine-export"`

**3. Run ship.sh via Python wrapper** (osascript cannot run bash scripts directly)
```
Script: ~/Documents/transcribemachine/run_ship.py
```
Run via osascript: `do shell script "python3 ~/Documents/transcribemachine/run_ship.py 2>&1"`

Output app: `/tmp/TranscribeMachine-export/TranscribeMachine.app`

**3. Notarize, staple, create DMG**
```
Script: ~/Documents/transcribemachine/notarize_dmg.py
Output: /tmp/TranscribeMachine.dmg
```
Run in background (takes ~2 min):
`do shell script "nohup python3 ~/Documents/transcribemachine/notarize_dmg.py > /tmp/notarize_dmg_log.txt 2>&1 &"`

Watch progress: `do shell script "cat /tmp/notarize_dmg_log.txt"`

Ends with `ALL_DONE` when complete.

**4. Upload DMG to Cloudflare R2**

DMG is served from R2 bucket `transcribemachine-releases`, key `TranscribeMachine.dmg`.
The worker redirects `/transcribemachine.dmg` → R2 public URL.

```
Script: ~/Documents/transcribemachine/upload_r2_api.py
```
Run: `do shell script "python3 ~/Documents/transcribemachine/upload_r2_api.py 2>&1"`

Expects output: `UPLOAD_SUCCESS`

The script reads the OAuth token dynamically from `~/.wrangler/config/default.toml` so it stays fresh. If it fails with 401/503, the token has expired — re-auth by running any wrangler deploy (which triggers a refresh), then retry.

---

## Update the website (1hsaved.com/transcribemachine)

### Architecture
- Site lives at: `https://1hsaved.com`
- Served by: Cloudflare Worker named `inboxfilter`
- Single-file source: `~/Documents/1hSaved/worker-embedded.js`
- The entire TranscribeMachine page HTML is a JS string inside that file

### To edit any text on the page

1. Open `~/Documents/1hSaved/worker-embedded.js`
2. Search for `PAGES['transcribemachine.html']` — the full HTML is on that line
3. Edit the text
4. Deploy (this command works, do not use any other wrangler subcommand):
```bash
cd ~/Documents/1hSaved && npx wrangler deploy worker-embedded.js --name inboxfilter
```
5. Commit:
```bash
cd ~/Documents/1hSaved && git add worker-embedded.js && git commit -m 'your message' && git push
```
6. Verify: `do shell script "curl -s https://1hsaved.com/transcribemachine | grep 'your text'"`

### Download button
Current HTML: `<a href="/transcribemachine.dmg" class="btn btn-primary btn-lg" download>Download for Mac</a>`

**Do NOT include file size in the button text** — it changes every build.

### Critical: what NOT to do
- Do NOT use `wrangler r2 object put` — crashes with `/.wrangler/cache` bug when run from osascript
- Do NOT use `wrangler pages deploy` — same bug
- Do NOT try to SSH/SCP from osascript — network is blocked
- Only `npx wrangler deploy` (worker deploy) works from osascript

---

## Submit to Mac App Store

### Build App Store .pkg

Archive first with Xcode or xcodebuild. Then manually codesign if exportArchive fails:
```
Script: ~/Documents/transcribemachine/resign_and_build.sh
```

Key steps in that script:
1. `xattr -cr "$APP"` — strip quarantine attributes (REQUIRED before codesign or ITMS-91109 error)
2. Copy provisioning profile to `$APP/Contents/embedded.provisionprofile`
3. `codesign --force --deep --sign "$CERT" --entitlements "$ENTITLEMENTS" "$APP"`
4. `productbuild --component "$APP" /Applications --sign "$INSTALLER_CERT" output.pkg`

Entitlements file: `~/Documents/transcribemachine/entitlements_mas.plist`

**Do NOT add `application-identifier` to the entitlements plist** — macOS rejects it with error 90285. That key is iOS-only.

### Upload to App Store Connect
```
Script: ~/Documents/transcribemachine/upload_tm2.py
```
Run: `do shell script "python3 ~/Documents/transcribemachine/upload_tm2.py 2>&1"`

**Known upload errors:**
- **90285** — `application-identifier` in plist. Remove it.
- **ITMS-91109** — quarantine on `embedded.provisionprofile`. Run `xattr -cr` on the whole app first.
- **ITMS-90886** — "missing application identifier" warning. Safe to ignore, does not block submission.
- **409 conflict** — multiple simultaneous uploads. Only upload once.

### Before you can submit in App Store Connect
These must be completed or the "Add for Review" button stays greyed out:
- **Age Ratings** — complete the 7-step questionnaire (all NONE/NO → 4+ rating)
- **Content Rights** — select "no third-party content"
- **App Encryption** — select "None of the algorithms listed above"

---

## Known code bugs

### WhisperKit.listLocalModels() does not exist
This static method is not in the WhisperKit API. If it appears in `TranscriptionEngine.swift`, replace with:
```swift
let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
let local = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
```
Fix script: `~/Documents/transcribemachine/fix_engine.py`

---

## Cloudflare account info (no secrets)

- **Account ID:** 03bfc6c58426697fcfd7fccc96ebd381
- **R2 bucket:** `transcribemachine-releases`
- **R2 object key:** `TranscribeMachine.dmg`
- **Worker name:** `inboxfilter`
- **Zone:** `1hsaved.com`
- **OAuth token location:** `~/.wrangler/config/default.toml` (expires ~24h, not committed to git)
