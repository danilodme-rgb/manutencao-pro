; =====================================================================
; Instalador do Manutenção PRO (Inno Setup 6.3 ou mais novo, https://jrsoftware.org/isinfo.php; usa "x64compatible")
; Compile depois de gerar ManutencaoPro.exe (Compilar_Para_EXE.bat chama o ISCC automaticamente se ele estiver instalado).
; Assinatura de código: configure em Tools > Configure Sign Tools um sign tool chamado "assinar" com o comando
;   signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /a $f
; e descomente as linhas SignTool/SignedUninstaller abaixo. Sem assinatura o SmartScreen avisa na primeira abertura.
; =====================================================================
#define NomeApp "Manutenção PRO"
#define Versao "6.0"
#define Editor "Seu nome ou razão social"
#define Site "https://github.com/danilodme-rgb/manutencao-pro"
#define Exe "ManutencaoPro.exe"

[Setup]
AppId={{7C1E3C8E-5B4D-4F1A-9B61-2A9D1C7F0A60}
AppName={#NomeApp}
AppVersion={#Versao}
AppVerName={#NomeApp} {#Versao}
AppPublisher={#Editor}
AppPublisherURL={#Site}
AppSupportURL={#Site}
AppUpdatesURL={#Site}
DefaultDirName={autopf}\ManutencaoPro
DefaultGroupName={#NomeApp}
DisableProgramGroupPage=yes
OutputDir=..\saida
OutputBaseFilename=ManutencaoPro-{#Versao}-Instalador
SetupIconFile=..\icone\ManutencaoPro.ico
UninstallDisplayIcon={app}\{#Exe}
UninstallDisplayName={#NomeApp}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=no
VersionInfoVersion={#Versao}.0.0
VersionInfoCompany={#Editor}
VersionInfoDescription=Instalador do {#NomeApp}
;SignTool=assinar $f
;SignedUninstaller=yes

[Languages]
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "Criar atalho na Área de Trabalho"; GroupDescription: "Atalhos:"

[Files]
Source: "..\{#Exe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\icone\ManutencaoPro.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#NomeApp}"; Filename: "{app}\{#Exe}"; IconFilename: "{app}\ManutencaoPro.ico"
Name: "{group}\Laudos e registros"; Filename: "{commonappdata}\ManutencaoPRO"
Name: "{autodesktop}\{#NomeApp}"; Filename: "{app}\{#Exe}"; IconFilename: "{app}\ManutencaoPro.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#Exe}"; Description: "Abrir o {#NomeApp} agora"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; Remove a manutenção mensal agendada (a tarefa roda uma cópia do programa a partir de ProgramData)
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""ManutencaoPRO - Mensal"" /F"; Flags: runhidden; RunOnceId: "RemoverAgendamento"

[Code]
// Na desinstalação, pergunta se os dados (laudos, histórico, licença e configurações) devem ser mantidos.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Pasta: string;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Pasta := ExpandConstant('{commonappdata}\ManutencaoPRO');
    if DirExists(Pasta) and (not UninstallSilent) then
    begin
      if MsgBox('Apagar também os laudos, o histórico de pontuações, a licença e as configurações em' + #13#10 + Pasta + '?' + #13#10#13#10 +
                'Escolha "Não" para manter tudo (recomendado se for reinstalar).', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(Pasta, True, True, True);
    end;
  end;
end;
