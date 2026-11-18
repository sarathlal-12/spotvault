; Script for SpotVault Installer (Inno Setup 6/7)
; Build first (2.0):
;   python -m PyInstaller --noconfirm --clean SpotVaultEngine.spec      -> dist\engine\
;   cd spotvault_mobile && flutter build windows --release              -> build\windows\x64\runner\Release\
; Then open this file in Inno Setup and press Compile (or run ISCC.exe on it).
#define MyAppName "SpotVault"
#define MyAppVersion "2.2.1"
#define MyAppPublisher "Sarath"
#define MyAppURL "https://github.com/sarathlal-12/spotvault"
#define MyAppExeName "SpotVault.exe"

[Setup]
; Same AppId as v1.0, so this installs over the old version as an upgrade.
AppId={{E68F1B3E-74B9-41B6-A925-B473412B621A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes
OutputDir=..\Output
OutputBaseFilename=SpotVault_Setup_v{#MyAppVersion}
SetupIconFile=..\assets\app_icon_v2.ico
UninstallDisplayIcon={app}\app_icon.ico
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user install (no admin prompt). {autopf} becomes %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Close a running SpotVault before upgrading, so the exe can be replaced.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The app (Flutter) and the hidden downloader engine (PyInstaller, one folder).
Source: "..\spotvault_mobile\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "library_config.json,*.log"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dist\engine\*"; DestDir: "{app}\engine"; Excludes: "library_config.json,*.log"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\assets\app_icon_v2.ico"; DestDir: "{app}"; DestName: "app_icon.ico"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

[InstallDelete]
; 1.x was one window app; 2.0 is SpotVault.exe plus engine\.
Type: files; Name: "{app}\SpotVault_V1.exe"

[Icons]
; WorkingDir matters: the app keeps library_config.json in its working folder.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app_icon.ico"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app_icon.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Settings created by the app at runtime. Downloaded music is never touched.
Type: files; Name: "{app}\library_config.json"

[Messages]
FinishedLabel=SpotVault is installed.%n%nTo sync music to your phone, open Settings > Phone link in the app. If Windows Firewall asks, allow SpotVault on Private networks.
