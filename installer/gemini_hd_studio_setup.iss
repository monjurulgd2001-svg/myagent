; ============================================================
;  Gemini HD Studio - Windows Setup (Inno Setup 6)
;  GitHub Actions-e Flutter Windows build er por ei script diye
;  purno installer (Setup.exe) toiri hoy.
;  Version bodlate chaile AppVersion line ta pubspec.yaml er
;  version er sathe miliye bodlao.
; ============================================================

#define AppName "Zedge Studio"
#define AppVersion "1.0.0"
#define AppPublisher "Zedge Studio"
#define AppExeName "GeminiHDStudio.exe"

[Setup]
AppId={{8F3A2C41-6D1E-4B9A-A5C7-2E4F6B8D0A31}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=GeminiHDStudio-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Zedge Studio"; Flags: nowait postinstall skipifsilent
