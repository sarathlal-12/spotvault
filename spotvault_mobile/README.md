# SpotVault Mobile (Android)

Companion app for the SpotVault Windows app. It copies your playlists from the
PC over Wi-Fi and plays them offline.

## Features

- Finds the SpotVault PC on your Wi-Fi, or connects by IP address + PIN
- Mirrors every playlist folder with songs, cover art and order
- Incremental sync: only new or changed songs are copied; interrupted copies resume
- Optional: remove songs from the phone that were deleted on the PC
- Music player: shuffle, repeat, queue editing, sleep timer, playback speed
- Liked Songs, Recently Played, Most Played, search
- Lock-screen and notification controls, pauses when headphones disconnect

## Build

```bash
flutter pub get
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Code map

| File | Purpose |
| --- | --- |
| `lib/sync_service.dart` | Discovery, PIN auth, downloads with resume |
| `lib/library_store.dart` | Songs, playlists, likes, history (`library.json`) |
| `lib/player_service.dart` | Playback queue, shuffle/repeat, sleep timer |
| `lib/ui/` | Screens: library, playlist, now playing, search, sync |

The PC side lives in `../src/phone_sync.py`.

## Tests

```bash
flutter test
```

`test/sync_e2e_test.dart` runs a full sync against a live PC server when
`SPOTVAULT_TEST_HOST`, `SPOTVAULT_TEST_PIN` and `SPOTVAULT_TEST_DIR` are set.
