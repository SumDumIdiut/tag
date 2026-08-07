; Inno Setup script for Tag -- produces TagSetup.exe, a proper installer
; (Start Menu/Desktop shortcuts, Add/Remove Programs entry, uninstaller)
; instead of the previous "download a bare Tag.exe and swap it in via a
; hand-rolled .bat file" approach (see update_prompt.gd's own history).
;
; Installs per-user, no admin/UAC required (PrivilegesRequired=lowest) --
; deliberate: the game self-updates from inside a running, unelevated
; process (see UpdateChecker/UpdatePrompt), so an install location that
; ever needed elevation would mean a UAC prompt on every single update,
; not just the first install. {localappdata}\Programs\Tag matches how
; other self-updating desktop apps (Discord, VS Code, etc.) do this on
; Windows for the same reason.
;
; AppId is a fixed, never-changing GUID -- Inno Setup uses it to recognize
; "this is an update to the same app" (upgrade the existing Add/Remove
; Programs entry and install directory) rather than creating a second,
; duplicate one every time TagSetup.exe runs again with a newer version.
; Do not regenerate this for future builds.
;
; Built via: "C:\Users\<you>\AppData\Local\Programs\Inno Setup 6\ISCC.exe" installer\tag.iss
; (or on CI -- windows-latest runners ship Inno Setup 6 preinstalled, see
; .github/workflows/build.yml). Pass /DMyAppVersion=<BuildVersion.VERSION>
; to stamp the real version into Add/Remove Programs; defaults to 0.0.0
; (dev build) if omitted.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{1CE7539A-D7C5-4361-A9E8-6035F42B0402}
AppName=Tag
AppVersion={#MyAppVersion}
AppPublisher=SumDumIdiut
DefaultDirName={localappdata}\Programs\Tag
DefaultGroupName=Tag
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\builds
OutputBaseFilename=TagSetup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\game\icon.ico
UninstallDisplayIcon={app}\Tag.exe
; Lets a silent update (see UpdatePrompt._on_download_completed, which
; passes /CLOSEAPPLICATIONS) close the currently-running Tag.exe so its exe
; file can actually be overwritten, instead of the old wait-for-exit-then-
; move .bat script. Confirmed live: Inno's own RestartApplications/
; /RESTARTAPPLICATIONS pair, despite closing the app correctly, does NOT
; reliably relaunch it afterward for a plain exe that never called
; RegisterApplicationRestart() (which Tag.exe doesn't) -- the [Run] entry
; below handles the actual relaunch instead, unconditionally, so this is
; deliberately just CloseApplications, not RestartApplications too.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\builds\Tag.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\builds\addons\webrtc_native\lib\*"; DestDir: "{app}\addons\webrtc_native\lib"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Tag"; Filename: "{app}\Tag.exe"
Name: "{group}\Uninstall Tag"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Tag"; Filename: "{app}\Tag.exe"; Tasks: desktopicon

[Run]
; No skipifsilent -- a silent auto-update run (see UpdatePrompt) needs this
; to actually relaunch Tag.exe just as much as an interactive install does
; (confirmed live: RestartApplications alone does not reliably do it, see
; this file's own [Setup] comment). postinstall still gives an interactive
; install its normal "Launch Tag" finish-page checkbox, checked by default.
Filename: "{app}\Tag.exe"; Description: "Launch Tag"; Flags: nowait postinstall
