# GitHub Actions Setup for Automated Build & Release

This document explains how to set up the required secrets and Apple Developer
credentials for automated macOS app building, code signing, and notarization.

## Prerequisites

You need:
- An [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year)
- A **Developer ID Application** certificate (for signing apps distributed outside the App Store)
- Access to the GitHub repository settings

## Required GitHub Secrets

Go to your repository **Settings > Secrets and variables > Actions** and add
these 6 secrets:

### 1. `DEVELOPER_ID_APPLICATION` — Signing certificate (base64)

The Developer ID Application certificate exported as a .p12 file, then
base64-encoded.

**How to create it:**

1. Open **Keychain Access** on your Mac
2. Find your "Developer ID Application" certificate (under "My Certificates")
   - If you don't have one, create it at
     [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
     → click **+** → choose **Developer ID Application**
3. Right-click the certificate → **Export** → save as `.p12` → set a password
4. Base64-encode and copy to clipboard:
   ```bash
   base64 -i DeveloperID_Application.p12 | pbcopy
   ```
5. Paste as the secret value

### 2. `DEVELOPER_ID_APPLICATION_PASSWORD` — Certificate password

The password you set when exporting the .p12 file in step 3 above.

### 3. `DEVELOPER_ID_NAME` — Signing identity name

The full name of your Developer ID certificate as used by `codesign`.

**How to find it:**
```bash
security find-identity -v -p codesigning
```

It looks like:
```
"Developer ID Application: Your Name (TEAM_ID)"
```

Copy the full quoted string (without the quotes) as the secret value.

### 4. `APPLE_ID` — Apple ID for notarization

Your Apple ID email address. This is the account that will submit builds to
Apple's notary service.

### 5. `APPLE_ID_PASSWORD` — App-specific password

An app-specific password for your Apple ID. This is **not** your regular Apple
ID password.

**How to create it:**

1. Go to [account.apple.com](https://account.apple.com)
2. Sign in → **Sign-In and Security** → **App-Specific Passwords**
3. Click **+** to generate a new password
4. Name it something like "GitHub Actions Fantastty"
5. Copy the generated password as the secret value

### 6. `APPLE_TEAM_ID` — Apple Developer Team ID

Your 10-character Apple Developer Team ID.

**How to find it:**
- Go to [developer.apple.com/account](https://developer.apple.com/account) → **Membership details**
- Or run:
  ```bash
  security find-identity -v -p codesigning | grep "Developer ID"
  ```
  The team ID is the string in parentheses at the end.

## How It Works

### Triggers

| Event | What happens |
|---|---|
| Push to `main` | Build, sign, notarize, upload artifact |
| Push tag `v*` | Build, sign, notarize, create GitHub Release with DMG |
| Manual dispatch | Build, sign, notarize, upload artifact (optional version override) |

### Build Steps

1. Check out code with Ghostty submodule
2. Install Zig and build GhosttyKit xcframework (cached between runs)
3. Import signing certificate into a temporary keychain
4. Build the app with `xcodebuild` using the Developer ID certificate
5. Create a DMG with Applications symlink
6. Sign and notarize the DMG with Apple
7. Upload the DMG as a build artifact
8. For tagged releases: create a GitHub Release with the DMG attached

### Releasing a New Version

```bash
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions will build, sign, notarize, and publish a release automatically.

### Manual Builds

1. Go to **Actions** tab in your GitHub repository
2. Select **Build and Release**
3. Click **Run workflow**
4. Optionally enter a version number
5. Click **Run workflow**

## Troubleshooting

### Common issues

- **"No identity found"** — Certificate not imported correctly. Verify
  `DEVELOPER_ID_APPLICATION` is valid base64 and the password is correct.
- **"User interaction is not allowed"** — Keychain partition list not set.
  This should be handled by the workflow, but check the signing step logs.
- **"Notarization failed"** — Check `APPLE_ID`, `APPLE_ID_PASSWORD`, and
  `APPLE_TEAM_ID`. The app-specific password may have expired.
- **xcframework build fails** — Zig version mismatch. Check
  `vendor/ghostty/build.zig.zon` for the required `minimum_zig_version` and
  update the workflow's Zig version accordingly.

### Debug commands

```bash
# List signing identities on your Mac
security find-identity -v -p codesigning

# Verify an app's signature
codesign --verify --deep --strict Fantastty.app
codesign -dvv Fantastty.app

# Check Gatekeeper status
spctl --assess --verbose Fantastty.app

# Check notarization history
xcrun notarytool history \
  --apple-id YOUR_APPLE_ID \
  --password YOUR_APP_PASSWORD \
  --team-id YOUR_TEAM_ID
```

## Security Notes

- Certificates are stored as encrypted GitHub secrets — never committed to the repo
- A temporary keychain is created per build and destroyed afterward
- App-specific passwords have limited scope (they can't access your full Apple account)
- Only `codesign` and `security` are granted keychain access
