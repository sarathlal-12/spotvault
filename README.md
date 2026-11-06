======================================================================
                          SPOTVAULT (v1.0)
             Offline Spotify Playlist Sync & Downloader
======================================================================

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
3. TROUBLESHOOTING
----------------------------------------------------------------------
* Q: A track shows "Provider match failed"?
  A: SpotVault matches tracks against audio streaming providers. Very 
     rare remixes, regional exclusives, or unreleased tracks may not 
     have a matching stream available.

* Q: Missing folder prompt appears constantly?
  A: Make sure the master folder path at the top exists and that your 
     storage drive is connected and writable.
======================================================================