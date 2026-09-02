; Inno Setup Script for Pear Music Windows Installer
#define MyAppName "Pear Music"
#define MyAppVersion "2.9.1"
#define MyAppPublisher "Boci0"
#define MyAppURL "https://github.com/Boci0/Pear-Music"
#define MyAppExeName "peerm_app.exe"

[Setup]
AppId={{D1A2B3C4-5678-90AB-CDEF-PEARMUSIC001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={userpf}\{#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=PearMusic-Setup-v{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=peerm_app.exe
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Get-NetFirewallRule | Where-Object {{ $_.DisplayName -like '*peerm*' -or $_.DisplayName -like '*Pear Music*' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Pear Music (TCP-In)' -Direction Inbound -Program '{app}\{#MyAppExeName}' -Protocol TCP -Action Allow -Profile Any -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Pear Music (UDP-In)' -Direction Inbound -Program '{app}\{#MyAppExeName}' -Protocol UDP -Action Allow -Profile Any -ErrorAction SilentlyContinue"""; Flags: runhidden
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Get-NetFirewallRule | Where-Object {{ $_.DisplayName -like '*peerm*' -or $_.DisplayName -like '*Pear Music*' } | Remove-NetFirewallRule -ErrorAction SilentlyContinue"""; Flags: runhidden
