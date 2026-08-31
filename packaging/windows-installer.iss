; Inno Setup script for Multi. Built by CI as:
;   iscc /DMultiVersion=0.2.0 /DMultiArch=x64   /DSourceDir=... windows-installer.iss
;   iscc /DMultiVersion=0.2.0 /DMultiArch=arm64 /DSourceDir=... windows-installer.iss
;
; SourceDir is the Flutter release runner directory, e.g.
;   build\windows\x64\runner\Release

#ifndef MultiVersion
  #define MultiVersion "0.0.0"
#endif
#ifndef MultiArch
  #define MultiArch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

#define MultiName "Multi"
#define MultiPublisher "Matt Vasquez"
#define MultiURL "https://github.com/jacketpng/Multi"
#define MultiExe "multi.exe"

[Setup]
; A stable AppId keeps upgrades replacing the previous install rather
; than piling up alongside it.
AppId={{7C9E6A2B-4D1F-4E52-9B3A-5F8D2C7E1A40}
AppName={#MultiName}
AppVersion={#MultiVersion}
AppPublisher={#MultiPublisher}
AppPublisherURL={#MultiURL}
AppSupportURL={#MultiURL}
DefaultDirName={autopf}\{#MultiName}
DefaultGroupName={#MultiName}
DisableProgramGroupPage=yes
OutputBaseFilename=multi-{#MultiVersion}-windows-{#MultiArch}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-user installs need no elevation; the installer asks.
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed={#MultiArch}compatible
ArchitecturesInstallIn64BitMode={#MultiArch}compatible
UninstallDisplayIcon={app}\{#MultiExe}
OutputDir=.
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter bundle: exe, DLLs, and the data directory.
Source: "{#SourceDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MultiName}"; Filename: "{app}\{#MultiExe}"
Name: "{autodesktop}\{#MultiName}"; Filename: "{app}\{#MultiExe}"; \
    Tasks: desktopicon

[Run]
Filename: "{app}\{#MultiExe}"; \
    Description: "{cm:LaunchProgram,{#StringChange(MultiName, '&', '&&')}}"; \
    Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Multi downloads yt-dlp, gallery-dl, aria2, FFmpeg and ImageMagick into
; the user's own data directory, not here, so only the app is removed.
Type: filesandordirs; Name: "{app}\data"
