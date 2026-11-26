# -*- mode: python ; coding: utf-8 -*-
# SpotVault 2.0 engine: the PC downloader without a window (src/engine.py).
# Build: pyinstaller SpotVaultEngine.spec  ->  dist/engine/SpotVaultEngine.exe
from PyInstaller.utils.hooks import collect_all

import os

# FFmpeg ships inside the exe so a fresh PC needs no setup or download.
# Get it once with:
#   curl -L -o assets/ffmpeg.exe https://github.com/eugeneware/ffmpeg-static/releases/download/b4.4/win32-x64
if not os.path.isfile('assets/ffmpeg.exe'):
    raise SystemExit('assets/ffmpeg.exe is missing. Download it first (see the comment in SpotVault_V1.spec).')

datas = []
binaries = [('assets/ffmpeg.exe', '.')]
hiddenimports = ['phone_sync', 'sources', 'updater', 'loudness', 'dedupe', 'mutagen', 'ytmusicapi']
tmp_ret = collect_all('spotdl')
datas += tmp_ret[0]; binaries += tmp_ret[1]; hiddenimports += tmp_ret[2]
tmp_ret = collect_all('PIL')
datas += tmp_ret[0]; binaries += tmp_ret[1]; hiddenimports += tmp_ret[2]
tmp_ret = collect_all('requests')
datas += tmp_ret[0]; binaries += tmp_ret[1]; hiddenimports += tmp_ret[2]
# spotdl dependencies read data files at runtime; without them the
# download thread crashes in the frozen exe.
# pykakasi: dictionaries, ytmusicapi: locales, yt_dlp: YouTube JS solver, validators: TLD list.
for pkg in ('pykakasi', 'ytmusicapi', 'yt_dlp', 'validators'):
    tmp_ret = collect_all(pkg)
    datas += tmp_ret[0]; binaries += tmp_ret[1]; hiddenimports += tmp_ret[2]


a = Analysis(
    ['src/engine.py'],
    pathex=['src'],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['customtkinter', 'tkinter'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

# One folder (not one file): starts in a second instead of unpacking each time.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SpotVaultEngine',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    icon=['assets/app_icon_v2.ico'],
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name='engine')
