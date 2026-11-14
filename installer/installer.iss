; Script for SpotVault Installer (Inno Setup 6/7)
; Build the exe first:  python -m PyInstaller --noconfirm --clean SpotVault_V1.spec
; Then open this file in Inno Setup and press Compile (or run ISCC.exe on it).
#define MyAppName "SpotVault"
#define MyAppVersion "1.5.0"
#define MyAppPublisher "Sarath"
#define MyAppURL "https://github.com/sarathlal-12/spotvault"
#define MyAppExeName "SpotVault_V1.exe"

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
SetupIconFile=..\assets\app_icon.ico
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
Source: "..\dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

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
FinishedLabel=SpotVault is installed.%n%nTo sync music to your phone, click "Connect phone" in the app. If Windows Firewall asks, allow SpotVault on Private networks.
