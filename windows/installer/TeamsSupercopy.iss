; Per-user installer of Teams Supercopy, compiled by tools/installer.ps1 (Inno Setup 6) from the tested portable ZIP.
; No administrator rights: program in %LOCALAPPDATA%\Programs, uninstaller in HKCU. Command line, besides the standard
; Inno Setup switches:   /STARTUP=1|0   Avvia all'avvio di Windows

#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef AssetsDir
  #error AssetsDir is required
#endif
#ifndef IconFile
  #error IconFile is required
#endif

#define AppName "Teams Supercopy"
#define AppExe "TeamsSupercopy.exe"

[Setup]
AppId={{3b1f6c2e-7d4a-4e8b-9f51-2c6a8d0e4b17}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Everbright
AppPublisherURL=https://servizi.everbright.it/prodotti/
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} - installazione
DefaultDirName={autopf}\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputBaseFilename=TeamsSupercopy-Windows-x64-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
WizardImageFile={#AssetsDir}\wizard-100.bmp,{#AssetsDir}\wizard-200.bmp
WizardSmallImageFile={#AssetsDir}\wizard-small-100.bmp,{#AssetsDir}\wizard-small-200.bmp
Compression=lzma2/max
SolidCompression=yes
; a running copy closes through its own exit path in PrepareToInstall, never through Restart Manager
CloseApplications=no
RestartApplications=no
SetupMutex=TeamsSupercopySetup
ShowLanguageDialog=no

[Languages]
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
it.OptionsCaption=Avvio
it.OptionsDescription=Quando deve partire Teams Supercopy
it.OptionsIntro=La stessa opzione del menu dell'icona vicino all'orologio: si può cambiare in qualsiasi momento.
it.StartupLabel=Avvia all'avvio di Windows
it.StartupHint=Parte nel tray all'accesso a Windows, pronto per Ctrl+C in Teams.
it.StillOpen=Teams Supercopy è ancora aperto. Chiudilo dal menu dell'icona (Exit) e riprova.
it.SettingsFailed=Programma installato, ma l'opzione di avvio non è stata applicata. Si può impostare dal menu dell'icona.
it.LaunchApp=Avvia Teams Supercopy

[Files]
Source: "{#PayloadDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Ctrl+C in Teams copia i messaggi con autore, ora, citazioni e immagini"

[Run]
Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Description: "{cm:LaunchApp}"; Flags: postinstall nowait skipifsilent

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = 'TeamsSupercopy';

var
  OptionsPage: TWizardPage;
  StartupBox: TNewCheckBox;

function SwitchParam(Name: String; Default: Boolean): Boolean;
var
  Value: String;
begin
  Value := Lowercase(ExpandConstant('{param:' + Name + '|}'));
  if Value = '' then Result := Default
  else Result := (Value = '1') or (Value = 'si') or (Value = 'yes') or (Value = 'true') or (Value = 'on');
end;

function OnOff(Value: Boolean): String;
begin
  if Value then Result := 'on' else Result := 'off';
end;

procedure InitializeWizard;
var
  Intro, Hint: TNewStaticText;
  Startup: Boolean;
begin
  OptionsPage := CreateCustomPage(wpWelcome, CustomMessage('OptionsCaption'), CustomMessage('OptionsDescription'));
  Intro := TNewStaticText.Create(OptionsPage);
  Intro.Parent := OptionsPage.Surface;
  Intro.Caption := CustomMessage('OptionsIntro');
  Intro.AutoSize := False;
  Intro.WordWrap := True;
  Intro.Width := OptionsPage.SurfaceWidth;
  Intro.Height := ScaleY(32);
  StartupBox := TNewCheckBox.Create(OptionsPage);
  StartupBox.Parent := OptionsPage.Surface;
  StartupBox.Caption := CustomMessage('StartupLabel');
  StartupBox.Top := ScaleY(44);
  StartupBox.Width := OptionsPage.SurfaceWidth;
  StartupBox.Height := ScaleY(20);
  StartupBox.Font.Style := [fsBold];
  Hint := TNewStaticText.Create(OptionsPage);
  Hint.Parent := OptionsPage.Surface;
  Hint.Caption := CustomMessage('StartupHint');
  Hint.AutoSize := False;
  Hint.WordWrap := True;
  Hint.Left := ScaleX(20);
  Hint.Top := ScaleY(66);
  Hint.Width := OptionsPage.SurfaceWidth - ScaleX(20);
  Hint.Height := ScaleY(30);
  Hint.Font.Color := $616161;

  // a reinstall keeps the current choice; a first install starts with it on
  Startup := RegValueExists(HKCU, RunKey, RunValue) or not RegKeyExists(HKCU, 'Software\TeamsSupercopy');
  StartupBox.Checked := SwitchParam('STARTUP', Startup);
end;

// the new exe, extracted to {tmp}, closes the running copy (any version, the old PowerShell one included)
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  ExtractTemporaryFiles('{app}\{#AppExe}');
  if Exec(ExpandConstant('{tmp}\') + '{app}\{#AppExe}', '--close-running', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 1) then
    Result := CustomMessage('StillOpen');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  if not Exec(ExpandConstant('{app}\{#AppExe}'), '--install-settings --startup ' + OnOff(StartupBox.Checked), '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
    SuppressibleMsgBox(CustomMessage('SettingsFailed'), mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
  Exe: String;
begin
  if CurUninstallStep <> usUninstall then Exit;
  Exe := ExpandConstant('{app}\{#AppExe}');
  if Exec(Exe, '--close-running', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 1) then
  begin
    SuppressibleMsgBox(CustomMessage('StillOpen'), mbError, MB_OK, IDOK);
    Abort;
  end;
  // Start with Windows goes only when it starts this copy
  Exec(Exe, '--uninstall-cleanup', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;
