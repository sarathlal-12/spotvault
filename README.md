
                          SPOTVAULT (v1.4.1)
               Offline Playlist Sync, Search & Downloader


SpotVault keeps your local music collection in step with your online
playlists (Spotify, YouTube, YouTube Music and SoundCloud links). It
downloads high-quality audio, embeds full metadata and album artwork,
and skips songs you already have. Search for any single song and save
it into a playlist. The phone app (Android & iPhone) copies your
playlists from the PC over Wi-Fi, plays them offline, and can add new
songs by search through the PC.

Website:  https://spotvault-web.vercel.app
Releases: https://github.com/sarathlal-12/spotvault/releases

----------------------------------------------------------------------
DOWNLOADS (v1.4.1)
----------------------------------------------------------------------
  Platform   File                            Install
  ---------  ------------------------------  ------------------
  Windows    SpotVault_Setup_v1.4.1.exe        Run the installer
  Android    SpotVault_v1.4.1.apk            Open on the phone
  iPhone     SpotVault_v1.4.1_unsigned.ipa   Sideload (see 4)

All files are attached to the v1.4.1 release on GitHub. Older
versions stay available on the Releases page.

----------------------------------------------------------------------
1. FIRST-TIME LAUNCH & REQUIREMENTS
----------------------------------------------------------------------
* INTERNET CONNECTION:
  Required when adding playlists or syncing new tracks.

* PLAYLIST PRIVACY SETTING:
  The playlist MUST be public or shared by link (Unlisted). Private
  playlists cannot be read.
  -> Use the playlist's "Share" -> "Copy link" option.

* NOTHING ELSE TO INSTALL:
  The audio converter (FFmpeg) is built into SpotVault, so the first
  sync works straight away on a new PC.

----------------------------------------------------------------------
2. HOW TO USE
----------------------------------------------------------------------
* SELECT STORAGE LOCATION:
  By default, music downloads to your Windows "Music" directory. 
  Click "Change" under MUSIC FOLDER in the sidebar to save tracks to
  an external drive or another folder.

* ADD A PLAYLIST:
  1. Click "+ Add Playlist".
  2. Paste the playlist link (Spotify, YouTube, YouTube Music or
     SoundCloud).
  3. Enter a folder name (e.g., "Gym Beats" or "Favorites").
  4. Click "Add to Library". The playlist and its cover art will 
     appear on your dashboard and remain saved.

* SYNCING SONGS:
  - To sync one playlist: Click the "Sync" button on its card.
  - To sync everything: Click "Sync all" at the top.

* CLEAN SONGS, NO DIALOGUE:
  Every song is looked up as the clean studio version: YouTube Music
  first, then SoundCloud, then YouTube lyric videos (video songs, movie
  scenes, trailers, loops and remixes are skipped). YouTube playlists of
  video songs are saved as the clean songs too.

* SEARCH SONGS:
  Click "Search songs", type a song or artist and press Search. Tick
  the songs you want, choose a playlist under "Save to", and click
  "Download selected". Progress shows in the Activity panel.

* SMART INCREMENTAL UPDATES:
  When you add new songs to your playlist weeks or months later, 
  simply click "Sync" again. SpotVault will instantly skip songs you 
  already have on disk and download only the new additions.

* FOLDER INTEGRITY RECOVERY:
  If you ever rename, move, or accidentally delete a playlist folder 
  from your hard drive, SpotVault will detect it and prompt you to 
  recreate or reassign the folder before downloading.

----------------------------------------------------------------------
3. PHONE SYNC (ANDROID & IPHONE)
----------------------------------------------------------------------
* Install the phone app: the APK on Android, or the IPA on iPhone
  (see section 4).
* Put the PC and the phone on the same Wi-Fi network.
* On the PC, click "Connect phone" in the sidebar. It shows this PC's
  address (e.g. 192.168.0.113:50505) and a 6-digit PIN.
* On the phone, open the Sync tab. Tap "Scan" to find the PC, or type
  the address. Enter the PIN and tap "Sync now".
  On iPhone, Scan cannot find the PC (Apple blocks Wi-Fi discovery for
  sideloaded apps): type the address instead.
* Every playlist folder is copied with its songs, cover art and order.
  Later syncs copy only new or changed songs. Songs deleted on the PC
  are removed from the phone (switch this off in the Sync tab).
* An interrupted sync resumes where it stopped.
* ADD SONGS FROM THE PHONE: open Search -> "Find new songs", type a
  song, tap it to listen, then tap the download button and pick a
  playlist. The PC downloads it and sends it back with cover art.
  Keep SpotVault open on the PC and both devices on the same Wi-Fi.
* The first time, Windows Firewall asks about network access. Allow
  SpotVault on "Private networks", or the phone cannot connect.

The phone app is a full offline music player: playlists, Liked Songs,
Recently/Most Played, search, shuffle, repeat, queue editing, sleep
timer, playback speed, and lock-screen / notification controls.

----------------------------------------------------------------------
4. INSTALL ON IPHONE (SIDELOAD WITH ALTSTORE)
----------------------------------------------------------------------
SpotVault is not on the App Store. Install the IPA with your own
Apple ID using AltStore (free; apps renew every 7 days).

  1. Install iTunes and iCloud using the direct (NOT Microsoft Store)
     installers linked in the AltStore guide: https://faq.altstore.io
  2. Install AltServer from https://altstore.io and run it (tray icon).
  3. Plug in the iPhone and tap "Trust". Click the AltServer tray icon
     -> Install AltStore -> your iPhone, and sign in with your Apple ID.
  4. On the iPhone: Settings -> General -> VPN & Device Management ->
     your Apple ID -> Trust. On iOS 16+, also turn on Settings ->
     Privacy & Security -> Developer Mode.
  5. Download SpotVault_v1.4.1_unsigned.ipa on the iPhone in Safari.
     In the Files app, tap it -> Share -> AltStore.
  6. Open SpotVault -> Sync tab, type the PC address and PIN, and allow
     Local Network access.

* Keep AltServer running and turn on "Sync with this iPhone over Wi-Fi"
  in iTunes once: AltStore then renews SpotVault automatically.
* Alternative: Sideloadly (https://sideloadly.io). Drag the IPA in and
  sign in; reinstall every 7 days.
* Synced songs also appear in the iPhone Files app under SpotVault.

----------------------------------------------------------------------
5. UPDATES
----------------------------------------------------------------------
SpotVault checks for a new version when it starts. Click "Check for
updates" (bottom of the sidebar on Windows, Sync tab on the phone) to
check yourself. "Update now" downloads and installs it; your playlists,
settings and music are kept.

----------------------------------------------------------------------
6. TROUBLESHOOTING
----------------------------------------------------------------------
* Q: A track shows "Provider match failed"?
  A: SpotVault matches tracks against audio streaming providers. Very 
     rare remixes, regional exclusives, or unreleased tracks may not 
     have a matching stream available.

* Q: Missing folder prompt appears constantly?
  A: Make sure the master folder path at the top exists and that your 
     storage drive is connected and writable.

* Q: The phone says "Can't reach" the PC?
  A: Check both are on the same Wi-Fi (not a guest network), SpotVault
     is open on the PC, and Windows Firewall allows SpotVault on
     Private networks. Public/hotel Wi-Fi often blocks devices from
     seeing each other.
======================================================================
