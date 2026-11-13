# Updates and the admin panel

## How updating works

Every SpotVault app from v1.3 on checks GitHub when it starts (and when the user
taps **Check for updates**). It looks at the release marked **Latest**:

- **Windows**: shows "SpotVault X is available" with the notes. **Update now**
  downloads the installer and runs it. Playlists, settings and music are kept.
- **Android / iPhone**: shows the same prompt. **Update** opens the new APK / IPA
  download. The phone library is kept.
- **iPhone with AltStore**: users who add the SpotVault source
  (`https://spotvault-web.vercel.app/altstore.json`, button on the website's iPhone
  section) get an **Update** button inside AltStore and install with one tap. The
  source is built live from approved GitHub releases (`web/api/altstore.js`), so
  approving in the admin panel updates it too (within about 10 minutes).
- Users can press **Later**, or **Skip** (no more automatic prompts for that
  version; a manual check still shows it).

**Pre-releases are invisible to the apps.** That is the approval gate: you publish a
build as a pre-release, test it, then approve it in the admin panel.

## The admin panel

Open `admin/index.html` in your browser (double-click it). It is not part of the
website, so nobody else can reach it.

- Without a key it is read-only: you see which version users are being offered and
  the download counts.
- Paste your admin key to unlock the buttons:
  - **Approve & send to users**: a tested pre-release becomes Latest. Every app
    gets the prompt on its next start.
  - **Pull back**: the live version goes back to testing and the previous version
    is approved again. People who already installed it keep it.
  - **Edit what's new**: the text users see in the update prompt.
- `admin/index.html?demo` opens it with fake data to try the buttons safely. (Query
  strings only survive when the page is served, e.g. `python -m http.server`.)

### Your admin key (one time)

1. GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token
   (https://github.com/settings/personal-access-tokens/new).
2. Name: `SpotVault admin`. Repository access: **Only select repositories → spotvault**.
3. Permissions → Repository → **Contents: Read and write**. Nothing else.
4. Generate, copy, paste into the admin panel. Tick "Remember" to keep it on this PC
   only. **Lock** removes it.

## Releasing a new version

1. Bump the version: `APP_VERSION` in `src/app.py` and `src/phone_sync.py`,
   `MyAppVersion` in `installer/installer.iss`, `version:` in
   `spotvault_mobile/pubspec.yaml` and `kAppVersion` in
   `spotvault_mobile/lib/update_service.dart` (a test checks the last two match).
2. Build the Windows installer:
   ```bash
   python -m PyInstaller --noconfirm --clean SpotVault_V1.spec
   ```
   then compile `installer/installer.iss` in Inno Setup.
3. Create the release as a **pre-release** and attach the installer:
   ```bash
   gh release create v1.4.0 Output/SpotVault_Setup_v1.4.exe --prerelease --title "SpotVault v1.4.0" --notes "- What changed"
   ```
   Creating the tag starts the Android and iPhone builds, which attach the APK and IPA.
4. Install it yourself from the release page and test.
5. Admin panel → **Approve & send to users**.

## Android signing key (one time, before the first release from v1.3)

Android only installs an update when it is signed with the same key as the
installed app. v1.3 uses a permanent key:

- `spotvault_mobile/android/app/spotvault-release.jks` (the key)
- `spotvault_mobile/android/key.properties` (its password)

Both are git-ignored. **Back them up somewhere safe (USB drive, password manager).
If they are lost, no Android user can update again without uninstalling.**

GitHub builds the APK, so give it the key as two repository secrets (run from the
repo folder, signed in with `gh`):

```bash
base64 -w0 spotvault_mobile/android/app/spotvault-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo sarathlal-12/spotvault
```

```bash
grep storePassword spotvault_mobile/android/key.properties | cut -d= -f2 | tr -d '\r\n' | gh secret set ANDROID_KEYSTORE_PASSWORD --repo sarathlal-12/spotvault
```

Without these secrets the Android build stops with an error instead of shipping an
APK that can't update.

## Moving existing users to v1.3

v1.0 and v1.1 have no update check, so tell those users once (website, posts):

- **Windows**: download the v1.3 installer and run it. It installs over the old
  version and keeps everything.
- **iPhone**: install the v1.3 IPA over the old app with AltStore. Library kept.
- **Android**: uninstall v1.1 first, then install v1.3. The old APK was signed with
  a temporary key, so Android refuses to install over it. Songs on the phone are
  removed with the old app; sync again from the PC afterwards. From v1.3 on,
  updates install over the top.
