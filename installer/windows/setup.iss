; ──────────────────────────────────────────────────────────────────────────────
;  PlayTorrio — Windows Installer (Inno Setup 6)
;  Built by CI from: build\windows\x64\runner\Release\
; ──────────────────────────────────────────────────────────────────────────────

#define MyAppName      "PlayTorrio"
#define MyAppVersion   "1.0.0"
#define MyAppPublisher "PlayTorrio"
#define MyAppExeName   "PlayTorrio.exe"
#define MyAppURL       "https://github.com/ayman708-UX/PlayTorrioV2"

[Setup]
AppId={{B8F7E3A1-9C4D-4E5F-A2B1-6D8E9F0C1A3B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
OutputDir=Output
OutputBaseFilename=PlayTorrio-Windows-Setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=lowest
DisableProgramGroupPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Clean up old files that might conflict with new version
Type: filesandordirs; Name: "{app}\data\flutter_assets\*"
Type: files; Name: "{app}\*.dll.old"

[Icons]
Name: "{group}\{#MyAppName}";    Filename: "{app}\{#MyAppExeName}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
