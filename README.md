
                          SPOTVAULT (v1.0)
             Offline Spotify Playlist Sync & Downloader


SpotVault keeps your local music collection synchronized with your 
Spotify playlists. It downloads high-quality audio files, embeds full 
metadata and album artwork, and skips existing tracks automatically.

----------------------------------------------------------------------
1. FIRST-TIME LAUNCH & REQUIREMENTS
----------------------------------------------------------------------
* INTERNET CONNECTION:
  Required when adding playlists or syncing new tracks.

* PLAYLIST PRIVACY SETTING:
  Your Spotify playlist MUST be set to "Public" or shared via link 
  (Unlisted). If a playlist is strictly set to "Private" inside 
  Spotify, the API cannot read the tracklist.
  -> In Spotify: Click the 3 dots (...) on the playlist -> "Make Public"
     or click "Share" -> "Copy link to playlist".

* FIRST-RUN CONVERSION SETUP:
  The very first time you sync a track, SpotVault will automatically 
  download portable audio conversion utilities (FFmpeg) into your local
  AppData cache. This takes 10 to 30 seconds on the first run; do not 
  force-close the app while it initializes.

----------------------------------------------------------------------
2. HOW TO USE
----------------------------------------------------------------------
* SELECT STORAGE LOCATION:
  By default, music downloads to your Windows "Music" directory. 
  Click "Change" in the top bar to save tracks to an external drive 
  or another folder.

* ADD A PLAYLIST:
  1. Click "+ Add Playlist".
  2. Paste the Spotify playlist link.
  3. Enter a folder name (e.g., "Gym Beats" or "Favorites").
  4. Click "Add to Library". The playlist and its cover art will 
     appear on your dashboard and remain saved.

* SYNCING SONGS:
  - To sync one playlist: Click the "Sync" button on its card.
  - To sync everything: Click "⚡ Sync All Playlists" at the top.

* SMART INCREMENTAL UPDATES:
  When you add new songs to your Spotify playlist weeks or months later, 
  simply click "Sync" again. SpotVault will instantly skip songs you 
  already have on disk and download only the new additions.

* FOLDER INTEGRITY RECOVERY:
  If you ever rename, move, or accidentally delete a playlist folder 
  from your hard drive, SpotVault will detect it and prompt you to 
  recreate or reassign the folder before downloading.

----------------------------------------------------------------------
3. PHONE SYNC (ANDROID COMPANION APP)
----------------------------------------------------------------------
* Install the SpotVault Android app (spotvault_mobile/) on your phone.
* Put the PC and the phone on the same Wi-Fi network.
* On the PC, click "📱 Phone Sync" in the top bar. It shows this PC's
  address (e.g. 192.168.0.113:50505) and a 6-digit PIN.
* On the phone, open the Sync tab. Tap "Scan" to find the PC, or type
  the address. Enter the PIN and tap "Sync now".
* Every playlist folder is copied with its songs, cover art and order.
  Later syncs copy only new or changed songs. Songs deleted on the PC
  are removed from the phone (switch this off in the Sync tab).
* An interrupted sync resumes where it stopped.
* The first time, Windows Firewall asks about network access. Allow
  SpotVault on "Private networks", or the phone cannot connect.

The phone app is a full offline music player: playlists, Liked Songs,
Recently/Most Played, search, shuffle, repeat, queue editing, sleep
timer, playback speed, and lock-screen / notification controls.

----------------------------------------------------------------------
4. TROUBLESHOOTING
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
