# ====================================================================
# MANUTENÇÃO PRO - APLICATIVO DE MANUTENÇÃO DO WINDOWS (POWERSHELL + WPF) - V6
# Usa apenas ferramentas nativas do Windows.
# Modo gráfico (padrão) ou automático/silencioso: -Automatico [-Perfil Diagnostico|Rapida|Completa|Reparo]
# -RemoverAgendamento: usado pelo desinstalador para apagar a tarefa agendada (sem interface).
# Regras de segurança: nada destrutivo sem confirmação; unidades removíveis (cartão SD/USB)
# só recebem verificações somente leitura; tarefas críticas nunca são interrompidas à força.
# ====================================================================
param(
    [switch]$Automatico,
    [switch]$RemoverAgendamento,
    [ValidateSet("Diagnostico", "Rapida", "Completa", "Reparo")]
    [string]$Perfil = "Completa"
)

# Evita janelas de progresso/aviso extras quando compilado com ps2exe -noConsole
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$script:Versao = "6.0"
$script:NomeProduto = "Manutenção PRO"

# Caminho do executável atual (.ps1 via powershell.exe ou .exe compilado pelo ps2exe)
$script:ProcessoExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:IsExe = ([IO.Path]::GetFileName($script:ProcessoExe) -notmatch '^(powershell|powershell_ise|pwsh)\.exe$')
$script:CaminhoScript = $PSCommandPath

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $ArgsExtras = "-Perfil $Perfil"
    if ($Automatico) { $ArgsExtras = "-Automatico $ArgsExtras" }
    if ($RemoverAgendamento) { $ArgsExtras = "-RemoverAgendamento $ArgsExtras" }
    if ($script:IsExe) { Start-Process -FilePath $script:ProcessoExe -ArgumentList $ArgsExtras -Verb RunAs }
    else { Start-Process powershell -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $ArgsExtras" -Verb RunAs }
    exit
}

$script:ModoAutomatico = [bool]$Automatico

# ==========================================
# DIRETÓRIOS (fora do OneDrive e independentes de onde o .exe está)
# ==========================================
$DataDir = Join-Path $env:ProgramData "ManutencaoPRO"
$DirLogs = Join-Path $DataDir "Logs"
$DirLaudos = Join-Path $DataDir "Laudos"
$DirTemp = Join-Path $DataDir "tmp"
$ConfigFile = Join-Path $DataDir "config.json"
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    # A tarefa agendada roda como SYSTEM a partir desta pasta: só Administradores e SYSTEM podem gravar nela
    Start-Process -FilePath "$env:SystemRoot\System32\icacls.exe" -WindowStyle Hidden -Wait -ArgumentList "`"$DataDir`" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX"
}
foreach ($d in @($DataDir, $DirLogs, $DirLaudos, $DirTemp)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$NomeTarefaAgendada = "ManutencaoPRO - Mensal"
$DiasDownloads = 30
$PontosRestauracaoManter = 2 # pontos de restauração mais recentes preservados na limpeza
$HistoricoFile = Join-Path $DataDir "historico.json"
$LicencaFile = Join-Path $DataDir "licenca.txt"
$ChaveRegistro = 'HKLM:\SOFTWARE\ManutencaoPRO'
$DiasAvaliacao = 30
$UrlVersao = "https://raw.githubusercontent.com/danilodme-rgb/manutencao-pro/main/versao.json"
$UrlSite = "https://github.com/danilodme-rgb/manutencao-pro"

# Desinstalador: só remove a tarefa agendada e sai (sem interface)
if ($RemoverAgendamento) {
    try { Unregister-ScheduledTask -TaskName $NomeTarefaAgendada -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    exit 0
}

# Controle de fluxo e segurança
$script:LogFile = $null
$script:ReportFile = $null
$script:LogBuffer = New-Object System.Text.StringBuilder
$script:ErrosEncontrados = $false
$script:AvisosEncontrados = $false
$script:ContadorFalhas = 0
$script:LimiteFalhas = 2 # Aborta no segundo erro grave
$script:Cancelado = $false
$script:Pausado = $false
$script:ProcessoAtual = $null
$script:Rodando = $false
$script:BloqueioSeguranca = $false
$script:ReinicioNecessario = $false
$script:HoraInicio = $null
$script:RelatorioTarefas = @()
$script:MetricasAntes = $null
$script:MetricasDepois = $null
$script:SaudeDiscos = @()
$script:AlertasSaude = @()
$script:Ameacas = @()
$script:AppsSelecionadosParaRemocao = @()
$script:Checkup = @()                 # itens do check-up (memória, hardware, segurança...)
$script:Unidades = @()                # C:, D: e demais unidades
$script:UnidadesParaCorrigir = @()    # cartão/USB com suspeita de erro: correção só manual
$script:AtualizacoesPendentes = @()   # drivers opcionais e versões novas do Windows (só listados)
$script:FecharAoTerminar = $false
$script:UltimoRelogio = $null
$script:Bateria = $null               # saúde da bateria (notebooks); $null = sem bateria
$script:BateriaLida = $false
$script:Inventario = $null            # ficha técnica (hardware, Windows, rede); lida pela tarefa Inventário ou pela página Ficha técnica
$script:InventarioDestaExecucao = $false # a ficha só entra no laudo quando a tarefa rodou nesta execução
$script:InventarioQuando = ""
$script:TelasAzuis = @()              # dumps de tela azul analisados (código, significado, data)
$script:Pontuacao = $null             # pontuação de saúde desta execução (0-100 com os motivos)
$script:PontuacaoAnterior = $null     # última pontuação do histórico (para mostrar a evolução)
$script:Atendimento = @{ Cliente = ""; OS = ""; Observacoes = "" } # dados do atendimento (edição Técnico)
$script:Config = $null                # configuração carregada (config.json)
$script:Licenca = $null               # licença/edição em uso (ver seção LICENÇA)

# Envio para a Lixeira sem diálogos (FOF_ALLOWUNDO | NOCONFIRMATION | NOERRORUI | SILENT | WANTNUKEWARNING)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LixeiraPRO {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT {
        public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo;
        public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    public static bool Enviar(string caminho) {
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.wFunc = 3;
        op.pFrom = caminho + "\0";
        op.fFlags = 0x0040 | 0x0010 | 0x0400 | 0x0004 | 0x4000;
        return SHFileOperation(ref op) == 0 && !op.fAnyOperationsAborted;
    }
}
// Barra de título escura/colorida no Windows 10/11 e efeito Mica no Windows 11 (ignorados em versões sem suporte)
public static class JanelaPRO {
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int valor, int tamanho);
    [StructLayout(LayoutKind.Sequential)]
    struct MARGINS { public int esq, dir, topo, base_; }
    [DllImport("dwmapi.dll")]
    static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
    public static void AplicarTema(IntPtr hwnd, bool escuro, int corRgb, bool corNaBarra) {
        int v = escuro ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref v, 4);
        // 35 = cor da barra de título; 0xFFFFFFFF devolve o padrão do sistema (necessário com Mica)
        int cor = corNaBarra ? (((corRgb & 0xFF) << 16) | (corRgb & 0xFF00) | ((corRgb >> 16) & 0xFF)) : unchecked((int)0xFFFFFFFF);
        DwmSetWindowAttribute(hwnd, 35, ref cor, 4);
    }
    // Mica (Windows 11 22H2+): devolve true se o sistema aceitou o efeito; o chamador então torna o fundo transparente
    public static bool AplicarMica(IntPtr hwnd) {
        MARGINS m = new MARGINS(); m.esq = -1; m.dir = -1; m.topo = -1; m.base_ = -1;
        if (DwmExtendFrameIntoClientArea(hwnd, ref m) != 0) return false;
        int tipo = 2; // DWMSBT_MAINWINDOW
        return DwmSetWindowAttribute(hwnd, 38, ref tipo, 4) == 0;
    }
    public static void RemoverMica(IntPtr hwnd) {
        int tipo = 1; // DWMSBT_NONE
        DwmSetWindowAttribute(hwnd, 38, ref tipo, 4);
        MARGINS m = new MARGINS();
        DwmExtendFrameIntoClientArea(hwnd, ref m);
    }
}
"@

# ==========================================
# UTILITÁRIOS
# ==========================================
Function Atualizar-Tela {
    if ($script:ModoAutomatico) { return }
    if ($script:Rodando -and $script:HoraInicio) {
        $Agora = Get-Date
        if (-not $script:UltimoRelogio -or ($Agora - $script:UltimoRelogio).TotalMilliseconds -ge 900) {
            $lblDecorrido.Text = ($Agora - $script:HoraInicio).ToString("hh\:mm\:ss")
            $script:UltimoRelogio = $Agora
        }
    }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

Function Escrever-Log {
    param ([string]$Mensagem, [ValidateSet("Info", "Aviso", "Erro")][string]$Tipo = "Info")
    $Prefixo = switch ($Tipo) { "Erro" { "[ERRO] " } "Aviso" { "[AVISO] " } default { "" } }
    $Hora = Get-Date -Format 'HH:mm:ss'
    $Linha = "[$Hora] $Prefixo$Mensagem"
    [void]$script:LogBuffer.AppendLine($Linha)
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $Linha -Encoding UTF8 } catch {} }
    if (-not $script:ModoAutomatico) { Adicionar-LinhaLog $Hora "$Prefixo$Mensagem"; Atualizar-Tela }
}

Function Registrar-ResultadoTarefa {
    param ([string]$NomeTarefa, [ValidateSet("Sucesso", "Aviso", "Erro", "Cancelada")][string]$Status, [string]$Detalhe)
    $script:RelatorioTarefas += [PSCustomObject]@{ Hora = (Get-Date -Format "HH:mm:ss"); Tarefa = $NomeTarefa; Status = $Status; Detalhe = $Detalhe }
    switch ($Status) {
        "Sucesso" { Escrever-Log "[OK] $Detalhe" }
        "Aviso" { $script:AvisosEncontrados = $true; Escrever-Log $Detalhe "Aviso" }
        "Cancelada" { Escrever-Log "Tarefa interrompida pelo cancelamento." "Aviso" }
    }
}

Function Processar-Erro {
    param ([string]$NomeTarefa, [string]$MensagemErro)
    $script:ContadorFalhas++
    $script:ErrosEncontrados = $true
    Escrever-Log $MensagemErro "Erro"
    $script:RelatorioTarefas += [PSCustomObject]@{ Hora = (Get-Date -Format "HH:mm:ss"); Tarefa = $NomeTarefa; Status = "Erro"; Detalhe = $MensagemErro }
    if ($script:ContadorFalhas -ge $script:LimiteFalhas) {
        Escrever-Log ">>> LIMITE DE FALHAS CRÍTICAS ATINGIDO ($script:ContadorFalhas/$script:LimiteFalhas). ABORTANDO... <<<" "Erro"
        $script:Cancelado = $true
    }
}

Function Aguardar-Pausa {
    while ($script:Pausado -and -not $script:Cancelado) { Start-Sleep -Milliseconds 200; Atualizar-Tela }
}

Function Formatar-Tamanho([double]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    return "{0:N0} MB" -f ($Bytes / 1MB)
}

Function Formatar-Codigo($Codigo) {
    if ($null -eq $Codigo) { return "desconhecido" }
    $Sem = [uint32]([int64]$Codigo -band [int64]4294967295)
    return "{0} (0x{1:X8})" -f $Codigo, $Sem
}

Function Obter-BytesLivres {
    return [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
}

Function Obter-EspacoSistema {
    $D = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    return [PSCustomObject]@{
        LivreGB = [math]::Round($D.FreeSpace / 1GB, 2)
        TotalGB = [math]::Round($D.Size / 1GB, 2)
        Percentual = [math]::Round(($D.FreeSpace / $D.Size) * 100, 1)
    }
}

Function Obter-PerfisUsuario {
    Get-CimInstance Win32_UserProfile -Filter "Special = False" -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -and (Test-Path $_.LocalPath) } | ForEach-Object { $_.LocalPath }
}

# Todas as unidades com letra: internas (C:), cartões de memória (D:) e USB.
# Removivel = cartão/USB: só recebe verificações somente leitura (nunca otimização nem correção automática).
Function Obter-Unidades {
    $Fisicos = @{}
    foreach ($P in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $Fisicos["$($P.DeviceId)"] = $P }
    $DiscoDaLetra = @{}
    foreach ($Part in @(Get-Partition -ErrorAction SilentlyContinue)) {
        if ("$($Part.DriveLetter)" -match '^[A-Za-z]$') { $DiscoDaLetra["$($Part.DriveLetter)"] = "$($Part.DiskNumber)" }
    }
    $Sujos = @{}
    foreach ($W in @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) { $Sujos[$W.DriveLetter.TrimEnd(':')] = [bool]$W.DirtyBitSet }
    $LetraSistema = $env:SystemDrive.TrimEnd(':')
    $Lista = @()
    $Volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' -and "$($_.DriveType)" -in 'Fixed', 'Removable' -and $_.Size -gt 0 } | Sort-Object DriveLetter)
    foreach ($V in $Volumes) {
        $L = "$($V.DriveLetter)".ToUpper()
        $F = $null
        if ($DiscoDaLetra.ContainsKey($L)) { $F = $Fisicos[$DiscoDaLetra[$L]] }
        $Bus = if ($F) { "$($F.BusType)" } else { "" }
        $NomeF = if ($F) { "$($F.FriendlyName)" } else { "" }
        $Removivel = $true
        if ($Bus -in 'SD', 'MMC' -or $NomeF -match 'Card Reader|SD Card|MMC') { $Tipo = "Cartão de memória" }
        elseif ("$($V.DriveType)" -eq 'Removable' -or $Bus -eq 'USB') { $Tipo = "Unidade USB" }
        else {
            $Removivel = $false
            $Midia = if ($F) { "$($F.MediaType)" } else { "" }
            $Tipo = if ($Midia -eq 'SSD') { if ($Bus -eq 'NVMe') { "SSD NVMe" } else { "SSD" } } elseif ($Midia -eq 'HDD') { "HD" } else { "Disco" }
        }
        $Lista += [PSCustomObject]@{
            Letra = $L; Rotulo = "$($V.FileSystemLabel)"; FS = "$($V.FileSystem)"; Tipo = $Tipo
            Removivel = $Removivel; Sistema = ($L -eq $LetraSistema)
            TotalBytes = [int64]$V.Size; LivreBytes = [int64]$V.SizeRemaining
            PercLivre = [math]::Round(($V.SizeRemaining / $V.Size) * 100, 1)
            Saude = "$($V.HealthStatus)"; Sujo = [bool]$Sujos[$L]
        }
    }
    return $Lista
}

Function Descrever-Unidade($U) {
    $Papel = if ($U.Sistema) { "sistema" } elseif ($U.Rotulo) { $U.Rotulo } else { "dados" }
    return "$($U.Letra): ($Papel, $($U.Tipo), $($U.FS))"
}

Function Testar-ReinicioPendente {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

Function Obter-PastaDownloads {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# Mantém os 30 logs e os 30 laudos HTML mais recentes; PDFs exportados pelo técnico nunca são apagados
Function Limpar-Historico {
    foreach ($Pasta in @($DirLogs, $DirLaudos)) {
        Get-ChildItem -Path $Pasta -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.pdf' } |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

Function Mostrar-Mensagem {
    param ([string]$Texto, [string]$Botoes = "OK", [string]$Icone = "Information")
    return [System.Windows.MessageBox]::Show($Texto, "Manutenção PRO", $Botoes, $Icone)
}

# Números em XAML, SVG e CSS sempre com ponto decimal (a cultura pt-BR usa vírgula, que quebraria a marcação)
Function Num([double]$Valor, [int]$Casas = 1) { return $Valor.ToString("F$Casas", [Globalization.CultureInfo]::InvariantCulture) }

Function Obter-BuildWindows {
    try { return [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber } catch { return 0 }
}

Function ConvertTo-Base64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
Function ConvertFrom-Base64Url([string]$Texto) {
    $t = $Texto.Trim().Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return [Convert]::FromBase64String($t)
}

Function Nome-ArquivoSeguro([string]$Texto, [int]$Maximo = 40) {
    $t = ($Texto -replace '[^\p{L}\p{N} _-]', '').Trim() -replace '\s+', '_'
    if ($t.Length -gt $Maximo) { $t = $t.Substring(0, $Maximo) }
    return $t
}

# ==========================================
# CONFIGURAÇÃO (config.json): preferências, identidade do laudo e primeiro uso
# ==========================================
Function Obter-ConfigPadrao {
    return [ordered]@{
        Perfil = "Completa"; Marcadas = @(); Detalhado = $false; Apps = @()
        Tema = "Sistema"                  # Sistema | Claro | Escuro
        Mica = $true                      # efeito Mica na janela (Windows 11 22H2+)
        VerificarAtualizacoes = $true
        PrimeiroUso = ""
        PaginaInicial = "Inicio"
        Marca = [ordered]@{ Nome = ""; Telefone = ""; Contato = ""; Tecnico = ""; Logo = ""; MostrarNoLaudo = $true }
    }
}

Function Carregar-Config {
    $Cfg = Obter-ConfigPadrao
    if (Test-Path $ConfigFile) {
        try {
            $Lido = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($P in $Lido.PSObject.Properties) {
                if ($P.Name -eq 'Marca') {
                    if ($P.Value) { foreach ($M in $P.Value.PSObject.Properties) { if ($Cfg.Marca.Contains($M.Name)) { $Cfg.Marca[$M.Name] = $M.Value } } }
                } elseif ($Cfg.Contains($P.Name)) { $Cfg[$P.Name] = $P.Value }
            }
        } catch {}
    }
    if ($Cfg.Tema -notin 'Sistema', 'Claro', 'Escuro') { $Cfg.Tema = 'Sistema' }
    $script:Config = $Cfg
    return $Cfg
}

Function Gravar-Config {
    try { ConvertTo-Json -InputObject $script:Config -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8 } catch {}
}

# ==========================================
# LICENÇA (offline, assinada com ECDSA P-256; a chave pública fica embutida no programa)
# Formato do texto: MPRO1.<base64url(json)>.<base64url(assinatura r||s)>
# JSON: n = nome do cliente, e = edição (Casa|Tecnico), m = código do computador (só Casa),
#       v = validade AAAA-MM-DD (vazio = sem vencimento), i = emissão, id = número da licença
# Edições em uso: Desenvolvimento (compilação sem chave pública), Avaliacao, Expirada, Casa, Tecnico
# A chave abaixo é gravada por ferramentas\Licencas.ps1 -GerarChaves (nunca versione a chave privada).
# ==========================================
$script:ChavePublicaLicenca = ""

Function Obter-CodigoMaquina {
    $Partes = @()
    try { $Partes += "$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid)" } catch {}
    try { $Partes += "$((Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID)" } catch {}
    try { $Partes += "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)" } catch {}
    $Texto = (@($Partes | Where-Object { $_ }) -join '|')
    if (-not $Texto) { $Texto = "$env:COMPUTERNAME" }
    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Texto))
    $Alfabeto = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # sem 0/O/1/I para não confundir na hora de digitar
    $Cod = ""
    for ($i = 0; $i -lt 16; $i++) { $Cod += [string]$Alfabeto[$Hash[$i] % 32] }
    return ($Cod -replace '(.{4})(?=.)', '$1-')
}

Function Verificar-Licenca([string]$Texto) {
    $R = [PSCustomObject]@{ Valida = $false; Motivo = ""; Nome = ""; Edicao = ""; Maquina = ""; Validade = $null; Emissao = $null; Id = "" }
    $Texto = "$Texto".Trim()
    if (-not $Texto) { $R.Motivo = "Nenhuma licença informada."; return $R }
    $Partes = @($Texto -split '\.')
    if ($Partes.Count -ne 3 -or $Partes[0] -ne 'MPRO1') { $R.Motivo = "Formato de licença inválido."; return $R }
    try {
        $Dados = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $Partes[1])) | ConvertFrom-Json
        $Assinatura = ConvertFrom-Base64Url $Partes[2]
    } catch { $R.Motivo = "A licença está corrompida (não foi possível ler)."; return $R }
    $R.Nome = "$($Dados.n)"; $R.Edicao = "$($Dados.e)"; $R.Maquina = "$($Dados.m)"; $R.Id = "$($Dados.id)"
    if ($Dados.v) { try { $R.Validade = [datetime]::ParseExact("$($Dados.v)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch {} }
    if ($Dados.i) { try { $R.Emissao = [datetime]::ParseExact("$($Dados.i)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch {} }
    if (-not $script:ChavePublicaLicenca) { $R.Motivo = "Esta compilação não tem chave pública embutida: licenças não podem ser verificadas."; return $R }
    try {
        $Chave = [System.Security.Cryptography.CngKey]::Import([Convert]::FromBase64String($script:ChavePublicaLicenca), [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $Ecdsa = New-Object System.Security.Cryptography.ECDsaCng $Chave
        $Ecdsa.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
        $Ok = $Ecdsa.VerifyData([Text.Encoding]::UTF8.GetBytes($Partes[1]), $Assinatura)
    } catch { $R.Motivo = "Falha ao verificar a assinatura: $($_.Exception.Message)"; return $R }
    if (-not $Ok) { $R.Motivo = "Assinatura inválida: esta licença não foi emitida para este produto."; return $R }
    if ($R.Edicao -notin 'Casa', 'Tecnico') { $R.Motivo = "Edição desconhecida: '$($R.Edicao)'."; return $R }
    if ($R.Validade -and (Get-Date).Date -gt $R.Validade) { $R.Motivo = "Licença vencida em $($R.Validade.ToString('dd/MM/yyyy'))."; return $R }
    if ($R.Edicao -eq 'Casa') {
        if (-not $R.Maquina) { $R.Motivo = "Licença Casa sem código de computador."; return $R }
        if ($R.Maquina -ne (Obter-CodigoMaquina)) { $R.Motivo = "Esta licença pertence a outro computador (código $($R.Maquina))."; return $R }
    }
    $R.Valida = $true
    return $R
}

# Data do primeiro uso: gravada no config.json e no registro (vale a mais antiga das duas)
Function Obter-PrimeiroUso {
    $Datas = @()
    try {
        $v = "$((Get-ItemProperty -Path $ChaveRegistro -Name PrimeiroUso -ErrorAction Stop).PrimeiroUso)"
        if ($v) { $Datas += [datetime]::ParseExact($v, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    } catch {}
    if ($script:Config.PrimeiroUso) { try { $Datas += [datetime]::ParseExact("$($script:Config.PrimeiroUso)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch {} }
    if ($Datas.Count -eq 0) { $Datas += (Get-Date).Date }
    $Primeiro = @($Datas | Sort-Object)[0]
    $Txt = $Primeiro.ToString('yyyy-MM-dd')
    if ($script:Config.PrimeiroUso -ne $Txt) { $script:Config.PrimeiroUso = $Txt; Gravar-Config }
    try {
        if (-not (Test-Path $ChaveRegistro)) { New-Item -Path $ChaveRegistro -Force | Out-Null }
        if ("$((Get-ItemProperty -Path $ChaveRegistro -Name PrimeiroUso -ErrorAction SilentlyContinue).PrimeiroUso)" -ne $Txt) { Set-ItemProperty -Path $ChaveRegistro -Name PrimeiroUso -Value $Txt }
    } catch {}
    return $Primeiro
}

# Candidatas: 1) licenca.txt ao lado do programa (técnico que roda do pendrive); 2) licença ativada neste computador
Function Ler-TextosLicenca {
    $Locais = @()
    $Origem = if ($script:IsExe) { $script:ProcessoExe } else { $script:CaminhoScript }
    if ($Origem) { $Locais += Join-Path (Split-Path -Parent $Origem) 'licenca.txt' }
    $Locais += $LicencaFile
    $Textos = @()
    foreach ($Arq in $Locais) {
        if (Test-Path -LiteralPath $Arq) { try { $t = (Get-Content -LiteralPath $Arq -Raw -Encoding UTF8).Trim(); if ($t) { $Textos += $t } } catch {} }
    }
    return $Textos
}

Function Carregar-Licenca {
    $Primeiro = Obter-PrimeiroUso
    $DiasUsados = [math]::Floor(((Get-Date).Date - $Primeiro.Date).TotalDays)
    $Restantes = [int][math]::Max(0, $DiasAvaliacao - $DiasUsados)
    $L = [PSCustomObject]@{ Edicao = "Avaliacao"; Nome = ""; Validade = $null; DiasRestantes = $Restantes; Motivo = ""; Texto = ""; Id = "" }
    # Vale a primeira licença VÁLIDA; uma licença vencida no pendrive não esconde a licença ativada no computador
    foreach ($Texto in @(Ler-TextosLicenca)) {
        $V = Verificar-Licenca $Texto
        if (-not $L.Texto) { $L.Texto = $Texto; $L.Motivo = $V.Motivo }
        if ($V.Valida) { $L.Edicao = $V.Edicao; $L.Nome = $V.Nome; $L.Validade = $V.Validade; $L.Id = $V.Id; $L.Texto = $Texto; $L.Motivo = ""; break }
    }
    if ($L.Edicao -eq 'Avaliacao') {
        if (-not $script:ChavePublicaLicenca) { $L.Edicao = "Desenvolvimento" }
        elseif ($Restantes -le 0) { $L.Edicao = "Expirada" }
    }
    $script:Licenca = $L
    return $L
}

Function Descrever-Edicao {
    $L = $script:Licenca
    $Quem = if ($L.Nome) { " · $($L.Nome)" } else { "" }
    switch ($L.Edicao) {
        'Desenvolvimento' { return "Edição de desenvolvimento (sem chave de licença embutida)" }
        'Avaliacao' { return "Avaliação: $($L.DiasRestantes) dia(s) restante(s)" }
        'Expirada' { return "Avaliação encerrada: só o diagnóstico continua liberado" }
        'Casa' { return "Edição Casa$Quem" }
        'Tecnico' { return "Edição Técnico$Quem" }
    }
    return "$($L.Edicao)"
}
Function Testar-RecursoTecnico { return ($script:Licenca.Edicao -in 'Tecnico', 'Avaliacao', 'Desenvolvimento') }
Function Testar-ManutencaoLiberada { return ($script:Licenca.Edicao -ne 'Expirada') }

$null = Carregar-Config
$null = Carregar-Licenca

# ==========================================
# EXECUTOR DE PROCESSOS EXTERNOS (interface não congela; saída capturada)
# ==========================================
Function Parar-ArvoreProcesso([int]$Id) {
    Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList "/PID $Id /T /F" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
}

Function Ler-ArquivoSaida([string]$Caminho) {
    if (-not (Test-Path $Caminho)) { return "" }
    $Bytes = [IO.File]::ReadAllBytes($Caminho)
    if ($Bytes.Length -eq 0) { return "" }
    $Nulos = 0
    for ($i = 0; $i -lt [math]::Min(400, $Bytes.Length); $i++) { if ($Bytes[$i] -eq 0) { $Nulos++ } }
    if ($Nulos -gt 20) { $Texto = [Text.Encoding]::Unicode.GetString($Bytes) } # sfc grava em UTF-16
    else {
        try { $Texto = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
        catch { $Texto = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($Bytes) }
    }
    return ($Texto -replace "`0", "")
}

Function Resumo-Saida([string]$Texto, [int]$Linhas = 5) {
    if (-not $Texto) { return "" }
    $Uteis = $Texto -split "[\r\n]+" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^[\s\-\\\|/\.]*$' -and $_ -notmatch '[█▒]' -and $_ -notmatch '^\[=*\s*\d' }
    return (($Uteis | Select-Object -Last $Linhas) -join " | ")
}

Function Executar-Comando {
    param (
        [string]$Comando,
        [string]$Argumentos = "",
        [bool]$PodeCancelar = $true,
        [int]$TimeoutMinutos = 0,  # 0 = nunca encerrar à força (DISM/SFC/Windows Update)
        [int]$AvisoMinutos = 0,    # só avisa que está demorando
        [switch]$SemSaida          # apps gráficos (cleanmgr): executa direto, sem capturar saída
    )
    $ArqSaida = Join-Path $DirTemp ("saida_{0}.txt" -f [guid]::NewGuid().ToString("N"))
    if ($SemSaida) {
        $p = Start-Process -FilePath $Comando -ArgumentList $Argumentos -WindowStyle Hidden -PassThru
    } else {
        # Entrada ligada a NUL: se alguma ferramenta fizer uma pergunta, ela recebe "fim de entrada" em vez de travar para sempre
        $Linha = "/s /c `"`"$Comando`" $Argumentos < NUL > `"$ArqSaida`" 2>&1`""
        $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $Linha -WindowStyle Hidden -PassThru
    }
    $null = $p.Handle # sem isso o ExitCode pode vir nulo
    $script:ProcessoAtual = $p
    $Inicio = Get-Date; $Avisado = $false; $FoiCancelado = $false; $Saida = ""
    try {
        while (-not $p.HasExited) {
            if ($script:Cancelado -and $PodeCancelar) { Parar-ArvoreProcesso $p.Id; $FoiCancelado = $true; break }
            $Minutos = ((Get-Date) - $Inicio).TotalMinutes
            if ($TimeoutMinutos -gt 0 -and $Minutos -gt $TimeoutMinutos) {
                Parar-ArvoreProcesso $p.Id
                throw "Tempo limite de $TimeoutMinutos min excedido; o processo foi encerrado."
            }
            if ($AvisoMinutos -gt 0 -and -not $Avisado -and $Minutos -gt $AvisoMinutos) {
                Escrever-Log "Está levando mais de $AvisoMinutos min. É normal em alguns PCs; não desligue o computador." "Aviso"
                $Avisado = $true
            }
            Start-Sleep -Milliseconds 250
            Atualizar-Tela
        }
        if (-not $SemSaida) { $Saida = Ler-ArquivoSaida $ArqSaida }
    } finally {
        $script:ProcessoAtual = $null
        Remove-Item $ArqSaida -Force -ErrorAction SilentlyContinue
    }
    $Codigo = if ($FoiCancelado) { $null } else { $p.ExitCode }
    return [PSCustomObject]@{ ExitCode = $Codigo; Saida = $Saida; Cancelado = $FoiCancelado }
}

# Roda um trecho de PowerShell em processo separado (cmdlets demorados não travam a interface)
Function Executar-PSIsolado {
    param ([string]$Script, [bool]$PodeCancelar = $true, [int]$TimeoutMinutos = 0, [int]$AvisoMinutos = 0)
    $Arq = Join-Path $DirTemp ("tarefa_{0}.ps1" -f [guid]::NewGuid().ToString("N"))
    $Preambulo = "`$ProgressPreference = 'SilentlyContinue'`n[Console]::OutputEncoding = [Text.Encoding]::UTF8`n"
    Set-Content -Path $Arq -Value ($Preambulo + $Script) -Encoding UTF8
    try {
        return Executar-Comando -Comando "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Argumentos "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Arq`"" `
            -PodeCancelar $PodeCancelar -TimeoutMinutos $TimeoutMinutos -AvisoMinutos $AvisoMinutos
    } finally { Remove-Item $Arq -Force -ErrorAction SilentlyContinue }
}

# Lista arquivos e subpastas sem NUNCA entrar em junções/links simbólicos (que podem apontar para fora da pasta)
# nem tocar em arquivos com ponto de nova análise (links, arquivos só na nuvem do OneDrive).
Function Obter-ArquivosSeguro([string]$Raiz) {
    $Arquivos = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $Pastas = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $Res = [PSCustomObject]@{ Arquivos = $Arquivos; Pastas = $Pastas }
    if (-not $Raiz) { return $Res }
    try { $Inicio = New-Object System.IO.DirectoryInfo $Raiz } catch { return $Res }
    if (-not $Inicio.Exists -or ($Inicio.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $Res }
    $Pilha = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $Pilha.Push($Inicio)
    $n = 0
    while ($Pilha.Count -gt 0) {
        $Atual = $Pilha.Pop()
        try { $Itens = $Atual.GetFileSystemInfos() } catch { continue }
        foreach ($I in $Itens) {
            if ($I.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($I -is [System.IO.DirectoryInfo]) { $Pastas.Add($I); $Pilha.Push($I) } else { $Arquivos.Add($I) }
        }
        $n++
        if ($n % 100 -eq 0) { Atualizar-Tela }
    }
    return $Res
}

# Apaga arquivos de uma pasta (opcionalmente só os antigos, ou enviando para a Lixeira) sem travar a interface
Function Limpar-Pasta {
    param ([string]$Caminho, [int]$IdadeMinimaHoras = 0, [switch]$ParaLixeira)
    $Liberado = [int64]0; $Falhas = 0; $Qtd = 0
    $Lista = Obter-ArquivosSeguro $Caminho
    $Limite = (Get-Date).AddHours(-$IdadeMinimaHoras)
    $i = 0
    foreach ($Arq in $Lista.Arquivos) {
        if ($script:Cancelado) { break }
        if ($IdadeMinimaHoras -gt 0 -and ($Arq.LastWriteTime -gt $Limite -or $Arq.CreationTime -gt $Limite)) { continue }
        $Tam = $Arq.Length
        $Ok = $false
        if ($ParaLixeira) { $Ok = [LixeiraPRO]::Enviar($Arq.FullName) }
        else { try { Remove-Item -LiteralPath $Arq.FullName -Force -ErrorAction Stop; $Ok = $true } catch {} }
        if ($Ok) { $Liberado += $Tam; $Qtd++ } else { $Falhas++ }
        $i++
        if ($i % 200 -eq 0) { Aguardar-Pausa; Atualizar-Tela }
    }
    if (-not $ParaLixeira -and -not $script:Cancelado) {
        # Remove subpastas que ficaram vazias (da mais profunda para a mais rasa). Pastas recém-criadas ficam:
        # um programa em execução pode estar contando com elas. DirectoryInfo.Delete() só apaga pasta vazia.
        foreach ($P in @($Lista.Pastas | Sort-Object { $_.FullName.Length } -Descending)) {
            try {
                $P.Refresh()
                if ($IdadeMinimaHoras -gt 0 -and $P.CreationTime -gt $Limite) { continue }
                if (@($P.GetFileSystemInfos()).Count -eq 0) { $P.Delete() }
            } catch {}
        }
    }
    return [PSCustomObject]@{ Bytes = $Liberado; Falhas = $Falhas; Arquivos = $Qtd }
}

Function Obter-PreviaDownloads {
    $Pasta = Obter-PastaDownloads
    $Limite = (Get-Date).AddDays(-$DiasDownloads)
    $Arqs = @((Obter-ArquivosSeguro $Pasta).Arquivos | Where-Object { $_.LastWriteTime -le $Limite -and $_.CreationTime -le $Limite })
    return [PSCustomObject]@{ Pasta = $Pasta; Quantidade = $Arqs.Count; Bytes = [int64]($Arqs | Measure-Object Length -Sum).Sum }
}

Function Obter-PreviaPontosRestauracao {
    $Total = 0
    try { $Total = @(Get-ComputerRestorePoint -ErrorAction Stop).Count } catch {}
    return [PSCustomObject]@{ Total = $Total; Apagar = [Math]::Max(0, $Total - $PontosRestauracaoManter) }
}

Function Obter-InfoLixeira {
    $Qtd = 0; $Bytes = [int64]0
    try {
        foreach ($I in (New-Object -ComObject Shell.Application).NameSpace(10).Items()) { $Qtd++; try { $Bytes += [int64]$I.Size } catch {} }
    } catch {}
    return [PSCustomObject]@{ Quantidade = $Qtd; Bytes = $Bytes }
}

# ==========================================
# DIAGNÓSTICOS (saúde dos discos, inicialização, CBS, DISM)
# ==========================================
Function Obter-SaudeDiscos {
    $Lista = @()
    foreach ($Disco in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        # Leitores de cartão não repassam SMART: o "Healthy" que informam não diz nada sobre o cartão
        $Leitor = ("$($Disco.BusType)" -in 'SD', 'MMC') -or ($Disco.FriendlyName -match 'Card Reader|SD Card|MMC')
        $R = $null
        if (-not $Leitor) { try { $R = $Disco | Get-StorageReliabilityCounter -ErrorAction Stop } catch {} }
        $Lista += [PSCustomObject]@{
            Nome = $Disco.FriendlyName
            Tipo = $(if ($Leitor) { "Cartão de memória (leitor)" } else { "$($Disco.MediaType)" })
            Barramento = "$($Disco.BusType)"
            TamanhoGB = [math]::Round($Disco.Size / 1GB)
            SemSmart = $Leitor
            Saude = $(if ($Leitor) { "Não informada" } else { "$($Disco.HealthStatus)" })
            Desgaste = $(if ($R -and $null -ne $R.Wear) { [int]$R.Wear } else { $null })
            Temperatura = $(if ($R -and $R.Temperature) { [int]$R.Temperature } else { $null })
            ErrosLeitura = $(if ($R) { $R.ReadErrorsUncorrected } else { $null })
            ErrosEscrita = $(if ($R) { $R.WriteErrorsUncorrected } else { $null })
            HorasLigado = $(if ($R) { $R.PowerOnHours } else { $null })
        }
    }
    return $Lista
}

Function Obter-AlertasDisco($D) {
    $A = @()
    if ($D.SemSmart) { return $A }
    if ($D.Saude -and $D.Saude -ne "Healthy") { $A += "$($D.Nome): o Windows marca a saúde do disco como '$($D.Saude)'. Faça backup dos seus arquivos imediatamente." }
    if ($null -ne $D.Desgaste -and $D.Desgaste -ge 80) { $A += "$($D.Nome): desgaste de $($D.Desgaste)% da vida útil. Planeje a troca e mantenha backup." }
    if ($D.ErrosLeitura -gt 0 -or $D.ErrosEscrita -gt 0) { $A += "$($D.Nome): $($D.ErrosLeitura) erro(s) de leitura e $($D.ErrosEscrita) de escrita não corrigidos." }
    if ($null -ne $D.Temperatura -and $D.Temperatura -ge 70) { $A += "$($D.Nome): temperatura alta ($($D.Temperatura) °C). Verifique a ventilação." }
    return $A
}

$script:FontesInicializacao = @(
    @{ Chave = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Origem = 'Usuário' }
    @{ Chave = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Origem = 'Todos os usuários' }
    @{ Chave = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprov = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Origem = 'Todos os usuários (32 bits)' }
)

Function Obter-EstadoAprovado([string]$ChaveAprov, [string]$Nome) {
    try { $v = (Get-Item -Path $ChaveAprov -ErrorAction Stop).GetValue($Nome) } catch { return $true }
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) } # 02 = ativo, 03 = desativado
    return $true
}

Function Definir-EstadoAprovado([string]$ChaveAprov, [string]$Nome, [bool]$Ativo) {
    if (-not (Test-Path $ChaveAprov)) { New-Item -Path $ChaveAprov -Force | Out-Null }
    $Bytes = New-Object byte[] 12
    if ($Ativo) { $Bytes[0] = 2 }
    else { $Bytes[0] = 3; [BitConverter]::GetBytes((Get-Date).ToFileTime()).CopyTo($Bytes, 4) }
    Set-ItemProperty -Path $ChaveAprov -Name $Nome -Value $Bytes -Type Binary
}

Function Obter-ItensInicializacao {
    $Itens = @()
    foreach ($F in $script:FontesInicializacao) {
        if (-not (Test-Path $F.Chave)) { continue }
        $Chave = Get-Item -Path $F.Chave
        foreach ($Nome in $Chave.GetValueNames()) {
            if (-not $Nome) { continue }
            $Itens += [PSCustomObject]@{ Nome = $Nome; Comando = "$($Chave.GetValue($Nome))"; Origem = $F.Origem; Aprov = $F.Aprov; Ativo = (Obter-EstadoAprovado $F.Aprov $Nome) }
        }
    }
    $Pastas = @(
        @{ Pasta = [Environment]::GetFolderPath('Startup'); Aprov = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Origem = 'Pasta Inicializar (usuário)' }
        @{ Pasta = [Environment]::GetFolderPath('CommonStartup'); Aprov = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Origem = 'Pasta Inicializar (todos)' }
    )
    foreach ($P in $Pastas) {
        if (-not $P.Pasta -or -not (Test-Path $P.Pasta)) { continue }
        foreach ($Arq in Get-ChildItem -Path $P.Pasta -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $Itens += [PSCustomObject]@{ Nome = $Arq.Name; Comando = $Arq.FullName; Origem = $P.Origem; Aprov = $P.Aprov; Ativo = (Obter-EstadoAprovado $P.Aprov $Arq.Name) }
        }
    }
    return $Itens
}

# Lê o CBS.log (em inglês em qualquer idioma do Windows) para saber o resultado real do SFC
Function Analisar-LogCBS([datetime]$Desde) {
    $Res = [PSCustomObject]@{ Reparados = 0; NaoReparados = 0; Concluido = $false }
    try {
        $fs = [IO.File]::Open("$env:SystemRoot\Logs\CBS\CBS.log", 'Open', 'Read', 'ReadWrite, Delete')
        try { $Texto = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return $Res }
    foreach ($m in [regex]::Matches($Texto, '(?m)^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),[^\r\n]*?\[SR\] ([^\r\n]*)')) {
        $Data = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        if ($Data -lt $Desde) { continue }
        $Msg = $m.Groups[2].Value
        if ($Msg -like 'Cannot repair member file*') { $Res.NaoReparados++ }
        elseif ($Msg -like 'Repairing corrupted file*') { $Res.Reparados++ }
        elseif ($Msg -like 'Verify complete*') { $Res.Concluido = $true }
    }
    return $Res
}

Function Obter-EstadoImagem([string]$Modo) {
    $R = Executar-PSIsolado -PodeCancelar $false -AvisoMinutos 30 -Script (@'
try { $r = Repair-WindowsImage -Online {0} -NoRestart -ErrorAction Stop; Write-Output ('ESTADO=' + $r.ImageHealthState) }
catch { Write-Output ('FALHA=' + $_.Exception.Message) }
'@ -replace '\{0\}', $Modo)
    if ($R.Saida -match 'ESTADO=(\w+)') { return $Matches[1] }
    if ($R.Saida -match 'FALHA=(.+)') { throw "DISM falhou: $($Matches[1].Trim())" }
    throw "DISM não retornou resultado. $(Resumo-Saida $R.Saida 3)"
}

Function Obter-CaminhoWinget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { try { [version](($_.Directory.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($p) { return $p.FullName }
    return $null
}

Function Obter-CaminhoMpCmdRun {
    $p = Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($p) { return $p.FullName }
    return "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
}

Function Obter-AmeacasDesde([datetime]$Inicio) {
    @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $Inicio } | ForEach-Object {
        $n = (Get-MpThreat -ThreatID $_.ThreatID -ErrorAction SilentlyContinue).ThreatName; if ($n) { $n } else { "ID $($_.ThreatID)" } } | Select-Object -Unique)
}

# ==========================================
# CHECK-UP DO SISTEMA (somente leitura: nada é alterado)
# Níveis: OK, Info, Atencao, Critico
# ==========================================
# Chave = identificador estável (histórico/tendências); Pontos = quanto o item tira da pontuação de saúde
# (padrão: Crítico 10, Atenção 4); Acao = o que fazer; Valor = número bruto guardado no histórico
Function Novo-ItemCheckup([string]$Area, [string]$Item, [string]$Resultado, [string]$Nivel = "OK", [string]$Chave = "", [int]$Pontos = -1, [string]$Acao = "", $Valor = $null) {
    if ($Pontos -lt 0) { $Pontos = switch ($Nivel) { 'Critico' { 10 } 'Atencao' { 4 } default { 0 } } }
    return [PSCustomObject]@{ Area = $Area; Item = $Item; Resultado = $Resultado; Nivel = $Nivel; Chave = $Chave; Pontos = $Pontos; Acao = $Acao; Valor = $Valor }
}

Function Contar-Eventos([hashtable]$Filtro) {
    try { return @(Get-WinEvent -FilterHashtable $Filtro -MaxEvents 1000 -ErrorAction Stop).Count } catch { return 0 }
}

# ---------- Saúde da bateria (notebooks) ----------
# Fonte principal: relatório XML nativo do Windows (powercfg /batteryreport /xml), independente do idioma.
# Alternativa: contadores WMI. Somente leitura. Retorna $null em computador sem bateria.
Function Obter-SaudeBateria {
    $Wmi = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($Wmi.Count -eq 0) { return $null }
    $B = [PSCustomObject]@{
        Fabricante = ""; Quimica = ""; ProjetadaMWh = 0; AtualMWh = 0; Saude = $null; Ciclos = $null
        Carga = $Wmi[0].EstimatedChargeRemaining; NaTomada = ($Wmi[0].BatteryStatus -in 2, 3, 6, 7, 8, 9, 11)
        AutonomiaAtual = $null; AutonomiaOriginal = $null; Historico = @(); Tendencia = $null
        Nivel = "Info"; Recomendacao = ""; Fonte = ""
    }
    $Arq = Join-Path $DirTemp ("bateria_{0}.xml" -f [guid]::NewGuid().ToString("N"))
    try {
        $null = Executar-Comando -Comando "$env:SystemRoot\System32\powercfg.exe" -Argumentos "/batteryreport /xml /output `"$Arq`"" -PodeCancelar $false -TimeoutMinutos 2
        if (Test-Path -LiteralPath $Arq) {
            [xml]$X = [IO.File]::ReadAllText($Arq)
            $Baterias = @($X.BatteryReport.Batteries.Battery)
            $B.ProjetadaMWh = [int64](($Baterias | ForEach-Object { [int64]$_.DesignCapacity } | Measure-Object -Sum).Sum)
            $B.AtualMWh = [int64](($Baterias | ForEach-Object { [int64]$_.FullChargeCapacity } | Measure-Object -Sum).Sum)
            $Ciclos = [int](($Baterias | ForEach-Object { [int]$_.CycleCount } | Measure-Object -Maximum).Maximum)
            if ($Ciclos -gt 0) { $B.Ciclos = $Ciclos }
            $B.Fabricante = (($Baterias | ForEach-Object { "$($_.Manufacturer)".Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ', ')
            $B.Quimica = "$($Baterias[0].Chemistry)".Trim()
            try { $B.AutonomiaAtual = [Xml.XmlConvert]::ToTimeSpan("$($X.BatteryReport.RuntimeEstimates.FullChargeCapacity.ActiveRuntime)") } catch {}
            try { $B.AutonomiaOriginal = [Xml.XmlConvert]::ToTimeSpan("$($X.BatteryReport.RuntimeEstimates.DesignCapacity.ActiveRuntime)") } catch {}
            $B.Historico = @($X.BatteryReport.History.HistoryEntry | Where-Object { [int64]$_.DesignCapacity -gt 0 -and [int64]$_.FullChargeCapacity -gt 0 } | ForEach-Object {
                [PSCustomObject]@{
                    Data = [datetime]::Parse($_.EndDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                    AtualMWh = [int64]$_.FullChargeCapacity
                    Saude = [math]::Min(100, [math]::Round([int64]$_.FullChargeCapacity / [int64]$_.DesignCapacity * 100))
                }
            } | Sort-Object Data)
            $B.Fonte = "Relatório de bateria do Windows"
        }
    } catch {} finally { Remove-Item -LiteralPath $Arq -Force -ErrorAction SilentlyContinue }

    if ($B.ProjetadaMWh -le 0 -or $B.AtualMWh -le 0) {
        try {
            $B.ProjetadaMWh = [int64](@(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)[0].DesignedCapacity)
            $B.AtualMWh = [int64](@(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)[0].FullChargedCapacity)
            try { $c = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop)[0].CycleCount; if ($c -gt 0) { $B.Ciclos = $c } } catch {}
            $B.Fonte = "Contadores do Windows (WMI)"
        } catch {}
    }
    if ($B.ProjetadaMWh -le 0 -or $B.AtualMWh -le 0) { return $B } # bateria presente, mas sem dados de capacidade

    $B.Saude = [int][math]::Min(100, [math]::Round($B.AtualMWh / $B.ProjetadaMWh * 100))
    $Autonomia = ""
    if ($B.AutonomiaAtual -and $B.AutonomiaAtual.TotalMinutes -gt 0) {
        $Autonomia = " Autonomia estimada com carga completa: $(Formatar-Duracao $B.AutonomiaAtual)"
        if ($B.AutonomiaOriginal -and $B.AutonomiaOriginal.TotalMinutes -gt 0) { $Autonomia += " (nova: $(Formatar-Duracao $B.AutonomiaOriginal))" }
        $Autonomia += "."
    }
    if ($B.Saude -ge 80) { $B.Nivel = "OK"; $B.Recomendacao = "Bateria em bom estado.$Autonomia" }
    elseif ($B.Saude -ge 60) { $B.Nivel = "Atencao"; $B.Recomendacao = "Desgaste natural: a autonomia já é menor.$Autonomia Planeje a troca quando ela não atender mais." }
    else { $B.Nivel = "Critico"; $B.Recomendacao = "Bateria bem desgastada: considere a troca.$Autonomia" }

    # Tendência: compara com cerca de 30 dias atrás (a capacidade oscila um pouco por calibração; só alerta acima de 3 pontos)
    $Antigo = @($B.Historico | Where-Object { $_.Data -le (Get-Date).AddDays(-25) }) | Select-Object -Last 1
    if ($Antigo) {
        $Dias = [math]::Round(((Get-Date) - $Antigo.Data).TotalDays)
        $Queda = $Antigo.Saude - $B.Saude
        if ($Queda -gt 3) { $B.Tendencia = @{ Nivel = "Atencao"; Texto = "A capacidade caiu $Queda pontos em $Dias dias ($($Antigo.Saude)% → $($B.Saude)%). Evite calor excessivo e manter a bateria sempre em 100%." } }
        else { $B.Tendencia = @{ Nivel = "OK"; Texto = "Estável: $($Antigo.Saude)% há $Dias dias, $($B.Saude)% hoje." } }
    }
    return $B
}

Function Formatar-Duracao([TimeSpan]$T) {
    $H = [math]::Floor($T.TotalHours)
    if ($H -ge 1) { return "{0} h {1:00} min" -f $H, $T.Minutes }
    return "{0} min" -f $T.Minutes
}

Function Executar-Checkup {
    $L = New-Object System.Collections.ArrayList
    $Desde = (Get-Date).AddDays(-30)

    # ---------- Memória RAM ----------
    try {
        $SO = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $UsoPct = [math]::Round((1 - $SO.FreePhysicalMemory / $SO.TotalVisibleMemorySize) * 100)
        $Pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $InstGB = if ($Pentes.Count -gt 0) { [math]::Round(($Pentes | Measure-Object Capacity -Sum).Sum / 1GB) } else { [math]::Round($SO.TotalVisibleMemorySize / 1MB) }
        $Vel = ($Pentes | Where-Object { $_.ConfiguredClockSpeed } | Select-Object -First 1).ConfiguredClockSpeed
        $Desc = "$InstGB GB instalados"
        if ($Pentes.Count -gt 0) { $Desc += " ($($Pentes.Count) módulo(s)$(if ($Vel) { ", $Vel MT/s" }))" }
        $Desc += "; $UsoPct% em uso agora."
        if ($UsoPct -ge 90) { [void]$L.Add((Novo-ItemCheckup "Memória" "Memória RAM" "$Desc Quase cheia: feche programas ou reduza os apps da inicialização." "Atencao" -Chave RAM -Pontos 3 -Acao "Feche programas pesados e reduza os apps da inicialização; avalie mais memória." -Valor $UsoPct)) }
        else { [void]$L.Add((Novo-ItemCheckup "Memória" "Memória RAM" $Desc -Chave RAM -Valor $UsoPct)) }
    } catch {}
    $PoucaMem = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = $Desde }
    if ($PoucaMem -gt 0) { [void]$L.Add((Novo-ItemCheckup "Memória" "Falta de memória (30 dias)" "O Windows ficou com pouca memória $PoucaMem vez(es). Feche programas pesados, revise a inicialização ou considere mais RAM." "Atencao" -Chave FaltaMemoria -Acao "Revise os programas da inicialização; se repetir, considere mais memória RAM." -Valor $PoucaMem)) }
    else { [void]$L.Add((Novo-ItemCheckup "Memória" "Falta de memória (30 dias)" "Nenhum episódio registrado." -Chave FaltaMemoria -Valor 0)) }
    try {
        $Ult = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction Stop
        $Quando = $Ult.TimeCreated.ToString('dd/MM/yyyy')
        if ($Ult.Id -in 1102, 1202 -or $Ult.Level -in 1, 2) { [void]$L.Add((Novo-ItemCheckup "Memória" "Teste de memória" "O último teste ($Quando) ENCONTROU erros na RAM. Memória com defeito corrompe arquivos: procure assistência técnica." "Critico" -Chave TesteRAM -Pontos 30 -Acao "Troque o módulo de memória com defeito (teste um módulo por vez para identificar).")) }
        else { [void]$L.Add((Novo-ItemCheckup "Memória" "Teste de memória" "Último teste em $Quando`: nenhum erro encontrado.")) }
    } catch { [void]$L.Add((Novo-ItemCheckup "Memória" "Teste de memória" "Nenhum teste registrado. Se houver travamentos ou telas azuis, use 'Agendar teste completo da memória RAM'." "Info")) }
    try {
        $Auto = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile
        $Pag = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if (-not $Auto -and $Pag.Count -eq 0) { [void]$L.Add((Novo-ItemCheckup "Memória" "Arquivo de paginação" "Desativado: programas podem fechar sozinhos por falta de memória. Recomendado: 'Gerenciar automaticamente'." "Atencao")) }
        elseif ($Auto) { [void]$L.Add((Novo-ItemCheckup "Memória" "Arquivo de paginação" "Gerenciado automaticamente pelo Windows.")) }
        else { [void]$L.Add((Novo-ItemCheckup "Memória" "Arquivo de paginação" "Configurado manualmente ($(($Pag | Measure-Object AllocatedBaseSize -Sum).Sum) MB)." "Info")) }
    } catch {}
    Atualizar-Tela

    # ---------- Estabilidade e hardware (log do sistema, últimos 30 dias) ----------
    $Blocos = Contar-Eventos @{ LogName = 'System'; ProviderName = 'disk'; Id = 7; StartTime = $Desde }
    $ErrDisco = (Contar-Eventos @{ LogName = 'System'; ProviderName = @('disk', 'Ntfs', 'stornvme', 'storahci', 'volmgr'); Level = @(1, 2); StartTime = $Desde }) +
                (Contar-Eventos @{ LogName = 'System'; ProviderName = 'disk'; Id = @(51, 153); StartTime = $Desde })
    if ($Blocos -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "$Blocos aviso(s) de bloco defeituoso e $ErrDisco evento(s) de erro de disco. Faça backup e acompanhe a saúde dos discos." "Critico" -Chave ErrosDisco -Pontos 15 -Acao "Faça backup agora e planeje a troca do disco." -Valor ($Blocos + $ErrDisco))) }
    elseif ($ErrDisco -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "$ErrDisco evento(s) de erro de disco ou do sistema de arquivos. Pode ser um cartão/USB removido sem segurança; se repetir, faça backup." "Atencao" -Chave ErrosDisco -Acao "Remova cartões/USB com segurança; se repetir, faça backup e verifique o disco." -Valor $ErrDisco)) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "Nenhum erro registrado." -Chave ErrosDisco -Valor 0)) }

    $WheaErro = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = @(1, 2); StartTime = $Desde }
    $WheaAviso = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 3; StartTime = $Desde }
    if ($WheaErro -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaErro erro(s) de hardware NÃO corrigido(s) (processador, memória ou barramento). Se repetir, procure assistência técnica." "Critico" -Chave WHEA -Pontos 15 -Acao "Verifique temperatura, fonte e memória; se repetir, procure assistência técnica." -Valor $WheaErro)) }
    elseif ($WheaAviso -ge 10) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaAviso erro(s) corrigido(s) automaticamente pelo hardware. Costuma ser inofensivo; acompanhe se aumentar." "Atencao" -Chave WHEA -Pontos 2 -Acao "Acompanhe nas próximas manutenções." -Valor $WheaAviso)) }
    elseif ($WheaAviso -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaAviso erro(s) corrigido(s) automaticamente pelo hardware (inofensivo)." "Info" -Chave WHEA -Valor $WheaAviso)) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "Nenhum erro registrado." -Chave WHEA -Valor 0)) }

    # Telas azuis: contagem pelos eventos + leitura nativa do cabeçalho dos dumps (código de parada e causa provável)
    $Telas = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Desde }
    $script:TelasAzuis = @(Analisar-Dumps $Desde)
    if ($Telas -lt $script:TelasAzuis.Count) { $Telas = $script:TelasAzuis.Count }
    if ($Telas -gt 0) {
        $Txt = "$Telas tela(s) azul(is)."
        $Causas = @($script:TelasAzuis | Group-Object Significado | Sort-Object Count -Descending)
        if ($Causas.Count -gt 0) { $Txt += " Causa provável pelos dumps: " + ((@($Causas | Select-Object -First 2) | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join '; ') + "." }
        else { $Txt += " Nenhum arquivo de dump disponível para analisar." }
        $AcaoBsod = if (@($script:TelasAzuis | Where-Object { $_.Significado -match 'RAM|memória' }).Count -gt 0) { "Agende o teste completo da memória RAM e verifique a temperatura." } else { "Atualize drivers (vídeo, chipset, armazenamento) e verifique a temperatura; se repetir, teste a memória." }
        [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Telas azuis (30 dias)" $Txt $(if ($Telas -ge 2) { "Critico" } else { "Atencao" }) -Chave TelasAzuis -Pontos $(if ($Telas -ge 2) { 15 } else { 8 }) -Acao $AcaoBsod -Valor $Telas))
    } else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Telas azuis (30 dias)" "Nenhuma registrada." -Chave TelasAzuis -Valor 0)) }

    $Quedas = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Desde }
    if ($Quedas -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Desligamentos inesperados (30 dias)" "$Quedas desligamento(s) sem encerramento correto (queda de energia, travamento ou botão de energia segurado)." "Atencao" -Chave Quedas -Pontos $(if ($Quedas -ge 3) { 5 } else { 2 }) -Acao "Use um estabilizador/nobreak e desligue sempre pelo menu Iniciar; se travar, investigue temperatura e memória." -Valor $Quedas)) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Desligamentos inesperados (30 dias)" "Nenhum registrado." -Chave Quedas -Valor 0)) }

    # Travamentos de programas (log de aplicativos, evento 1000)
    $Crash = @()
    try { $Crash = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $Desde } -MaxEvents 500 -ErrorAction Stop) } catch {}
    if ($Crash.Count -gt 0) {
        $Top = @($Crash | ForEach-Object { try { "$($_.Properties[0].Value)" } catch { "desconhecido" } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count)x)" })
        $NivelCrash = if ($Crash.Count -ge 20) { "Atencao" } else { "Info" }
        [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Travamentos de programas (30 dias)" "$($Crash.Count) travamento(s): $($Top -join ', ')." $NivelCrash -Chave Travamentos -Pontos $(if ($Crash.Count -ge 20) { 4 } else { 0 }) -Acao "Atualize ou reinstale os programas que mais travam; se forem vários, verifique memória e disco." -Valor $Crash.Count))
    } else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Travamentos de programas (30 dias)" "Nenhum registrado." -Chave Travamentos -Valor 0)) }

    try {
        $Prob = @(Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0" -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 })
        if ($Prob.Count -gt 0) {
            $Nomes = ($Prob | Select-Object -First 4 | ForEach-Object { if ($_.Name) { $_.Name } else { $_.PNPDeviceID } }) -join '; '
            [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Dispositivos e drivers" "$($Prob.Count) dispositivo(s) com erro: $Nomes. Veja no Gerenciador de Dispositivos." "Atencao" -Chave Dispositivos -Pontos 5 -Acao "Instale o driver do fabricante para os dispositivos com erro." -Valor $Prob.Count))
        } else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Dispositivos e drivers" "Todos os dispositivos funcionando." -Chave Dispositivos -Valor 0)) }
    } catch {}

    # Índice de estabilidade do próprio Windows (Monitor de Confiabilidade, 1 a 10)
    try {
        $Rac = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -Property SystemStabilityIndex, TimeGenerated -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1)
        if ($Rac.Count -gt 0 -and $null -ne $Rac[0].SystemStabilityIndex) {
            $Idx = [math]::Round([double]$Rac[0].SystemStabilityIndex, 1)
            $TxtIdx = "$($Idx.ToString('0.0')) de 10 (Monitor de Confiabilidade do Windows)"
            if ($Idx -lt 5) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Índice de estabilidade" "$TxtIdx. Falhas frequentes nos últimos dias." "Atencao" -Chave Estabilidade -Pontos 5 -Acao "Veja o Monitor de Confiabilidade (Painel de Controle > Segurança e Manutenção) para identificar o programa ou driver que falha." -Valor $Idx)) }
            else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Índice de estabilidade" "$TxtIdx." -Chave Estabilidade -Valor $Idx)) }
        }
    } catch {}

    # Tempo de inicialização (eventos 100 do Diagnostics-Performance: média dos últimos 5 boots)
    try {
        $Evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop)
        $Tempos = @()
        foreach ($E in $Evs) { if ($E.ToXml() -match '<Data Name="BootTime">(\d+)</Data>') { $Tempos += [int]$Matches[1] } }
        if ($Tempos.Count -gt 0) {
            $BootSeg = [int][math]::Round(($Tempos | Measure-Object -Average).Average / 1000)
            $TxtBoot = "Cerca de $BootSeg s até o Windows ficar pronto (média dos últimos $($Tempos.Count) boots)."
            if ($BootSeg -ge 120) { [void]$L.Add((Novo-ItemCheckup "Desempenho" "Tempo de inicialização" "$TxtBoot Lento." "Atencao" -Chave Boot -Pontos 5 -Acao "Desative programas da inicialização; se o disco for HD, um SSD é a maior melhoria possível." -Valor $BootSeg)) }
            elseif ($BootSeg -ge 60) { [void]$L.Add((Novo-ItemCheckup "Desempenho" "Tempo de inicialização" "$TxtBoot Pode melhorar." "Info" -Chave Boot -Acao "Desative programas da inicialização desnecessários." -Valor $BootSeg)) }
            else { [void]$L.Add((Novo-ItemCheckup "Desempenho" "Tempo de inicialização" $TxtBoot -Chave Boot -Valor $BootSeg)) }
        }
    } catch {}

    # Temperatura da zona térmica (ACPI): nem todo computador informa; só entra se o valor for plausível
    try {
        $Tz = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15) } | Where-Object { $_ -gt 10 -and $_ -lt 120 })
        if ($Tz.Count -gt 0) {
            $TMax = [int](($Tz | Measure-Object -Maximum).Maximum)
            if ($TMax -ge 90) { [void]$L.Add((Novo-ItemCheckup "Desempenho" "Temperatura (zona térmica)" "$TMax °C agora: alta." "Atencao" -Chave Temperatura -Pontos 3 -Acao "Limpe a poeira, verifique ventoinhas e, em notebooks, a pasta térmica." -Valor $TMax)) }
            else { [void]$L.Add((Novo-ItemCheckup "Desempenho" "Temperatura (zona térmica)" "$TMax °C agora." -Chave Temperatura -Valor $TMax)) }
        }
    } catch {}
    Atualizar-Tela

    # ---------- Bateria (notebooks) ----------
    $script:Bateria = Obter-SaudeBateria
    $script:BateriaLida = $true
    if ($script:Bateria) {
        $B = $script:Bateria
        if ($null -eq $B.Saude) { [void]$L.Add((Novo-ItemCheckup "Bateria" "Saúde da bateria" "O sistema não informou a capacidade da bateria." "Info")) }
        else {
            $Txt = "Capacidade atual: $($B.Saude)% da original"
            if ($B.Ciclos) { $Txt += " ($($B.Ciclos) ciclos de carga)" }
            [void]$L.Add((Novo-ItemCheckup "Bateria" "Saúde da bateria" "$Txt. $($B.Recomendacao)" $B.Nivel))
            if ($B.Tendencia) { [void]$L.Add((Novo-ItemCheckup "Bateria" "Desgaste recente" $B.Tendencia.Texto $B.Tendencia.Nivel)) }
        }
    }

    # ---------- Segurança ----------
    $Mp = $null
    try { $Mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $OutrosAV = @()
    try { $OutrosAV = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { $_.displayName -notmatch 'Defender' } | ForEach-Object { $_.displayName }) } catch {}
    if ($Mp -and $Mp.AntivirusEnabled -and $Mp.RealTimeProtectionEnabled) {
        if ($Mp.AntivirusSignatureAge -gt 7) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Microsoft Defender ativo, mas as definições têm $($Mp.AntivirusSignatureAge) dias. A tarefa do Defender atualiza." "Atencao" -Chave Antivirus -Acao "Rode a 'Verificação rápida de vírus' (atualiza as definições) ou conecte à internet.")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Microsoft Defender ativo, com proteção em tempo real." -Chave Antivirus)) }
    } elseif ($OutrosAV.Count -gt 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Antivírus ativo: $($OutrosAV -join ', ')." -Chave Antivirus)) }
    elseif ($Mp -and $Mp.AntivirusEnabled) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "A proteção em tempo real do Defender está DESLIGADA. Ligue em Segurança do Windows." "Critico" -Chave Antivirus -Pontos 20 -Acao "Ligue a proteção em tempo real em Segurança do Windows > Proteção contra vírus e ameaças.")) }
    else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Nenhum antivírus ativo foi encontrado." "Critico" -Chave Antivirus -Pontos 20 -Acao "Ative o Microsoft Defender (gratuito, já instalado) em Segurança do Windows.")) }

    try {
        $NomesPerfil = @{ Domain = 'Domínio'; Private = 'Privado'; Public = 'Público' }
        $Desl = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { "$($_.Enabled)" -eq 'False' } | ForEach-Object { $NomesPerfil["$($_.Name)"] })
        if ($Desl.Count -eq 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Ativo em todos os perfis de rede.")) }
        else {
            $FwTerc = @()
            try { $FwTerc = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch {}
            if ($FwTerc.Count -gt 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Firewall ativo: $($FwTerc -join ', ').")) }
            else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Firewall do Windows desligado nos perfis: $($Desl -join ', ')." "Critico" -Chave Firewall -Pontos 10 -Acao "Ligue o firewall em Segurança do Windows > Firewall e proteção de rede.")) }
        }
    } catch {}

    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Inicialização Segura" "Ativa.")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Inicialização Segura" "Desativada no firmware (UEFI). Ela protege contra malware que age antes do Windows." "Atencao" -Chave SecureBoot -Pontos 3 -Acao "Ative o Secure Boot nas configurações do UEFI (BIOS), se o sistema for compatível.")) }
    } catch { [void]$L.Add((Novo-ItemCheckup "Segurança" "Inicialização Segura" "Não suportada neste computador." "Info")) }

    try {
        $Tpm = Get-Tpm -ErrorAction Stop
        if ($Tpm.TpmPresent -and $Tpm.TpmReady) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Chip de segurança (TPM)" "Presente e pronto.")) }
        elseif ($Tpm.TpmPresent) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Chip de segurança (TPM)" "Presente, mas não está pronto para uso." "Atencao")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Chip de segurança (TPM)" "Não encontrado." "Info")) }
    } catch {}

    try {
        $Enc = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($Enc -and $Enc.ProtectionStatus -eq 1) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Criptografia do disco" "Ativa em $env:SystemDrive. Guarde a chave de recuperação (fica na sua conta Microsoft).")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Criptografia do disco" "Desativada em $env:SystemDrive." "Info")) }
    } catch { [void]$L.Add((Novo-ItemCheckup "Segurança" "Criptografia do disco" "Recurso não disponível nesta edição do Windows." "Info")) }
    Atualizar-Tela

    # ---------- Sistema ----------
    try {
        $Boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $Dias = [math]::Floor(((Get-Date) - $Boot).TotalDays)
        if ($Dias -ge 7) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Tempo sem reiniciar" "Ligado há $Dias dias sem reiniciar. Use 'Reiniciar': com a Inicialização Rápida, 'Desligar' não zera o sistema." "Atencao" -Chave Uptime -Pontos 3 -Acao "Reinicie o computador pelo menu Iniciar." -Valor $Dias)) }
        else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Tempo sem reiniciar" "Último reinício em $($Boot.ToString('dd/MM HH:mm'))." -Chave Uptime -Valor $Dias)) }
    } catch {}

    try {
        $Pontos = @(Get-ComputerRestorePoint -ErrorAction Stop)
        if ($Pontos.Count -eq 0) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Pontos de restauração" "Nenhum disponível. A tarefa 'Criar ponto de restauração' resolve." "Atencao" -Chave Restauracao -Acao "Rode a tarefa 'Criar ponto de restauração'.")) }
        else {
            $UltP = $Pontos[-1].ConvertToDateTime($Pontos[-1].CreationTime)
            [void]$L.Add((Novo-ItemCheckup "Sistema" "Pontos de restauração" "$($Pontos.Count) disponível(is); o mais recente em $($UltP.ToString('dd/MM/yyyy')).")) }
    } catch {}

    try {
        $UltWU = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
        if ($UltWU -and $UltWU.Year -gt 2000) {
            $DiasWU = [math]::Floor(((Get-Date).ToUniversalTime() - $UltWU).TotalDays)
            if ($DiasWU -gt 40) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Windows Update" "Última instalação bem-sucedida há $DiasWU dias. Rode a tarefa de atualizações." "Atencao" -Chave WindowsUpdate -Pontos 8 -Acao "Rode a tarefa 'Atualizações do Windows e drivers' ou abra o Windows Update." -Valor $DiasWU)) }
            else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Windows Update" "Última instalação bem-sucedida em $($UltWU.ToLocalTime().ToString('dd/MM/yyyy'))." -Chave WindowsUpdate -Valor $DiasWU)) }
        }
    } catch {}

    if (@(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.MediaType)" -eq 'SSD' }).Count -gt 0) {
        $R = Executar-Comando -Comando "$env:SystemRoot\System32\fsutil.exe" -Argumentos "behavior query DisableDeleteNotify" -PodeCancelar $false -TimeoutMinutos 2
        if ($R.Saida -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') {
            if ($Matches[1] -eq '0') { [void]$L.Add((Novo-ItemCheckup "Sistema" "TRIM do SSD" "Ativo: o SSD recebe a limpeza de blocos livres.")) }
            else { [void]$L.Add((Novo-ItemCheckup "Sistema" "TRIM do SSD" "Desativado: o SSD perde desempenho com o tempo. Para reativar: fsutil behavior set DisableDeleteNotify 0" "Atencao" -Chave TRIM -Pontos 5 -Acao "Reative o TRIM: fsutil behavior set DisableDeleteNotify 0")) }
        }
    }

    try {
        $TD = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        if ("$($TD.State)" -eq 'Disabled') { [void]$L.Add((Novo-ItemCheckup "Sistema" "Otimização automática" "A otimização agendada das unidades está desativada no Windows." "Atencao" -Chave Defrag -Pontos 2 -Acao "Reative em Otimizar Unidades > Alterar configurações.")) }
        else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Otimização automática" "Ativa (o Windows otimiza as unidades sozinho).")) }
    } catch {}

    # ---------- Windows: versão, fim do suporte e ativação ----------
    try {
        $Cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $Build = [int]$Cv.CurrentBuildNumber
        $Disp = "$($Cv.DisplayVersion)"; if (-not $Disp) { $Disp = "$($Cv.ReleaseId)" }
        $Caption = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption)".Replace('Microsoft ', '')
        $DescWin = "$Caption $Disp (compilação $Build.$($Cv.UBR))"
        $EdicaoEspecial = ("$($Cv.EditionID)" -match 'Enterprise|LTSC|Server|Education')
        # Fim do suporte das edições Home/Pro (lifecycle da Microsoft); compilações mais novas que a tabela são consideradas suportadas
        $FimSuporte = switch ($Build) { 19041 { '2021-12-14' } 19042 { '2022-05-10' } 19043 { '2022-12-13' } 19044 { '2023-06-13' } 19045 { '2025-10-14' } 22000 { '2023-10-10' } 22621 { '2024-10-08' } 22631 { '2025-11-11' } 26100 { '2026-10-13' } 26200 { '2027-10-12' } default { $null } }
        if ($EdicaoEspecial) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin. Edição corporativa/LTSC: o prazo de suporte é diferente das edições Home/Pro." "Info" -Chave Windows)) }
        elseif ($Build -lt 19041) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin. Esta versão não recebe atualizações de segurança há anos." "Critico" -Chave Windows -Pontos 15 -Acao "Atualize para uma versão com suporte (Windows 11, se o PC for compatível).")) }
        elseif ($FimSuporte) {
            $DataFim = [datetime]::ParseExact($FimSuporte, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $DiasFim = ($DataFim - (Get-Date).Date).Days
            if ($DiasFim -lt 0) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin. O suporte das edições Home/Pro terminou em $($DataFim.ToString('dd/MM/yyyy')): sem atualizações de segurança desde então (salvo ESU)." "Critico" -Chave Windows -Pontos 15 -Acao $(if ($Build -lt 22000) { "Atualize para o Windows 11 (se o PC for compatível) ou ative o ESU do Windows 10." } else { "Instale a versão mais nova do Windows 11 pelo Windows Update." }))) }
            elseif ($DiasFim -le 90) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin. O suporte termina em $($DataFim.ToString('dd/MM/yyyy')) ($DiasFim dias)." "Atencao" -Chave Windows -Pontos 3 -Acao "Planeje a atualização de versão pelo Windows Update.")) }
            else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin. Com suporte até $($DataFim.ToString('dd/MM/yyyy'))." -Chave Windows)) }
        } else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Versão do Windows" "$DescWin." -Chave Windows)) }
    } catch {}
    $Ativ = Obter-AtivacaoWindows
    if ($Ativ) {
        if ($Ativ.Ativado) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Ativação do Windows" "$($Ativ.Texto)." -Chave Ativacao)) }
        else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Ativação do Windows" "$($Ativ.Texto). Sem ativação, a licença fica irregular e personalizações são bloqueadas." "Atencao" -Chave Ativacao -Pontos 5 -Acao "Ative o Windows com uma licença válida (Configurações > Sistema > Ativação).")) }
    }

    # ---------- Internet (só informa; um computador de bancada pode estar sem rede) ----------
    try {
        $Ping = New-Object System.Net.NetworkInformation.Ping
        $Lat = $null
        foreach ($Alvo in '1.1.1.1', '8.8.8.8') { try { $Resp = $Ping.Send($Alvo, 1500); if ($Resp.Status -eq 'Success') { $Lat = $Resp.RoundtripTime; break } } catch {} }
        $Dns = $false
        if ($null -ne $Lat) { try { $null = [System.Net.Dns]::GetHostAddresses('www.microsoft.com'); $Dns = $true } catch {} }
        if ($null -eq $Lat) { [void]$L.Add((Novo-ItemCheckup "Rede" "Internet" "Sem resposta da internet agora (sem conexão ou bloqueio de ping)." "Info" -Chave Internet)) }
        elseif (-not $Dns) { [void]$L.Add((Novo-ItemCheckup "Rede" "Internet" "Conecta ($Lat ms), mas a resolução de nomes (DNS) falhou: sites não abrem pelo nome." "Atencao" -Chave Internet -Pontos 3 -Acao "Rode 'Limpar cache DNS'; se persistir, use o DNS 1.1.1.1 ou 8.8.8.8 no adaptador de rede." -Valor $Lat)) }
        elseif ($Lat -ge 150) { [void]$L.Add((Novo-ItemCheckup "Rede" "Internet" "Conectada, latência alta ($Lat ms)." "Info" -Chave Internet -Valor $Lat)) }
        else { [void]$L.Add((Novo-ItemCheckup "Rede" "Internet" "Conectada ($Lat ms)." -Chave Internet -Valor $Lat)) }
    } catch {}

    return $L
}

# ==========================================
# TELAS AZUIS: leitura nativa do cabeçalho dos dumps (código de parada e causa provável), sem ferramentas externas
# ==========================================
$script:SignificadoBugcheck = @{
    '0xA'   = 'IRQL_NOT_LESS_OR_EQUAL: driver ou RAM'
    '0x1A'  = 'MEMORY_MANAGEMENT: forte indício de RAM defeituosa'
    '0x1E'  = 'KMODE_EXCEPTION_NOT_HANDLED: driver'
    '0x3B'  = 'SYSTEM_SERVICE_EXCEPTION: driver'
    '0x4E'  = 'PFN_LIST_CORRUPT: RAM ou driver'
    '0x50'  = 'PAGE_FAULT_IN_NONPAGED_AREA: RAM ou driver'
    '0x7A'  = 'KERNEL_DATA_INPAGE_ERROR: disco/cabo ou RAM'
    '0x7E'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: driver'
    '0x9F'  = 'DRIVER_POWER_STATE_FAILURE: driver/energia'
    '0xC2'  = 'BAD_POOL_CALLER: driver'
    '0xD1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver'
    '0xEF'  = 'CRITICAL_PROCESS_DIED: processo essencial encerrado (disco, RAM ou arquivo do sistema)'
    '0xF4'  = 'CRITICAL_OBJECT_TERMINATION: disco ou arquivo do sistema'
    '0xF7'  = 'DRIVER_OVERRAN_STACK_BUFFER: driver, mas também corrupção de memória'
    '0x101' = 'CLOCK_WATCHDOG_TIMEOUT: CPU/BIOS'
    '0x109' = 'CRITICAL_STRUCTURE_CORRUPTION: RAM ou driver'
    '0x116' = 'VIDEO_TDR_FAILURE: driver de vídeo ou placa de vídeo'
    '0x117' = 'VIDEO_TDR_TIMEOUT_DETECTED: driver de vídeo ou placa de vídeo'
    '0x124' = 'WHEA_UNCORRECTABLE_ERROR: hardware (CPU/RAM)'
    '0x133' = 'DPC_WATCHDOG_VIOLATION: driver (armazenamento/rede) ou firmware do SSD'
    '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE: driver ou RAM'
    '0x13A' = 'KERNEL_MODE_HEAP_CORRUPTION: corrupção de memória (RAM ou driver)'
    '0x154' = 'UNEXPECTED_STORE_EXCEPTION: disco ou RAM'
    '0x1C6' = 'FAST_ERASE_OR_CORRUPTION'
    '0xC000021A' = 'STATUS_SYSTEM_PROCESS_TERMINATED: arquivo do sistema ou driver'
}

Function Analisar-Dumps([datetime]$Desde) {
    $Lista = @()
    $Arqs = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Desde })
    $Mem = Get-Item "$env:SystemRoot\MEMORY.DMP" -ErrorAction SilentlyContinue
    if ($Mem -and $Mem.LastWriteTime -ge $Desde) { $Arqs += $Mem }
    foreach ($D in @($Arqs | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
        try {
            $FS = [IO.File]::Open($D.FullName, 'Open', 'Read', 'ReadWrite')
            try { $B = New-Object byte[] 96; $n = $FS.Read($B, 0, 96) } finally { $FS.Close() }
            if ($n -lt 96) { continue }
            $Assinatura = [Text.Encoding]::ASCII.GetString($B, 0, 8)
            if ($Assinatura -eq 'PAGEDU64') { $Cod = [BitConverter]::ToUInt32($B, 56); $P1 = [BitConverter]::ToUInt64($B, 64) }
            elseif ($Assinatura.StartsWith('PAGEDUMP')) { $Cod = [BitConverter]::ToUInt32($B, 40); $P1 = [uint64][BitConverter]::ToUInt32($B, 44) }
            else { continue }
            $Hex = '0x{0:X}' -f $Cod
            $Sig = $script:SignificadoBugcheck[$Hex]
            if (-not $Sig) { $Sig = "código $Hex (consulte a documentação de bug check)" }
            $Lista += [PSCustomObject]@{ Data = $D.LastWriteTime; Arquivo = $D.Name; Codigo = $Hex; Significado = $Sig; Parametro1 = ('0x{0:X}' -f $P1) }
        } catch {}
    }
    return $Lista
}

# ==========================================
# FICHA TÉCNICA (inventário de hardware e do Windows; somente leitura)
# ==========================================
Function Obter-AtivacaoWindows {
    try {
        $Lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -Property LicenseStatus, LicenseFamily, Description -ErrorAction Stop)
        $Ativo = @($Lic | Where-Object { $_.LicenseStatus -eq 1 }) | Select-Object -First 1
        if ($Ativo) {
            $Canal = if ("$($Ativo.Description)" -match 'OEM') { 'OEM (veio com o computador)' } elseif ("$($Ativo.Description)" -match 'RETAIL') { 'de varejo' } elseif ("$($Ativo.Description)" -match 'VOLUME|KMS') { 'de volume (empresa)' } else { '' }
            return [PSCustomObject]@{ Ativado = $true; Texto = ("Windows ativado" + $(if ($Canal) { " · licença $Canal" })) }
        }
        if ($Lic.Count -gt 0) {
            $Nomes = @{ 0 = 'não licenciado'; 2 = 'período de carência encerrado'; 3 = 'em carência'; 4 = 'não genuíno'; 5 = 'ativação pendente'; 6 = 'carência estendida' }
            $St = [int]$Lic[0].LicenseStatus
            $Desc = if ($Nomes.ContainsKey($St)) { $Nomes[$St] } else { "status $St" }
            return [PSCustomObject]@{ Ativado = $false; Texto = "Windows NÃO ativado ($Desc)" }
        }
    } catch {}
    return $null
}

Function Obter-Inventario {
    $Inv = [ordered]@{}
    $Add = { param($Grupo, $Nome, $Valor)
        $V = ("$Valor" -replace '\s+', ' ').Trim()
        if (-not $V) { return }
        if (-not $Inv.Contains($Grupo)) { $Inv[$Grupo] = [ordered]@{} }
        $Inv[$Grupo][$Nome] = $V
    }
    try {
        $CS = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        & $Add "Computador" "Fabricante e modelo" "$($CS.Manufacturer) $($CS.Model)"
        if ($CS.SystemFamily -and "$($CS.SystemFamily)" -ne "$($CS.Model)") { & $Add "Computador" "Família" $CS.SystemFamily }
        & $Add "Computador" "Tipo" $(if ($CS.PCSystemType -eq 2) { "Notebook / portátil" } else { "Desktop" })
        & $Add "Computador" "Nome na rede" $env:COMPUTERNAME
    } catch {}
    try {
        $Bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        & $Add "Computador" "Número de série" $Bios.SerialNumber
        $DataBios = if ($Bios.ReleaseDate -is [datetime]) { " (" + $Bios.ReleaseDate.ToString('dd/MM/yyyy') + ")" } else { "" }
        & $Add "Placa-mãe e BIOS" "BIOS / UEFI" "$($Bios.SMBIOSBIOSVersion)$DataBios"
    } catch {}
    try { $BB = Get-CimInstance Win32_BaseBoard -ErrorAction Stop; & $Add "Placa-mãe e BIOS" "Placa-mãe" "$($BB.Manufacturer) $($BB.Product)" } catch {}
    if ($env:firmware_type) { & $Add "Placa-mãe e BIOS" "Modo de inicialização" $(if ($env:firmware_type -eq 'UEFI') { "UEFI" } else { "Legado (BIOS)" }) }
    try {
        foreach ($C in @(Get-CimInstance Win32_Processor -ErrorAction Stop)) {
            & $Add "Processador" "CPU" ("{0} · {1} núcleos / {2} threads · até {3:N2} GHz" -f "$($C.Name)".Trim(), $C.NumberOfCores, $C.NumberOfLogicalProcessors, ($C.MaxClockSpeed / 1000))
        }
    } catch {}
    try {
        $TiposRam = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
        $Mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($Mods.Count -gt 0) {
            & $Add "Memória RAM" "Total" "$([math]::Round(($Mods | Measure-Object Capacity -Sum).Sum / 1GB)) GB em $($Mods.Count) módulo(s)"
            $n = 0
            foreach ($M in $Mods) {
                $n++
                $Tipo = $TiposRam[[int]$M.SMBIOSMemoryType]; if (-not $Tipo) { $Tipo = "" }
                $Vel = if ($M.ConfiguredClockSpeed) { "$($M.ConfiguredClockSpeed) MT/s" } elseif ($M.Speed) { "$($M.Speed) MT/s" } else { "" }
                $Fab = "$($M.Manufacturer)".Trim(); if ($Fab -match '^(Unknown|0+)$') { $Fab = "" }
                & $Add "Memória RAM" "Módulo $n ($($M.DeviceLocator))" ("{0} GB {1} {2} {3} {4}" -f [math]::Round($M.Capacity / 1GB), $Tipo, $Vel, $Fab, "$($M.PartNumber)".Trim())
            }
        }
    } catch {}
    try {
        foreach ($G in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            $DrvData = if ($G.DriverDate -is [datetime]) { " de " + $G.DriverDate.ToString('dd/MM/yyyy') } else { "" }
            & $Add "Vídeo" "$($G.Name)" "driver $($G.DriverVersion)$DrvData"
        }
    } catch {}
    try {
        foreach ($D in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $Fw = if ($D.FirmwareVersion) { " · firmware $("$($D.FirmwareVersion)".Trim())" } else { "" }
            $Ser = if ($D.SerialNumber) { " · série $("$($D.SerialNumber)".Trim())" } else { "" }
            & $Add "Armazenamento" "$($D.FriendlyName)" ("{0} {1} · {2} GB{3}{4}" -f $D.MediaType, $D.BusType, [math]::Round($D.Size / 1GB), $Fw, $Ser)
        }
    } catch {}
    try {
        foreach ($Mon in @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction Stop)) {
            $NomeMon = (-join ([char[]]@($Mon.UserFriendlyName | Where-Object { $_ -gt 0 }))).Trim()
            $FabMon = (-join ([char[]]@($Mon.ManufacturerName | Where-Object { $_ -gt 0 }))).Trim()
            if (-not $NomeMon) { $NomeMon = "Monitor" }
            & $Add "Monitores" $NomeMon ("{0}{1}" -f $FabMon, $(if ($Mon.YearOfManufacture -gt 2000) { " · fabricado em $($Mon.YearOfManufacture)" } else { "" }))
        }
    } catch {}
    try {
        foreach ($A in @(Get-NetAdapter -Physical -ErrorAction Stop | Sort-Object Status -Descending)) {
            $Estado = if ("$($A.Status)" -eq 'Up') { "conectado" } elseif ("$($A.Status)" -eq 'Disconnected') { "desconectado" } else { "$($A.Status)" }
            & $Add "Rede" "$($A.Name)" "$($A.InterfaceDescription) · $Estado · $($A.LinkSpeed) · MAC $($A.MacAddress)"
        }
    } catch {}
    try {
        $SO = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $Cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $Disp = "$($Cv.DisplayVersion)"; if (-not $Disp) { $Disp = "$($Cv.ReleaseId)" }
        & $Add "Windows" "Sistema" ("{0} {1} (compilação {2}.{3}) · {4}" -f "$($SO.Caption)".Replace('Microsoft ', ''), $Disp, $Cv.CurrentBuildNumber, $Cv.UBR, $SO.OSArchitecture)
        if ($SO.InstallDate -is [datetime]) { & $Add "Windows" "Instalado em" $SO.InstallDate.ToString('dd/MM/yyyy') }
        $Ativ = Obter-AtivacaoWindows
        if ($Ativ) { & $Add "Windows" "Ativação" $Ativ.Texto }
        $Progs = @()
        foreach ($K in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            $Progs += @(Get-ItemProperty $K -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } | ForEach-Object { "$($_.DisplayName)" })
        }
        & $Add "Windows" "Programas instalados" "$(@($Progs | Select-Object -Unique).Count)"
        & $Add "Windows" "Usuário" "$env:USERDOMAIN\$env:USERNAME"
    } catch {}
    return $Inv
}

# ==========================================
# PONTUAÇÃO DE SAÚDE (0 a 100): cada ponto perdido tem motivo e ação. Só usa dados lidos (nada inflado).
# ==========================================
Function Calcular-Pontuacao {
    param ($Checkup, $Discos, $Unidades, $Metricas, $Ameacas)
    $Perdas = New-Object System.Collections.ArrayList
    $Perder = { param($Area, $Pontos, $Motivo, $Acao) [void]$Perdas.Add([PSCustomObject]@{ Area = $Area; Pontos = [int]$Pontos; Motivo = $Motivo; Acao = $Acao }) }
    foreach ($I in @($Checkup)) {
        if ($I.Pontos -gt 0) { & $Perder $I.Area $I.Pontos "$($I.Item): $($I.Resultado)" $I.Acao }
    }
    foreach ($D in @($Discos)) {
        if ($D.SemSmart) { continue }
        if ($D.Saude -and $D.Saude -ne 'Healthy') { & $Perder "Discos" 30 "$($D.Nome): o Windows marca o disco como '$($D.Saude)'." "Faça backup imediatamente e planeje a troca do disco." }
        if ($null -ne $D.Desgaste -and $D.Desgaste -ge 80) { & $Perder "Discos" 15 "$($D.Nome): $($D.Desgaste)% da vida útil consumida." "Mantenha backup em dia e planeje a troca." }
        elseif ($null -ne $D.Desgaste -and $D.Desgaste -ge 60) { & $Perder "Discos" 5 "$($D.Nome): $($D.Desgaste)% da vida útil consumida." "Acompanhe o desgaste a cada manutenção." }
        if ($D.ErrosLeitura -gt 0 -or $D.ErrosEscrita -gt 0) { & $Perder "Discos" 10 "$($D.Nome): erros não corrigidos ($($D.ErrosLeitura) de leitura / $($D.ErrosEscrita) de escrita)." "Faça backup; verifique cabo e porta; se persistir, troque o disco." }
        if ($null -ne $D.Temperatura -and $D.Temperatura -ge 70) { & $Perder "Discos" 5 "$($D.Nome): temperatura alta ($($D.Temperatura) °C)." "Verifique ventilação e poeira." }
    }
    foreach ($U in @($Unidades)) {
        if ($U.Removivel) { continue } # cartão/USB cheio ou com erro não é saúde do computador (o laudo avisa à parte)
        $Min = if ($U.Sistema) { 15 } else { 10 }
        if ($U.PercLivre -lt 5) { & $Perder "Espaço" $(if ($U.Sistema) { 15 } else { 5 }) "$($U.Letra): só $($U.PercLivre)% livre." "Libere espaço (limpeza, Downloads antigos, programas sem uso)." }
        elseif ($U.PercLivre -lt $Min) { & $Perder "Espaço" $(if ($U.Sistema) { 8 } else { 3 }) "$($U.Letra): $($U.PercLivre)% livre (ideal: acima de $Min%)." "Libere espaço para preservar desempenho e a vida útil do SSD." }
        if ($U.Saude -and $U.Saude -ne 'Healthy') { & $Perder "Discos" 15 "$($U.Letra): volume marcado como '$($U.Saude)'." "Faça backup dos arquivos dessa unidade." }
    }
    if (@($Ameacas).Count -gt 0) { & $Perder "Segurança" 20 "Ameaças detectadas: $(@($Ameacas) -join ', ')." "Confira a quarentena em Segurança do Windows e evite reabrir os arquivos." }
    if ($Metricas) {
        if ($Metricas.Inicializacao -gt 15) { & $Perder "Desempenho" 8 "$($Metricas.Inicializacao) programas abrem junto com o Windows." "Desative os desnecessários em Ferramentas > Inicialização." }
        elseif ($Metricas.Inicializacao -gt 10) { & $Perder "Desempenho" 4 "$($Metricas.Inicializacao) programas abrem junto com o Windows." "Desative os desnecessários em Ferramentas > Inicialização." }
        if ($Metricas.ReinicioPendente) { & $Perder "Sistema" 2 "Há um reinício pendente." "Reinicie o computador para concluir reparos e atualizações." }
    }
    $Total = 0; foreach ($P in $Perdas) { $Total += $P.Pontos }
    $Nota = [int][math]::Max(0, 100 - $Total)
    $Rotulo = if ($Nota -ge 90) { "Excelente" } elseif ($Nota -ge 75) { "Bom" } elseif ($Nota -ge 50) { "Atenção" } else { "Crítico" }
    $Nivel = if ($Nota -ge 75) { "OK" } elseif ($Nota -ge 50) { "Atencao" } else { "Critico" }
    return [PSCustomObject]@{ Nota = $Nota; Rotulo = $Rotulo; Nivel = $Nivel; Perdas = @($Perdas | Sort-Object Pontos -Descending) }
}

Function Descrever-Nota([int]$Nota) {
    if ($Nota -ge 90) { return "Excelente" } elseif ($Nota -ge 75) { return "Bom" } elseif ($Nota -ge 50) { return "Atenção" } else { return "Crítico" }
}

# ==========================================
# HISTÓRICO (historico.json): uma entrada por execução, para evolução e comparação entre manutenções
# ==========================================
Function Ler-Historico {
    if (-not (Test-Path $HistoricoFile)) { return @() }
    try {
        $Lido = Get-Content $HistoricoFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($Lido | Where-Object { $_ -and $_.Data } | Sort-Object Data)
    } catch { return @() }
}

Function Gravar-EntradaHistorico([object]$Entrada) {
    $Lista = @(Ler-Historico) + @($Entrada)
    if ($Lista.Count -gt 100) { $Lista = @($Lista | Select-Object -Last 100) }
    try { ConvertTo-Json -InputObject $Lista -Depth 6 | Set-Content -Path $HistoricoFile -Encoding UTF8 } catch {}
}

Function Obter-UltimaEntradaHistorico {
    $H = @(Ler-Historico)
    if ($H.Count -eq 0) { return $null }
    return $H[-1]
}

# Entradas que têm pontuação (uma execução Personalizada sem check-up não tem nota e não deve esconder a última avaliação)
Function Obter-EntradasComNota {
    return @(Ler-Historico | Where-Object { $null -ne $_.Nota -and "$($_.Nota)" -ne "" })
}

# Quatro indicadores resumidos (discos, segurança, estabilidade, espaço) para o painel Início e o histórico
Function Obter-Indicadores {
    $Ind = @()
    $Pior = { param($Niveis) if ($Niveis -contains 'Critico') { 'Critico' } elseif ($Niveis -contains 'Atencao') { 'Atencao' } else { 'OK' } }
    $NivD = @(); $TxtD = @()
    foreach ($D in @($script:SaudeDiscos)) {
        if ($D.SemSmart) { continue }
        if ($D.Saude -and $D.Saude -ne 'Healthy') { $NivD += 'Critico' }
        if (($null -ne $D.Desgaste -and $D.Desgaste -ge 80) -or $D.ErrosLeitura -gt 0 -or $D.ErrosEscrita -gt 0 -or ($null -ne $D.Temperatura -and $D.Temperatura -ge 70)) { $NivD += 'Atencao' }
        if ($null -ne $D.Desgaste) { $TxtD += "desgaste $($D.Desgaste)%" }
        if ($null -ne $D.Temperatura) { $TxtD += "$($D.Temperatura) °C" }
    }
    foreach ($U in @($script:MetricasDepois.Unidades)) { if (-not $U.Removivel -and $U.Saude -and $U.Saude -ne 'Healthy') { $NivD += 'Critico' } }
    if (@($script:SaudeDiscos).Count -gt 0) {
        $Ind += [PSCustomObject]@{ Chave = 'Discos'; Titulo = 'Discos'; Nivel = (& $Pior $NivD); Texto = $(if ($TxtD.Count -gt 0) { (@($TxtD | Select-Object -First 2) -join ' · ') } else { 'saudáveis (sem SMART disponível)' }) }
    }
    $Seg = @($script:Checkup | Where-Object { $_.Area -eq 'Segurança' })
    if ($Seg.Count -gt 0) {
        $NivS = @($Seg | ForEach-Object { $_.Nivel }); if (@($script:Ameacas).Count -gt 0) { $NivS += 'Critico' }
        $Pontos = @($Seg | Where-Object { $_.Nivel -in 'Critico', 'Atencao' } | ForEach-Object { $_.Item })
        $Ind += [PSCustomObject]@{ Chave = 'Seguranca'; Titulo = 'Segurança'; Nivel = (& $Pior $NivS); Texto = $(if (@($script:Ameacas).Count -gt 0) { "ameaças detectadas pelo antivírus" } elseif ($Pontos.Count -gt 0) { "atenção: $(@($Pontos | Select-Object -First 2) -join ', ')" } else { "antivírus e firewall ativos" }) }
    }
    $Est = @($script:Checkup | Where-Object { $_.Area -eq 'Estabilidade' })
    if ($Est.Count -gt 0) {
        $Pontos = @($Est | Where-Object { $_.Nivel -in 'Critico', 'Atencao' } | ForEach-Object { ($_.Item -replace ' \(30 dias\)', '').ToLower() })
        $Ind += [PSCustomObject]@{ Chave = 'Estabilidade'; Titulo = 'Estabilidade'; Nivel = (& $Pior @($Est | ForEach-Object { $_.Nivel })); Texto = $(if ($Pontos.Count -gt 0) { (@($Pontos | Select-Object -First 2) -join ', ') } else { "sem telas azuis nem erros em 30 dias" }) }
    }
    $Sis = @($script:MetricasDepois.Unidades | Where-Object { $_.Sistema }) | Select-Object -First 1
    if ($Sis) {
        $NivE = if ($Sis.PercLivre -lt 5) { 'Critico' } elseif ($Sis.PercLivre -lt 15) { 'Atencao' } else { 'OK' }
        $Ind += [PSCustomObject]@{ Chave = 'Espaco'; Titulo = "Espaço em $($Sis.Letra):"; Nivel = $NivE; Texto = "$(Formatar-Pct $Sis.PercLivre) livre · $(Formatar-Tamanho $Sis.LivreBytes)" }
    }
    return $Ind
}

Function Novo-EntradaHistorico {
    param ([string]$NomePerfil, [string]$Modo, [timespan]$Duracao, [int64]$Liberado)
    $Depois = $script:MetricasDepois
    $Sis = @($Depois.Unidades | Where-Object { $_.Sistema }) | Select-Object -First 1
    $DesgMax = $null; $TempMax = $null
    foreach ($D in @($script:SaudeDiscos)) {
        if ($null -ne $D.Desgaste -and ($null -eq $DesgMax -or $D.Desgaste -gt $DesgMax)) { $DesgMax = $D.Desgaste }
        if ($null -ne $D.Temperatura -and ($null -eq $TempMax -or $D.Temperatura -gt $TempMax)) { $TempMax = $D.Temperatura }
    }
    $ValorChave = { param($Chave) $I = @($script:Checkup | Where-Object { $_.Chave -eq $Chave }) | Select-Object -First 1; if ($I) { $I.Valor } else { $null } }
    return [PSCustomObject]@{
        Data = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); Perfil = $NomePerfil; Modo = $Modo; Versao = $script:Versao; Computador = $env:COMPUTERNAME
        Nota = $(if ($script:Pontuacao) { $script:Pontuacao.Nota } else { $null })
        Duracao = [int]$Duracao.TotalSeconds; LiberadoBytes = $Liberado
        Ok = @($script:RelatorioTarefas | Where-Object Status -eq "Sucesso").Count
        Aviso = @($script:RelatorioTarefas | Where-Object Status -eq "Aviso").Count
        Erro = @($script:RelatorioTarefas | Where-Object Status -eq "Erro").Count
        LivrePct = $(if ($Sis) { $Sis.PercLivre } else { $null }); LivreBytes = $(if ($Sis) { $Sis.LivreBytes } else { $null })
        Desgaste = $DesgMax; Temperatura = $TempMax
        Bateria = $(if ($script:Bateria -and $null -ne $script:Bateria.Saude) { $script:Bateria.Saude } else { $null })
        TelasAzuis = (& $ValorChave 'TelasAzuis'); Boot = (& $ValorChave 'Boot'); Estabilidade = (& $ValorChave 'Estabilidade')
        Inicializacao = $Depois.Inicializacao; Ameacas = @($script:Ameacas).Count
        Laudo = "$($script:ReportFile)"; Cliente = "$($script:Atendimento.Cliente)"; OS = "$($script:Atendimento.OS)"
        Perdas = @($(if ($script:Pontuacao) { $script:Pontuacao.Perdas | Select-Object -First 8 | ForEach-Object { [PSCustomObject]@{ Pontos = [int]$_.Pontos; Motivo = "$($_.Motivo)"; Acao = "$($_.Acao)"; Area = "$($_.Area)" } } }))
        Indicadores = @(Obter-Indicadores)
    }
}

# Compara a execução mais recente com a anterior (o que melhorou e o que piorou)
Function Obter-Tendencias {
    $H = @(Ler-Historico)
    if ($H.Count -lt 2) { return @() }
    $Ult = $H[-1]; $Ant = $H[-2]
    $Itens = @(
        @{ Nome = "Pontuação de saúde"; Campo = "Nota"; Unidade = ""; MaiorMelhor = $true }
        @{ Nome = "Espaço livre em $env:SystemDrive"; Campo = "LivrePct"; Unidade = "%"; MaiorMelhor = $true }
        @{ Nome = "Desgaste do SSD"; Campo = "Desgaste"; Unidade = "%"; MaiorMelhor = $false }
        @{ Nome = "Saúde da bateria"; Campo = "Bateria"; Unidade = "%"; MaiorMelhor = $true }
        @{ Nome = "Tempo de inicialização"; Campo = "Boot"; Unidade = " s"; MaiorMelhor = $false }
        @{ Nome = "Telas azuis (30 dias)"; Campo = "TelasAzuis"; Unidade = ""; MaiorMelhor = $false }
        @{ Nome = "Programas na inicialização"; Campo = "Inicializacao"; Unidade = ""; MaiorMelhor = $false }
    )
    $T = @()
    foreach ($I in $Itens) {
        $A = $Ant.($I.Campo); $U = $Ult.($I.Campo)
        if ($null -eq $A -or $null -eq $U -or "$A" -eq "" -or "$U" -eq "") { continue }
        $Delta = [math]::Round([double]$U - [double]$A, 1)
        $Melhorou = if ($Delta -eq 0) { $null } elseif ($I.MaiorMelhor) { $Delta -gt 0 } else { $Delta -lt 0 }
        $T += [PSCustomObject]@{ Nome = $I.Nome; Antes = $A; Agora = $U; Delta = $Delta; Unidade = $I.Unidade; Melhorou = $Melhorou; Desde = ([datetime]$Ant.Data).ToString('dd/MM/yyyy') }
    }
    return $T
}

# ==========================================
# TABELA DE TAREFAS
# Perfis: Rapida (semanal), Completa (mensal), Reparo (quando há problemas)
# Auto = pode rodar no modo automático/agendado (sem ninguém na frente do PC)
# Critica = Pausar/Cancelar ficam bloqueados (interromper seria perigoso)
# Grupo/Resumo = como aparece na interface; Dica = detalhes (ao passar o mouse); Selo = etiqueta de alerta
# A ordem da tabela é a ordem de execução (backup e diagnóstico primeiro; DISM antes do SFC).
# ==========================================
$script:Grupos = @("Diagnóstico", "Proteção", "Limpeza", "Reparo", "Atualizações", "Desempenho")
$script:Tarefas = @(
    @{ Id = "Restore"; Grupo = "Proteção"; Nome = "Criar ponto de restauração"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 3
       Resumo = "Salva o estado do sistema antes de qualquer mudança."
       Dica = "Salva o estado do sistema antes das mudanças. Ativa a Proteção do Sistema em C: se estiver desligada. No Windows 11 24H2 em diante, o próprio Windows apaga pontos com mais de 60 dias."
       Acao = { param($Nome)
            $ChaveSR = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            $FreqAntiga = (Get-ItemProperty -Path $ChaveSR -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
            Set-ItemProperty -Path $ChaveSR -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord # libera mais de um ponto por dia
            $Inicio = Get-Date
            try {
                $R = Executar-PSIsolado -PodeCancelar $false -TimeoutMinutos 15 -Script @'
try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch { Write-Output ('AVISO=' + $_.Exception.Message) }
try { Checkpoint-Computer -Description 'ManutencaoPRO - antes da manutencao' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
catch { Write-Output ('FALHA=' + $_.Exception.Message) }
'@
            } finally {
                if ($null -eq $FreqAntiga) { Remove-ItemProperty -Path $ChaveSR -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -Path $ChaveSR -Name SystemRestorePointCreationFrequency -Value $FreqAntiga -Type DWord }
            }
            $Novo = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.ConvertToDateTime($_.CreationTime) -ge $Inicio.AddMinutes(-1) })
            if ($Novo.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Ponto de restauração nº $($Novo[-1].SequenceNumber) criado e confirmado." }
            else {
                $Motivo = if ($R.Saida -match 'FALHA=(.+)') { $Matches[1].Trim() } else { Resumo-Saida $R.Saida 2 }
                Registrar-ResultadoTarefa $Nome "Aviso" "O Windows não criou o ponto de restauração. $Motivo"
            }
       } }

    @{ Id = "Saude"; Grupo = "Diagnóstico"; Nome = "Saúde dos discos e unidades"; Perfis = @("Diagnostico", "Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1; SomenteLeitura = $true
       Resumo = "SMART do SSD, espaço livre e estado de C:, D: e demais unidades."
       Dica = "Lê desgaste, temperatura e erros (SMART) dos discos internos e confere espaço livre, saúde do volume e a marca de 'verificação pendente' de todas as unidades, incluindo cartões de memória. Somente leitura."
       Acao = { param($Nome)
            $script:SaudeDiscos = @(Obter-SaudeDiscos)
            $Alertas = @()
            foreach ($D in $script:SaudeDiscos) {
                if ($D.SemSmart) { Escrever-Log (" -> {0} ({1} GB): leitor de cartão, não informa SMART; o cartão é avaliado pela unidade abaixo." -f $D.Nome, $D.TamanhoGB); continue }
                $Desg = if ($null -ne $D.Desgaste) { "$($D.Desgaste)%" } else { "n/d" }
                $Temp = if ($null -ne $D.Temperatura) { "$($D.Temperatura) °C" } else { "n/d" }
                Escrever-Log (" -> {0} ({1}, {2} GB): saúde {3}, desgaste {4}, temperatura {5}" -f $D.Nome, $D.Tipo, $D.TamanhoGB, $D.Saude, $Desg, $Temp)
                $Alertas += Obter-AlertasDisco $D
            }
            $script:Unidades = @(Obter-Unidades)
            foreach ($U in $script:Unidades) {
                Escrever-Log (" -> {0}: {1} livres de {2} ({3}%)" -f (Descrever-Unidade $U), (Formatar-Tamanho $U.LivreBytes), (Formatar-Tamanho $U.TotalBytes), $U.PercLivre)
                $Minimo = if ($U.Sistema) { 15 } else { 10 }
                $Pct = "{0:N1}%" -f $U.PercLivre
                if ($U.PercLivre -lt $Minimo) {
                    $Alertas += if ($U.Sistema) { "Pouco espaço livre em $($U.Letra): ($Pct). Manter ao menos 15% livre preserva o desempenho e a vida útil do SSD." }
                                else { "Pouco espaço livre em $($U.Letra): ($Pct). Libere espaço antes de copiar backups grandes." }
                }
                if ($U.Saude -and $U.Saude -ne "Healthy") { $Alertas += "$($U.Letra): o Windows marca o volume como '$($U.Saude)'. Faça backup dos arquivos dessa unidade." }
                if ($U.Sujo) { $Alertas += "$($U.Letra): marcada para verificação (o Windows detectou uma inconsistência). Rode 'Verificar sistema de arquivos'." }
            }
            $script:AlertasSaude = $Alertas
            if ($Alertas.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" ($Alertas -join " ") }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "Discos saudáveis; $($script:Unidades.Count) unidade(s) com espaço adequado ($((@($script:Unidades | ForEach-Object { "{0}: {1:N1}% livre" -f $_.Letra, $_.PercLivre })) -join ', '))." }
       } }

    @{ Id = "Checkup"; Grupo = "Diagnóstico"; Nome = "Check-up do sistema e da memória"; Perfis = @("Diagnostico", "Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 2; SomenteLeitura = $true
       Resumo = "Memória, telas azuis (com causa provável), estabilidade, segurança, suporte do Windows, boot e bateria."
       Dica = "Somente leitura. Confere memória RAM e o último teste de RAM; erros de disco e de hardware, telas azuis (lendo os dumps para apontar a causa provável), desligamentos inesperados, travamentos de programas e o índice de estabilidade do Windows; dispositivos com erro; tempo de inicialização e temperatura; bateria; antivírus, firewall, Inicialização Segura, TPM e criptografia; versão e fim do suporte do Windows, ativação, pontos de restauração, Windows Update e internet. Gera a pontuação de saúde."
       Acao = { param($Nome)
            $script:Checkup = @(Executar-Checkup)
            foreach ($I in $script:Checkup) {
                $Marca = switch ($I.Nivel) { 'Critico' { 'CRÍTICO' } 'Atencao' { 'ATENÇÃO' } 'Info' { 'info' } default { 'ok' } }
                Escrever-Log (" -> [{0}] {1}: {2}" -f $Marca, $I.Item, $I.Resultado)
            }
            $Pontos = @($script:Checkup | Where-Object { $_.Nivel -in 'Critico', 'Atencao' })
            if ($Pontos.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" ("$($Pontos.Count) ponto(s) para atenção: " + (($Pontos | ForEach-Object { $_.Item }) -join '; ') + ".") }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "$($script:Checkup.Count) verificações sem problemas (memória, estabilidade, segurança e sistema)." }
       } }

    @{ Id = "Inventario"; Grupo = "Diagnóstico"; Nome = "Ficha técnica do computador"; Perfis = @("Diagnostico", "Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1; SomenteLeitura = $true
       Resumo = "Modelo, série, CPU, módulos de RAM, BIOS, discos, vídeo, rede e Windows."
       Dica = "Somente leitura. Lê o inventário de hardware e do Windows (fabricante e modelo, número de série, processador, cada módulo de memória, BIOS, placa-mãe, discos com firmware e série, placa de vídeo e driver, monitores, adaptadores de rede, versão e ativação do Windows). Vai para o laudo como 'Ficha técnica'."
       Acao = { param($Nome)
            $script:Inventario = Obter-Inventario
            $script:InventarioDestaExecucao = $true
            $script:InventarioQuando = (Get-Date).ToString('dd/MM/yyyy HH:mm')
            $Grupos = @($script:Inventario.Keys)
            foreach ($G in 'Computador', 'Processador', 'Memória RAM', 'Armazenamento', 'Windows') {
                if ($script:Inventario.Contains($G)) {
                    $Primeiro = @($script:Inventario[$G].GetEnumerator())[0]
                    if ($Primeiro) { Escrever-Log " -> ${G}: $($Primeiro.Value)" }
                }
            }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Ficha técnica lida: $($Grupos -join ', ')."
       } }

    @{ Id = "TesteMemoria"; Grupo = "Diagnóstico"; Nome = "Agendar teste completo da memória RAM"; Perfis = @("Reparo"); Auto = $false; Minutos = 1; Selo = "Requer reinício"
       Resumo = "Diagnóstico de Memória do Windows no próximo reinício (15 a 30 min)."
       Dica = "Usa a ferramenta nativa Diagnóstico de Memória do Windows. Nada é testado agora: no próximo reinício o teste roda uma única vez, antes de o Windows abrir. O resultado aparece numa notificação e no próximo check-up. Indicado quando há travamentos, telas azuis ou arquivos corrompidos."
       Acao = { param($Nome)
            $Bcd = "$env:SystemRoot\System32\bcdedit.exe"
            $R = Executar-Comando -Comando $Bcd -Argumentos "/enum {memdiag}" -PodeCancelar $false -TimeoutMinutos 2
            if ($R.ExitCode -ne 0) { throw "O Diagnóstico de Memória do Windows não está disponível neste computador. $(Resumo-Saida $R.Saida 1)" }
            $R = Executar-Comando -Comando $Bcd -Argumentos "/bootsequence {memdiag}" -PodeCancelar $false -TimeoutMinutos 2
            if ($R.ExitCode -ne 0) { throw "Não foi possível agendar o teste (bcdedit retornou $(Formatar-Codigo $R.ExitCode)). $(Resumo-Saida $R.Saida 1)" }
            $script:ReinicioNecessario = $true
            Registrar-ResultadoTarefa $Nome "Sucesso" "Teste de memória agendado para o PRÓXIMO reinício (uma única vez). Para desistir antes de reiniciar: bcdedit /deletevalue {bootmgr} bootsequence"
       } }

    @{ Id = "Temp"; Grupo = "Limpeza"; Nome = "Limpar arquivos temporários"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 2
       Resumo = "Temporários do Windows e dos usuários com mais de 24 horas."
       Dica = "Apaga arquivos temporários com mais de 24 h (Windows e todos os usuários). Arquivos em uso e pastas recentes são mantidos; atalhos de pasta (junções/links) nunca são seguidos."
       Acao = { param($Nome)
            $Pastas = @("$env:SystemRoot\Temp") + @(Obter-PerfisUsuario | ForEach-Object { Join-Path $_ 'AppData\Local\Temp' })
            $Total = [int64]0; $Falhas = 0
            foreach ($P in $Pastas) { $R = Limpar-Pasta -Caminho $P -IdadeMinimaHoras 24; $Total += $R.Bytes; $Falhas += $R.Falhas }
            Registrar-ResultadoTarefa $Nome "Sucesso" "$(Formatar-Tamanho $Total) apagados em $($Pastas.Count) pasta(s) temporária(s); $Falhas arquivo(s) em uso mantido(s)."
       } }

    @{ Id = "Lixeira"; Grupo = "Limpeza"; Nome = "Esvaziar a Lixeira"; Perfis = @("Rapida", "Completa"); Auto = $false; Minutos = 1; Selo = "Confirmação"
       Resumo = "Mostra o tamanho e pede confirmação antes de esvaziar."
       Dica = "Esvazia a Lixeira de todas as unidades. Antes de começar, o programa mostra quantos itens e quanto espaço ela ocupa e pergunta se pode esvaziar. Nunca roda na manutenção automática."
       Acao = { param($Nome)
            $Info = Obter-InfoLixeira
            if ($Info.Quantidade -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "A Lixeira já estava vazia."; return }
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch {}
            $Resta = Obter-InfoLixeira
            if ($Resta.Quantidade -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$($Resta.Quantidade) item(ns) não puderam ser removidos da Lixeira (em uso)." }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "Lixeira esvaziada: $($Info.Quantidade) item(ns), cerca de $(Formatar-Tamanho $Info.Bytes)." }
       } }

    @{ Id = "Nav"; Grupo = "Limpeza"; Nome = "Limpar cache dos navegadores"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 1
       Resumo = "Chrome, Edge, Brave e Firefox. Senhas, histórico e cookies ficam."
       Dica = "Chrome, Edge, Brave e Firefox, em todos os perfis. Não apaga senhas, histórico nem cookies. Navegadores abertos são pulados."
       Acao = { param($Nome)
            $Navegadores = @(
                @{ Nome = "Chrome"; Processo = "chrome"; Base = "AppData\Local\Google\Chrome\User Data"; Tipo = "Chromium" }
                @{ Nome = "Edge"; Processo = "msedge"; Base = "AppData\Local\Microsoft\Edge\User Data"; Tipo = "Chromium" }
                @{ Nome = "Brave"; Processo = "brave"; Base = "AppData\Local\BraveSoftware\Brave-Browser\User Data"; Tipo = "Chromium" }
                @{ Nome = "Firefox"; Processo = "firefox"; Base = "AppData\Local\Mozilla\Firefox\Profiles"; Tipo = "Firefox" }
            )
            $Total = [int64]0; $Limpos = @(); $Pulados = @()
            foreach ($N in $Navegadores) {
                $Pastas = @()
                foreach ($PerfilUsuario in Obter-PerfisUsuario) {
                    $Base = Join-Path $PerfilUsuario $N.Base
                    if (-not (Test-Path $Base)) { continue }
                    if ($N.Tipo -eq "Chromium") {
                        foreach ($Prof in Get-ChildItem $Base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }) {
                            $Pastas += @("Cache", "Code Cache", "GPUCache") | ForEach-Object { Join-Path $Prof.FullName $_ }
                        }
                    } else {
                        $Pastas += Get-ChildItem $Base -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'cache2' }
                    }
                }
                if ($Pastas.Count -eq 0) { continue }
                if (Get-Process -Name $N.Processo -ErrorAction SilentlyContinue) { $Pulados += $N.Nome; continue }
                foreach ($P in $Pastas) { $Total += (Limpar-Pasta -Caminho $P).Bytes }
                $Limpos += $N.Nome
            }
            $Det = "$(Formatar-Tamanho $Total) de cache apagados"
            if ($Limpos) { $Det += " ($($Limpos -join ', '))" }
            if ($Pulados) { Registrar-ResultadoTarefa $Nome "Aviso" "$Det. Pulados por estarem abertos: $($Pulados -join ', '). Feche-os e rode de novo para limpar." }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "$Det." }
       } }

    @{ Id = "CleanMgr"; Grupo = "Limpeza"; Nome = "Limpeza de Disco do Windows"; Perfis = @("Completa"); Auto = $true; Minutos = 8
       Resumo = "Ferramenta nativa (cleanmgr), só com categorias seguras."
       Dica = "Usa a Limpeza de Disco nativa só com categorias seguras (miniaturas, relatórios de erro, dumps, cache de shaders...). Não mexe em Downloads nem em instalações anteriores do Windows."
       Acao = { param($Nome)
            $Base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $Seguros = @("Active Setup Temp Folders", "D3D Shader Cache", "Delivery Optimization Files", "Diagnostic Data Viewer database files",
                "Downloaded Program Files", "Feedback Hub Archive log files", "Internet Cache Files", "Old ChkDsk Files", "Setup Log Files",
                "System error memory dump files", "System error minidump files", "Temporary Files", "Temporary Setup Files", "Thumbnail Cache",
                "Upgrade Discarded Files", "Windows Defender", "Windows Error Reporting Files")
            $Flag = "StateFlags0077"
            foreach ($Sub in Get-ChildItem $Base -ErrorAction SilentlyContinue) {
                if ($Seguros -contains $Sub.PSChildName) { Set-ItemProperty -Path $Sub.PSPath -Name $Flag -Value 2 -Type DWord -ErrorAction SilentlyContinue }
                else { Remove-ItemProperty -Path $Sub.PSPath -Name $Flag -ErrorAction SilentlyContinue }
            }
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\cleanmgr.exe" -Argumentos "/sagerun:77" -TimeoutMinutos 45 -SemSaida
            if ($R.Cancelado) { return }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Limpeza de Disco concluída (categorias seguras)."
       } }

    @{ Id = "DNS"; Grupo = "Reparo"; Nome = "Limpar cache DNS"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1
       Resumo = "Resolve sites que não abrem por endereço antigo em cache."
       Dica = "Resolve sites que não abrem por endereço antigo em cache. Não exige reinício."
       Acao = { param($Nome)
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\ipconfig.exe" -Argumentos "/flushdns"
            if ($R.ExitCode -ne 0) { throw "ipconfig /flushdns retornou $(Formatar-Codigo $R.ExitCode)." }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Cache DNS limpo."
       } }

    @{ Id = "Rede"; Grupo = "Reparo"; Nome = "Reparo de rede (Winsock)"; Perfis = @("Reparo"); Auto = $false; Minutos = 1; Selo = "Requer reinício"
       Resumo = "Só quando a internet não funciona. Pode desconfigurar VPNs."
       Dica = "Use só quando a internet não funciona. Exige reinício e pode desconfigurar VPNs e alguns antivírus."
       Acao = { param($Nome)
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\netsh.exe" -Argumentos "winsock reset"
            if ($R.ExitCode -ne 0) { throw "netsh winsock reset retornou $(Formatar-Codigo $R.ExitCode). $(Resumo-Saida $R.Saida 2)" }
            $script:ReinicioNecessario = $true
            Registrar-ResultadoTarefa $Nome "Sucesso" "Winsock redefinido. REINICIE o computador para concluir."
       } }

    @{ Id = "DISM"; Grupo = "Reparo"; Nome = "Verificar e reparar a imagem do Windows"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 15; Critica = $true; Selo = "Não interrompível"
       Resumo = "DISM: verifica os componentes e só repara se houver dano."
       Dica = "Verifica o repositório de componentes e só executa o reparo (RestoreHealth) se encontrar danos. Nunca é interrompido à força."
       Acao = { param($Nome)
            Escrever-Log " -> Verificando a imagem (ScanHealth)..."
            $Estado = Obter-EstadoImagem "-ScanHealth"
            if ($Estado -eq "Healthy") { Registrar-ResultadoTarefa $Nome "Sucesso" "Imagem do Windows íntegra; nenhum reparo necessário."; return }
            if ($Estado -eq "Repairable") {
                Escrever-Log " -> Danos encontrados. Reparando (RestoreHealth)... pode levar vários minutos." "Aviso"
                $Estado = Obter-EstadoImagem "-RestoreHealth"
                if ($Estado -eq "Healthy") { Registrar-ResultadoTarefa $Nome "Sucesso" "Danos na imagem do Windows encontrados e REPARADOS."; return }
            }
            throw "Imagem do Windows com danos não reparáveis (estado: $Estado). Considere um reparo in-place (reinstalar o Windows mantendo arquivos e apps)."
       } }

    @{ Id = "PontosAntigos"; Grupo = "Limpeza"; Nome = "Limpar pontos de restauração antigos"; Perfis = @("Completa"); Auto = $false; Minutos = 2; Selo = "Confirmação"
       Resumo = "Apaga os pontos de restauração mais antigos e mantém os $PontosRestauracaoManter mais recentes."
       Dica = "Libera o espaço usado pela Proteção do Sistema apagando os pontos de restauração mais antigos de C: (o Windows só permite apagar do mais antigo para o mais novo). Os $PontosRestauracaoManter mais recentes são sempre mantidos, inclusive o criado nesta manutenção. Pede confirmação e nunca roda na manutenção automática."
       Acao = { param($Nome)
            $Antes = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
            if ($Antes -le $PontosRestauracaoManter) { Registrar-ResultadoTarefa $Nome "Sucesso" "Nada a apagar: há $Antes ponto(s) de restauração (mantidos: $PontosRestauracaoManter)."; return }
            $Atual = $Antes
            # Apaga a cópia de sombra mais antiga do volume do sistema pela WMI (Win32_ShadowCopy), sempre da mais antiga para a mais nova.
            # Só prossegue enquanto cada cópia de sombra corresponder a um ponto de restauração: uma sombra a mais seria de backup/terceiros.
            $VolumeSistema = "$((Get-CimInstance Win32_Volume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction SilentlyContinue).DeviceID)"
            if (-not $VolumeSistema) { Registrar-ResultadoTarefa $Nome "Aviso" "Não foi possível identificar o volume do sistema; nenhum ponto de restauração foi apagado."; return }
            while ($Atual -gt $PontosRestauracaoManter) {
                $Sombras = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $VolumeSistema } | Sort-Object InstallDate)
                if ($Sombras.Count -eq 0) { Registrar-ResultadoTarefa $Nome "Aviso" "Só foi possível reduzir de $Antes para $Atual ponto(s): o Windows não listou mais cópias de sombra para apagar."; return }
                if ($Sombras.Count -ne $Atual) { Registrar-ResultadoTarefa $Nome "Aviso" "Só foi possível reduzir de $Antes para $Atual ponto(s): há $($Sombras.Count) cópia(s) de sombra para $Atual ponto(s) de restauração (alguma pode ser de backup), então nada mais foi apagado por segurança."; return }
                $Erro = ""
                try { Remove-CimInstance -InputObject $Sombras[0] -ErrorAction Stop } catch { $Erro = $_.Exception.Message }
                $Novo = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
                if ($Novo -ge $Atual) {
                    Registrar-ResultadoTarefa $Nome "Aviso" "Só foi possível reduzir de $Antes para $Novo ponto(s). $Erro"
                    return
                }
                $Atual = $Novo
            }
            Registrar-ResultadoTarefa $Nome "Sucesso" "$($Antes - $Atual) ponto(s) de restauração antigo(s) apagado(s); $Atual mantido(s)."
       } }

    @{ Id = "SFC"; Grupo = "Reparo"; Nome = "Verificar arquivos do sistema"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 15; Critica = $true; Selo = "Não interrompível"
       Resumo = "SFC: procura e corrige arquivos do Windows corrompidos."
       Dica = "Procura e conserta arquivos corrompidos do Windows. O resultado real é lido do CBS.log. Nunca é interrompido à força."
       Acao = { param($Nome)
            $Inicio = (Get-Date).AddSeconds(-5)
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\sfc.exe" -Argumentos "/scannow" -PodeCancelar $false -AvisoMinutos 30
            $Cbs = Analisar-LogCBS $Inicio
            if ($Cbs.NaoReparados -gt 0) { throw "SFC encontrou $($Cbs.NaoReparados) arquivo(s) corrompido(s) que NÃO conseguiu reparar. Rode o reparo DISM e depois o SFC de novo." }
            if ($Cbs.Reparados -gt 0) {
                $script:ReinicioNecessario = $true
                Registrar-ResultadoTarefa $Nome "Sucesso" "SFC encontrou e REPAROU $($Cbs.Reparados) arquivo(s) corrompido(s). Reinicie para concluir."
                return
            }
            if ($Cbs.Concluido -or $R.ExitCode -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Nenhuma violação de integridade encontrada."; return }
            throw "SFC não concluiu a verificação (código $(Formatar-Codigo $R.ExitCode)). $(Resumo-Saida $R.Saida 3)"
       } }

    @{ Id = "Volume"; Grupo = "Reparo"; Nome = "Verificar sistema de arquivos das unidades"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 5
       Resumo = "C:, D: e demais unidades, sem reiniciar. Cartão/USB: só leitura."
       Dica = "Unidades internas NTFS: verificação com o Windows ligado (Repair-Volume -Scan); se houver erros, a correção é agendada para o próximo reinício. Cartão de memória/USB (exFAT/FAT): chkdsk somente leitura. Se houver suspeita de erro, o programa oferece a correção manual (com sua confirmação); nunca corrige sozinho."
       Acao = { param($Nome)
            $Det = @(); $Aviso = $false
            foreach ($U in Obter-Unidades) {
                if ($script:Cancelado) { return }
                $L = $U.Letra
                if ($U.FS -in 'NTFS', 'ReFS') {
                    Escrever-Log " -> Verificando $(Descrever-Unidade $U)..."
                    $R = Executar-PSIsolado -AvisoMinutos 20 -TimeoutMinutos 90 -Script ("try { Write-Output ('ESTADO=' + (Repair-Volume -DriveLetter LETRA -Scan -ErrorAction Stop)) } catch { Write-Output ('FALHA=' + `$_.Exception.Message) }" -replace 'LETRA', $L)
                    if ($R.Cancelado) { return }
                    $Estado = if ($R.Saida -match 'ESTADO=(\w+)') { $Matches[1] } else { "Desconhecido" }
                    switch ($Estado) {
                        'NoErrorsFound' { $Det += "${L}: sem erros" }
                        'ScanNeeded' { $Det += "${L}: verificação incompleta, repita depois"; $Aviso = $true }
                        'Desconhecido' { $Det += "${L}: não foi possível verificar ($(Resumo-Saida $R.Saida 1))"; $Aviso = $true }
                        default {
                            $Aviso = $true
                            if ($U.Removivel) {
                                # Unidade removível: nada de correção automática (forçaria a desmontagem com arquivos abertos)
                                if ($script:UnidadesParaCorrigir -notcontains $L) { $script:UnidadesParaCorrigir += $L }
                                $Det += "${L}: ERROS encontrados ($Estado). Feche os arquivos da unidade e use 'Corrigir ${L}:'"
                            } else {
                                $null = Executar-Comando -Comando "$env:SystemRoot\System32\fsutil.exe" -Argumentos "dirty set ${L}:"
                                $script:ReinicioNecessario = $true
                                $Det += "${L}: ERROS encontrados ($Estado); correção agendada para o próximo reinício"
                            }
                        }
                    }
                } elseif ($U.FS -match '^(exFAT|FAT32|FAT)$') {
                    # Repair-Volume não suporta exFAT/FAT: chkdsk sem parâmetros só lê, não altera nada
                    Escrever-Log " -> Verificando $(Descrever-Unidade $U) em modo somente leitura..."
                    $R = Executar-Comando -Comando "$env:SystemRoot\System32\chkdsk.exe" -Argumentos "${L}:" -AvisoMinutos 15 -TimeoutMinutos 60
                    if ($R.Cancelado) { return }
                    if ($R.ExitCode -eq 0) { $Det += "${L}: sem erros" }
                    else {
                        $Aviso = $true
                        if ($script:UnidadesParaCorrigir -notcontains $L) { $script:UnidadesParaCorrigir += $L }
                        $Det += "${L}: possíveis erros (código $(Formatar-Codigo $R.ExitCode)). Se algo estava gravando na unidade, repita; persistindo, feche os arquivos e use 'Corrigir ${L}:'"
                    }
                } else { $Det += "${L}: sistema de arquivos $($U.FS) não verificado" }
            }
            Registrar-ResultadoTarefa $Nome $(if ($Aviso) { "Aviso" } else { "Sucesso" }) (($Det -join "; ") + ".")
       } }

    @{ Id = "WU"; Grupo = "Atualizações"; Nome = "Atualizações do Windows e drivers"; Perfis = @("Completa"); Auto = $true; Minutos = 20; Critica = $true; Selo = "Não interrompível"
       Resumo = "Segurança, qualidade e drivers recomendados. Opcionais só são listados."
       Dica = "Usa o Windows Update nativo: instala atualizações de segurança/qualidade e os drivers que o próprio Windows recomenda (só se forem mais novos que o atual). Nunca instala uma nova versão do Windows, atualizações prévias, drivers opcionais nem atualizações que exigem interação: esses aparecem no laudo para você decidir."
       Acao = { param($Nome)
            $R = Executar-PSIsolado -PodeCancelar $false -AvisoMinutos 45 -Script @'
try {
    $Sessao = New-Object -ComObject Microsoft.Update.Session
    $Sessao.ClientApplicationID = 'ManutencaoPRO'
    $Res = $Sessao.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    $Instalados = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID })
    $Lista = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($U in $Res.Updates) {
        # Nova versão do Windows (categoria "Upgrades"): nunca por aqui
        $EhVersaoNova = $false
        foreach ($C in $U.Categories) { if ($C.CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5') { $EhVersaoNova = $true } }
        if ($EhVersaoNova) { Write-Output ('VERSAO=' + $U.Title); continue }
        if ($U.InstallationBehavior.CanRequestUserInput) { Write-Output ('INTERATIVA=' + $U.Title); continue }
        if ($U.Type -eq 2) {
            # Driver: só se for mais novo que o driver atual do mesmo dispositivo
            $Atual = $Instalados | Where-Object { $_.HardwareID -eq $U.DriverHardwareID } | Select-Object -First 1
            if ($Atual -and $Atual.DriverDate -and $Atual.DriverDate -ge $U.DriverVerDate) { Write-Output ('PULADO=' + $U.Title); continue }
            if ($U.BrowseOnly) { Write-Output ('OPCIONAL=' + $U.Title); continue } # driver opcional: só listar
        } elseif ($U.BrowseOnly) { continue } # atualizações opcionais/prévias de software
        if (-not $U.EulaAccepted) { $U.AcceptEula() }
        [void]$Lista.Add($U)
    }
    if ($Lista.Count -eq 0) { Write-Output 'RESULTADO=NENHUMA'; exit 0 }
    $Down = $Sessao.CreateUpdateDownloader(); $Down.Updates = $Lista; [void]$Down.Download()
    $Inst = $Sessao.CreateUpdateInstaller(); $Inst.Updates = $Lista
    $Final = $Inst.Install()
    for ($i = 0; $i -lt $Lista.Count; $i++) {
        $Tipo = if ($Lista.Item($i).Type -eq 2) { 'DRIVER' } else { 'SW' }
        Write-Output ('ITEM=' + $Final.GetUpdateResult($i).ResultCode + '|' + $Tipo + '|' + $Lista.Item($i).Title)
    }
    Write-Output ('REINICIAR=' + $Final.RebootRequired)
} catch { Write-Output ('FALHA=' + $_.Exception.Message) }
'@
            foreach ($m in [regex]::Matches($R.Saida, '(?m)^(OPCIONAL|VERSAO|INTERATIVA)=(.+)$')) {
                $Titulo = $m.Groups[2].Value.Trim()
                switch ($m.Groups[1].Value) {
                    'OPCIONAL' { $script:AtualizacoesPendentes += [PSCustomObject]@{ Tipo = "Driver opcional"; Titulo = $Titulo }; Escrever-Log " -> Driver opcional disponível (não instalado): $Titulo" }
                    'VERSAO' { $script:AtualizacoesPendentes += [PSCustomObject]@{ Tipo = "Nova versão do Windows"; Titulo = $Titulo }; Escrever-Log " -> Nova versão do Windows disponível (instale pelo Windows Update quando quiser): $Titulo" }
                    'INTERATIVA' { $script:AtualizacoesPendentes += [PSCustomObject]@{ Tipo = "Exige interação"; Titulo = $Titulo }; Escrever-Log " -> Atualização que exige interação (instale pelo Windows Update): $Titulo" }
                }
            }
            if ($R.Saida -match 'FALHA=(.+)') { throw "Windows Update falhou: $($Matches[1].Trim())" }
            if ($R.Saida -match 'RESULTADO=NENHUMA') { Registrar-ResultadoTarefa $Nome "Sucesso" "Windows e drivers recomendados já estão atualizados."; return }
            $Ok = @(); $Falha = @(); $Drivers = 0
            foreach ($m in [regex]::Matches($R.Saida, '(?m)^ITEM=(\d)\|(\w+)\|(.+)$')) {
                $Titulo = $m.Groups[3].Value.Trim()
                if ($m.Groups[1].Value -in '2', '3') { $Ok += $Titulo; if ($m.Groups[2].Value -eq 'DRIVER') { $Drivers++ } }
                else { $Falha += $Titulo }
            }
            if ($R.Saida -match 'REINICIAR=True') { $script:ReinicioNecessario = $true }
            foreach ($t in $Ok) { Escrever-Log " -> Instalada: $t" }
            $Det = "$($Ok.Count) atualização(ões) instalada(s), sendo $Drivers de driver."
            if ($Falha.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$Det Falharam: $($Falha -join '; ')" }
            elseif ($Ok.Count -eq 0) { throw "Nenhuma atualização foi instalada. $(Resumo-Saida $R.Saida 3)" }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" $Det }
       } }

    @{ Id = "Winget"; Grupo = "Atualizações"; Nome = "Atualizar aplicativos"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 10
       Resumo = "Programas pelo winget e apps da Microsoft Store."
       Dica = "Atualiza os programas instalados com o winget e pede à Microsoft Store que atualize os apps dela."
       Acao = { param($Nome)
            $W = Obter-CaminhoWinget
            if (-not $W) { Registrar-ResultadoTarefa $Nome "Aviso" "Winget não encontrado. Instale o 'Instalador de Aplicativo' pela Microsoft Store (em edições LTSC/sem Store ele pode não existir)." }
            else {
                $R = Executar-Comando -Comando $W -Argumentos "upgrade --all --silent --accept-source-agreements --accept-package-agreements --disable-interactivity" -TimeoutMinutos 45 -AvisoMinutos 20
                if ($R.Cancelado) { return }
                $Resumo = Resumo-Saida $R.Saida 4
                if ($R.ExitCode -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Aplicativos atualizados. $Resumo" }
                elseif ($R.ExitCode -eq -1978335189) { Registrar-ResultadoTarefa $Nome "Sucesso" "Todos os aplicativos já estavam atualizados." }
                else { Registrar-ResultadoTarefa $Nome "Aviso" "Alguns aplicativos não foram atualizados (código $(Formatar-Codigo $R.ExitCode)). $Resumo" }
            }
            try {
                Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
                    Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
                Escrever-Log " -> Atualização dos apps da Microsoft Store solicitada (continua em segundo plano)."
            } catch { Escrever-Log " -> Não foi possível acionar a atualização da Microsoft Store: $($_.Exception.Message)" "Aviso" }
       } }

    @{ Id = "WinUpLimpeza"; Grupo = "Limpeza"; Nome = "Limpar resíduos do Windows Update"; Perfis = @("Completa"); Auto = $true; Minutos = 10; Critica = $true; Selo = "Não interrompível"
       Resumo = "Componentes antigos (DISM) e caches de atualização."
       Dica = "Remove versões antigas de componentes (DISM StartComponentCleanup, sem /ResetBase: as atualizações continuam desinstaláveis), o cache de downloads do Windows Update e o cache de Otimização de Entrega. É adiada se houver atualização instalando ou reinício pendente."
       Acao = { param($Nome)
            $Det = @()
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; $Det += "cache de Otimização de Entrega limpo" } catch {}
            if (Testar-ReinicioPendente) {
                Registrar-ResultadoTarefa $Nome "Aviso" "Há atualizações aguardando reinício; a limpeza de componentes foi adiada. Reinicie e rode de novo. $($Det -join '; ')"
                return
            }
            $Ocupado = $false
            try { $Ocupado = [bool](New-Object -ComObject Microsoft.Update.Installer).IsBusy } catch {}
            if ($Ocupado) {
                Registrar-ResultadoTarefa $Nome "Aviso" "O Windows Update está instalando algo agora; a limpeza foi adiada para não interferir. Rode de novo mais tarde. $($Det -join '; ')"
                return
            }
            try {
                Stop-Service -Name wuauserv -Force -ErrorAction Stop
                $R = Limpar-Pasta -Caminho "$env:SystemRoot\SoftwareDistribution\Download"
                $Det += "cache de downloads: $(Formatar-Tamanho $R.Bytes)"
            } catch { $Det += "cache de downloads não limpo ($($_.Exception.Message))" }
            finally { Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\Dism.exe" -Argumentos "/Online /Cleanup-Image /StartComponentCleanup" -PodeCancelar $false -AvisoMinutos 30
            if ($R.ExitCode -ne 0) { throw "DISM StartComponentCleanup retornou $(Formatar-Codigo $R.ExitCode). $(Resumo-Saida $R.Saida 2)" }
            $Det += "componentes antigos removidos"
            Registrar-ResultadoTarefa $Nome "Sucesso" (($Det -join "; ") + ".")
       } }

    @{ Id = "Defender"; Grupo = "Proteção"; Nome = "Verificação rápida de vírus"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 5
       Resumo = "Microsoft Defender: atualiza as definições e verifica o sistema."
       Dica = "Atualiza as definições e faz uma verificação rápida. O laudo mostra as ameaças realmente detectadas."
       Acao = { param($Nome)
            $Status = $null
            try { $Status = Get-MpComputerStatus -ErrorAction Stop } catch {}
            if (-not $Status -or -not $Status.AntivirusEnabled) { Registrar-ResultadoTarefa $Nome "Aviso" "Windows Defender desativado (outro antivírus deve estar ativo). Verificação não executada."; return }
            $Mp = Obter-CaminhoMpCmdRun
            $Atual = Executar-Comando -Comando $Mp -Argumentos "-SignatureUpdate" -TimeoutMinutos 10
            if ($Atual.Cancelado) { return }
            if ($Atual.ExitCode -ne 0) { Escrever-Log " -> Não foi possível atualizar as definições agora (sem internet?). Verificando com as atuais." "Aviso" }
            $Inicio = (Get-Date).AddMinutes(-1)
            $R = Executar-Comando -Comando $Mp -Argumentos "-Scan -ScanType 1" -TimeoutMinutos 60 -AvisoMinutos 20
            if ($R.Cancelado) { return }
            $Novas = @(Obter-AmeacasDesde $Inicio)
            $script:Ameacas = @($script:Ameacas + $Novas | Select-Object -Unique)
            if ($Novas.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$($Novas.Count) ameaça(s) detectada(s): $($Novas -join ', '). Confira em Segurança do Windows > Proteção contra vírus e ameaças." }
            elseif ($R.ExitCode -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Nenhuma ameaça encontrada na verificação rápida." }
            elseif ($R.ExitCode -eq 2) { Registrar-ResultadoTarefa $Nome "Aviso" "O Defender relatou ameaças. Confira em Segurança do Windows > Histórico de proteção." }
            else { throw "MpCmdRun retornou $(Formatar-Codigo $R.ExitCode). $(Resumo-Saida $R.Saida 2)" }
       } }

    @{ Id = "DefenderUnidades"; Grupo = "Proteção"; Nome = "Verificar outras unidades com o antivírus"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 5
       Resumo = "D: e demais unidades (cartão, USB): instaladores, backups e fotos."
       Dica = "Faz uma verificação personalizada do Microsoft Defender em cada unidade além do sistema (por exemplo, o cartão D:). Só lê os arquivos; se o Defender encontrar uma ameaça, ele a coloca em quarentena como sempre faz. Unidades desconectadas são ignoradas."
       Acao = { param($Nome)
            $Extras = @(Obter-Unidades | Where-Object { -not $_.Sistema })
            if ($Extras.Count -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Nenhuma unidade além do sistema está conectada."; return }
            $Status = $null
            try { $Status = Get-MpComputerStatus -ErrorAction Stop } catch {}
            if (-not $Status -or -not $Status.AntivirusEnabled) { Registrar-ResultadoTarefa $Nome "Aviso" "Microsoft Defender desativado (outro antivírus deve estar ativo). Verificação não executada."; return }
            $Mp = Obter-CaminhoMpCmdRun
            $Inicio = (Get-Date).AddMinutes(-1)
            $Det = @(); $Falhou = $false
            foreach ($U in $Extras) {
                Escrever-Log " -> Verificando $(Descrever-Unidade $U), $(Formatar-Tamanho ($U.TotalBytes - $U.LivreBytes)) em uso..."
                # Sem aspas em volta de "X:\": a barra antes da aspa seria lida como aspa escapada
                # No modo agendado o limite é menor: a tarefa inteira tem 4 h e o laudo precisa ser gerado
                $Limite = if ($script:ModoAutomatico) { 90 } else { 240 }
                $R = Executar-Comando -Comando $Mp -Argumentos "-Scan -ScanType 3 -File $($U.Letra):\" -TimeoutMinutos $Limite -AvisoMinutos 20
                if ($R.Cancelado) { return }
                if ($R.ExitCode -in 0, 2) { $Det += "$($U.Letra): verificada" } else { $Det += "$($U.Letra): falhou ($(Formatar-Codigo $R.ExitCode))"; $Falhou = $true }
            }
            $Novas = @(Obter-AmeacasDesde $Inicio)
            $script:Ameacas = @($script:Ameacas + $Novas | Select-Object -Unique)
            if ($Novas.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$($Novas.Count) ameaça(s) detectada(s): $($Novas -join ', '). Confira em Segurança do Windows > Proteção contra vírus e ameaças." }
            else { Registrar-ResultadoTarefa $Nome $(if ($Falhou) { "Aviso" } else { "Sucesso" }) ("Nenhuma ameaça encontrada. " + ($Det -join "; ") + ".") }
       } }

    @{ Id = "Otimizar"; Grupo = "Desempenho"; Nome = "Otimizar unidades"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 5
       Resumo = "TRIM no SSD, desfragmentação só em HD. Cartões de memória ficam de fora."
       Dica = "Usa 'defrag /O', que escolhe sozinho a otimização certa para cada tipo de disco: SSD recebe TRIM e nunca é desfragmentado. Cartões de memória e unidades USB são pulados (otimizá-los só gastaria a memória flash)."
       Acao = { param($Nome)
            $Det = @(); $Falhou = $false
            foreach ($U in Obter-Unidades) {
                $L = $U.Letra
                if ($U.Removivel) { $Det += "${L}: ($($U.Tipo)) não se aplica"; continue }
                if ($U.FS -notin 'NTFS', 'ReFS') { $Det += "${L}: ($($U.FS)) não se aplica"; continue }
                Escrever-Log " -> ${L}: ($($U.Tipo)) otimizando..."
                $R = Executar-Comando -Comando "$env:SystemRoot\System32\defrag.exe" -Argumentos "${L}: /O" -AvisoMinutos 30
                if ($R.Cancelado) { return }
                if ($R.ExitCode -eq 0) { $Det += "${L}: ($($U.Tipo)) OK" } else { $Det += "${L}: falhou ($(Formatar-Codigo $R.ExitCode))"; $Falhou = $true }
            }
            Registrar-ResultadoTarefa $Nome $(if ($Falhou) { "Aviso" } else { "Sucesso" }) (($Det -join "; ") + ".")
       } }

    @{ Id = "StorageSense"; Grupo = "Desempenho"; Nome = "Ativar o Sensor de Armazenamento"; Perfis = @("Completa"); Auto = $false; Minutos = 1
       Resumo = "Limpeza automática mensal do próprio Windows (Downloads fora)."
       Dica = "Configura o recurso nativo do Windows para limpar temporários e a Lixeira (itens com mais de 30 dias) todo mês. A pasta Downloads não é tocada."
       Acao = { param($Nome)
            $Chave = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
            if (-not (Test-Path $Chave)) { New-Item -Path $Chave -Force | Out-Null }
            $Valores = @{ '01' = 1; '2048' = 30; '04' = 1; '08' = 1; '256' = 30 }
            foreach ($k in $Valores.Keys) { Set-ItemProperty -Path $Chave -Name $k -Value $Valores[$k] -Type DWord }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Sensor de Armazenamento ativo: roda mensalmente (temporários e Lixeira com mais de 30 dias)."
       } }

    @{ Id = "Debloat"; Grupo = "Desempenho"; Nome = "Remover aplicativos escolhidos"; Perfis = @(); Auto = $false; Minutos = 3
       Resumo = "Só os apps que você marcar em 'Escolher apps'."
       Dica = "Remove só os apps que você escolher em 'Selecionar Apps'. Sem seleção, nada é removido."
       Acao = { param($Nome)
            if ($script:AppsSelecionadosParaRemocao.Count -eq 0) { Registrar-ResultadoTarefa $Nome "Aviso" "Nenhum aplicativo selecionado em 'Escolher apps'; nada foi removido."; return }
            $Provisionados = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
            $Ok = @(); $Falha = @()
            foreach ($App in $script:AppsSelecionadosParaRemocao) {
                if ($script:Cancelado) { break }
                Escrever-Log " -> Removendo: $App"
                try { Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch {}
                # Remove também o pacote provisionado, senão o app volta em atualizações grandes do Windows
                $Provisionados | Where-Object { $_.DisplayName -eq $App } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                if (Get-AppxPackage -AllUsers -Name $App -ErrorAction SilentlyContinue) { $Falha += $App } else { $Ok += $App }
                Atualizar-Tela
            }
            if ($Falha.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$($Ok.Count) removido(s). O Windows não permitiu remover: $($Falha -join ', ')." }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "$($Ok.Count) aplicativo(s) removido(s): $($Ok -join ', ')." }
       } }

    @{ Id = "Downloads"; Grupo = "Limpeza"; Nome = "Limpar Downloads antigos"; Perfis = @(); Auto = $false; Minutos = 2; Selo = "Confirmação"
       Resumo = "Arquivos com mais de $DiasDownloads dias vão para a Lixeira (reversível)."
       Dica = "Move para a Lixeira os arquivos da pasta Downloads com mais de $DiasDownloads dias. Pede confirmação antes."
       Acao = { param($Nome)
            $Pasta = Obter-PastaDownloads
            $R = Limpar-Pasta -Caminho $Pasta -IdadeMinimaHoras ($DiasDownloads * 24) -ParaLixeira
            $Det = "$($R.Arquivos) arquivo(s) ($(Formatar-Tamanho $R.Bytes)) com mais de $DiasDownloads dias movidos para a Lixeira."
            if ($R.Falhas -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$Det $($R.Falhas) arquivo(s) em uso foram mantidos." }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" $Det }
       } }
)

# ==========================================
# LAUDO HTML (segue o tema claro/escuro de quem abre; imprime limpo)
# ==========================================
Function Codificar-Html([object]$Texto) { return [System.Net.WebUtility]::HtmlEncode("$Texto") }

Function Classe-Status([string]$Status) {
    switch ($Status) { "Sucesso" { "ok" } "OK" { "ok" } "Aviso" { "aviso" } "Atencao" { "aviso" } "Info" { "info" } "Cancelada" { "info" } default { "erro" } }
}

Function Rotulo-Nivel([string]$Nivel) {
    switch ($Nivel) { "Atencao" { "Atenção" } "Critico" { "Crítico" } default { $Nivel } }
}

Function Formatar-Pct([double]$Valor) { return ("{0:N0}%" -f $Valor) }

# Lê o log mais recente do MemTest86 gravado em qualquer unidade pronta (o pendrive de boot guarda em EFI\BOOT).
# Somente leitura; devolve $null se não houver log.
Function Obter-ResultadoMemTest86 {
    $Logs = @()
    foreach ($Drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $Drive.IsReady) { continue }
            foreach ($Pasta in @("EFI\BOOT", "")) {
                $Logs += @(Get-ChildItem -Path (Join-Path $Drive.RootDirectory.FullName $Pasta) -Filter "MemTest86-*.log" -File -ErrorAction SilentlyContinue)
            }
        } catch {}
    }
    $Ultimo = $Logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $Ultimo) { return $null }
    try {
        $Linhas = @(Get-Content -LiteralPath $Ultimo.FullName -Encoding UTF8 -ErrorAction Stop)
        $Dh = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) - '
        $Inicio = $null; $Fim = $null
        if ($Linhas.Count -gt 0 -and $Linhas[0] -match $Dh) { $Inicio = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) }
        for ($i = $Linhas.Count - 1; $i -ge 0; $i--) { if ($Linhas[$i] -match $Dh) { $Fim = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null); break } }

        $Resultado = $null; $Erros = $null
        foreach ($L in $Linhas) { if ($L -match 'Test result: (\w+) \(Errors: (\d+)\)') { $Resultado = $Matches[1]; $Erros = [int]$Matches[2] } }
        $Passes = $null; $PassesTotal = $null
        foreach ($L in $Linhas) { if ($L -match 'Finished pass #(\d+) \(of (\d+)\)') { $Passes = [int]$Matches[1]; $PassesTotal = [int]$Matches[2] } }
        $Versao = ($Linhas | Where-Object { $_ -match 'MemTest86 V[\d.]+' } | Select-Object -First 1) -replace '^.*(MemTest86 V[\d.]+ \w+).*$', '$1'
        $Equip = ""
        $Sis = $Linhas | Where-Object { $_ -match 'SMBIOS BASEBOARD INFO Manufacturer: "([^"]*)", Product: "([^"]*)"' } | Select-Object -First 1
        if ($Sis -match 'Manufacturer: "([^"]*)", Product: "([^"]*)"') { $Equip = "$($Matches[1]) $($Matches[2])" }
        $Tam = $null
        $T = $Linhas | Where-Object { $_ -match 'Total memory size \((\d+) bytes\)' } | Select-Object -First 1
        if ($T -match 'Total memory size \((\d+) bytes\)') { $Tam = [int64]$Matches[1] }
        $Veloc = ""
        $V = $Linhas | Where-Object { $_ -match 'Current mem timings: (.+)$' } | Select-Object -Last 1
        if ($V -match 'Current mem timings: (.+)$') { $Veloc = $Matches[1].Trim() }
        $Ddr = ""
        $D = $Linhas | Where-Object { $_ -match 'DDR type=(\w+)' } | Select-Object -First 1
        if ($D -match 'DDR type=(\w+)') { $Ddr = $Matches[1] }
        $Temps = @($Linhas | ForEach-Object { if ($_ -match 'CPU temperature: (\d+)C') { [int]$Matches[1] } })
        $Hammer = @($Linhas | Where-Object { $_ -match 'Running test #13 ' }).Count -gt 0

        return [PSCustomObject]@{
            Arquivo = $Ultimo.FullName; Versao = $Versao; Inicio = $Inicio; Fim = $Fim
            Resultado = $Resultado; Erros = $Erros; Passes = $Passes; PassesTotal = $PassesTotal
            Equipamento = $Equip; MemoriaBytes = $Tam; Velocidade = $Veloc; Tipo = $Ddr
            TempMin = if ($Temps.Count) { ($Temps | Measure-Object -Minimum).Minimum } else { $null }
            TempMax = if ($Temps.Count) { ($Temps | Measure-Object -Maximum).Maximum } else { $null }
            Hammer = $Hammer
        }
    } catch { return $null }
}

Function Obter-LogoBase64 {
    $Arq = "$($script:Config.Marca.Logo)"
    if (-not $Arq -or -not (Test-Path -LiteralPath $Arq)) { return "" }
    try {
        $Info = Get-Item -LiteralPath $Arq
        if ($Info.Length -gt 600KB) { return "" }
        $Mime = switch ($Info.Extension.ToLower()) { '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.gif' { 'image/gif' } '.webp' { 'image/webp' } '.svg' { 'image/svg+xml' } default { '' } }
        if (-not $Mime) { return "" }
        return "data:$Mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Arq))
    } catch { return "" }
}

# Anel SVG da pontuação (circunferência 2*pi*52 = 326,73; o traço preenchido é proporcional à nota)
Function Html-AnelNota([int]$Nota, [int]$Tamanho = 120) {
    $Classe = if ($Nota -ge 75) { 'ok' } elseif ($Nota -ge 50) { 'aviso' } else { 'erro' }
    $Circ = 326.73
    $Off = Num ($Circ * (1 - ($Nota / 100.0))) 2
    return "<svg class='anel $Classe' viewBox='0 0 120 120' width='$Tamanho' height='$Tamanho' role='img' aria-label='Pontuação $Nota de 100'>" +
        "<circle class='trilha' cx='60' cy='60' r='52'/><circle class='valor' cx='60' cy='60' r='52' stroke-dasharray='$(Num $Circ 2)' stroke-dashoffset='$Off' transform='rotate(-90 60 60)'/>" +
        "<text x='60' y='55' class='num'>$Nota</text><text x='60' y='84' class='de'>de 100</text></svg>"
}

# Linha de evolução da nota (SVG simples, imprime bem)
Function Html-Sparkline([object[]]$Valores) {
    $V = @($Valores | Where-Object { $null -ne $_ -and "$_" -ne "" } | ForEach-Object { [double]$_ })
    if ($V.Count -lt 2) { return "" }
    $W = 600; $H = 60; $Pad = 6
    $Min = [math]::Min(0, ($V | Measure-Object -Minimum).Minimum); $Max = [math]::Max(100, ($V | Measure-Object -Maximum).Maximum)
    $Pontos = @(); $Circulos = ""
    for ($i = 0; $i -lt $V.Count; $i++) {
        $x = $Pad + ($W - 2 * $Pad) * $i / ($V.Count - 1)
        $y = $H - $Pad - ($H - 2 * $Pad) * (($V[$i] - $Min) / ($Max - $Min))
        $Pontos += "$(Num $x 1),$(Num $y 1)"
        $Circulos += "<circle cx='$(Num $x 1)' cy='$(Num $y 1)' r='3'/>"
    }
    return "<svg class='spark' viewBox='0 0 $W $H' preserveAspectRatio='none' aria-hidden='true'><polyline points='$($Pontos -join ' ')'/>$Circulos</svg>"
}

Function Gerar-LaudoHTML {
    param ([bool]$Detalhado, [bool]$Abrir, [object[]]$Historico = @())
    $Antes = $script:MetricasAntes; $Depois = $script:MetricasDepois
    $Liberado = [math]::Max([int64]0, [int64]($Depois.BytesLivres - $Antes.BytesLivres)) # Int64: mais de 2 GB estourava o Int32
    $Ok = @($script:RelatorioTarefas | Where-Object Status -eq "Sucesso").Count
    $Av = @($script:RelatorioTarefas | Where-Object Status -eq "Aviso").Count
    $Er = @($script:RelatorioTarefas | Where-Object Status -eq "Erro").Count
    $Criticos = @($script:Checkup | Where-Object { $_.Nivel -eq 'Critico' })
    $Atencao = @($script:Checkup | Where-Object { $_.Nivel -eq 'Atencao' })
    $Reiniciar = $Depois.ReinicioPendente -or $script:ReinicioNecessario
    $Nota = $script:Pontuacao
    $Tecnico = (Testar-RecursoTecnico)
    $Marca = $script:Config.Marca
    $MostrarMarca = $Tecnico -and [bool]$Marca.MostrarNoLaudo -and ("$($Marca.Nome)".Trim() -ne "")

    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { $Rec = "Manutenção interrompida por falhas críticas. Veja os erros abaixo; pode ser necessária análise técnica."; $ClasseRec = "erro" }
    elseif ($Criticos.Count -gt 0) { $Rec = "O check-up encontrou pontos críticos. Faça backup dos seus arquivos e veja os alertas abaixo."; $ClasseRec = "erro" }
    elseif ($script:Ameacas.Count -gt 0) { $Rec = "Ameaças foram detectadas. Confira a Segurança do Windows."; $ClasseRec = "erro" }
    elseif ($script:AlertasSaude.Count -gt 0) { $Rec = "Atenção às unidades: veja os alertas abaixo e mantenha o backup em dia."; $ClasseRec = "aviso" }
    elseif ($Reiniciar) { $Rec = "Reinicie o computador para concluir reparos e atualizações."; $ClasseRec = "aviso" }
    elseif ($Er -gt 0) { $Rec = "Manutenção concluída com erros: veja os detalhes abaixo."; $ClasseRec = "aviso" }
    elseif ($Atencao.Count -gt 0 -or $Av -gt 0) { $Rec = "Manutenção concluída. Há alguns pontos de atenção abaixo."; $ClasseRec = "aviso" }
    else { $Rec = "Sistema em ordem. Próxima manutenção completa em cerca de 1 mês (a rápida pode ser semanal)."; $ClasseRec = "ok" }

    # ---------- Cabeçalho: marca do técnico e dados do atendimento ----------
    $HtmlMarca = ""
    if ($MostrarMarca) {
        $Logo = Obter-LogoBase64
        $HtmlMarca = "<div class='marca'>" + $(if ($Logo) { "<img src='$Logo' alt=''>" } else { "" }) + "<b>$(Codificar-Html $Marca.Nome)</b>"
        if ("$($Marca.Telefone)".Trim()) { $HtmlMarca += "<span>$(Codificar-Html $Marca.Telefone)</span><br>" }
        if ("$($Marca.Contato)".Trim()) { $HtmlMarca += "<span>$(Codificar-Html $Marca.Contato)</span>" }
        $HtmlMarca += "</div>"
    }
    $HtmlAtend = ""
    if ($Tecnico) {
        $Campos = @()
        if ("$($script:Atendimento.Cliente)".Trim()) { $Campos += @("Cliente", $script:Atendimento.Cliente) }
        if ("$($script:Atendimento.OS)".Trim()) { $Campos += @("Ordem de serviço", $script:Atendimento.OS) }
        if ("$($Marca.Tecnico)".Trim()) { $Campos += @("Técnico responsável", $Marca.Tecnico) }
        if ($Campos.Count -gt 0) {
            $HtmlAtend = "<div class='atend'>"
            for ($i = 0; $i -lt $Campos.Count; $i += 2) { $HtmlAtend += "<div class='metrica'><span>$(Codificar-Html $Campos[$i])</span><b>$(Codificar-Html $Campos[$i+1])</b></div>" }
            $HtmlAtend += "</div>"
        }
    }

    # ---------- Pontuação de saúde ----------
    $HtmlNota = ""
    if ($Nota) {
        $Comparacao = ""
        $Ant = $script:PontuacaoAnterior
        if ($Ant -and $null -ne $Ant.Nota -and "$($Ant.Nota)" -ne "") {
            $Delta = [int]$Nota.Nota - [int]$Ant.Nota
            $ClasseD = if ($Delta -gt 0) { 'up' } elseif ($Delta -lt 0) { 'down' } else { 'flat' }
            $Sinal = if ($Delta -gt 0) { "+$Delta" } elseif ($Delta -lt 0) { "$Delta" } else { "sem mudança" }
            $Comparacao = "<p class='rotulo' style='margin:6px 0 0'>Avaliação anterior: $($Ant.Nota) em $(([datetime]$Ant.Data).ToString('dd/MM/yyyy')) · <span class='delta $ClasseD'>$Sinal</span></p>"
        }
        $HtmlPerdas = ""
        if ($Nota.Perdas.Count -gt 0) {
            $HtmlPerdas = "<ul class='perdas'>"
            foreach ($P in @($Nota.Perdas | Select-Object -First 8)) {
                $HtmlPerdas += "<li><span class='pts'>-$($P.Pontos)</span><span>$(Codificar-Html $P.Motivo)" + $(if ($P.Acao) { "<span class='acao'>O que fazer: $(Codificar-Html $P.Acao)</span>" } else { "" }) + "</span></li>"
            }
            if ($Nota.Perdas.Count -gt 8) { $HtmlPerdas += "<li><span class='pts'></span><span class='rotulo'>e mais $($Nota.Perdas.Count - 8) ponto(s) menores no check-up abaixo.</span></li>" }
            $HtmlPerdas += "</ul>"
        } else { $HtmlPerdas = "<p class='rotulo' style='margin:8px 0 0'>Nenhum ponto perdido: todos os itens verificados estão em ordem.</p>" }
        $ClasseNota = switch ($Nota.Nivel) { 'OK' { 'ok' } 'Atencao' { 'aviso' } default { 'erro' } }
        $HtmlNota = "<section><div class='hero'>$(Html-AnelNota $Nota.Nota)<div class='texto'><h2>Pontuação de saúde: <span class='nivel $ClasseNota'>$($Nota.Rotulo)</span></h2>" +
            "<p class='rotulo' style='margin:0'>Calculada só com o que foi medido neste computador. Cada ponto perdido tem um motivo e uma ação; nada é inflado para vender serviço.</p>$Comparacao$HtmlPerdas</div></div></section>"
    } elseif ($script:Checkup.Count -eq 0) {
        $HtmlNota = "<section><h2>Pontuação de saúde</h2><p class='nota' style='margin:0'>Não calculada: a tarefa 'Check-up do sistema e da memória' não foi executada nesta manutenção.</p></section>"
    }

    # ---------- Tendências (comparação com a execução anterior) ----------
    $HtmlTend = ""
    $Tend = @()
    if ($Historico.Count -ge 2) {
        $UltH = $Historico[-1]; $AntH = $Historico[-2]
        $Campos = @(
            @{ Nome = "Pontuação de saúde"; Campo = "Nota"; Unidade = ""; MaiorMelhor = $true }
            @{ Nome = "Espaço livre em $env:SystemDrive"; Campo = "LivrePct"; Unidade = "%"; MaiorMelhor = $true }
            @{ Nome = "Desgaste do SSD"; Campo = "Desgaste"; Unidade = "%"; MaiorMelhor = $false }
            @{ Nome = "Saúde da bateria"; Campo = "Bateria"; Unidade = "%"; MaiorMelhor = $true }
            @{ Nome = "Tempo de inicialização"; Campo = "Boot"; Unidade = " s"; MaiorMelhor = $false }
            @{ Nome = "Telas azuis (30 dias)"; Campo = "TelasAzuis"; Unidade = ""; MaiorMelhor = $false }
            @{ Nome = "Programas na inicialização"; Campo = "Inicializacao"; Unidade = ""; MaiorMelhor = $false }
        )
        foreach ($C in $Campos) {
            $A = $AntH.($C.Campo); $U = $UltH.($C.Campo)
            if ($null -eq $A -or $null -eq $U -or "$A" -eq "" -or "$U" -eq "") { continue }
            $Delta = [math]::Round([double]$U - [double]$A, 1)
            $Melhorou = if ($Delta -eq 0) { $null } elseif ($C.MaiorMelhor) { $Delta -gt 0 } else { $Delta -lt 0 }
            $Tend += [PSCustomObject]@{ Nome = $C.Nome; Antes = $A; Agora = $U; Delta = $Delta; Unidade = $C.Unidade; Melhorou = $Melhorou }
        }
        if ($Tend.Count -gt 0) {
            $HtmlTend = "<section><h2>Evolução desde a manutenção anterior ($(([datetime]$AntH.Data).ToString('dd/MM/yyyy')))</h2><table><thead><tr><th>Indicador</th><th>Antes</th><th>Agora</th><th>Variação</th></tr></thead><tbody>"
            foreach ($T in $Tend) {
                $ClasseD = if ($null -eq $T.Melhorou) { 'flat' } elseif ($T.Melhorou) { 'up' } else { 'down' }
                $Seta = if ($null -eq $T.Melhorou) { "=" } elseif ($T.Delta -gt 0) { "▲ +$($T.Delta)" } else { "▼ $($T.Delta)" }
                $HtmlTend += "<tr><td>$(Codificar-Html $T.Nome)</td><td>$($T.Antes)$($T.Unidade)</td><td>$($T.Agora)$($T.Unidade)</td><td><span class='delta $ClasseD'>$Seta$(if ($null -ne $T.Melhorou) { $T.Unidade })</span></td></tr>"
            }
            $HtmlTend += "</tbody></table></section>"
        }
    }

    $Alertas = @($script:AlertasSaude)
    foreach ($I in @($Criticos + $Atencao)) { $Alertas += "$($I.Item): $($I.Resultado)" }
    foreach ($L in $script:UnidadesParaCorrigir) { $Alertas += "${L}: possíveis erros no sistema de arquivos. Feche os arquivos da unidade e use 'Corrigir ${L}:' no programa." }
    if ($Reiniciar) { $Alertas += "Há um reinício pendente." }
    if ($script:Ameacas.Count -gt 0) { $Alertas += "Ameaças detectadas: $($script:Ameacas -join ', ')." }
    if ($Depois.Inicializacao -gt 10) { $Alertas += "$($Depois.Inicializacao) programas abrem junto com o Windows. Desativar os desnecessários (Ferramentas > Inicialização) acelera o boot e libera memória." }
    $Mt = Obter-ResultadoMemTest86
    if ($Mt -and $Mt.Resultado -and ($Mt.Resultado -ne "PASS" -or $Mt.Erros -ne 0)) { $Alertas += "O MemTest86 encontrou $($Mt.Erros) erro(s) na memória RAM. Veja a seção do teste de memória." }
    elseif ($Mt -and -not $Mt.Resultado) { $Alertas += "O último log do MemTest86 não tem resultado final: o teste foi interrompido e não vale como aprovação." }
    $HtmlAlertas = ""
    if ($Alertas.Count -gt 0) {
        $HtmlAlertas = "<section><h2>Alertas</h2><ul class='lista'>" + (($Alertas | ForEach-Object { "<li>$(Codificar-Html $_)</li>" }) -join "") + "</ul></section>"
    }

    $HtmlUnidades = ""
    if (@($Depois.Unidades).Count -gt 0) {
        $HtmlUnidades = "<section><h2>Unidades</h2><div class='grade'>"
        foreach ($U in $Depois.Unidades) {
            $A = @($Antes.Unidades | Where-Object { $_.Letra -eq $U.Letra }) | Select-Object -First 1
            $Uso = [int][math]::Round(100 - $U.PercLivre)
            $Minimo = if ($U.Sistema) { 15 } else { 10 }
            $ClasseBarra = if ($U.PercLivre -lt $Minimo) { "aviso" } else { "" }
            $Papel = if ($U.Sistema) { "Sistema" } elseif ($U.Rotulo) { $U.Rotulo } else { "Dados" }
            $Var = ""
            if ($A -and [math]::Abs($U.LivreBytes - $A.LivreBytes) -ge 50MB) { $Var = " · antes: $(Formatar-Tamanho $A.LivreBytes)" }
            $HtmlUnidades += "<div class='unidade'><div class='u-topo'><strong>$($U.Letra):</strong><span>$(Codificar-Html "$Papel · $($U.Tipo) · $($U.FS)")</span></div>" +
                "<div class='barra'><span class='$ClasseBarra' style='width:$Uso%'></span></div>" +
                "<div class='u-pe'>$(Formatar-Tamanho $U.LivreBytes) livres de $(Formatar-Tamanho $U.TotalBytes) ($(Formatar-Pct $U.PercLivre))$(Codificar-Html $Var)</div></div>"
        }
        $HtmlUnidades += "</div></section>"
    }

    $HtmlCheckup = ""
    if ($script:Checkup.Count -gt 0) {
        $HtmlCheckup = "<section><h2>Check-up do sistema</h2><table><thead><tr><th style='width:13%'>Área</th><th style='width:22%'>Verificação</th><th>Resultado</th><th style='width:11%'>Situação</th></tr></thead><tbody>"
        foreach ($I in $script:Checkup) {
            $Acao = if ($I.Acao -and $I.Nivel -in 'Critico', 'Atencao') { "<div class='acao'>O que fazer: $(Codificar-Html $I.Acao)</div>" } else { "" }
            $HtmlCheckup += "<tr><td>$(Codificar-Html $I.Area)</td><td>$(Codificar-Html $I.Item)</td><td>$(Codificar-Html $I.Resultado)$Acao</td><td><span class='pill $(Classe-Status $I.Nivel)'>$(Codificar-Html (Rotulo-Nivel $I.Nivel))</span></td></tr>"
        }
        $HtmlCheckup += "</tbody></table></section>"
    }

    # Telas azuis: dumps lidos nesta execução (código de parada e causa provável)
    $HtmlBsod = ""
    if (@($script:TelasAzuis).Count -gt 0) {
        $HtmlBsod = "<section><h2>Telas azuis analisadas (últimos 30 dias)</h2><p class='nota'>Lidas diretamente dos arquivos de dump do Windows, sem ferramentas externas. O significado é a causa mais comum para cada código; confirme com o teste de memória e a atualização de drivers.</p>" +
            "<table><thead><tr><th style='width:18%'>Data</th><th style='width:14%'>Código</th><th>Causa provável</th><th style='width:22%'>Arquivo</th></tr></thead><tbody>"
        foreach ($T in $script:TelasAzuis) {
            $HtmlBsod += "<tr><td>$($T.Data.ToString('dd/MM/yyyy HH:mm'))</td><td>$(Codificar-Html $T.Codigo)</td><td>$(Codificar-Html $T.Significado)</td><td>$(Codificar-Html $T.Arquivo)</td></tr>"
        }
        $HtmlBsod += "</tbody></table></section>"
    }

    $HtmlDiscos = ""
    if ($script:SaudeDiscos.Count -gt 0) {
        $HtmlDiscos = "<section><h2>Saúde dos discos</h2><table><thead><tr><th>Disco</th><th>Tipo</th><th>Saúde</th><th>Desgaste</th><th>Temperatura</th><th>Erros (leit./escr.)</th><th>Horas ligado</th></tr></thead><tbody>"
        foreach ($D in $script:SaudeDiscos) {
            $ClasseS = if ($D.SemSmart) { "info" } elseif ($D.Saude -eq "Healthy") { "ok" } else { "erro" }
            $Desg = if ($null -ne $D.Desgaste) { "$($D.Desgaste)%" } else { "n/d" }
            $Temp = if ($null -ne $D.Temperatura) { "$($D.Temperatura) °C" } else { "n/d" }
            $Erros = if ($D.SemSmart -or ($null -eq $D.ErrosLeitura -and $null -eq $D.ErrosEscrita)) { "n/d" } else { "$($D.ErrosLeitura) / $($D.ErrosEscrita)" }
            $Horas = if ($null -ne $D.HorasLigado) { "$($D.HorasLigado)" } else { "n/d" }
            $HtmlDiscos += "<tr><td>$(Codificar-Html $D.Nome) ($($D.TamanhoGB) GB)</td><td>$(Codificar-Html "$($D.Tipo) / $($D.Barramento)")</td><td><span class='pill $ClasseS'>$(Codificar-Html $D.Saude)</span></td><td>$Desg</td><td>$Temp</td><td>$(Codificar-Html $Erros)</td><td>$(Codificar-Html $Horas)</td></tr>"
        }
        $HtmlDiscos += "</tbody></table></section>"
    }

    # Saúde da bateria: sempre no laudo de notebooks (lida aqui se o check-up não rodou)
    if (-not $script:BateriaLida) { $script:Bateria = Obter-SaudeBateria; $script:BateriaLida = $true }
    $B = $script:Bateria
    $HtmlBateria = ""; $CardBateria = ""
    if ($B -and $null -ne $B.Saude) {
        $ClasseB = Classe-Status $B.Nivel
        $RotuloB = switch ($B.Nivel) { "OK" { "Boa" } "Atencao" { "Desgastada" } default { "Muito desgastada" } }
        $CardBateria = "<div class='metrica'><span>Saúde da bateria</span><b>$($B.Saude)%</b></div>"
        $Linhas = @()
        if ($B.Ciclos) { $Linhas += @("Ciclos de carga", "$($B.Ciclos)") }
        if ($B.AutonomiaAtual -and $B.AutonomiaAtual.TotalMinutes -gt 0) {
            $Linhas += @("Autonomia estimada", (Formatar-Duracao $B.AutonomiaAtual))
        }
        if ($null -ne $B.Carga) { $Linhas += @("Carga agora", "$($B.Carga)% · $(if ($B.NaTomada) { 'na tomada' } else { 'na bateria' })") }
        if ($B.Fabricante) { $Linhas += @("Fabricante", $B.Fabricante) }
        if ($B.Quimica) {
            $Quim = switch -Regex ($B.Quimica) { '^(LION|Li-?I)' { "Íon de lítio" } '^LiP' { "Polímero de lítio" } '^NiMH' { "Níquel-hidreto metálico" } default { $B.Quimica } }
            $Linhas += @("Tipo", $Quim)
        }
        $HtmlInfo = ""
        for ($i = 0; $i -lt $Linhas.Count; $i += 2) { $HtmlInfo += "<div class='metrica'><span>$(Codificar-Html $Linhas[$i])</span><b>$(Codificar-Html $Linhas[$i+1])</b></div>" }

        # Evolução: início do histórico, ~90 dias, ~30 dias e hoje (o Windows guarda o histórico de capacidade)
        $Pontos = @()
        if ($B.Historico.Count -gt 0) {
            $Pontos += $B.Historico[0]
            foreach ($d in 90, 30) { $p = @($B.Historico | Where-Object { $_.Data -le (Get-Date).AddDays(-$d) }) | Select-Object -Last 1; if ($p) { $Pontos += $p } }
        }
        $Pontos = @($Pontos | Sort-Object Data -Unique)
        $HtmlEvol = ""
        if ($Pontos.Count -gt 0) {
            $HtmlEvol = "<h2 style='margin-top:18px'>Evolução da capacidade</h2><table><thead><tr><th>Data</th><th>Capacidade máxima</th><th>Saúde</th></tr></thead><tbody>"
            foreach ($p in $Pontos) { $HtmlEvol += "<tr><td>$($p.Data.ToString('dd/MM/yyyy'))</td><td>$('{0:N0}' -f $p.AtualMWh) mWh</td><td>$($p.Saude)%</td></tr>" }
            $HtmlEvol += "<tr><td><strong>Hoje</strong></td><td><strong>$('{0:N0}' -f $B.AtualMWh) mWh</strong></td><td><strong>$($B.Saude)%</strong></td></tr></tbody></table>"
        }
        $Dica = if ($B.NaTomada) { "<p class='nota' style='margin:12px 0 0'>Dica de conservação: se o notebook fica quase sempre na tomada, ative o limite de carga (por exemplo, 80%) no aplicativo do fabricante. Calor e carga sempre em 100% são o que mais desgasta a bateria.</p>" } else { "" }
        $Tendencia = if ($B.Tendencia) { "<p class='nota' style='margin:8px 0 0'>$(Codificar-Html $B.Tendencia.Texto)</p>" } else { "" }
        $HtmlBateria = "<section><h2>Saúde da bateria</h2>" +
            "<div class='u-topo'><b style='font-size:22px'>$($B.Saude)%</b><span class='pill $ClasseB'>$RotuloB</span><span>da capacidade original</span></div>" +
            "<div class='barra'><span class='$(if ($B.Nivel -ne 'OK') { 'aviso' })' style='width:$($B.Saude)%'></span></div>" +
            "<div class='u-pe'>$('{0:N0}' -f $B.AtualMWh) mWh hoje, de $('{0:N0}' -f $B.ProjetadaMWh) mWh quando nova · desgaste de $(100 - $B.Saude)%</div>" +
            "<p style='margin:12px 0'>$(Codificar-Html $B.Recomendacao)</p>" +
            "<div class='metricas' style='margin-bottom:0'>$HtmlInfo</div>$Tendencia$HtmlEvol$Dica" +
            "<p class='nota' style='margin:10px 0 0'>Fonte: $(Codificar-Html $B.Fonte). A capacidade varia alguns pontos de um dia para outro por calibração; o que importa é a tendência.</p></section>"
    } elseif ($B) {
        $HtmlBateria = "<section><h2>Saúde da bateria</h2><p class='nota' style='margin:0'>Bateria detectada, mas o Windows não informou a capacidade dela.</p></section>"
    }

    # Teste de memória: aparece quando há log do MemTest86 no pendrive de boot (ou em qualquer unidade conectada)
    $HtmlMemTest = ""
    if ($Mt) {
        if ($Mt.Resultado -eq "PASS" -and $Mt.Erros -eq 0) { $ClasseM = "ok"; $RotuloM = "Aprovada: 0 erros" }
        elseif ($Mt.Resultado) { $ClasseM = "erro"; $RotuloM = "Reprovada: $($Mt.Erros) erro(s)" }
        else { $ClasseM = "aviso"; $RotuloM = "Teste incompleto (sem resultado final)" }
        $Linhas = @()
        $Linhas += ,@("Ferramenta", "$($Mt.Versao)")
        if ($Mt.Inicio -and $Mt.Fim) { $Linhas += ,@("Período", "$($Mt.Inicio.ToString('dd/MM/yyyy HH:mm')) a $($Mt.Fim.ToString('dd/MM/yyyy HH:mm')) ($(Formatar-Duracao ($Mt.Fim - $Mt.Inicio)))") }
        if ($null -ne $Mt.Passes) { $Linhas += ,@("Passes concluídos", "$($Mt.Passes) de $($Mt.PassesTotal)") }
        if ($Mt.Hammer) { $Linhas += ,@("Hammer test (bit flip)", "Executado") }
        if ($Mt.Equipamento) { $Linhas += ,@("Equipamento", $Mt.Equipamento) }
        if ($Mt.MemoriaBytes) { $Linhas += ,@("Memória", ("$(Formatar-Tamanho $Mt.MemoriaBytes) $($Mt.Tipo) · $($Mt.Velocidade)").Trim(' ', '·')) }
        if ($null -ne $Mt.TempMax) { $Linhas += ,@("Temperatura da CPU", "$($Mt.TempMin) a $($Mt.TempMax) °C durante o teste") }
        $HtmlMemTest = "<section><h2>Teste de memória RAM (MemTest86)</h2><div class='u-topo'><span class='pill $ClasseM'>$(Codificar-Html $RotuloM)</span></div>" +
            "<table><tbody>" + (($Linhas | ForEach-Object { "<tr><td style='width:30%'>$(Codificar-Html $_[0])</td><td>$(Codificar-Html $_[1])</td></tr>" }) -join "") + "</tbody></table>" +
            "<p class='nota' style='margin:10px 0 0'>Teste feito fora do Windows, a partir do pendrive de boot. Uma aprovação reduz muito a chance de pente defeituoso, mas não prova que a RAM é perfeita. Log: $(Codificar-Html $Mt.Arquivo)</p></section>"
    }

    $HtmlPendentes = ""
    if ($script:AtualizacoesPendentes.Count -gt 0) {
        $HtmlPendentes = "<section><h2>Atualizações deixadas para você decidir</h2><p class='nota'>Por segurança, estes itens não são instalados automaticamente. Instale pelo Windows Update (Configurações &gt; Windows Update &gt; Opções avançadas &gt; Atualizações opcionais) se precisar.</p><ul class='lista'>"
        foreach ($P in $script:AtualizacoesPendentes) { $HtmlPendentes += "<li><span class='pill info'>$(Codificar-Html $P.Tipo)</span> $(Codificar-Html $P.Titulo)</li>" }
        $HtmlPendentes += "</ul></section>"
    }

    # Ficha técnica (inventário)
    $HtmlFicha = ""
    if ($script:InventarioDestaExecucao -and $script:Inventario -and $script:Inventario.Count -gt 0) {
        $HtmlFicha = "<section><h2>Ficha técnica do computador</h2><div class='ficha'>"
        foreach ($G in $script:Inventario.Keys) {
            $HtmlFicha += "<div><h3>$(Codificar-Html $G)</h3><dl>"
            foreach ($K in $script:Inventario[$G].Keys) { $HtmlFicha += "<dt>$(Codificar-Html $K)</dt><dd>$(Codificar-Html $script:Inventario[$G][$K])</dd>" }
            $HtmlFicha += "</dl></div>"
        }
        $HtmlFicha += "</div></section>"
    }

    # Observações do técnico
    $HtmlObs = ""
    if ($Tecnico -and "$($script:Atendimento.Observacoes)".Trim()) {
        $HtmlObs = "<section><h2>Observações do técnico</h2><p class='obs' style='margin:0'>$(Codificar-Html $script:Atendimento.Observacoes)</p></section>"
    }

    if ($Detalhado) {
        $HtmlTarefas = "<section><h2>Tarefas executadas</h2><table><thead><tr><th style='width:9%'>Hora</th><th style='width:27%'>Tarefa</th><th style='width:11%'>Situação</th><th>Detalhes</th></tr></thead><tbody>"
        foreach ($i in $script:RelatorioTarefas) {
            $HtmlTarefas += "<tr><td>$(Codificar-Html $i.Hora)</td><td>$(Codificar-Html $i.Tarefa)</td><td><span class='pill $(Classe-Status $i.Status)'>$(Codificar-Html $i.Status)</span></td><td>$(Codificar-Html $i.Detalhe)</td></tr>"
        }
        $HtmlTarefas += "</tbody></table></section><section><h2>Registro completo</h2><pre class='log'>$(Codificar-Html $script:LogBuffer.ToString())</pre></section>"
    } else {
        $HtmlTarefas = "<section><h2>Tarefas executadas</h2><ul class='lista'>"
        foreach ($i in $script:RelatorioTarefas) {
            $HtmlTarefas += "<li><span class='pill $(Classe-Status $i.Status)'>$(Codificar-Html $i.Status)</span> <strong>$(Codificar-Html $i.Tarefa)</strong><div class='nota' style='margin:2px 0 0'>$(Codificar-Html $i.Detalhe)</div></li>"
        }
        $HtmlTarefas += "</ul></section>"
    }

    # Histórico das últimas execuções (inclui a atual)
    $HtmlHist = ""
    if ($Historico.Count -ge 2) {
        $Ultimas = @($Historico | Select-Object -Last 12)
        $HtmlHist = "<section><h2>Histórico de manutenções</h2>" + (Html-Sparkline @($Ultimas | ForEach-Object { $_.Nota })) +
            "<table><thead><tr><th>Data</th><th>Perfil</th><th>Nota</th><th>Livre em $env:SystemDrive</th><th>Desgaste</th><th>Bateria</th><th>Telas azuis</th><th>Liberado</th></tr></thead><tbody>"
        foreach ($H in $Ultimas) {
            $NotaH = if ($null -ne $H.Nota -and "$($H.Nota)" -ne "") { "<span class='pill $(if ($H.Nota -ge 75) { 'ok' } elseif ($H.Nota -ge 50) { 'aviso' } else { 'erro' })'>$($H.Nota)</span>" } else { "n/d" }
            $Fmt = { param($v, $u) if ($null -ne $v -and "$v" -ne "") { "$v$u" } else { "n/d" } }
            $HtmlHist += "<tr><td>$(([datetime]$H.Data).ToString('dd/MM/yyyy HH:mm'))</td><td>$(Codificar-Html $H.Perfil)</td><td>$NotaH</td><td>$(& $Fmt $H.LivrePct '%')</td><td>$(& $Fmt $H.Desgaste '%')</td><td>$(& $Fmt $H.Bateria '%')</td><td>$(& $Fmt $H.TelasAzuis '')</td><td>$(if ($H.LiberadoBytes -gt 0) { Formatar-Tamanho ([int64]$H.LiberadoBytes) } else { '-' })</td></tr>"
        }
        $HtmlHist += "</tbody></table></section>"
    }

    $CardsExtras = ""
    $ItemBoot = @($script:Checkup | Where-Object { $_.Chave -eq 'Boot' -and $null -ne $_.Valor }) | Select-Object -First 1
    if ($ItemBoot) { $CardsExtras += "<div class='metrica'><span>Tempo de boot</span><b>$($ItemBoot.Valor) s</b></div>" }
    $ItemEst = @($script:Checkup | Where-Object { $_.Chave -eq 'Estabilidade' -and $null -ne $_.Valor }) | Select-Object -First 1
    if ($ItemEst) { $CardsExtras += "<div class='metrica'><span>Estabilidade do Windows</span><b>$($ItemEst.Valor) / 10</b></div>" }

    $Titulo = if ($script:ContadorFalhas -ge $script:LimiteFalhas) { "Laudo de emergência" } elseif ($Detalhado) { "Laudo técnico detalhado" } else { "Laudo de manutenção" }
    $Modo = if ($script:ModoAutomatico) { "automática (agendada)" } else { "manual" }
    $Duracao = ((Get-Date) - $script:HoraInicio).ToString("hh\:mm\:ss")
    $Subtitulo = "$(Codificar-Html $env:COMPUTERNAME) · $(Get-Date -Format 'dd/MM/yyyy HH:mm') · execução $Modo"
    $ResumoStatus = "$Ok tarefa(s) concluída(s), $Av com aviso, $Er com erro."
    $Emitido = if ($MostrarMarca) { "Emitido por $(Codificar-Html $Marca.Nome) · " } else { "" }
    $NotaEdicao = switch ($script:Licenca.Edicao) { 'Avaliacao' { " · versão de avaliação" } 'Expirada' { " · avaliação encerrada (laudo de diagnóstico)" } 'Desenvolvimento' { " · compilação de desenvolvimento" } default { "" } }
    $TituloPagina = $Titulo + $(if ("$($script:Atendimento.Cliente)".Trim()) { " · $($script:Atendimento.Cliente)" } else { "" })
    $LogoTopo = if ($MostrarMarca) { "" } else { "<div class='logo'><svg viewBox='0 0 24 24' width='22' height='22' fill='currentColor' aria-hidden='true'><path d='M22.7 19l-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.4 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.5-.4.5-1.1.1-1.4z'/></svg></div>" }

    $HTML = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Codificar-Html $TituloPagina) - Manutenção PRO</title>
<style>
:root{--fundo:#f3f3f3;--painel:#fff;--borda:#e5e5e5;--texto:#1b1b1b;--texto2:#5c5c5c;--destaque:#c15f3c;--sobre:#fff;--ok:#0f7b0f;--okf:#dff6dd;--aviso:#9d5d00;--avisof:#fff4ce;--erro:#c42b1c;--errof:#fde7e9;--info:#c15f3c;--infof:#fbeee8;--trilha:#e0e0e0;--log:#fafafa}
@media (prefers-color-scheme:dark){:root{--fundo:#202020;--painel:#2b2b2b;--borda:#3a3a3a;--texto:#fff;--texto2:#c8c8c8;--destaque:#d97757;--sobre:#000;--ok:#6ccb5f;--okf:#393d1b;--aviso:#fce100;--avisof:#433519;--erro:#ff99a4;--errof:#442726;--info:#d97757;--infof:#3d2a22;--trilha:#3d3d3d;--log:#1c1c1c}}
*{box-sizing:border-box}
body{margin:0;background:var(--fundo);color:var(--texto);font:14px/1.5 'Segoe UI',system-ui,sans-serif}
.pagina{max-width:1000px;margin:0 auto;padding:32px 16px 48px}
.topo{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:22px;flex-wrap:wrap}
header{display:flex;align-items:center;gap:14px}
.logo{width:44px;height:44px;border-radius:10px;background:var(--destaque);color:var(--sobre);display:grid;place-items:center;flex:none}
h1{margin:0;font-size:22px;font-weight:600;line-height:1.3}
h2{margin:0 0 12px;font-size:15px;font-weight:600}
.sub{color:var(--texto2);font-size:13px}
.marca{text-align:right;font-size:13px;color:var(--texto2);line-height:1.45}.marca b{display:block;color:var(--texto);font-size:15px}
.marca img{max-height:56px;max-width:220px;object-fit:contain;display:block;margin-left:auto;margin-bottom:6px}
.atend{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:16px}
section{background:var(--painel);border:1px solid var(--borda);border-radius:8px;padding:18px 20px;margin-bottom:16px;overflow-x:auto}
.status{display:flex;gap:12px;align-items:flex-start;border:1px solid var(--borda);border-radius:8px;padding:14px 18px;margin-bottom:16px}
.status.ok{background:var(--okf)}.status.aviso{background:var(--avisof)}.status.erro{background:var(--errof)}
.ponto{width:10px;height:10px;border-radius:50%;margin-top:7px;flex:none}
.ok .ponto{background:var(--ok)}.aviso .ponto{background:var(--aviso)}.erro .ponto{background:var(--erro)}
.status strong{display:block;font-size:15px;font-weight:600}
.hero{display:flex;gap:26px;align-items:center;flex-wrap:wrap}
.hero .texto{flex:1;min-width:260px}.hero h2{margin:0 0 4px;font-size:18px}
.rotulo{font-size:13px;color:var(--texto2)}
svg.anel{flex:none}svg.anel .trilha{fill:none;stroke:var(--trilha);stroke-width:10}
svg.anel .valor{fill:none;stroke-width:10;stroke-linecap:round}
svg.anel.ok .valor{stroke:var(--ok)}svg.anel.aviso .valor{stroke:var(--aviso)}svg.anel.erro .valor{stroke:var(--erro)}
svg.anel .num{font-size:32px;font-weight:600;fill:var(--texto);text-anchor:middle;dominant-baseline:central}
svg.anel .de{font-size:11px;fill:var(--texto2);text-anchor:middle}
.hero h2 .nivel.ok{color:var(--ok)}.hero h2 .nivel.aviso{color:var(--aviso)}.hero h2 .nivel.erro{color:var(--erro)}
ul.perdas{list-style:none;margin:12px 0 0;padding:0}ul.perdas li{display:flex;gap:10px;padding:7px 0;border-top:1px solid var(--borda);font-size:13px}
ul.perdas .pts{flex:none;min-width:34px;font-weight:600;color:var(--erro)}
.acao{color:var(--texto2);display:block;font-size:12.5px;margin-top:2px}
.delta{font-weight:600;white-space:nowrap}.delta.up{color:var(--ok)}.delta.down{color:var(--erro)}.delta.flat{color:var(--texto2)}
.metricas{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:12px;margin-bottom:16px}
.metrica{background:var(--painel);border:1px solid var(--borda);border-radius:8px;padding:12px 14px}
.metrica span{display:block;color:var(--texto2);font-size:12px}
.metrica b{font-size:17px;font-weight:600}
.grade{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.unidade{border:1px solid var(--borda);border-radius:8px;padding:12px 14px}
.u-topo{display:flex;gap:8px;align-items:baseline}.u-topo span{color:var(--texto2);font-size:12.5px}
.barra{height:6px;border-radius:3px;background:var(--trilha);margin:10px 0 6px;overflow:hidden}
.barra span{display:block;height:100%;background:var(--destaque);border-radius:3px}.barra span.aviso{background:var(--aviso)}
.u-pe{color:var(--texto2);font-size:12px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:12px;font-weight:600;color:var(--texto2);padding:8px 10px;border-bottom:1px solid var(--borda)}
td{padding:9px 10px;border-bottom:1px solid var(--borda);vertical-align:top;font-size:13px}
tr:last-child td{border-bottom:0}
.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11.5px;font-weight:600;white-space:nowrap}
.pill.ok{background:var(--okf);color:var(--ok)}.pill.aviso{background:var(--avisof);color:var(--aviso)}.pill.erro{background:var(--errof);color:var(--erro)}.pill.info{background:var(--infof);color:var(--info)}
ul.lista{list-style:none;margin:0;padding:0}ul.lista li{padding:8px 0;border-bottom:1px solid var(--borda)}ul.lista li:last-child{border-bottom:0}
.nota{color:var(--texto2);font-size:12.5px;margin:-4px 0 10px}
.ficha{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px}
.ficha h3{margin:0 0 4px;font-size:12.5px;color:var(--texto2);font-weight:600;text-transform:uppercase;letter-spacing:.3px}
.ficha dl{margin:0}.ficha dt{font-size:12px;color:var(--texto2);margin-top:7px}.ficha dd{margin:0;font-size:13px}
.obs{white-space:pre-wrap}
.spark{width:100%;height:64px;display:block;margin:4px 0 12px}
.spark polyline{fill:none;stroke:var(--destaque);stroke-width:2;vector-effect:non-scaling-stroke}.spark circle{fill:var(--destaque)}
pre.log{background:var(--log);border:1px solid var(--borda);border-radius:6px;padding:12px;font:12px/1.5 'Cascadia Mono',Consolas,monospace;max-height:420px;overflow:auto;white-space:pre-wrap;margin:0}
footer{color:var(--texto2);font-size:12px;text-align:center;margin-top:24px}
@media print{body{background:#fff;color:#000}section,.metrica,.status,.unidade{break-inside:avoid}pre.log{max-height:none}.pagina{padding:0}}
</style>
</head>
<body>
<div class="pagina">
<div class="topo">
<header>
  $LogoTopo
  <div><h1>$Titulo</h1><div class="sub">$Subtitulo</div></div>
</header>
$HtmlMarca
</div>
$HtmlAtend
<div class="status $ClasseRec"><div class="ponto"></div><div><strong>$(Codificar-Html $Rec)</strong><span class="sub">$ResumoStatus</span></div></div>
$HtmlNota
<div class="metricas">
  <div class="metrica"><span>Duração</span><b>$Duracao</b></div>
  <div class="metrica"><span>Espaço liberado em $env:SystemDrive</span><b>$(Formatar-Tamanho $Liberado)</b></div>
  <div class="metrica"><span>Tarefas ok/aviso/erro</span><b>$Ok / $Av / $Er</b></div>
  <div class="metrica"><span>Apps na inicialização</span><b>$($Depois.Inicializacao)</b></div>
  <div class="metrica"><span>Plano de energia</span><b>$(Codificar-Html $Depois.PlanoEnergia)</b></div>
  $CardBateria
  $CardsExtras
</div>
$HtmlAlertas
$HtmlTend
$HtmlUnidades
$HtmlCheckup
$HtmlBsod
$HtmlBateria
$HtmlDiscos
$HtmlMemTest
$HtmlPendentes
$HtmlFicha
$HtmlObs
$HtmlTarefas
$HtmlHist
<footer>${Emitido}Manutenção PRO $($script:Versao) · somente ferramentas nativas do Windows$NotaEdicao</footer>
</div>
</body>
</html>
"@
    Set-Content -Path $script:ReportFile -Value $HTML -Encoding UTF8
    if ($Abrir) { Start-Process $script:ReportFile }
}

Function Obter-CaminhoEdge {
    foreach ($Chave in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe') {
        try { $p = (Get-ItemProperty -Path $Chave -ErrorAction Stop).'(default)'; if ($p -and (Test-Path -LiteralPath $p)) { return $p } } catch {}
    }
    foreach ($p in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# Converte o laudo HTML em PDF com o Microsoft Edge em modo headless (presente no Windows 10/11). Devolve o caminho do PDF ou $null.
Function Exportar-LaudoPdf([string]$Html, [string]$Pdf = "") {
    $Edge = Obter-CaminhoEdge
    if (-not $Edge -or -not $Html -or -not (Test-Path -LiteralPath $Html)) { return $null }
    if (-not $Pdf) { $Pdf = [IO.Path]::ChangeExtension($Html, '.pdf') }
    $PerfilTemp = Join-Path $DirTemp 'edge_pdf'
    $Uri = ([Uri]$Html).AbsoluteUri
    $Argumentos = "--headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions --user-data-dir=`"$PerfilTemp`" --no-pdf-header-footer --print-to-pdf=`"$Pdf`" `"$Uri`""
    try {
        $p = Start-Process -FilePath $Edge -ArgumentList $Argumentos -WindowStyle Hidden -PassThru
        $Limite = (Get-Date).AddSeconds(90)
        while (-not $p.HasExited -and (Get-Date) -lt $Limite) { Start-Sleep -Milliseconds 200; Atualizar-Tela }
        if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    } catch { return $null }
    Remove-Item -LiteralPath $PerfilTemp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Pdf) { return $Pdf }
    return $null
}


Function Obter-Metricas {
    $Plano = "n/d"
    try { $Plano = (Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter "IsActive=True" -ErrorAction Stop).ElementName } catch {}
    $Inic = 0
    try { $Inic = @(Obter-ItensInicializacao | Where-Object Ativo).Count } catch {}
    return [PSCustomObject]@{
        Espaco = Obter-EspacoSistema
        BytesLivres = Obter-BytesLivres
        ReinicioPendente = (Testar-ReinicioPendente)
        PlanoEnergia = $Plano
        Inicializacao = $Inic
        Unidades = @(Obter-Unidades)
    }
}

# ==========================================
# EXECUÇÃO DA MANUTENÇÃO (usada pela interface e pelo modo automático)
# ==========================================
Function Definir-Progresso([double]$Valor) {
    if (-not $script:ModoAutomatico) { $pbStatus.Value = $Valor; Atualizar-Tela }
}

Function Definir-Etapa([string]$Titulo, [string]$Detalhe) {
    if ($script:ModoAutomatico) { return }
    $lblEtapa.Text = $Titulo
    $lblDetalhe.Text = $Detalhe
    # Em etapa crítica, Pausar/Cancelar ficam indisponíveis (interromper poderia danificar o sistema)
    $Livre = $script:Rodando -and -not $script:BloqueioSeguranca -and -not $script:Cancelado
    $btnPausar.IsEnabled = $Livre
    $btnCancelar.IsEnabled = $Livre
}

Function Nome-Perfil([string]$Id) {
    switch ($Id) { 'Diagnostico' { return 'Diagnóstico' } 'Rapida' { return 'Rápida' } 'Completa' { return 'Completa' } 'Reparo' { return 'Reparo' } }
    return 'Personalizada'
}

Function Executar-Manutencao {
    param ([object[]]$Selecionadas, [bool]$Detalhado, [bool]$GerarLaudo, [bool]$AbrirLaudo, [string]$NomePerfil = "Personalizada")
    $Carimbo = Get-Date -Format "yyyy-MM-dd_HHmm"
    $Sufixo = Nome-ArquivoSeguro "$($script:Atendimento.Cliente)"
    $script:LogFile = Join-Path $DirLogs "Manutencao_$Carimbo.txt"
    $script:ReportFile = Join-Path $DirLaudos ("Laudo_$Carimbo" + $(if ($Sufixo) { "_$Sufixo" } else { "" }) + ".html")
    $script:LogBuffer = New-Object System.Text.StringBuilder
    $script:HoraInicio = Get-Date
    $script:ContadorFalhas = 0; $script:ErrosEncontrados = $false; $script:AvisosEncontrados = $false
    $script:Cancelado = $false; $script:Pausado = $false; $script:ReinicioNecessario = $false
    $script:RelatorioTarefas = @(); $script:SaudeDiscos = @(); $script:AlertasSaude = @(); $script:Ameacas = @()
    $script:Checkup = @(); $script:AtualizacoesPendentes = @(); $script:UnidadesParaCorrigir = @(); $script:Unidades = @()
    $script:Bateria = $null; $script:BateriaLida = $false
    $script:InventarioDestaExecucao = $false; $script:TelasAzuis = @(); $script:Pontuacao = $null
    $script:PontuacaoAnterior = @(Obter-EntradasComNota) | Select-Object -Last 1
    $script:Rodando = $true
    Limpar-Historico

    Definir-Etapa "Analisando o sistema" "Medindo espaço, unidades e reinícios pendentes..."
    Escrever-Log "=== ANALISANDO O SISTEMA... ==="
    $script:MetricasAntes = Obter-Metricas
    if ($script:MetricasAntes.ReinicioPendente) { Escrever-Log "Há um reinício pendente. Algumas tarefas (DISM, atualizações) podem ser adiadas até reiniciar." "Aviso" }
    Escrever-Log "=== INICIANDO MANUTENÇÃO ($($Selecionadas.Count) tarefas) ==="
    Definir-Progresso 0

    $Indice = 0
    foreach ($T in $Selecionadas) {
        Aguardar-Pausa
        if ($script:Cancelado) { break }
        $Indice++
        Escrever-Log "$Indice/$($Selecionadas.Count). $($T.Nome)..."
        $script:BloqueioSeguranca = [bool]$T.Critica
        $Detalhe = "Etapa $Indice de $($Selecionadas.Count)"
        if ($T.Critica) { $Detalhe += " · não pode ser interrompida com segurança" }
        Definir-Etapa $T.Nome $Detalhe
        $LivreAntes = Obter-BytesLivres
        $QtdAntes = $script:RelatorioTarefas.Count
        try { & $T.Acao $T.Nome }
        catch { Processar-Erro $T.Nome $_.Exception.Message }
        finally { $script:BloqueioSeguranca = $false; Definir-Etapa $T.Nome $Detalhe }
        if ($script:RelatorioTarefas.Count -eq $QtdAntes -and $script:Cancelado) { Registrar-ResultadoTarefa $T.Nome "Cancelada" "Interrompida pelo cancelamento." }
        $Delta = (Obter-BytesLivres) - $LivreAntes
        if ($Delta -gt 50MB) { Escrever-Log " -> Espaço liberado nesta etapa: $(Formatar-Tamanho $Delta)" }
        Definir-Progresso (($Indice / $Selecionadas.Count) * 100)
    }

    Definir-Progresso 100
    Definir-Etapa "Finalizando" "Medindo o resultado, calculando a pontuação e gerando o laudo..."
    $script:MetricasDepois = Obter-Metricas
    if ($script:MetricasDepois.ReinicioPendente) { $script:ReinicioNecessario = $true }
    $script:Rodando = $false

    # Pontuação de saúde: só quando o check-up rodou (sem ele a nota seria chute)
    if ($script:Checkup.Count -gt 0) {
        $script:Pontuacao = Calcular-Pontuacao -Checkup $script:Checkup -Discos $script:SaudeDiscos -Unidades $script:MetricasDepois.Unidades -Metricas $script:MetricasDepois -Ameacas $script:Ameacas
        Escrever-Log "=== PONTUAÇÃO DE SAÚDE: $($script:Pontuacao.Nota)/100 ($($script:Pontuacao.Rotulo)) ==="
        foreach ($P in @($script:Pontuacao.Perdas | Select-Object -First 5)) { Escrever-Log " -> -$($P.Pontos): $($P.Motivo)" }
    }
    $Liberado = [math]::Max([int64]0, [int64]($script:MetricasDepois.BytesLivres - $script:MetricasAntes.BytesLivres))
    $Entrada = Novo-EntradaHistorico -NomePerfil $NomePerfil -Modo $(if ($script:ModoAutomatico) { "Agendada" } else { "Manual" }) -Duracao ((Get-Date) - $script:HoraInicio) -Liberado $Liberado
    if (-not $GerarLaudo) { $Entrada.Laudo = "" }
    $HistoricoCompleto = @(Ler-Historico) + @($Entrada)

    if ($GerarLaudo) {
        Escrever-Log "Gerando laudo HTML..."
        Gerar-LaudoHTML -Detalhado $Detalhado -Abrir $AbrirLaudo -Historico $HistoricoCompleto
        Escrever-Log "[OK] Laudo salvo em: $script:ReportFile"
    }
    Gravar-EntradaHistorico $Entrada
    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { Escrever-Log "=== MANUTENÇÃO ABORTADA DEVIDO A FALHAS CRÍTICAS ===" "Erro" }
    elseif ($script:Cancelado) { Escrever-Log "=== MANUTENÇÃO CANCELADA PELO USUÁRIO ===" "Aviso" }
    elseif ($script:ErrosEncontrados) { Escrever-Log "=== MANUTENÇÃO CONCLUÍDA COM ERROS ===" "Aviso" }
    elseif ($script:AvisosEncontrados) { Escrever-Log "=== MANUTENÇÃO CONCLUÍDA COM AVISOS ===" }
    else { Escrever-Log "=== MANUTENÇÃO CONCLUÍDA COM SUCESSO ===" }
    if ($script:ReinicioNecessario) { Escrever-Log ">>> REINICIE o computador para concluir reparos/atualizações. <<<" "Aviso" }
}

# ==========================================
# MODO AUTOMÁTICO (tarefa agendada): sem interface
# ==========================================
if ($script:ModoAutomatico) {
    $Sel = @($script:Tarefas | Where-Object { $_.Auto -and $_.Perfis -contains $Perfil })
    # Avaliação encerrada: só as tarefas somente leitura continuam liberadas (diagnóstico e laudo)
    if (-not (Testar-ManutencaoLiberada)) { $Sel = @($Sel | Where-Object { $_.SomenteLeitura }) }
    Executar-Manutencao -Selecionadas $Sel -Detalhado $true -GerarLaudo $true -AbrirLaudo $false -NomePerfil (Nome-Perfil $Perfil)
    if ($script:ErrosEncontrados) { exit 1 } else { exit 0 }
}

# ==========================================
# INTERFACE GRÁFICA
# ==========================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------- Tema: Sistema (segue o Windows), Claro ou Escuro ----------
Function Obter-TemaEscuro {
    switch ("$($script:Config.Tema)") {
        'Claro' { return $false }
        'Escuro' { return $true }
    }
    try { return ((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}
$script:TemaEscuro = Obter-TemaEscuro

Function Obter-Paleta([bool]$Escuro) {
    if ($Escuro) {
        return [ordered]@{
            Fundo = '#202020'; Painel = '#2B2B2B'; PainelAlt = '#262626'; Hover = '#353535'; Pressionado = '#303030'
            Borda = '#3A3A3A'; BordaForte = '#5A5A5A'; Texto = '#FFFFFF'; Texto2 = '#C8C8C8'; Texto3 = '#9A9A9A'
            Destaque = '#D97757'; DestaqueHover = '#C96A4B'; DestaquePress = '#B85F43'; SobreDestaque = '#000000'
            Perigo = '#C42B1C'; PerigoHover = '#D23A2B'; PerigoPress = '#B02617'; SobrePerigo = '#FFFFFF'
            Azul = '#4CC2FF'; AzulHover = '#47B1E8'; AzulPress = '#42A1D2'; SobreAzul = '#000000'; AzulFundo = '#1F3140'
            Sucesso = '#6CCB5F'; Aviso = '#FCE100'; Erro = '#FF99A4'
            SucessoFundo = '#393D1B'; AvisoFundo = '#433519'; ErroFundo = '#442726'; InfoFundo = '#3D2A22'
            LogFundo = '#1C1C1C'; LogTexto = '#D6D6D6'; Trilha = '#3D3D3D'
        }
    }
    return [ordered]@{
        Fundo = '#F3F3F3'; Painel = '#FFFFFF'; PainelAlt = '#F9F9F9'; Hover = '#F0F0F0'; Pressionado = '#E8E8E8'
        Borda = '#E5E5E5'; BordaForte = '#C4C4C4'; Texto = '#1B1B1B'; Texto2 = '#5C5C5C'; Texto3 = '#8A8A8A'
        Destaque = '#C15F3C'; DestaqueHover = '#CA6B49'; DestaquePress = '#D27856'; SobreDestaque = '#FFFFFF'
        Perigo = '#C42B1C'; PerigoHover = '#B3261A'; PerigoPress = '#A32217'; SobrePerigo = '#FFFFFF'
        Azul = '#005FB8'; AzulHover = '#1973BA'; AzulPress = '#2E7FC2'; SobreAzul = '#FFFFFF'; AzulFundo = '#E6F0FA'
        Sucesso = '#0F7B0F'; Aviso = '#9D5D00'; Erro = '#C42B1C'
        SucessoFundo = '#DFF6DD'; AvisoFundo = '#FFF4CE'; ErroFundo = '#FDE7E9'; InfoFundo = '#FBEEE8'
        LogFundo = '#FAFAFA'; LogTexto = '#242424'; Trilha = '#E0E0E0'
    }
}
$script:Paleta = Obter-Paleta $script:TemaEscuro
$script:NsXaml = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$script:FonteIcones = 'Segoe Fluent Icons, Segoe MDL2 Assets'

Function Esc([object]$Texto) { return [Security.SecurityElement]::Escape("$Texto") }

# Caixinha de marcação: o preenchimento com o "visto" aparece/some esmaecendo (gatilho IsChecked -> 'preenchimento')
Function Xaml-CaixaMarcacao([string]$Alinhamento, [string]$Margem) {
    return @"
<Grid Width="18" Height="18" VerticalAlignment="$Alinhamento" Margin="$Margem">
    <Border x:Name="caixa" CornerRadius="4" BorderThickness="1" BorderBrush="{DynamicResource BordaForte}" Background="{DynamicResource PainelAlt}"/>
    <Border x:Name="preenchimento" CornerRadius="4" Background="{DynamicResource Destaque}" Opacity="0">
        <TextBlock Text="&#xE73E;" FontFamily="$($script:FonteIcones)" FontSize="12" Foreground="{DynamicResource SobreDestaque}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</Grid>
"@
}

# Gatilho de template que esmaece um elemento (opacidade 0 -> 1) em vez de trocar de uma vez
Function Xaml-Esmaecer([string]$Propriedade, [string]$Alvo, [int]$EntradaMs = 120, [int]$SaidaMs = 220) {
    return @"
<Trigger Property="$Propriedade" Value="True">
    <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="$Alvo" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.$('{0:000}' -f $EntradaMs)"><DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></Trigger.EnterActions>
    <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="$Alvo" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.$('{0:000}' -f $SaidaMs)"><DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></Trigger.ExitActions>
</Trigger>
"@
}

# Template dos botões de fundo cheio (primário e de perigo): só mudam as cores de passagem e de pressão
Function Xaml-TemplateBotaoCheio([string]$Hover, [string]$Pressao) {
    return @"
<ControlTemplate TargetType="Button">
    <Grid SnapsToDevicePixels="True">
        <Border Background="{TemplateBinding Background}" CornerRadius="5"/>
        <Border x:Name="realce" Background="{DynamicResource $Hover}" CornerRadius="5" Opacity="0"/>
        <Border x:Name="pressao" Background="{DynamicResource $Pressao}" CornerRadius="5" Opacity="0"/>
        <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
    </Grid>
    <ControlTemplate.Triggers>
        $(Xaml-Esmaecer 'IsMouseOver' 'realce')
        $(Xaml-Esmaecer 'IsPressed' 'pressao' 60 180)
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
    </ControlTemplate.Triggers>
</ControlTemplate>
"@
}

# Cores + estilos compartilhados por todas as janelas (botões, caixas, segmentos, navegação, campos, barras de rolagem, dicas)
Function Obter-RecursosXaml {
    $Pinceis = ($script:Paleta.GetEnumerator() | ForEach-Object { "<SolidColorBrush x:Key=`"$($_.Key)`" Color=`"$($_.Value)`"/>" }) -join "`n"
    return $Pinceis + @"

<Style x:Key="Icone" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="$($script:FonteIcones)"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
</Style>
<Style x:Key="Rotulo" TargetType="TextBlock">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{DynamicResource Texto2}"/>
</Style>
<Style x:Key="TituloPagina" TargetType="TextBlock">
    <Setter Property="FontSize" Value="24"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
</Style>
<Style x:Key="SubtituloPagina" TargetType="TextBlock">
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Foreground" Value="{DynamicResource Texto2}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="Margin" Value="0,2,0,0"/>
</Style>
<Style x:Key="TituloCartao" TargetType="TextBlock">
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
</Style>
<Style x:Key="Cartao" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Painel}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Borda}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
</Style>

<Style x:Key="BotaoBase" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
    <Setter Property="Background" Value="{DynamicResource Painel}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Borda}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="14,0"/>
    <Setter Property="Height" Value="34"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="Button">
                <Grid SnapsToDevicePixels="True">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5"/>
                    <Border x:Name="realce" Background="{DynamicResource Hover}" CornerRadius="5" Margin="{TemplateBinding BorderThickness}" Opacity="0"/>
                    <Border x:Name="pressao" Background="{DynamicResource Pressionado}" CornerRadius="5" Margin="{TemplateBinding BorderThickness}" Opacity="0"/>
                    <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                </Grid>
                <ControlTemplate.Triggers>
                    $(Xaml-Esmaecer 'IsMouseOver' 'realce')
                    $(Xaml-Esmaecer 'IsPressed' 'pressao' 60 180)
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="BotaoSutil" TargetType="Button" BasedOn="{StaticResource BotaoBase}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="10,0"/>
</Style>
<Style x:Key="BotaoPrimario" TargetType="Button" BasedOn="{StaticResource BotaoBase}">
    <Setter Property="Foreground" Value="{DynamicResource SobreDestaque}"/>
    <Setter Property="Background" Value="{DynamicResource Destaque}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="20,0"/>
    <Setter Property="Template">
        <Setter.Value>
$(Xaml-TemplateBotaoCheio 'DestaqueHover' 'DestaquePress')
        </Setter.Value>
    </Setter>
</Style>
<!-- Ações que não têm volta (apagar, remover): vermelho com texto branco, para não serem clicadas por engano -->
<Style x:Key="BotaoPerigo" TargetType="Button" BasedOn="{StaticResource BotaoPrimario}">
    <Setter Property="Foreground" Value="{DynamicResource SobrePerigo}"/>
    <Setter Property="Background" Value="{DynamicResource Perigo}"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="Template">
        <Setter.Value>
$(Xaml-TemplateBotaoCheio 'PerigoHover' 'PerigoPress')
        </Setter.Value>
    </Setter>
</Style>
<!-- Diagnóstico (só leitura): azul do Windows 11, para diferenciar do laranja da manutenção -->
<Style x:Key="BotaoAzul" TargetType="Button" BasedOn="{StaticResource BotaoPrimario}">
    <Setter Property="Foreground" Value="{DynamicResource SobreAzul}"/>
    <Setter Property="Background" Value="{DynamicResource Azul}"/>
    <Setter Property="Template">
        <Setter.Value>
$(Xaml-TemplateBotaoCheio 'AzulHover' 'AzulPress')
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="BotaoLink" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Destaque}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="12.5"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="Button">
                <ContentPresenter x:Name="cp" RecognizesAccessKey="False"/>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="cp" Property="Opacity" Value="0.75"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="cp" Property="Opacity" Value="0.4"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>

<!-- Item da navegação lateral: ícone no Tag, pílula de fundo e marca lateral quando selecionado -->
<Style x:Key="NavItem" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{DynamicResource Texto2}"/>
    <Setter Property="FontSize" Value="13.5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Margin" Value="0,1"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="RadioButton">
                <Grid Height="38" Background="Transparent">
                    <Border x:Name="fundo" Background="{DynamicResource Painel}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="6" Opacity="0"/>
                    <Border x:Name="realce" Background="{DynamicResource Hover}" CornerRadius="6" Opacity="0"/>
                    <Border x:Name="marca" Width="3" Height="16" CornerRadius="2" Background="{DynamicResource Destaque}" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,0,0" Opacity="0"/>
                    <StackPanel Orientation="Horizontal" Margin="16,0,12,0" VerticalAlignment="Center">
                        <TextBlock Text="{TemplateBinding Tag}" FontFamily="$($script:FonteIcones)" FontSize="16" VerticalAlignment="Center"/>
                        <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                    </StackPanel>
                </Grid>
                <ControlTemplate.Triggers>
                    $(Xaml-Esmaecer 'IsMouseOver' 'realce')
                    <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="fundo" Property="Opacity" Value="1"/>
                        <Setter TargetName="marca" Property="Opacity" Value="1"/>
                        <Setter TargetName="realce" Property="Visibility" Value="Hidden"/>
                        <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
                        <Setter Property="FontWeight" Value="SemiBold"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>

<Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="CheckBox">
                <Grid Background="Transparent">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    $(Xaml-CaixaMarcacao 'Center' '0')
                    <ContentPresenter Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="caixa" Property="BorderBrush" Value="{DynamicResource Texto2}"/></Trigger>
                    $(Xaml-Esmaecer 'IsChecked' 'preenchimento' 140 140)
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="LinhaTarefa" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="ToolTipService.InitialShowDelay" Value="700"/>
    <Setter Property="ToolTipService.ShowDuration" Value="30000"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="CheckBox">
                <Grid>
                    <Border Background="Transparent" CornerRadius="6"/>
                    <Border x:Name="realce" Background="{DynamicResource Hover}" CornerRadius="6" Opacity="0"/>
                    <Grid Margin="10,8">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        $(Xaml-CaixaMarcacao 'Top' '0,1,0,0')
                        <ContentPresenter Grid.Column="1" Margin="12,0,0,0" HorizontalAlignment="Stretch" RecognizesAccessKey="False"/>
                    </Grid>
                </Grid>
                <ControlTemplate.Triggers>
                    $(Xaml-Esmaecer 'IsMouseOver' 'realce')
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="caixa" Property="BorderBrush" Value="{DynamicResource Texto2}"/></Trigger>
                    $(Xaml-Esmaecer 'IsChecked' 'preenchimento' 140 140)
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="Segmento" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{DynamicResource Texto2}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
        <Setter.Value>
            <!-- O fundo do item marcado é a "pílula" que desliza por trás (Ativar-SegmentoDeslizante) -->
            <ControlTemplate TargetType="RadioButton">
                <Grid>
                    <Border x:Name="realce" Background="{DynamicResource Hover}" CornerRadius="5" Opacity="0"/>
                    <Border Background="Transparent" Padding="10,6">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                    </Border>
                </Grid>
                <ControlTemplate.Triggers>
                    $(Xaml-Esmaecer 'IsMouseOver' 'realce')
                    <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="realce" Property="Visibility" Value="Hidden"/>
                        <Setter Property="FontWeight" Value="SemiBold"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
<Style x:Key="Pilula" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Destaque}"/>
    <Setter Property="CornerRadius" Value="5"/>
    <Setter Property="HorizontalAlignment" Value="Left"/>
    <Setter Property="Width" Value="0"/>
    <Style.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger></Style.Triggers>
</Style>

<Style TargetType="TextBox">
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
    <Setter Property="Background" Value="{DynamicResource PainelAlt}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BordaForte}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="CaretBrush" Value="{DynamicResource Texto}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Destaque}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="TextBox">
                <Border x:Name="borda" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" SnapsToDevicePixels="True">
                    <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="borda" Property="BorderBrush" Value="{DynamicResource Texto3}"/></Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="borda" Property="BorderBrush" Value="{DynamicResource Destaque}"/></Trigger>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>

<Style TargetType="ProgressBar">
    <Setter Property="Height" Value="4"/>
    <Setter Property="Foreground" Value="{DynamicResource Destaque}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="ProgressBar">
                <Grid>
                    <Border x:Name="PART_Track" CornerRadius="2" Background="{DynamicResource Trilha}"/>
                    <Border x:Name="PART_Indicator" CornerRadius="2" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
                </Grid>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>

<Style TargetType="ScrollBar">
    <Setter Property="Width" Value="10"/>
    <Setter Property="MinWidth" Value="10"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                    <Track.Thumb>
                        <Thumb>
                            <Thumb.Template>
                                <ControlTemplate TargetType="Thumb">
                                    <Border x:Name="t" Background="{DynamicResource BordaForte}" CornerRadius="3" Margin="3,2"/>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="{DynamicResource Texto3}"/></Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Thumb.Template>
                        </Thumb>
                    </Track.Thumb>
                </Track>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
    <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="MinWidth" Value="0"/>
            <Setter Property="Height" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" IsDirectionReversed="False">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource BordaForte}" CornerRadius="3" Margin="2,3"/></ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Trigger>
    </Style.Triggers>
</Style>

<Style TargetType="ToolTip">
    <Setter Property="Foreground" Value="{DynamicResource Texto}"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="ToolTip">
                <Border Background="{DynamicResource Painel}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="6" Padding="10,7" MaxWidth="380">
                    <ContentPresenter>
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </Border>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
"@
}

Function Criar-Elemento([string]$Xaml) { return [Windows.Markup.XamlReader]::Parse($Xaml) }

# Barra de título no tom da janela (escura no tema escuro), ícone próprio e, no Windows 11 22H2+, efeito Mica
$script:MicaAtivo = $false
Function Aplicar-TemaJanela($Janela, [bool]$Principal = $false) {
    # Sem closure de propósito: GetNewClosure trocaria o escopo de $script: pelo de um módulo vazio.
    # No manipulador, a janela chega em $this e o sinal de "janela principal" vai no Tag.
    $Janela.Tag = [bool]$Principal
    $Janela.Add_SourceInitialized({
        try {
            $J = $this
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($J)).Handle
            $QuerMica = [bool]$J.Tag -and [bool]$script:Config.Mica -and (Obter-BuildWindows) -ge 22621
            $ComMica = $false
            if ($QuerMica) {
                $ComMica = [JanelaPRO]::AplicarMica($h)
                if ($ComMica) {
                    # O DWM pinta o Mica por trás: a janela e a composição do WPF precisam ficar transparentes
                    $Fonte = [System.Windows.Interop.HwndSource]::FromHwnd($h)
                    $Fonte.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
                    $J.Background = [System.Windows.Media.Brushes]::Transparent
                    $script:MicaAtivo = $true
                }
            }
            [JanelaPRO]::AplicarTema($h, $script:TemaEscuro, [Convert]::ToInt32($script:Paleta.Fundo.TrimStart('#'), 16), (-not $ComMica))
        } catch {}
    })
    if ($script:IconeApp) { $Janela.Icon = $script:IconeApp }
}

Function Criar-IconeApp {
    try {
        $Tam = 64
        $Visual = New-Object System.Windows.Media.DrawingVisual
        $Ctx = $Visual.RenderOpen()
        $Fundo = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#D97757'))
        $Ctx.DrawRoundedRectangle($Fundo, $null, (New-Object System.Windows.Rect 0, 0, $Tam, $Tam), 14, 14)
        $Fonte = New-Object System.Windows.Media.Typeface $script:FonteIcones
        $Glifo = [System.Windows.Media.FormattedText]::new([string][char]0xE90F, [Globalization.CultureInfo]::InvariantCulture,
            [System.Windows.FlowDirection]::LeftToRight, $Fonte, 34, [System.Windows.Media.Brushes]::White, 1.0)
        $Ctx.DrawText($Glifo, (New-Object System.Windows.Point ((($Tam - $Glifo.Width) / 2), (($Tam - $Glifo.Height) / 2))))
        $Ctx.Close()
        $Bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Tam, $Tam, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $Bmp.Render($Visual)
        $Bmp.Freeze()
        return $Bmp
    } catch { return $null }
}
$script:IconeApp = Criar-IconeApp

# ---------- Janela principal: navegação lateral + páginas ----------
$RecursosXaml = Obter-RecursosXaml
[xml]$XAML = @"
<Window $($script:NsXaml)
        Title="Manutenção PRO" Width="1180" Height="800" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
$RecursosXaml
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="224"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

        <!-- Navegação lateral -->
        <DockPanel Margin="12,18,6,18">
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="12,2,0,20">
                <Border Width="36" Height="36" CornerRadius="8" Background="{DynamicResource Destaque}">
                    <TextBlock Style="{StaticResource Icone}" Text="&#xE90F;" FontSize="17" Foreground="{DynamicResource SobreDestaque}" HorizontalAlignment="Center"/>
                </Border>
                <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="Manutenção PRO" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Name="lblVersaoNav" Text="versão" Foreground="{DynamicResource Texto3}" FontSize="11.5"/>
                </StackPanel>
            </StackPanel>
            <Border DockPanel.Dock="Bottom" Name="bdEdicao" Style="{StaticResource Cartao}" Padding="12,10" Margin="2,0" Cursor="Hand" ToolTip="Clique para ver a licença e as edições">
                <StackPanel>
                    <DockPanel>
                        <TextBlock Name="icoEdicao" Style="{StaticResource Icone}" Text="&#xE72E;" FontSize="13" Foreground="{DynamicResource Texto2}" DockPanel.Dock="Left" Margin="0,0,8,0"/>
                        <TextBlock Name="lblEdicaoTitulo" Text="Edição" FontSize="12.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    </DockPanel>
                    <TextBlock Name="lblEdicaoDetalhe" Text="" FontSize="11.5" Foreground="{DynamicResource Texto3}" TextWrapping="Wrap" Margin="0,3,0,0"/>
                </StackPanel>
            </Border>
            <StackPanel Name="spNav" VerticalAlignment="Top">
                <RadioButton Name="navInicio" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE80F;" Content="Início" IsChecked="True"/>
                <RadioButton Name="navManutencao" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE90F;" Content="Manutenção"/>
                <RadioButton Name="navHistorico" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE81C;" Content="Histórico"/>
                <RadioButton Name="navSistema" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE770;" Content="Ficha técnica"/>
                <RadioButton Name="navFerramentas" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE912;" Content="Ferramentas"/>
                <RadioButton Name="navConfig" Style="{StaticResource NavItem}" GroupName="nav" Tag="&#xE713;" Content="Configurações"/>
            </StackPanel>
        </DockPanel>

        <!-- Conteúdo: avisos no topo + páginas -->
        <Grid Grid.Column="1" Margin="6,18,22,18">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel Name="spAvisos" Margin="16,0,8,0"/>
            <Grid Grid.Row="1">

                <!-- INÍCIO -->
                <ScrollViewer Name="pgInicio" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="16,2,12,8">
                        <TextBlock Text="Início" Style="{StaticResource TituloPagina}"/>
                        <TextBlock Name="lblInicioSub" Style="{StaticResource SubtituloPagina}" Text="Visão geral da saúde deste computador."/>
                        <Grid Margin="0,18,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="13*" MinWidth="420"/><ColumnDefinition Width="16"/><ColumnDefinition Width="7*" MinWidth="270"/></Grid.ColumnDefinitions>
                            <Border Style="{StaticResource Cartao}" Padding="22,20">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <Grid Width="150" Height="150" VerticalAlignment="Top">
                                        <Ellipse Stroke="{DynamicResource Trilha}" StrokeThickness="11" Margin="0.5"/>
                                        <Path Name="anelValor" Stroke="{DynamicResource Sucesso}" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                            <TextBlock Name="lblNota" Text="–" FontSize="40" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,-4"/>
                                            <TextBlock Name="lblNotaDe" Text="de 100" FontSize="11.5" Foreground="{DynamicResource Texto3}" HorizontalAlignment="Center"/>
                                        </StackPanel>
                                    </Grid>
                                    <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
                                        <TextBlock Text="Pontuação de saúde" Style="{StaticResource TituloCartao}"/>
                                        <TextBlock Name="lblNotaRotulo" Text="Sem avaliação ainda" FontSize="20" FontWeight="SemiBold" Margin="0,2,0,0"/>
                                        <TextBlock Name="lblNotaDetalhe" Text="Avalie o computador: leva cerca de 1 minuto e nada é alterado." Foreground="{DynamicResource Texto2}" FontSize="12.5" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                        <TextBlock Name="lblNotaComparacao" Foreground="{DynamicResource Texto2}" FontSize="12.5" TextWrapping="Wrap" Margin="0,2,0,0" Visibility="Collapsed"/>
                                        <!-- WrapPanel: quando a janela estreita, o segundo botão desce em vez de ter o texto cortado -->
                                        <WrapPanel Margin="0,14,0,0">
                                            <Button Name="btnAvaliar" Style="{StaticResource BotaoPrimario}" Height="36" Margin="0,0,8,8">
                                                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icone}" Text="&#xE9D9;" FontSize="13"/><TextBlock Text="Avaliar agora" Margin="8,0,0,0"/></StackPanel>
                                            </Button>
                                            <Button Name="btnManutencaoCompleta" Style="{StaticResource BotaoBase}" Height="36" Margin="0,0,8,8" Content="Manutenção completa"/>
                                        </WrapPanel>
                                        <TextBlock Text="Pontuação honesta: cada ponto perdido tem motivo e ação. Nada é inflado para vender serviço." Foreground="{DynamicResource Texto3}" FontSize="11.5" Margin="0,2,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                            <Border Grid.Column="2" Style="{StaticResource Cartao}" Padding="18,16">
                                <StackPanel>
                                    <TextBlock Text="Indicadores" Style="{StaticResource TituloCartao}" Margin="0,0,0,8"/>
                                    <UniformGrid Name="ugIndicadores" Columns="2"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                        <TextBlock Text="Unidades" Style="{StaticResource Rotulo}" Margin="2,18,0,8"/>
                        <WrapPanel Name="wpUnidades"/>
                        <Border Name="bdPerdas" Style="{StaticResource Cartao}" Padding="18,16" Margin="0,6,0,0">
                            <StackPanel>
                                <TextBlock Name="lblPerdasTitulo" Text="O que puxou a nota para baixo" Style="{StaticResource TituloCartao}" Margin="0,0,0,4"/>
                                <StackPanel Name="spPerdas"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- MANUTENÇÃO -->
                <Grid Name="pgManutencao" Visibility="Collapsed" Margin="16,2,12,0">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="Manutenção" Style="{StaticResource TituloPagina}"/>
                        <TextBlock Style="{StaticResource SubtituloPagina}" Text="Escolha um perfil ou marque só as tarefas que quiser. Nada destrutivo acontece sem a sua confirmação."/>
                    </StackPanel>
                    <Border Grid.Row="1" Name="bdAtendimento" Style="{StaticResource Cartao}" Padding="16,12" Margin="0,14,0,0" Visibility="Collapsed">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="2*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="5*"/></Grid.ColumnDefinitions>
                            <StackPanel><TextBlock Text="Cliente" Style="{StaticResource Rotulo}"/><TextBox Name="txtCliente" Margin="0,5,0,0"/></StackPanel>
                            <StackPanel Grid.Column="2"><TextBlock Text="Ordem de serviço" Style="{StaticResource Rotulo}"/><TextBox Name="txtOS" Margin="0,5,0,0"/></StackPanel>
                            <StackPanel Grid.Column="4"><TextBlock Text="Observações do técnico (vão para o laudo)" Style="{StaticResource Rotulo}"/><TextBox Name="txtObservacoes" Margin="0,5,0,0"/></StackPanel>
                        </Grid>
                    </Border>
                    <!-- Perfil em linha própria, alinhado com os cartões abaixo: os cinco nomes cabem inteiros em qualquer tamanho de janela -->
                    <StackPanel Grid.Row="2" Margin="0,14,0,0">
                        <TextBlock Text="Perfil" Style="{StaticResource Rotulo}"/>
                        <Border Background="{DynamicResource Painel}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="7" Padding="3" Margin="0,6,0,0">
                            <Grid>
                                <Border Style="{StaticResource Pilula}" IsEnabled="{Binding IsEnabled, ElementName=ugPerfis}"/>
                                <UniformGrid Name="ugPerfis" Rows="1">
                                    <RadioButton Name="rbDiagnostico" GroupName="perfil" Tag="Diagnostico" Content="Diagnóstico" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbRapida" GroupName="perfil" Tag="Rapida" Content="Rápida" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbCompleta" GroupName="perfil" Tag="Completa" Content="Completa" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbReparo" GroupName="perfil" Tag="Reparo" Content="Reparo" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbPersonalizada" GroupName="perfil" Tag="Personalizada" Content="Personalizada" Style="{StaticResource Segmento}"/>
                                </UniformGrid>
                            </Grid>
                        </Border>
                        <TextBlock Name="lblPerfilDesc" Foreground="{DynamicResource Texto2}" FontSize="12" Margin="2,8,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <Grid Grid.Row="3" Margin="0,14,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="5*" MinWidth="350"/>
                            <ColumnDefinition Width="16"/>
                            <ColumnDefinition Width="6*" MinWidth="338"/>
                        </Grid.ColumnDefinitions>
                        <Border Style="{StaticResource Cartao}">
                            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="6,10,2,8">
                                <StackPanel Name="spTarefas" Margin="4,0,8,4"/>
                            </ScrollViewer>
                        </Border>
                        <Border Grid.Column="2" Style="{StaticResource Cartao}">
                            <Grid Margin="20,18,20,18">
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <Border Name="bdEstado" Width="38" Height="38" CornerRadius="19" Background="{DynamicResource InfoFundo}" VerticalAlignment="Top">
                                        <TextBlock Name="icoEstado" Style="{StaticResource Icone}" Text="&#xE9D9;" FontSize="16" Foreground="{DynamicResource Destaque}" HorizontalAlignment="Center"/>
                                    </Border>
                                    <StackPanel Grid.Column="1" Margin="12,0,12,0" VerticalAlignment="Center">
                                        <TextBlock Name="lblEtapa" Text="Pronto para começar" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                                        <TextBlock Name="lblDetalhe" Text="Escolha um perfil e clique em Iniciar." Foreground="{DynamicResource Texto2}" FontSize="12.5" TextWrapping="Wrap"/>
                                        <StackPanel Name="spAcoesLaudo" Orientation="Horizontal" Margin="0,5,0,0" Visibility="Collapsed">
                                            <Button Name="btnAbrirLaudo" Style="{StaticResource BotaoLink}" FontWeight="SemiBold" Content="Abrir o laudo"/>
                                            <Button Name="btnPdf" Style="{StaticResource BotaoLink}" FontWeight="SemiBold" Content="Salvar em PDF" Margin="14,0,0,0"/>
                                            <Button Name="btnVerPontuacao" Style="{StaticResource BotaoLink}" FontWeight="SemiBold" Content="Ver a pontuação" Margin="14,0,0,0"/>
                                        </StackPanel>
                                    </StackPanel>
                                    <TextBlock Grid.Column="2" Name="lblDecorrido" Foreground="{DynamicResource Texto2}" FontSize="13" VerticalAlignment="Top" Margin="0,2,0,0"/>
                                </Grid>
                                <ProgressBar Grid.Row="1" Name="pbStatus" Minimum="0" Maximum="100" Value="0" Margin="0,16,0,14"/>
                                <Border Grid.Row="2" Background="{DynamicResource LogFundo}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="6">
                                    <RichTextBox Name="rtbLog" IsReadOnly="True" BorderThickness="0" Background="Transparent" Foreground="{DynamicResource LogTexto}"
                                                 FontFamily="Cascadia Mono, Consolas" FontSize="12" Padding="8,8" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                        <FlowDocument PagePadding="0"/>
                                    </RichTextBox>
                                </Border>
                            </Grid>
                        </Border>
                    </Grid>
                    <Grid Grid.Row="4" Margin="0,14,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <CheckBox Name="chkLaudo" Content="Gerar laudo" IsChecked="True"/>
                            <Border Name="bdFormato" Background="{DynamicResource Painel}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="6" Padding="2" Margin="12,0,0,0">
                                <Grid>
                                    <Border Style="{StaticResource Pilula}"/>
                                    <UniformGrid Name="ugFormato" Rows="1">
                                        <RadioButton Name="rbResumido" GroupName="formato" Content="Resumido" IsChecked="True" Style="{StaticResource Segmento}" FontSize="12"/>
                                        <RadioButton Name="rbDetalhado" GroupName="formato" Content="Detalhado" Style="{StaticResource Segmento}" FontSize="12"/>
                                    </UniformGrid>
                                </Grid>
                            </Border>
                            <CheckBox Name="chkDesligar" Content="Desligar ao concluir" Margin="24,0,0,0" ToolTip="Desliga o computador 60 s após concluir, se não houver erros. Para cancelar o desligamento: shutdown /a"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <TextBlock Name="lblTempo" Foreground="{DynamicResource Texto2}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                            <Button Name="btnPausar" Style="{StaticResource BotaoBase}" Height="40" IsEnabled="False" Margin="0,0,8,0">
                                <StackPanel Orientation="Horizontal"><TextBlock Name="icoPausar" Style="{StaticResource Icone}" Text="&#xE769;" FontSize="12"/><TextBlock Name="txtPausar" Text="Pausar" Margin="8,0,0,0"/></StackPanel>
                            </Button>
                            <Button Name="btnCancelar" Style="{StaticResource BotaoBase}" Height="40" IsEnabled="False" Margin="0,0,8,0">
                                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icone}" Text="&#xE711;" FontSize="12"/><TextBlock Text="Cancelar" Margin="8,0,0,0"/></StackPanel>
                            </Button>
                            <Button Name="btnIniciar" Style="{StaticResource BotaoPrimario}" Height="40" MinWidth="210">
                                <StackPanel Orientation="Horizontal"><TextBlock Name="icoIniciar" Style="{StaticResource Icone}" Text="&#xE768;" FontSize="13"/><TextBlock Name="txtIniciar" Text="Iniciar manutenção" Margin="8,0,0,0"/></StackPanel>
                            </Button>
                        </StackPanel>
                    </Grid>
                </Grid>

                <!-- HISTÓRICO -->
                <ScrollViewer Name="pgHistorico" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="16,2,12,8">
                        <TextBlock Text="Histórico" Style="{StaticResource TituloPagina}"/>
                        <TextBlock Style="{StaticResource SubtituloPagina}" Text="Evolução da pontuação e registro de cada manutenção feita neste computador."/>
                        <Border Name="bdEvolucao" Style="{StaticResource Cartao}" Padding="18,16" Margin="0,18,0,0">
                            <StackPanel>
                                <TextBlock Name="lblHistResumo" Text="Evolução da pontuação" Style="{StaticResource TituloCartao}"/>
                                <Grid Name="gdSpark" Height="96" Margin="0,12,0,4" ClipToBounds="True">
                                    <Polyline Name="plSpark" Stroke="{DynamicResource Destaque}" StrokeThickness="2" StrokeLineJoin="Round"/>
                                    <Canvas Name="cvSpark"/>
                                </Grid>
                                <UniformGrid Name="ugTendencias" Columns="4" Margin="0,8,0,0"/>
                            </StackPanel>
                        </Border>
                        <TextBlock Text="Manutenções" Style="{StaticResource Rotulo}" Margin="2,18,0,8"/>
                        <StackPanel Name="spHistorico"/>
                    </StackPanel>
                </ScrollViewer>

                <!-- FICHA TÉCNICA -->
                <ScrollViewer Name="pgSistema" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="16,2,12,8">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="12,4,0,0">
                                <Button Name="btnLerFicha" Style="{StaticResource BotaoPrimario}" Content="Ler agora"/>
                                <Button Name="btnCopiarFicha" Style="{StaticResource BotaoBase}" Content="Copiar texto" Margin="8,0,0,0"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock Text="Ficha técnica" Style="{StaticResource TituloPagina}"/>
                                <TextBlock Name="lblFichaSub" Style="{StaticResource SubtituloPagina}" Text="Inventário de hardware e do Windows, somente leitura. Vai para o laudo quando a tarefa 'Ficha técnica' está marcada."/>
                            </StackPanel>
                        </DockPanel>
                        <!-- Grade de cartões (duas colunas, mesma altura por linha), montada por Atualizar-PaginaSistema -->
                        <Border Name="bdFicha" Margin="0,14,0,0" Visibility="Collapsed">
                            <Grid Name="gdFicha"/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- FERRAMENTAS -->
                <ScrollViewer Name="pgFerramentas" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="16,2,12,8">
                        <TextBlock Text="Ferramentas" Style="{StaticResource TituloPagina}"/>
                        <TextBlock Style="{StaticResource SubtituloPagina}" Text="Ações pontuais que não fazem parte da manutenção programada."/>
                        <WrapPanel Name="wpFerramentas" Margin="0,14,0,0"/>
                    </StackPanel>
                </ScrollViewer>

                <!-- CONFIGURAÇÕES -->
                <ScrollViewer Name="pgConfig" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Margin="16,2,12,8" MaxWidth="860" HorizontalAlignment="Left">
                        <TextBlock Text="Configurações" Style="{StaticResource TituloPagina}"/>
                        <TextBlock Style="{StaticResource SubtituloPagina}" Text="As alterações são salvas automaticamente."/>

                        <Border Style="{StaticResource Cartao}" Padding="18,16" Margin="0,18,0,0">
                            <StackPanel>
                                <TextBlock Text="Aparência" Style="{StaticResource TituloCartao}"/>
                                <TextBlock Text="Tema" Style="{StaticResource Rotulo}" Margin="0,12,0,6"/>
                                <Border Background="{DynamicResource Fundo}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="7" Padding="3" HorizontalAlignment="Left" Width="390">
                                    <Grid>
                                        <Border Style="{StaticResource Pilula}"/>
                                        <UniformGrid Name="ugTema" Rows="1">
                                            <RadioButton Name="rbTemaSistema" GroupName="tema" Tag="Sistema" Content="Igual ao Windows" Style="{StaticResource Segmento}"/>
                                            <RadioButton Name="rbTemaClaro" GroupName="tema" Tag="Claro" Content="Claro" Style="{StaticResource Segmento}"/>
                                            <RadioButton Name="rbTemaEscuro" GroupName="tema" Tag="Escuro" Content="Escuro" Style="{StaticResource Segmento}"/>
                                        </UniformGrid>
                                    </Grid>
                                </Border>
                                <CheckBox Name="chkMica" Content="Efeito Mica no fundo da janela (Windows 11 22H2 ou mais novo; vale ao reabrir)" Margin="0,14,0,0"/>
                            </StackPanel>
                        </Border>

                        <Border Style="{StaticResource Cartao}" Padding="18,16" Margin="0,14,0,0">
                            <StackPanel>
                                <TextBlock Text="Identidade do laudo (edição Técnico)" Style="{StaticResource TituloCartao}"/>
                                <TextBlock Name="lblMarcaNota" Style="{StaticResource SubtituloPagina}" Text="Nome, telefone e logotipo da sua assistência aparecem no cabeçalho do laudo; os campos Cliente e Ordem de serviço aparecem na página Manutenção."/>
                                <Grid Margin="0,12,0,0">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                                    <StackPanel><TextBlock Text="Nome da assistência / técnico" Style="{StaticResource Rotulo}"/><TextBox Name="txtMarcaNome" Margin="0,5,0,10"/></StackPanel>
                                    <StackPanel Grid.Column="2"><TextBlock Text="Telefone / WhatsApp" Style="{StaticResource Rotulo}"/><TextBox Name="txtMarcaTelefone" Margin="0,5,0,10"/></StackPanel>
                                    <StackPanel Grid.Row="1"><TextBlock Text="E-mail ou site" Style="{StaticResource Rotulo}"/><TextBox Name="txtMarcaContato" Margin="0,5,0,0"/></StackPanel>
                                    <StackPanel Grid.Row="1" Grid.Column="2"><TextBlock Text="Técnico responsável (opcional)" Style="{StaticResource Rotulo}"/><TextBox Name="txtMarcaTecnico" Margin="0,5,0,0"/></StackPanel>
                                </Grid>
                                <DockPanel Margin="0,14,0,0">
                                    <Button Name="btnLogoRemover" DockPanel.Dock="Right" Style="{StaticResource BotaoPerigo}" Content="Remover" Margin="8,0,0,0"/>
                                    <Button Name="btnLogo" DockPanel.Dock="Right" Style="{StaticResource BotaoBase}" Content="Escolher logotipo..."/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Logotipo (PNG, JPG ou SVG, até 600 KB)" Style="{StaticResource Rotulo}"/>
                                        <TextBlock Name="lblLogo" Text="Nenhum logotipo" Foreground="{DynamicResource Texto3}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,3,12,0"/>
                                    </StackPanel>
                                </DockPanel>
                                <CheckBox Name="chkMarcaLaudo" Content="Mostrar a identidade no laudo" IsChecked="True" Margin="0,14,0,0"/>
                            </StackPanel>
                        </Border>

                        <Border Style="{StaticResource Cartao}" Padding="18,16" Margin="0,14,0,0">
                            <StackPanel>
                                <TextBlock Text="Licença" Style="{StaticResource TituloCartao}"/>
                                <TextBlock Name="lblLicencaStatus" FontSize="13" Margin="0,8,0,0" TextWrapping="Wrap"/>
                                <TextBlock Name="lblLicencaAjuda" Style="{StaticResource SubtituloPagina}" Text="Edição Casa: todas as tarefas de manutenção neste computador. Edição Técnico: tudo da Casa, mais laudo com a sua marca, campos de cliente/OS, exportação em PDF e uso em qualquer computador (inclusive do pendrive). O diagnóstico e o laudo continuam gratuitos para sempre."/>
                                <DockPanel Margin="0,12,0,0">
                                    <Button Name="btnCopiarCodigo" DockPanel.Dock="Right" Style="{StaticResource BotaoBase}" Content="Copiar código" Margin="12,0,0,0"/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Código deste computador (informe ao comprar a edição Casa)" Style="{StaticResource Rotulo}"/>
                                        <TextBlock Name="lblCodigoMaquina" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="15" Margin="0,3,0,0"/>
                                    </StackPanel>
                                </DockPanel>
                                <TextBlock Text="Cole aqui a licença recebida" Style="{StaticResource Rotulo}" Margin="0,14,0,5"/>
                                <TextBox Name="txtLicenca" Height="72" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Mono, Consolas" FontSize="11.5"/>
                                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                    <Button Name="btnAtivar" Style="{StaticResource BotaoPrimario}" Content="Ativar licença"/>
                                    <Button Name="btnRemoverLicenca" Style="{StaticResource BotaoPerigo}" Content="Remover licença deste computador" Margin="8,0,0,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Style="{StaticResource Cartao}" Padding="18,16" Margin="0,14,0,0">
                            <StackPanel>
                                <TextBlock Text="Atualizações" Style="{StaticResource TituloCartao}"/>
                                <TextBlock Name="lblVersaoAtual" Style="{StaticResource SubtituloPagina}"/>
                                <CheckBox Name="chkAtualizacoes" Content="Avisar quando houver uma versão nova (consulta um arquivo de versão pela internet ao abrir)" Margin="0,12,0,0"/>
                                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                    <Button Name="btnVerificarAtualizacao" Style="{StaticResource BotaoBase}" Content="Verificar agora"/>
                                    <Button Name="btnSite" Style="{StaticResource BotaoSutil}" Content="Abrir o site do produto" Margin="8,0,0,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Style="{StaticResource Cartao}" Padding="18,16" Margin="0,14,0,0">
                            <StackPanel>
                                <TextBlock Text="Dados do programa" Style="{StaticResource TituloCartao}"/>
                                <TextBlock Name="lblPastaDados" Style="{StaticResource SubtituloPagina}"/>
                                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                    <Button Name="btnAbrirPasta" Style="{StaticResource BotaoBase}" Content="Abrir pasta de laudos e logs"/>
                                    <Button Name="btnLimparHistorico" Style="{StaticResource BotaoPerigo}" Content="Apagar histórico de pontuações" Margin="8,0,0,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </Grid>
        </Grid>
    </Grid>
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $XAML))
foreach ($n in @("lblVersaoNav", "bdEdicao", "icoEdicao", "lblEdicaoTitulo", "lblEdicaoDetalhe", "spNav", "navInicio", "navManutencao", "navHistorico", "navSistema", "navFerramentas", "navConfig",
                 "spAvisos", "pgInicio", "lblInicioSub", "anelValor", "lblNota", "lblNotaDe", "lblNotaRotulo", "lblNotaDetalhe", "lblNotaComparacao", "btnAvaliar", "btnManutencaoCompleta",
                 "ugIndicadores", "wpUnidades", "bdPerdas", "lblPerdasTitulo", "spPerdas",
                 "pgManutencao", "bdAtendimento", "txtCliente", "txtOS", "txtObservacoes", "ugPerfis", "rbDiagnostico", "rbRapida", "rbCompleta", "rbReparo", "rbPersonalizada", "lblPerfilDesc", "spTarefas",
                 "bdEstado", "icoEstado", "lblEtapa", "lblDetalhe", "spAcoesLaudo", "btnAbrirLaudo", "btnPdf", "btnVerPontuacao", "lblDecorrido", "pbStatus", "rtbLog",
                 "chkLaudo", "bdFormato", "ugFormato", "rbResumido", "rbDetalhado", "chkDesligar", "lblTempo", "btnPausar", "icoPausar", "txtPausar", "btnCancelar", "btnIniciar", "icoIniciar", "txtIniciar",
                 "pgHistorico", "bdEvolucao", "lblHistResumo", "gdSpark", "plSpark", "cvSpark", "ugTendencias", "spHistorico",
                 "pgSistema", "btnLerFicha", "btnCopiarFicha", "lblFichaSub", "bdFicha", "gdFicha",
                 "pgFerramentas", "wpFerramentas",
                 "pgConfig", "ugTema", "rbTemaSistema", "rbTemaClaro", "rbTemaEscuro", "chkMica", "lblMarcaNota", "txtMarcaNome", "txtMarcaTelefone", "txtMarcaContato", "txtMarcaTecnico",
                 "btnLogo", "btnLogoRemover", "lblLogo", "chkMarcaLaudo", "lblLicencaStatus", "lblLicencaAjuda", "btnCopiarCodigo", "lblCodigoMaquina", "txtLicenca", "btnAtivar", "btnRemoverLicenca",
                 "lblVersaoAtual", "chkAtualizacoes", "btnVerificarAtualizacao", "btnSite", "lblPastaDados", "btnAbrirPasta", "btnLimparHistorico")) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}
Aplicar-TemaJanela $Window $true
$lblVersaoNav.Text = "versão $($script:Versao)"
$Window.Height = [math]::Min(800, [System.Windows.SystemParameters]::WorkArea.Height - 24)
$Window.Width = [math]::Min(1180, [System.Windows.SystemParameters]::WorkArea.Width - 24)

# ---------- Registro colorido na tela ----------
Function Adicionar-LinhaLog([string]$Hora, [string]$Texto) {
    $Chave = 'LogTexto'
    if ($Texto -match '^\[ERRO\]') { $Chave = 'Erro' }
    elseif ($Texto -match '^\[AVISO\]') { $Chave = 'Aviso' }
    elseif ($Texto -match '^\[OK\]') { $Chave = 'Sucesso' }
    elseif ($Texto -match '^(===|>>>)') { $Chave = 'Destaque' }
    elseif ($Texto -match '^\s*-> \[CRÍTICO\]') { $Chave = 'Erro' }
    elseif ($Texto -match '^\s*-> \[ATENÇÃO\]') { $Chave = 'Aviso' }
    elseif ($Texto -match '^\s*->') { $Chave = 'Texto2' }
    $Par = New-Object System.Windows.Documents.Paragraph
    $Par.Margin = New-Object System.Windows.Thickness 0, 0, 0, 3
    if ($Hora) {
        $RHora = New-Object System.Windows.Documents.Run "$Hora  "
        $RHora.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'Texto3')
        $Par.Inlines.Add($RHora)
    }
    $RTexto = New-Object System.Windows.Documents.Run $Texto
    $RTexto.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, $Chave)
    if ($Chave -eq 'Destaque') { $RTexto.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $Par.Inlines.Add($RTexto)
    $rtbLog.Document.Blocks.Add($Par)
    $rtbLog.ScrollToEnd()
}

# ---------- Estado (ícone + título + detalhe do painel de atividade) ----------
$script:Estados = @{
    Pronto    = @{ Fundo = 'InfoFundo';    Cor = 'Destaque'; Glifo = 0xE9D9 }
    Rodando   = @{ Fundo = 'InfoFundo';    Cor = 'Destaque'; Glifo = 0xE895 }
    Pausado   = @{ Fundo = 'AvisoFundo';   Cor = 'Aviso';    Glifo = 0xE769 }
    Sucesso   = @{ Fundo = 'SucessoFundo'; Cor = 'Sucesso';  Glifo = 0xE73E }
    Aviso     = @{ Fundo = 'AvisoFundo';   Cor = 'Aviso';    Glifo = 0xE7BA }
    Erro      = @{ Fundo = 'ErroFundo';    Cor = 'Erro';     Glifo = 0xE783 }
    Cancelado = @{ Fundo = 'AvisoFundo';   Cor = 'Aviso';    Glifo = 0xE711 }
}
Function Mostrar-Estado([string]$Estado, [string]$Titulo, [string]$Detalhe) {
    if ($Estado -and $script:Estados.ContainsKey($Estado)) {
        $E = $script:Estados[$Estado]
        $bdEstado.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $E.Fundo)
        $icoEstado.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $E.Cor)
        $icoEstado.Text = [string][char]$E.Glifo
        $pbStatus.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $(if ($Estado -in 'Rodando', 'Pronto') { 'Destaque' } else { $E.Cor }))
    }
    if ($Titulo) { $lblEtapa.Text = $Titulo }
    if ($Detalhe) { $lblDetalhe.Text = $Detalhe }
}

# ---------- Avisos no topo da área de conteúdo (aparecem em qualquer página) ----------
$script:AvisosUI = @{}
Function Remover-Aviso([string]$Id) {
    if ($script:AvisosUI.ContainsKey($Id)) { $spAvisos.Children.Remove($script:AvisosUI[$Id]); $script:AvisosUI.Remove($Id) }
}
Function Adicionar-Aviso {
    param ([string]$Id, [ValidateSet('Info', 'Aviso', 'Erro')][string]$Tipo = 'Info', [string]$Texto, [string]$TextoBotao, [scriptblock]$Acao, [object]$Dados)
    Remover-Aviso $Id
    $Fundo = @{ Info = 'InfoFundo'; Aviso = 'AvisoFundo'; Erro = 'ErroFundo' }[$Tipo]
    $Cor = @{ Info = 'Destaque'; Aviso = 'Aviso'; Erro = 'Erro' }[$Tipo]
    $Glifo = @{ Info = 'E946'; Aviso = 'E7BA'; Erro = 'E783' }[$Tipo]
    $BotaoXaml = if ($TextoBotao) { "<Button x:Name=`"acao`" DockPanel.Dock=`"Right`" Style=`"{DynamicResource BotaoBase}`" Height=`"30`" Margin=`"12,0,0,0`" Content=`"$(Esc $TextoBotao)`"/>" } else { "" }
    $El = Criar-Elemento @"
<Border $($script:NsXaml) Background="{DynamicResource $Fundo}" CornerRadius="6" Padding="14,8" Margin="0,0,0,10">
    <DockPanel>
        <TextBlock DockPanel.Dock="Left" Text="&#x$Glifo;" FontFamily="$($script:FonteIcones)" FontSize="16" Foreground="{DynamicResource $Cor}" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="fechar" DockPanel.Dock="Right" Style="{DynamicResource BotaoSutil}" Width="30" Height="30" Padding="0" Margin="6,0,0,0" ToolTip="Dispensar">
            <TextBlock Text="&#xE711;" FontFamily="$($script:FonteIcones)" FontSize="10"/>
        </Button>
        $BotaoXaml
        <TextBlock Text="$(Esc $Texto)" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </DockPanel>
</Border>
"@
    $Fechar = $El.FindName("fechar")
    $Fechar.Tag = $Id
    $Fechar.Add_Click({ Remover-Aviso $this.Tag })
    if ($TextoBotao) {
        $Btn = $El.FindName("acao")
        $Btn.Tag = @{ Id = $Id; Acao = $Acao; Dados = $Dados }
        $Btn.Add_Click({ & $this.Tag.Acao $this.Tag })
    }
    [void]$spAvisos.Children.Add($El)
    $script:AvisosUI[$Id] = $El
}

# ---------- Navegação entre páginas (esmaecimento curto ao trocar) ----------
$script:Paginas = [ordered]@{ Inicio = $pgInicio; Manutencao = $pgManutencao; Historico = $pgHistorico; Sistema = $pgSistema; Ferramentas = $pgFerramentas; Config = $pgConfig }
$script:NavItens = @{ Inicio = $navInicio; Manutencao = $navManutencao; Historico = $navHistorico; Sistema = $navSistema; Ferramentas = $navFerramentas; Config = $navConfig }
$script:PaginaAtual = ""
Function Mostrar-Pagina([string]$Id) {
    if (-not $script:Paginas.Contains($Id)) { return }
    if (-not $script:NavItens[$Id].IsChecked) { $script:NavItens[$Id].IsChecked = $true; return } # o evento Checked chama de novo
    if ($script:PaginaAtual -eq $Id) { return }
    $script:PaginaAtual = $Id
    foreach ($k in $script:Paginas.Keys) { $script:Paginas[$k].Visibility = $(if ($k -eq $Id) { 'Visible' } else { 'Collapsed' }) }
    switch ($Id) { 'Inicio' { Atualizar-PaginaInicio } 'Historico' { Atualizar-PaginaHistorico } 'Sistema' { Atualizar-PaginaSistema } 'Ferramentas' { Atualizar-PaginaFerramentas } 'Config' { Atualizar-PaginaConfig } }
    $Anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $Anim.From = 0; $Anim.To = 1; $Anim.Duration = [TimeSpan]::FromMilliseconds(200)
    $Curva = New-Object System.Windows.Media.Animation.CubicEase; $Curva.EasingMode = 'EaseOut'; $Anim.EasingFunction = $Curva
    $script:Paginas[$Id].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $Anim)
    $script:Config.PaginaInicial = $Id
}
foreach ($k in $script:NavItens.Keys) { $script:NavItens[$k].Add_Checked({ Mostrar-Pagina ($this.Name -replace '^nav', '') }) }

# ---------- Anel de pontuação (página Início): centro 75,75 e raio 69 na linha central do traço ----------
# A elipse de trilha tem margem 0,5 e traço 11 numa caixa de 150: o WPF recua a geometria em meio traço,
# então a linha central dela também fica no raio 69 e os dois anéis coincidem.
Function Definir-Anel([double]$Pct) {
    if ($Pct -le 0.1) { $anelValor.Data = $null; return }
    if ($Pct -ge 100) { $Pct = 99.99 }
    $Ang = $Pct / 100 * 2 * [math]::PI
    $Ex = 75 + 69 * [math]::Sin($Ang); $Ey = 75 - 69 * [math]::Cos($Ang)
    $Grande = if ($Pct -gt 50) { 1 } else { 0 }
    $anelValor.Data = [System.Windows.Media.Geometry]::Parse("M 75,6 A 69,69 0 $Grande 1 $(Num $Ex 2),$(Num $Ey 2)")
}
$script:AnimAnel = @{ De = 0.0; Para = 0.0; Inicio = $null; Timer = $null }
Function Animar-Anel([int]$Para, [string]$Cor) {
    $anelValor.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, $Cor)
    if (-not $script:AnimAnel.Timer) {
        $script:AnimAnel.Timer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AnimAnel.Timer.Interval = [TimeSpan]::FromMilliseconds(16)
        $script:AnimAnel.Timer.Add_Tick({
            $A = $script:AnimAnel
            $t = [math]::Min(1.0, ((Get-Date) - $A.Inicio).TotalMilliseconds / 900.0)
            $v = $A.De + ($A.Para - $A.De) * (1 - [math]::Pow(1 - $t, 3))
            Definir-Anel $v
            $lblNota.Text = [string][int][math]::Round($v)
            if ($t -ge 1) { $A.Timer.Stop() }
        })
    }
    $script:AnimAnel.De = [double]$script:AnimAnel.Para
    $script:AnimAnel.Para = [double]$Para
    $script:AnimAnel.Inicio = Get-Date
    $script:AnimAnel.Timer.Start()
}

# ---------- Página Início: indicadores, perdas e unidades ----------
Function Cor-Nivel([string]$Nivel) {
    switch ($Nivel) { 'Critico' { return 'Erro' } 'Atencao' { return 'Aviso' } 'OK' { return 'Sucesso' } }
    return 'Texto3'
}
Function Xaml-Indicador([string]$Titulo, [string]$Texto, [string]$Nivel) {
    $Cor = Cor-Nivel $Nivel
    $Glifo = switch -Regex ($Titulo) { '^Disco' { 'EDA2' } '^Segur' { 'EA18' } '^Estab' { 'E9D9' } default { 'E8B7' } }
    return @"
<Border $($script:NsXaml) Margin="0,0,8,8" Padding="12,10" CornerRadius="6" Background="{DynamicResource PainelAlt}" BorderBrush="{DynamicResource Borda}" BorderThickness="1">
    <DockPanel>
        <Ellipse DockPanel.Dock="Right" Width="9" Height="9" Fill="{DynamicResource $Cor}" VerticalAlignment="Top" Margin="8,4,0,0"/>
        <TextBlock DockPanel.Dock="Left" Text="&#x$Glifo;" FontFamily="$($script:FonteIcones)" FontSize="16" Foreground="{DynamicResource Texto2}" VerticalAlignment="Top" Margin="0,2,10,0"/>
        <StackPanel>
            <TextBlock Text="$(Esc $Titulo)" FontSize="12.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="$(Esc $Texto)" FontSize="11.5" Foreground="{DynamicResource Texto2}" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
    </DockPanel>
</Border>
"@
}
Function Xaml-Perda([int]$Pontos, [string]$Motivo, [string]$Acao) {
    $AcaoXaml = if ($Acao) { "<TextBlock Text=`"$(Esc "O que fazer: $Acao")`" FontSize=`"11.5`" Foreground=`"{DynamicResource Texto3}`" TextWrapping=`"Wrap`" Margin=`"0,2,0,0`"/>" } else { "" }
    return @"
<Border $($script:NsXaml) BorderBrush="{DynamicResource Borda}" BorderThickness="0,1,0,0" Padding="0,8">
    <DockPanel>
        <Border DockPanel.Dock="Left" Background="{DynamicResource ErroFundo}" CornerRadius="4" Padding="7,1" VerticalAlignment="Top" Margin="0,1,12,0" MinWidth="40">
            <TextBlock Text="-$Pontos" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource Erro}" HorizontalAlignment="Center"/>
        </Border>
        <StackPanel>
            <TextBlock Text="$(Esc $Motivo)" FontSize="12.5" TextWrapping="Wrap"/>
            $AcaoXaml
        </StackPanel>
    </DockPanel>
</Border>
"@
}

Function Atualizar-PaginaInicio {
    $Avaliacoes = @(Obter-EntradasComNota)
    $Ult = if ($Avaliacoes.Count -gt 0) { $Avaliacoes[-1] } else { $null }
    $ugIndicadores.Children.Clear(); $spPerdas.Children.Clear()
    $ComNota = ($null -ne $Ult)
    if (-not $ComNota) {
        $lblNotaRotulo.Text = "Sem avaliação ainda"
        $lblNotaRotulo.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Texto')
        $lblNotaDetalhe.Text = "Avalie o computador: leva cerca de 1 minuto e nada é alterado."
        $lblNotaComparacao.Visibility = 'Collapsed'
        $lblNota.Text = "–"; $anelValor.Data = $null; $script:AnimAnel.Para = 0.0
        $bdPerdas.Visibility = 'Collapsed'
        foreach ($T in 'Discos', 'Segurança', 'Estabilidade', 'Espaço') { [void]$ugIndicadores.Children.Add((Criar-Elemento (Xaml-Indicador $T 'Sem dados ainda' 'Info'))) }
        return
    }
    $Nota = [int]$Ult.Nota
    $Cor = if ($Nota -ge 75) { 'Sucesso' } elseif ($Nota -ge 50) { 'Aviso' } else { 'Erro' }
    $lblNotaRotulo.Text = Descrever-Nota $Nota
    $lblNotaRotulo.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Cor)
    $Quando = [datetime]$Ult.Data
    $lblNotaDetalhe.Text = "Última avaliação: $($Quando.ToString('dd/MM/yyyy HH:mm')) · perfil $($Ult.Perfil)" + $(if ("$($Ult.Cliente)".Trim()) { " · $($Ult.Cliente)" } else { "" })
    Animar-Anel $Nota $Cor
    $Ant = if ($Avaliacoes.Count -ge 2) { $Avaliacoes[-2] } else { $null }
    if ($Ant -and $null -ne $Ant.Nota -and "$($Ant.Nota)" -ne "") {
        $Delta = $Nota - [int]$Ant.Nota
        $lblNotaComparacao.Text = "Avaliação anterior: $($Ant.Nota) em $(([datetime]$Ant.Data).ToString('dd/MM/yyyy')) · " + $(if ($Delta -gt 0) { "melhorou $Delta ponto(s)" } elseif ($Delta -lt 0) { "caiu $(-$Delta) ponto(s)" } else { "sem mudança" })
        $lblNotaComparacao.Visibility = 'Visible'
    } else { $lblNotaComparacao.Visibility = 'Collapsed' }
    $Ind = @($Ult.Indicadores | Where-Object { $_ })
    if ($Ind.Count -eq 0) { foreach ($T in 'Discos', 'Segurança', 'Estabilidade', 'Espaço') { [void]$ugIndicadores.Children.Add((Criar-Elemento (Xaml-Indicador $T 'Sem dados' 'Info'))) } }
    else { foreach ($I in $Ind) { [void]$ugIndicadores.Children.Add((Criar-Elemento (Xaml-Indicador "$($I.Titulo)" "$($I.Texto)" "$($I.Nivel)"))) } }
    $Perdas = @($Ult.Perdas | Where-Object { $_ })
    $bdPerdas.Visibility = 'Visible'
    if ($Perdas.Count -eq 0) {
        $lblPerdasTitulo.Text = "Nenhum ponto perdido"
        [void]$spPerdas.Children.Add((Criar-Elemento "<TextBlock $($script:NsXaml) Text=`"Todos os itens verificados estavam em ordem na última avaliação.`" Foreground=`"{DynamicResource Texto2}`" FontSize=`"12.5`"/>"))
    } else {
        $lblPerdasTitulo.Text = "O que puxou a nota para baixo"
        foreach ($P in @($Perdas | Select-Object -First 6)) {
            if ($P -is [string]) { $Pontos = 0; $Motivo = $P; $Acao = "" } else { $Pontos = [int]$P.Pontos; $Motivo = "$($P.Motivo)"; $Acao = "$($P.Acao)" }
            [void]$spPerdas.Children.Add((Criar-Elemento (Xaml-Perda $Pontos $Motivo $Acao)))
        }
    }
}

# ---------- Cartões das unidades (C:, D: ...) ----------
Function Atualizar-Unidades {
    $wpUnidades.Children.Clear()
    foreach ($U in @(Obter-Unidades)) {
        $Glifo = if ($U.Tipo -eq "Cartão de memória") { 'E7F1' } elseif ($U.Tipo -eq "Unidade USB") { 'E88E' } else { 'EDA2' }
        $Papel = if ($U.Sistema) { "Sistema" } elseif ($U.Rotulo) { $U.Rotulo } else { "Dados" }
        $Minimo = if ($U.Sistema) { 15 } else { 10 }
        $CorBarra = if ($U.PercLivre -lt $Minimo) { 'Aviso' } else { 'Destaque' }
        $Uso = [math]::Round(100 - $U.PercLivre)
        $El = Criar-Elemento @"
<Border $($script:NsXaml) Background="{DynamicResource Painel}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="8" Padding="14,11" Margin="0,0,12,10" Width="272">
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#x$Glifo;" FontFamily="$($script:FonteIcones)" FontSize="22" Foreground="{DynamicResource Texto2}" VerticalAlignment="Top" Margin="0,3,12,0"/>
        <StackPanel Grid.Column="1">
            <DockPanel>
                <TextBlock DockPanel.Dock="Right" Text="$(Esc (Formatar-Pct $U.PercLivre)) livre" Foreground="{DynamicResource Texto2}" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock FontWeight="SemiBold" TextTrimming="CharacterEllipsis"><Run Text="$($U.Letra):"/><Run Text="  $(Esc $Papel)" FontWeight="Normal" Foreground="{DynamicResource Texto2}"/></TextBlock>
            </DockPanel>
            <TextBlock Text="$(Esc "$($U.Tipo) · $($U.FS)")" Foreground="{DynamicResource Texto3}" FontSize="12" Margin="0,1,0,8"/>
            <ProgressBar Value="$Uso" Maximum="100" Foreground="{DynamicResource $CorBarra}"/>
            <TextBlock Text="$(Esc "$(Formatar-Tamanho $U.LivreBytes) livres de $(Formatar-Tamanho $U.TotalBytes)")" Foreground="{DynamicResource Texto3}" FontSize="11.5" Margin="0,6,0,0"/>
        </StackPanel>
    </Grid>
</Border>
"@
        $El.ToolTip = "$(Descrever-Unidade $U)`nSaúde do volume: $($U.Saude)$(if ($U.Sujo) { "`nMarcada para verificação pelo Windows" })"
        [void]$wpUnidades.Children.Add($El)
    }
}

# ---------- Lista de tarefas agrupada ----------
$script:SeloEstilo = @{
    'Requer reinício'   = @{ Fundo = 'AvisoFundo'; Cor = 'Aviso' }
    'Confirmação'       = @{ Fundo = 'InfoFundo'; Cor = 'Destaque' }
    'Não interrompível' = @{ Fundo = 'Hover'; Cor = 'Texto2' }
    'Somente leitura'   = @{ Fundo = 'SucessoFundo'; Cor = 'Sucesso' }
}
foreach ($G in $script:Grupos) {
    $DoGrupo = @($script:Tarefas | Where-Object { $_.Grupo -eq $G })
    if ($DoGrupo.Count -eq 0) { continue }
    $Margem = if ($spTarefas.Children.Count -eq 0) { "10,6,0,4" } else { "10,16,0,4" }
    [void]$spTarefas.Children.Add((Criar-Elemento "<TextBlock $($script:NsXaml) Text=`"$(Esc $G)`" Style=`"{DynamicResource Rotulo}`" Margin=`"$Margem`"/>"))
    foreach ($T in $DoGrupo) {
        $SeloXaml = ""
        $Selos = @(); if ($T.Selo) { $Selos += $T.Selo }; if ($T.SomenteLeitura) { $Selos += 'Somente leitura' }
        foreach ($SeloNome in $Selos) {
            $S = $script:SeloEstilo[$SeloNome]
            if (-not $S) { $S = @{ Fundo = 'Hover'; Cor = 'Texto2' } }
            $SeloXaml += "<Border Background=`"{DynamicResource $($S.Fundo)}`" CornerRadius=`"4`" Padding=`"6,1`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$(Esc $SeloNome)`" FontSize=`"11`" Foreground=`"{DynamicResource $($S.Cor)}`"/></Border>"
        }
        $BotaoApps = if ($T.Id -eq "Debloat") { "<Button x:Name=`"btnApps`" Style=`"{DynamicResource BotaoLink}`" Content=`"Escolher apps (0)`" HorizontalAlignment=`"Left`" Margin=`"0,4,0,0`"/>" } else { "" }
        $cb = Criar-Elemento @"
<CheckBox $($script:NsXaml) Style="{DynamicResource LinhaTarefa}" ToolTip="$(Esc $T.Dica)">
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
            <WrapPanel>
                <TextBlock Text="$(Esc $T.Nome)" FontSize="13.5" VerticalAlignment="Center"/>
                $SeloXaml
            </WrapPanel>
            <TextBlock Text="$(Esc $T.Resumo)" FontSize="12" Foreground="{DynamicResource Texto2}" TextWrapping="Wrap" Margin="0,2,0,0"/>
            $BotaoApps
        </StackPanel>
        <TextBlock Grid.Column="1" Text="$($T.Minutos) min" FontSize="11.5" Foreground="{DynamicResource Texto3}" Margin="12,2,0,0"/>
    </Grid>
</CheckBox>
"@
        $cb.Add_Click({ Selecionar-Perfil "Personalizada"; Atualizar-TempoEstimado })
        $T.Checkbox = $cb
        if ($T.Id -eq "Debloat") {
            $T.Botao = $cb.FindName("btnApps")
            $T.Botao.Add_Click({ Abrir-SeletorDebloat })
        }
        [void]$spTarefas.Children.Add($cb)
    }
}

# ---------- Segmentos com pílula deslizante (Perfil, formato do laudo e tema) ----------
# A pílula é o 1º filho do Grid que contém o UniformGrid dos botões; ela corre até o item marcado
# com desaceleração suave e, se o clique vier no meio do caminho, muda de rumo sem dar salto.
$script:DuracaoPilulaMs = 380
# ---------- Texto que não cabe: some esmaecendo pela direita em vez de ser cortado seco ----------
# Usado nos segmentos e no botão "Manutenção completa". No WPF um TextBlock que não cabe é recortado pelo pai: o DesiredSize
# fica limitado ao espaço disponível (largura visível), mas o ActualWidth continua sendo a largura natural do texto. A máscara
# usa coordenadas absolutas, para o esmaecimento terminar exatamente na borda visível.
Function Medir-LarguraTexto($Tb) {
    $Tipo = New-Object System.Windows.Media.Typeface $Tb.FontFamily, $Tb.FontStyle, $Tb.FontWeight, $Tb.FontStretch
    $Ppd = [double][System.Windows.Media.VisualTreeHelper]::GetDpi($Tb).PixelsPerDip
    $Ft = New-Object System.Windows.Media.FormattedText "$($Tb.Text)", ([Globalization.CultureInfo]::CurrentUICulture), $Tb.FlowDirection, $Tipo, ([double]$Tb.FontSize), ([System.Windows.Media.Brushes]::Black), $Ppd
    return $Ft.WidthIncludingTrailingWhitespace + $Tb.Padding.Left + $Tb.Padding.Right
}
Function Atualizar-Desvanecimento($Tb) {
    $Mascara = $null
    try {
        $Visivel = [math]::Min($Tb.DesiredSize.Width, $Tb.ActualWidth)
        $Natural = [math]::Max($Tb.ActualWidth, (Medir-LarguraTexto $Tb))
        if ($Visivel -gt 0 -and "$($Tb.Text)" -ne "" -and $Natural -gt ($Visivel + 1)) {
            $Mascara = New-Object System.Windows.Media.LinearGradientBrush
            $Mascara.MappingMode = 'Absolute'
            $Mascara.StartPoint = New-Object System.Windows.Point ([math]::Max(0, $Visivel - 26)), 0
            $Mascara.EndPoint = New-Object System.Windows.Point $Visivel, 0
            $Mascara.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Colors]::Black), 0.0))
            $Mascara.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Colors]::Transparent), 1.0))
            $Mascara.Freeze()
        }
    } catch {}
    $Tb.OpacityMask = $Mascara
}
Function Obter-Descendentes($Raiz) {
    $Lista = New-Object System.Collections.Generic.List[object]
    $Fila = New-Object System.Collections.Generic.Queue[object]
    $Fila.Enqueue($Raiz)
    while ($Fila.Count -gt 0) {
        $Atual = $Fila.Dequeue()
        if ($Atual -isnot [System.Windows.Media.Visual]) { continue }
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Atual)
        for ($i = 0; $i -lt $n; $i++) { $Filho = [System.Windows.Media.VisualTreeHelper]::GetChild($Atual, $i); $Lista.Add($Filho); $Fila.Enqueue($Filho) }
    }
    return $Lista
}
# Reavalia cada TextBlock de uma linha dentro do elemento (e liga o SizeChanged dele na primeira vez). O conteúdo de botões e
# segmentos só vira TextBlock depois do template aplicado, por isso a busca repete em Loaded e a cada SizeChanged do elemento:
# o SizeChanged do próprio TextBlock não dispara quando só o espaço disponível muda, já que o ActualWidth dele é o natural.
Function Registrar-Desvanecimento($Raiz) {
    foreach ($Tb in @(Obter-Descendentes $Raiz | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.TextWrapping -eq 'NoWrap' -and $_.TextTrimming -eq 'None' })) {
        if (-not $Tb.Resources.Contains('Desvanecer')) {
            $Tb.Resources['Desvanecer'] = $true
            $Tb.Add_SizeChanged({ Atualizar-Desvanecimento $this })
        }
        Atualizar-Desvanecimento $Tb
    }
}
Function Ativar-Desvanecimento($Raiz) {
    $Raiz.Add_Loaded({ Registrar-Desvanecimento $this })
    $Raiz.Add_SizeChanged({ Registrar-Desvanecimento $this })
}

Function Mover-Pilula($Painel, [bool]$Animar) {
    $Pilula = $Painel.Parent.Children[0]
    $Marcado = @($Painel.Children | Where-Object { $_.IsChecked })[0]
    if (-not $Marcado -or $Painel.ActualWidth -le 0) { return }
    $Largura = [math]::Round($Painel.ActualWidth / $Painel.Children.Count)
    $X = [math]::Round($Painel.Children.IndexOf($Marcado) * $Painel.ActualWidth / $Painel.Children.Count)
    $Pilula.Width = $Largura
    $PropX = [System.Windows.Media.TranslateTransform]::XProperty
    if ($Animar) {
        $Anim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $Anim.To = $X
        $Anim.Duration = [TimeSpan]::FromMilliseconds($script:DuracaoPilulaMs)
        $Curva = New-Object System.Windows.Media.Animation.QuinticEase
        $Curva.EasingMode = 'EaseOut'
        $Anim.EasingFunction = $Curva
        $Pilula.Tag = (Get-Date).AddMilliseconds($script:DuracaoPilulaMs)
        $Pilula.RenderTransform.BeginAnimation($PropX, $Anim)
    } else {
        $Pilula.RenderTransform.BeginAnimation($PropX, $null)
        $Pilula.RenderTransform.X = $X
    }
}

# O texto do item marcado clareia quando a pílula já está chegando (antes ficaria invisível sobre o fundo claro)
Function Colorir-Segmento($Radio, [bool]$Animar) {
    $Cor = [System.Windows.Media.ColorConverter]::ConvertFromString($(if ($Radio.IsChecked) { $script:Paleta.SobreDestaque } else { $script:Paleta.Texto2 }))
    $PropCor = [System.Windows.Media.SolidColorBrush]::ColorProperty
    if (-not $Animar) { $Radio.Foreground.BeginAnimation($PropCor, $null); $Radio.Foreground.Color = $Cor; return }
    $Anim = New-Object System.Windows.Media.Animation.ColorAnimation
    $Anim.To = $Cor
    # Quem sai escurece logo (a pílula já foi embora); quem chega clareia quando a pílula está por baixo
    if ($Radio.IsChecked) { $Anim.BeginTime = [TimeSpan]::FromMilliseconds(60); $Anim.Duration = [TimeSpan]::FromMilliseconds(160) }
    else { $Anim.Duration = [TimeSpan]::FromMilliseconds(90) }
    $Radio.Foreground.BeginAnimation($PropCor, $Anim)
}

Function Ativar-SegmentoDeslizante($Painel) {
    $Painel.Parent.Children[0].RenderTransform = New-Object System.Windows.Media.TranslateTransform
    foreach ($rb in $Painel.Children) {
        $rb.Foreground = New-Object System.Windows.Media.SolidColorBrush
        Colorir-Segmento $rb $false
        $rb.Add_Checked({ Mover-Pilula $this.Parent $true; Colorir-Segmento $this $true })
        $rb.Add_Unchecked({ Colorir-Segmento $this $true })
        Ativar-Desvanecimento $rb
    }
    # Na abertura e ao redimensionar a janela a pílula vai direto ao lugar; se estiver correndo, só corrige o destino
    $Painel.Add_SizeChanged({
        $Fim = $this.Parent.Children[0].Tag
        Mover-Pilula $this (($Fim -is [datetime]) -and ((Get-Date) -lt $Fim))
    })
}
Ativar-SegmentoDeslizante $ugPerfis
Ativar-SegmentoDeslizante $ugFormato
Ativar-SegmentoDeslizante $ugTema
Ativar-Desvanecimento $btnManutencaoCompleta

# ---------- Perfis ----------
$script:DescricaoPerfis = @{
    Diagnostico = "Só leitura, cerca de 1 minuto: discos, check-up completo e ficha técnica. Gera a pontuação de saúde e o laudo sem alterar nada."
    Rapida = "Semanal: diagnóstico, limpeza leve, apps atualizados e verificação rápida de vírus."
    Completa = "Mensal: ponto de restauração, diagnóstico, limpeza, reparo, atualizações, antivírus em todas as unidades e otimização."
    Reparo = "Quando algo não vai bem: diagnóstico, teste de memória, reparo do sistema, das unidades e da rede."
    Personalizada = "Marque abaixo só as tarefas que quiser executar."
}
$script:RadiosPerfil = @{ Diagnostico = $rbDiagnostico; Rapida = $rbRapida; Completa = $rbCompleta; Reparo = $rbReparo; Personalizada = $rbPersonalizada }
$script:IgnorarTrocaPerfil = $false
$script:ExecucaoAtiva = $false

Function Atualizar-TempoEstimado {
    $Total = ($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Minutos } | Measure-Object -Sum).Sum
    if (-not $Total) { $Total = 0 }
    $lblTempo.Text = "Tempo estimado ≈ $Total min"
}

Function Aplicar-Perfil([string]$Id) {
    foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = (($T.Perfis -contains $Id) -and $T.Checkbox.IsEnabled) }
    Atualizar-TempoEstimado
}

Function Selecionar-Perfil([string]$Id) {
    if (-not $script:RadiosPerfil.ContainsKey("$Id")) { $Id = "Personalizada" }
    $script:IgnorarTrocaPerfil = $true
    $script:RadiosPerfil[$Id].IsChecked = $true
    $lblPerfilDesc.Text = $script:DescricaoPerfis[$Id]
    $script:IgnorarTrocaPerfil = $false
    Atualizar-BotaoIniciar
}

foreach ($rb in $script:RadiosPerfil.Values) {
    $rb.Add_Checked({
        $lblPerfilDesc.Text = $script:DescricaoPerfis["$($this.Tag)"]
        if (-not $script:IgnorarTrocaPerfil -and $this.Tag -ne "Personalizada") { Aplicar-Perfil "$($this.Tag)" }
        Atualizar-BotaoIniciar
    })
}

Function Obter-PerfilAtual {
    foreach ($k in $script:RadiosPerfil.Keys) { if ($script:RadiosPerfil[$k].IsChecked) { return $k } }
    return "Personalizada"
}

# No perfil Diagnóstico a página Manutenção inteira troca o laranja pelo azul do Windows 11 (pílulas, caixas de marcação,
# ícone de estado, barra, links). Os pincéis são sobrescritos só nos recursos da página: a busca do DynamicResource sobe do
# elemento até a janela e encontra a página antes, então as outras páginas continuam laranja. Fora do Diagnóstico as
# sobrescritas são removidas e tudo volta ao normal.
$script:PinceisPerfilDiagnostico = @{ Destaque = 'Azul'; DestaqueHover = 'AzulHover'; DestaquePress = 'AzulPress'; SobreDestaque = 'SobreAzul'; InfoFundo = 'AzulFundo' }
Function Aplicar-CorDoPerfil([bool]$Diagnostico) {
    foreach ($Chave in $script:PinceisPerfilDiagnostico.Keys) {
        if ($Diagnostico) {
            $pgManutencao.Resources[$Chave] = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($script:Paleta[$script:PinceisPerfilDiagnostico[$Chave]]))
        } elseif ($pgManutencao.Resources.Contains($Chave)) {
            $pgManutencao.Resources.Remove($Chave)
        }
    }
}

# O botão de início muda com o perfil: "Iniciar diagnóstico" em azul (nada é alterado) ou "Iniciar manutenção" em laranja
Function Atualizar-BotaoIniciar {
    $Diagnostico = ((Obter-PerfilAtual) -eq 'Diagnostico')
    Aplicar-CorDoPerfil $Diagnostico
    $btnIniciar.Style = $Window.FindResource($(if ($Diagnostico) { 'BotaoAzul' } else { 'BotaoPrimario' }))
    $icoIniciar.Text = if ($Diagnostico) { [string][char]0xE9D9 } else { [string][char]0xE768 }
    if (-not $script:ExecucaoAtiva) { $txtIniciar.Text = if ($Diagnostico) { "Iniciar diagnóstico" } else { "Iniciar manutenção" } }
}

Function Salvar-Config {
    $script:Config.Perfil = Obter-PerfilAtual
    $script:Config.Marcadas = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Id })
    $script:Config.Detalhado = [bool]$rbDetalhado.IsChecked
    $script:Config.Apps = @($script:AppsSelecionadosParaRemocao)
    Gravar-Config
}

Function Atualizar-BotaoApps {
    ($script:Tarefas | Where-Object { $_.Id -eq "Debloat" }).Botao.Content = "Escolher apps ($($script:AppsSelecionadosParaRemocao.Count))"
}

# ---------- Edição/licença: selo na navegação e liberação das tarefas ----------
Function Atualizar-BadgeEdicao {
    $L = $script:Licenca
    $Ate = if ($L.Validade) { " · até $($L.Validade.ToString('dd/MM/yyyy'))" } else { "" }
    switch ($L.Edicao) {
        'Tecnico' { $lblEdicaoTitulo.Text = 'Edição Técnico'; $lblEdicaoDetalhe.Text = $(if ($L.Nome) { $L.Nome } else { 'Licença ativa' }) + $Ate; $Glifo = 0xE785 }
        'Casa' { $lblEdicaoTitulo.Text = 'Edição Casa'; $lblEdicaoDetalhe.Text = $(if ($L.Nome) { $L.Nome } else { 'Licença ativa' }) + $Ate; $Glifo = 0xE785 }
        'Avaliacao' { $lblEdicaoTitulo.Text = 'Avaliação'; $lblEdicaoDetalhe.Text = "$($L.DiasRestantes) dia(s) restante(s) com tudo liberado"; $Glifo = 0xE946 }
        'Expirada' { $lblEdicaoTitulo.Text = 'Avaliação encerrada'; $lblEdicaoDetalhe.Text = 'Diagnóstico e laudo seguem gratuitos. Clique para ativar.'; $Glifo = 0xE72E }
        default { $lblEdicaoTitulo.Text = 'Desenvolvimento'; $lblEdicaoDetalhe.Text = 'Compilação sem chave de licença'; $Glifo = 0xE946 }
    }
    $icoEdicao.Text = [string][char]$Glifo
}

Function Aplicar-Gating {
    $Liberado = Testar-ManutencaoLiberada
    foreach ($T in $script:Tarefas) {
        $Pode = $Liberado -or [bool]$T.SomenteLeitura
        $T.Checkbox.IsEnabled = $Pode
        if (-not $Pode -and $T.Checkbox.IsChecked) { $T.Checkbox.IsChecked = $false }
    }
    $bdAtendimento.Visibility = $(if (Testar-RecursoTecnico) { 'Visible' } else { 'Collapsed' })
    Atualizar-BadgeEdicao
    if (-not $Liberado) {
        Adicionar-Aviso -Id 'licenca' -Tipo Aviso -Texto "A avaliação de $DiasAvaliacao dias terminou. O diagnóstico, a ficha técnica e o laudo continuam gratuitos; para executar manutenção, ative uma licença." -TextoBotao "Ativar licença" -Acao { param($Info) Mostrar-Pagina 'Config' }
    } else { Remover-Aviso 'licenca' }
    Atualizar-TempoEstimado
}

# ---------- Tema em tempo real (troca os pincéis da janela; as sub-janelas pegam a paleta ao abrir) ----------
Function Aplicar-Tema([string]$Modo) {
    $script:Config.Tema = $Modo
    $script:TemaEscuro = Obter-TemaEscuro
    $script:Paleta = Obter-Paleta $script:TemaEscuro
    foreach ($k in @($script:Paleta.Keys)) {
        $Window.Resources[$k] = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($script:Paleta[$k]))
    }
    foreach ($Painel in @($ugPerfis, $ugFormato, $ugTema)) { foreach ($rb in $Painel.Children) { Colorir-Segmento $rb $false } }
    Atualizar-BotaoIniciar   # refaz as sobrescritas azuis da página Manutenção com a paleta do novo tema
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        if ($h -ne [IntPtr]::Zero) { [JanelaPRO]::AplicarTema($h, $script:TemaEscuro, [Convert]::ToInt32($script:Paleta.Fundo.TrimStart('#'), 16), (-not $script:MicaAtivo)) }
    } catch {}
    Gravar-Config
}

# ---------- Página Histórico: linha da pontuação, tendências e lista de manutenções ----------
Function Desenhar-Sparkline {
    $cvSpark.Children.Clear()
    $plSpark.Points = New-Object System.Windows.Media.PointCollection
    $H = @(Ler-Historico | Where-Object { $null -ne $_.Nota -and "$($_.Nota)" -ne "" } | Select-Object -Last 20)
    $W = $gdSpark.ActualWidth; $Alt = $gdSpark.ActualHeight
    if ($H.Count -lt 2 -or $W -le 0 -or $Alt -le 0) { return }
    $Pad = 10
    for ($i = 0; $i -lt $H.Count; $i++) {
        $x = $Pad + ($W - 2 * $Pad) * $i / ($H.Count - 1)
        $y = $Alt - $Pad - ($Alt - 2 * $Pad) * ([double]$H[$i].Nota / 100.0)
        $plSpark.Points.Add((New-Object System.Windows.Point $x, $y))
        $Nota = [int]$H[$i].Nota
        $Cor = if ($Nota -ge 75) { 'Sucesso' } elseif ($Nota -ge 50) { 'Aviso' } else { 'Erro' }
        $Ponto = Criar-Elemento "<Ellipse $($script:NsXaml) Width=`"9`" Height=`"9`" Fill=`"{DynamicResource $Cor}`" Stroke=`"{DynamicResource Painel}`" StrokeThickness=`"1.5`"/>"
        $Ponto.ToolTip = "$(([datetime]$H[$i].Data).ToString('dd/MM/yyyy HH:mm')) · $Nota pontos · $($H[$i].Perfil)"
        [System.Windows.Controls.Canvas]::SetLeft($Ponto, $x - 4.5)
        [System.Windows.Controls.Canvas]::SetTop($Ponto, $y - 4.5)
        [void]$cvSpark.Children.Add($Ponto)
    }
}
$gdSpark.Add_SizeChanged({ if ($script:PaginaAtual -eq 'Historico') { Desenhar-Sparkline } })

Function Xaml-Tendencia($T) {
    $Cor = if ($null -eq $T.Melhorou) { 'Texto2' } elseif ($T.Melhorou) { 'Sucesso' } else { 'Erro' }
    $Seta = if ($null -eq $T.Melhorou) { "sem mudança" } elseif ($T.Delta -gt 0) { "▲ +$($T.Delta)$($T.Unidade)" } else { "▼ $($T.Delta)$($T.Unidade)" }
    return @"
<Border $($script:NsXaml) Margin="0,0,8,8" Padding="12,9" CornerRadius="6" Background="{DynamicResource PainelAlt}" BorderBrush="{DynamicResource Borda}" BorderThickness="1">
    <StackPanel>
        <TextBlock Text="$(Esc $T.Nome)" FontSize="11.5" Foreground="{DynamicResource Texto2}" TextTrimming="CharacterEllipsis"/>
        <TextBlock FontSize="13" Margin="0,3,0,0"><Run Text="$(Esc "$($T.Antes)$($T.Unidade)")" Foreground="{DynamicResource Texto3}"/><Run Text="  →  "/><Run Text="$(Esc "$($T.Agora)$($T.Unidade)")" FontWeight="SemiBold"/></TextBlock>
        <TextBlock Text="$(Esc $Seta)" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource $Cor}" Margin="0,2,0,0"/>
    </StackPanel>
</Border>
"@
}

Function Atualizar-PaginaHistorico {
    $H = @(Ler-Historico)
    $spHistorico.Children.Clear(); $ugTendencias.Children.Clear()
    if ($H.Count -eq 0) {
        $bdEvolucao.Visibility = 'Collapsed'
        [void]$spHistorico.Children.Add((Criar-Elemento "<TextBlock $($script:NsXaml) Text=`"Nenhuma manutenção registrada ainda. Rode o Diagnóstico (1 minuto, nada é alterado) para começar o histórico.`" Foreground=`"{DynamicResource Texto2}`" TextWrapping=`"Wrap`"/>"))
        return
    }
    $bdEvolucao.Visibility = 'Visible'
    $ComNota = @($H | Where-Object { $null -ne $_.Nota -and "$($_.Nota)" -ne "" })
    $lblHistResumo.Text = if ($ComNota.Count -ge 2) { "Pontuação: $($ComNota[0].Nota) em $(([datetime]$ComNota[0].Data).ToString('dd/MM/yyyy')) → $($ComNota[-1].Nota) em $(([datetime]$ComNota[-1].Data).ToString('dd/MM/yyyy'))" }
        elseif ($ComNota.Count -eq 1) { "Uma avaliação registrada ($($ComNota[0].Nota) pontos). A linha de evolução aparece a partir da segunda." }
        else { "Nenhuma pontuação registrada ainda: rode o Diagnóstico ou o Check-up." }
    Desenhar-Sparkline
    foreach ($T in @(Obter-Tendencias | Select-Object -First 8)) { [void]$ugTendencias.Children.Add((Criar-Elemento (Xaml-Tendencia $T))) }
    $ugTendencias.Visibility = $(if ($ugTendencias.Children.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    foreach ($E in @($H | Sort-Object Data -Descending | Select-Object -First 40)) {
        $TemNota = ($null -ne $E.Nota -and "$($E.Nota)" -ne "")
        $Nota = if ($TemNota) { [int]$E.Nota } else { 0 }
        $Cor = if (-not $TemNota) { 'Texto3' } elseif ($Nota -ge 75) { 'Sucesso' } elseif ($Nota -ge 50) { 'Aviso' } else { 'Erro' }
        $Fundo = if (-not $TemNota) { 'Hover' } elseif ($Nota -ge 75) { 'SucessoFundo' } elseif ($Nota -ge 50) { 'AvisoFundo' } else { 'ErroFundo' }
        $TxtNota = if ($TemNota) { "$Nota" } else { "–" }
        $Partes = @("$($E.Ok) ok", "$($E.Aviso) aviso(s)", "$($E.Erro) erro(s)")
        if ($E.LiberadoBytes -gt 0) { $Partes += "liberou $(Formatar-Tamanho ([int64]$E.LiberadoBytes))" }
        if ($E.Duracao -gt 0) { $Partes += "$([math]::Round([int]$E.Duracao / 60)) min" }
        $Linha3 = @(); if ("$($E.Cliente)".Trim()) { $Linha3 += "Cliente: $($E.Cliente)" }; if ("$($E.OS)".Trim()) { $Linha3 += "OS $($E.OS)" }
        $Xaml3 = if ($Linha3.Count -gt 0) { "<TextBlock Text=`"$(Esc ($Linha3 -join ' · '))`" FontSize=`"12`" Foreground=`"{DynamicResource Texto2}`"/>" } else { "" }
        $TemLaudo = ("$($E.Laudo)" -ne "" -and (Test-Path -LiteralPath "$($E.Laudo)"))
        $El = Criar-Elemento @"
<Border $($script:NsXaml) Style="{DynamicResource Cartao}" Padding="14,10" Margin="0,0,0,8">
    <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="abrir" Style="{DynamicResource BotaoBase}" Content="Abrir laudo" Height="30" IsEnabled="$(if ($TemLaudo) { 'True' } else { 'False' })"/>
            <Button x:Name="pdf" Style="{DynamicResource BotaoBase}" Content="PDF" Height="30" Margin="6,0,0,0" IsEnabled="$(if ($TemLaudo) { 'True' } else { 'False' })"/>
        </StackPanel>
        <Border DockPanel.Dock="Left" Width="46" Height="46" CornerRadius="23" Background="{DynamicResource $Fundo}" Margin="0,0,14,0" VerticalAlignment="Center">
            <TextBlock Text="$TxtNota" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource $Cor}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
            <TextBlock><Run Text="$(([datetime]$E.Data).ToString('dd/MM/yyyy HH:mm'))" FontWeight="SemiBold"/><Run Text="$(Esc "  ·  $($E.Perfil) · $("$($E.Modo)".ToLower())")" Foreground="{DynamicResource Texto2}"/></TextBlock>
            <TextBlock Text="$(Esc ($Partes -join ' · '))" FontSize="12" Foreground="{DynamicResource Texto2}" Margin="0,1,0,0"/>
            $Xaml3
        </StackPanel>
    </DockPanel>
</Border>
"@
        $BAbrir = $El.FindName('abrir'); $BAbrir.Tag = "$($E.Laudo)"; $BAbrir.Add_Click({ if (Test-Path -LiteralPath $this.Tag) { Start-Process $this.Tag } })
        $BPdf = $El.FindName('pdf'); $BPdf.Tag = "$($E.Laudo)"; $BPdf.Add_Click({ Salvar-Pdf $this.Tag })
        [void]$spHistorico.Children.Add($El)
    }
}

# Exporta um laudo para PDF (Edge headless) com a janela responsiva
Function Salvar-Pdf([string]$Html) {
    if (-not $Html -or -not (Test-Path -LiteralPath $Html)) { Mostrar-Mensagem "O laudo não foi encontrado." "OK" "Warning" | Out-Null; return }
    if (-not (Testar-RecursoTecnico)) { Mostrar-Mensagem "A exportação em PDF faz parte da edição Técnico. Alternativa gratuita: abra o laudo, pressione Ctrl+P e escolha 'Microsoft Print to PDF'." "OK" "Information" | Out-Null; return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $Pdf = Exportar-LaudoPdf $Html } finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
    if ($Pdf) {
        $r = Mostrar-Mensagem "PDF salvo em:`n$Pdf`n`nAbrir agora?" "YesNo" "Information"
        if ($r -eq "Yes") { Start-Process $Pdf }
    } else {
        Mostrar-Mensagem "Não foi possível gerar o PDF automaticamente (o Microsoft Edge não foi encontrado ou falhou).`n`nAlternativa: abra o laudo, pressione Ctrl+P e escolha 'Microsoft Print to PDF'." "OK" "Warning" | Out-Null
    }
}

# ---------- Página Ficha técnica ----------
# Ficha em grade de duas colunas: cartões arredondados (mesmo estilo das Ferramentas), da mesma altura em cada linha.
# O último grupo ocupa a linha inteira quando a contagem é ímpar.
Function Xaml-CelulaFicha([string]$Grupo, [int]$Linha, [int]$Coluna, [int]$Largura) {
    $Linhas = ""
    foreach ($K in $script:Inventario[$Grupo].Keys) {
        $Linhas += "<TextBlock Text=`"$(Esc $K)`" FontSize=`"11.5`" Foreground=`"{DynamicResource Texto3}`" Margin=`"0,7,0,0`"/><TextBlock Text=`"$(Esc $script:Inventario[$Grupo][$K])`" FontSize=`"12.5`" TextWrapping=`"Wrap`"/>"
    }
    # Folga de 12 px entre as colunas dividida ao meio, para os dois cartões ficarem da mesma largura
    $Margem = if ($Largura -gt 1) { "0,0,0,12" } elseif ($Coluna -eq 0) { "0,0,6,12" } else { "6,0,0,12" }
    return @"
<Border $($script:NsXaml) Grid.Row="$Linha" Grid.Column="$Coluna" Grid.ColumnSpan="$Largura" Style="{DynamicResource Cartao}" Margin="$Margem" Padding="16,12,16,14">
    <StackPanel>
        <TextBlock Text="$(Esc $Grupo)" Style="{DynamicResource TituloCartao}"/>
        $Linhas
    </StackPanel>
</Border>
"@
}

Function Atualizar-PaginaSistema {
    $gdFicha.Children.Clear()
    $gdFicha.RowDefinitions.Clear()
    $gdFicha.ColumnDefinitions.Clear()
    if (-not $script:Inventario -or $script:Inventario.Count -eq 0) {
        $bdFicha.Visibility = 'Collapsed'
        $lblFichaSub.Text = "Inventário de hardware e do Windows, somente leitura. Clique em 'Ler agora' (alguns segundos) ou rode o Diagnóstico."
        return
    }
    $lblFichaSub.Text = "Lida em $($script:InventarioQuando). Vai para o laudo quando a tarefa 'Ficha técnica' está marcada."
    $Grupos = @($script:Inventario.Keys)
    $Colunas = 2
    $TotalLinhas = [math]::Ceiling($Grupos.Count / $Colunas)
    for ($c = 0; $c -lt $Colunas; $c++) { $gdFicha.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
    for ($l = 0; $l -lt $TotalLinhas; $l++) { $Def = New-Object System.Windows.Controls.RowDefinition; $Def.Height = [System.Windows.GridLength]::Auto; $gdFicha.RowDefinitions.Add($Def) }
    for ($i = 0; $i -lt $Grupos.Count; $i++) {
        $Linha = [math]::Floor($i / $Colunas); $Coluna = $i % $Colunas
        $Largura = if ($i -eq $Grupos.Count - 1 -and $Coluna -eq 0) { $Colunas } else { 1 }
        [void]$gdFicha.Children.Add((Criar-Elemento (Xaml-CelulaFicha $Grupos[$i] $Linha $Coluna $Largura)))
    }
    $bdFicha.Visibility = 'Visible'
}

Function Ler-FichaTecnica {
    $btnLerFicha.IsEnabled = $false
    $lblFichaSub.Text = "Lendo o inventário..."
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    Atualizar-Tela
    try { $script:Inventario = Obter-Inventario; $script:InventarioQuando = (Get-Date).ToString('dd/MM/yyyy HH:mm') }
    finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow; $btnLerFicha.IsEnabled = $true }
    Atualizar-PaginaSistema
}

Function Texto-Ficha {
    if (-not $script:Inventario) { return "" }
    $Sb = New-Object System.Text.StringBuilder
    [void]$Sb.AppendLine("FICHA TÉCNICA · $env:COMPUTERNAME · $(Get-Date -Format 'dd/MM/yyyy HH:mm')")
    foreach ($G in $script:Inventario.Keys) {
        [void]$Sb.AppendLine(""); [void]$Sb.AppendLine("[$G]")
        foreach ($K in $script:Inventario[$G].Keys) { [void]$Sb.AppendLine("$K`: $($script:Inventario[$G][$K])") }
    }
    return $Sb.ToString()
}

# ---------- Página Ferramentas ----------
Function Xaml-Ferramenta([string]$Glifo, [string]$Titulo, [string]$Texto, [string]$Botao) {
    return @"
<Border $($script:NsXaml) Style="{DynamicResource Cartao}" Width="372" Padding="16,14" Margin="0,0,12,12" VerticalAlignment="Top">
    <DockPanel>
        <Border DockPanel.Dock="Left" Width="40" Height="40" CornerRadius="8" Background="{DynamicResource InfoFundo}" VerticalAlignment="Top" Margin="0,0,14,0">
            <TextBlock Text="&#x$Glifo;" FontFamily="$($script:FonteIcones)" FontSize="18" Foreground="{DynamicResource Destaque}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel>
            <TextBlock Text="$(Esc $Titulo)" FontSize="13.5" FontWeight="SemiBold"/>
            <TextBlock Text="$(Esc $Texto)" FontSize="12" Foreground="{DynamicResource Texto2}" TextWrapping="Wrap" Margin="0,3,0,10" MinHeight="34"/>
            <Button x:Name="acao" Style="{DynamicResource BotaoPrimario}" Content="$(Esc $Botao)" HorizontalAlignment="Left" Height="32"/>
        </StackPanel>
    </DockPanel>
</Border>
"@
}

Function Agendar-TesteMemoria {
    $r = Mostrar-Mensagem "Agendar o Diagnóstico de Memória do Windows para o próximo reinício?`n`nO teste roda uma única vez antes de o Windows abrir (15 a 30 min) e o resultado aparece no próximo check-up. Para desistir antes de reiniciar: bcdedit /deletevalue {bootmgr} bootsequence" "YesNo" "Question"
    if ($r -ne "Yes") { return }
    $Bcd = "$env:SystemRoot\System32\bcdedit.exe"
    $R = Executar-Comando -Comando $Bcd -Argumentos "/bootsequence {memdiag}" -PodeCancelar $false -TimeoutMinutos 2
    if ($R.ExitCode -eq 0) {
        $r2 = Mostrar-Mensagem "Teste de memória agendado para o próximo reinício. Reiniciar agora? (salve seus trabalhos antes)" "YesNo" "Question"
        if ($r2 -eq "Yes") { Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /t 30" -WindowStyle Hidden }
    } else { Mostrar-Mensagem "Não foi possível agendar o teste (bcdedit retornou $(Formatar-Codigo $R.ExitCode)). $(Resumo-Saida $R.Saida 2)" "OK" "Error" | Out-Null }
}

Function Atualizar-PaginaFerramentas {
    $wpFerramentas.Children.Clear()
    $Agendada = [bool](Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue)
    $TxtAgenda = if ($Agendada) {
        $Prox = (Get-ScheduledTaskInfo -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue).NextRunTime
        "Agendada: perfil Completa a cada 4 semanas, domingo às 12:00" + $(if ($Prox) { " (próxima: $($Prox.ToString('dd/MM/yyyy HH:mm')))" } else { "" }) + ". Laudos ficam na pasta de dados."
    } else { "Roda o perfil Completa a cada 4 semanas, só na tomada e sem reiniciar sozinho. Cartão/USB recebem só verificações." }
    $Itens = @(
        @{ Glifo = 'E7E8'; Titulo = 'Programas da inicialização'; Texto = 'Escolha o que abre junto com o Windows. Menos programas no boot: inicialização mais rápida e mais memória livre.'; Botao = 'Abrir'; Acao = { Abrir-GerenciadorInicializacao } }
        @{ Glifo = 'ECAA'; Titulo = 'Remover aplicativos pré-instalados'; Texto = 'Apps de fábrica que você não usa. Os marcados como reinstaláveis voltam de graça pela Microsoft Store.'; Botao = 'Escolher apps'; Acao = { Abrir-SeletorDebloat } }
        @{ Glifo = 'E787'; Titulo = 'Manutenção mensal automática'; Texto = $TxtAgenda; Botao = $(if ($Agendada) { 'Remover agendamento' } else { 'Agendar' }); Acao = { Alternar-Agendamento; Atualizar-PaginaFerramentas } }
        @{ Glifo = 'E950'; Titulo = 'Teste completo da memória RAM'; Texto = 'Agenda o Diagnóstico de Memória do Windows (nativo) para o próximo reinício. Indicado quando há travamentos ou telas azuis.'; Botao = 'Agendar teste'; Acao = { Agendar-TesteMemoria } }
        @{ Glifo = 'ED25'; Titulo = 'Laudos e registros'; Texto = "Pasta com todos os laudos (HTML/PDF), logs de execução e o histórico de pontuações."; Botao = 'Abrir pasta'; Acao = { Start-Process explorer.exe -ArgumentList "`"$DataDir`"" } }
        @{ Glifo = 'E72C'; Titulo = 'Atualização do programa'; Texto = "Versão instalada: $($script:Versao). Consulta o arquivo de versão publicado e avisa se houver uma mais nova."; Botao = 'Verificar agora'; Acao = { Verificar-AtualizacaoAgora } }
    )
    foreach ($U in @(Obter-Unidades | Where-Object { $_.Removivel })) {
        $Itens += @{ Glifo = $(if ($U.Tipo -eq 'Cartão de memória') { 'E7F1' } else { 'E88E' }); Titulo = "Corrigir $($U.Letra): ($($U.Tipo))"; Texto = "Verificação com correção (chkdsk /f) da unidade removível, sempre manual e com confirmação. Feche antes os arquivos abertos nela."; Botao = "Corrigir $($U.Letra):"; Dados = $U.Letra; Acao = { param($Letra) Corrigir-Unidade $Letra } }
    }
    foreach ($I in $Itens) {
        $El = Criar-Elemento (Xaml-Ferramenta $I.Glifo $I.Titulo $I.Texto $I.Botao)
        $B = $El.FindName('acao'); $B.Tag = @{ Acao = $I.Acao; Dados = $I.Dados }
        $B.Add_Click({ & $this.Tag.Acao $this.Tag.Dados })
        [void]$wpFerramentas.Children.Add($El)
    }
    if (-not (Testar-ManutencaoLiberada)) { foreach ($El in $wpFerramentas.Children) { $B = $El.FindName('acao'); if ($B.Content -notin 'Abrir pasta', 'Verificar agora') { $B.IsEnabled = $false; $B.ToolTip = 'Requer licença (avaliação encerrada)' } } }
}

# ---------- Página Configurações ----------
$script:IgnorarConfig = $false
$script:CodigoMaquina = ""
Function Atualizar-PaginaConfig {
    $script:IgnorarConfig = $true
    try {
        $Tema = "$($script:Config.Tema)"
        $rbTemaSistema.IsChecked = ($Tema -eq 'Sistema'); $rbTemaClaro.IsChecked = ($Tema -eq 'Claro'); $rbTemaEscuro.IsChecked = ($Tema -eq 'Escuro')
        $chkMica.IsChecked = [bool]$script:Config.Mica
        $chkMica.IsEnabled = ((Obter-BuildWindows) -ge 22621)
        $M = $script:Config.Marca
        $txtMarcaNome.Text = "$($M.Nome)"; $txtMarcaTelefone.Text = "$($M.Telefone)"; $txtMarcaContato.Text = "$($M.Contato)"; $txtMarcaTecnico.Text = "$($M.Tecnico)"
        $lblLogo.Text = if ("$($M.Logo)" -and (Test-Path -LiteralPath "$($M.Logo)")) { "$($M.Logo)" } else { "Nenhum logotipo" }
        $btnLogoRemover.IsEnabled = ("$($M.Logo)" -ne "")
        $chkMarcaLaudo.IsChecked = [bool]$M.MostrarNoLaudo
        $Tecnico = Testar-RecursoTecnico
        foreach ($c in @($txtMarcaNome, $txtMarcaTelefone, $txtMarcaContato, $txtMarcaTecnico, $btnLogo, $btnLogoRemover, $chkMarcaLaudo)) { $c.IsEnabled = $Tecnico }
        $lblMarcaNota.Text = if ($Tecnico) { "Nome, telefone e logotipo aparecem no cabeçalho do laudo; os campos Cliente, Ordem de serviço e Observações ficam na página Manutenção." } else { "Disponível na edição Técnico (e durante a avaliação). Ative uma licença Técnico para personalizar o laudo com a sua marca." }
        $L = $script:Licenca
        $Status = Descrever-Edicao
        if ($L.Motivo -and $L.Edicao -notin 'Casa', 'Tecnico') { $Status += " · licença encontrada, mas recusada: $($L.Motivo)" }
        $lblLicencaStatus.Text = $Status
        if (-not $script:CodigoMaquina) { $script:CodigoMaquina = Obter-CodigoMaquina }
        $lblCodigoMaquina.Text = $script:CodigoMaquina
        $btnRemoverLicenca.IsEnabled = (Test-Path -LiteralPath $LicencaFile)
        $lblVersaoAtual.Text = "Versão instalada: $($script:Versao) · dados em $DataDir"
        $chkAtualizacoes.IsChecked = [bool]$script:Config.VerificarAtualizacoes
        $lblPastaDados.Text = "Laudos, logs, histórico, licença e configurações ficam em $DataDir (fora do OneDrive). A desinstalação pergunta se deve mantê-los."
    } finally { $script:IgnorarConfig = $false }
}

Function Ativar-Licenca([string]$Texto) {
    $Texto = ("$Texto" -replace '\s+', '')
    if (-not $Texto) { Mostrar-Mensagem "Cole o texto da licença recebida (começa com MPRO1.)." "OK" "Information" | Out-Null; return }
    $V = Verificar-Licenca $Texto
    if (-not $V.Valida) { Mostrar-Mensagem "Licença não aceita: $($V.Motivo)" "OK" "Warning" | Out-Null; return }
    try { Set-Content -Path $LicencaFile -Value $Texto -Encoding ASCII } catch { Mostrar-Mensagem "Não foi possível gravar a licença: $($_.Exception.Message)" "OK" "Error" | Out-Null; return }
    $null = Carregar-Licenca
    $txtLicenca.Text = ""
    Aplicar-Gating; Atualizar-PaginaConfig
    $PerfilAtual = Obter-PerfilAtual
    if ($PerfilAtual -ne 'Personalizada') { Aplicar-Perfil $PerfilAtual }
    Mostrar-Mensagem "Licença ativada: $(Descrever-Edicao)." | Out-Null
}

Function Remover-Licenca {
    $r = Mostrar-Mensagem "Remover a licença deste computador? O programa volta ao modo de avaliação (ou só diagnóstico, se a avaliação já terminou)." "YesNo" "Question"
    if ($r -ne "Yes") { return }
    Remove-Item -LiteralPath $LicencaFile -Force -ErrorAction SilentlyContinue
    $null = Carregar-Licenca
    Aplicar-Gating; Atualizar-PaginaConfig
}

Function Escolher-Logo {
    $Dlg = New-Object Microsoft.Win32.OpenFileDialog
    $Dlg.Title = "Escolher logotipo"
    $Dlg.Filter = "Imagens (*.png;*.jpg;*.jpeg;*.gif;*.webp;*.svg)|*.png;*.jpg;*.jpeg;*.gif;*.webp;*.svg"
    if (-not $Dlg.ShowDialog($Window)) { return }
    $Info = Get-Item -LiteralPath $Dlg.FileName
    if ($Info.Length -gt 600KB) { Mostrar-Mensagem "A imagem tem $(Formatar-Tamanho $Info.Length). Use uma com até 600 KB: o logotipo é embutido em cada laudo." "OK" "Warning" | Out-Null; return }
    $Destino = Join-Path $DataDir ("logo" + $Info.Extension.ToLower())
    Get-ChildItem -Path (Join-Path $DataDir 'logo.*') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Copy-Item -LiteralPath $Info.FullName -Destination $Destino -Force -ErrorAction Stop } catch { Mostrar-Mensagem "Não foi possível copiar a imagem: $($_.Exception.Message)" "OK" "Error" | Out-Null; return }
    $script:Config.Marca.Logo = $Destino
    Gravar-Config; Atualizar-PaginaConfig
}

Function Remover-Logo {
    Get-ChildItem -Path (Join-Path $DataDir 'logo.*') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:Config.Marca.Logo = ""
    Gravar-Config; Atualizar-PaginaConfig
}

# ---------- Verificação de versão nova (arquivo versao.json publicado; nunca instala nada sozinho) ----------
Function Processar-VersaoRemota($Info, [bool]$Interativo) {
    $Remota = "$($Info.versao)".Trim()
    $Nova = $false
    try { $Nova = ([version]$Remota -gt [version]$script:Versao) } catch { try { $Nova = ([double]$Remota -gt [double]$script:Versao) } catch {} }
    if ($Nova) {
        $Texto = "Versão $Remota disponível" + $(if ($Info.data) { " ($($Info.data))" } else { "" }) + "." + $(if ($Info.notas) { " $($Info.notas)" } else { "" })
        # Só abre endereços https (o arquivo de versão vem da internet; nunca executa um caminho local vindo dele)
        $Url = "$($Info.url)".Trim(); if ($Url -notmatch '^https://') { $Url = $UrlSite }
        Adicionar-Aviso -Id 'atualizacao' -Tipo Info -Texto $Texto -TextoBotao "Baixar" -Dados $Url -Acao { param($I) if ("$($I.Dados)" -match '^https://') { Start-Process "$($I.Dados)" } }
        if ($Interativo) { Mostrar-Mensagem "Há uma versão nova: $Remota. Use o botão 'Baixar' no aviso do topo." | Out-Null }
    } elseif ($Interativo) { Mostrar-Mensagem "Você já tem a versão mais recente ($($script:Versao))." | Out-Null }
}

Function Verificar-AtualizacaoAgora {
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Info = Invoke-RestMethod -Uri $UrlVersao -TimeoutSec 12 -Headers @{ 'User-Agent' = "ManutencaoPRO/$($script:Versao)"; 'Cache-Control' = 'no-cache' }
        Processar-VersaoRemota $Info $true
    } catch { Mostrar-Mensagem "Não foi possível consultar a versão agora: $($_.Exception.Message)" "OK" "Warning" | Out-Null }
    finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
}

Function Iniciar-VerificacaoAtualizacao {
    if (-not [bool]$script:Config.VerificarAtualizacoes) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Wc = New-Object System.Net.WebClient
        $Wc.Headers.Add('User-Agent', "ManutencaoPRO/$($script:Versao)")
        $Wc.Headers.Add('Cache-Control', 'no-cache')
        $script:TarefaAtualizacao = $Wc.DownloadStringTaskAsync([Uri]$UrlVersao)
        $script:TimerAtualizacao = New-Object System.Windows.Threading.DispatcherTimer
        $script:TimerAtualizacao.Interval = [TimeSpan]::FromMilliseconds(700)
        $script:TimerAtualizacao.Tag = (Get-Date).AddSeconds(25)
        $script:TimerAtualizacao.Add_Tick({
            $T = $script:TarefaAtualizacao
            if ($T.IsCompleted) {
                $script:TimerAtualizacao.Stop()
                if (-not $T.IsFaulted -and -not $T.IsCanceled) { try { Processar-VersaoRemota ($T.Result | ConvertFrom-Json) $false } catch {} }
            } elseif ((Get-Date) -gt $script:TimerAtualizacao.Tag) { $script:TimerAtualizacao.Stop() }
        })
        $script:TimerAtualizacao.Start()
    } catch {}
}

# ---------- Janela: seleção de apps para remover (Debloat) ----------
Function Abrir-SeletorDebloat {
    $DebloatXAML = @"
<Window $($script:NsXaml)
        Title="Remover aplicativos" Height="660" Width="560" MinHeight="480" MinWidth="460" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
$(Obter-RecursosXaml)
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
            <TextBlock Text="Quais aplicativos você quer remover?" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Texto2}" Margin="0,6,0,0"
                Text="Os marcados como 'Reinstalável' voltam de graça pela Microsoft Store. Os de 'Atenção' (fabricante e utilitários) podem não ter como reinstalar: remova só se tiver certeza. Componentes do sistema, codecs e bibliotecas não aparecem aqui."/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,14,0,10">
            <Button Name="btnPresetRecomendado" Style="{StaticResource BotaoBase}" Content="Marcar reinstaláveis" Margin="0,0,8,0"/>
            <Button Name="btnPresetProfundo" Style="{StaticResource BotaoBase}" Content="Marcar todos" Margin="0,0,8,0"/>
            <Button Name="btnPresetLimpar" Style="{StaticResource BotaoSutil}" Content="Desmarcar todos"/>
        </StackPanel>
        <Border Grid.Row="2" Style="{StaticResource Cartao}">
            <Grid>
                <TextBlock Name="lblStatusDebloat" Text="Procurando aplicativos instalados..." Foreground="{DynamicResource Texto2}" Margin="16"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel Name="spAppsList" Margin="6"/>
                </ScrollViewer>
            </Grid>
        </Border>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button Name="btnDebloatCancelar" Style="{StaticResource BotaoBase}" Content="Cancelar" Height="36" Margin="0,0,8,0" IsCancel="True"/>
            <Button Name="btnDebloatSalvar" Style="{StaticResource BotaoPrimario}" Content="Confirmar seleção" Height="36"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $script:DWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$DebloatXAML)))
    $script:DWindow.Owner = $Window
    Aplicar-TemaJanela $script:DWindow
    $script:DWindow.Cursor = [System.Windows.Input.Cursors]::Wait

    $script:DWindow.Add_ContentRendered({
        $Dicionario = @{
            "Microsoft.YourPhone" = @("Vincular ao Celular", "Laranja"); "Microsoft.GetHelp" = @("Obter Ajuda", "Verde")
            "Microsoft.Getstarted" = @("Dicas do Windows", "Verde"); "Microsoft.BingWeather" = @("Clima (MSN)", "Verde")
            "Microsoft.BingNews" = @("Notícias", "Verde"); "Microsoft.BingSearch" = @("Pesquisa Bing", "Verde")
            "Microsoft.BingFinance" = @("Finanças (MSN)", "Verde"); "Microsoft.BingSports" = @("Esportes (MSN)", "Verde")
            "Microsoft.Microsoft3DViewer" = @("Visualizador 3D", "Verde"); "Microsoft.ZuneVideo" = @("Filmes e TV", "Verde")
            "Microsoft.ZuneMusic" = @("Media Player / Groove", "Laranja"); "Microsoft.WindowsMaps" = @("Mapas", "Verde")
            "Microsoft.XboxApp" = @("Xbox (antigo)", "Verde"); "Microsoft.GamingApp" = @("Xbox", "Laranja")
            "Microsoft.XboxGamingOverlay" = @("Xbox Game Bar", "Laranja"); "Microsoft.XboxIdentityProvider" = @("Provedor de Identidade Xbox", "Laranja")
            "Microsoft.XboxSpeechToTextOverlay" = @("Overlay de Voz Xbox", "Laranja"); "Microsoft.MicrosoftOfficeHub" = @("Microsoft 365 (atalho do Office)", "Verde")
            "Microsoft.MicrosoftStickyNotes" = @("Anotações (Sticky Notes)", "Laranja"); "Microsoft.WindowsSoundRecorder" = @("Gravador de Som", "Verde")
            "Microsoft.WindowsAlarms" = @("Relógio e Alarmes", "Laranja"); "Microsoft.SkypeApp" = @("Skype", "Verde")
            "Microsoft.MicrosoftSolitaireCollection" = @("Paciência (Solitaire)", "Verde"); "Microsoft.People" = @("Contatos (People)", "Verde")
            "Microsoft.WindowsFeedbackHub" = @("Hub de Comentários", "Verde"); "Microsoft.549981C3F5F10" = @("Cortana", "Verde")
            "Microsoft.MixedReality.Portal" = @("Portal de Realidade Misturada", "Verde"); "Microsoft.Wallet" = @("Carteira", "Verde")
            "Microsoft.Messaging" = @("Mensagens", "Verde"); "Microsoft.OneConnect" = @("Planos Móveis", "Verde")
            "Microsoft.Todos" = @("Microsoft To Do", "Verde"); "Microsoft.PowerAutomateDesktop" = @("Power Automate", "Verde")
            "Microsoft.OutlookForWindows" = @("Outlook (novo)", "Laranja"); "microsoft.windowscommunicationsapps" = @("Email e Calendário (antigo)", "Verde")
            "Microsoft.Copilot" = @("Copilot", "Verde"); "Microsoft.Windows.DevHome" = @("Dev Home", "Verde"); "Microsoft.DevHome" = @("Dev Home", "Verde")
            "Microsoft.Office.OneNote" = @("OneNote", "Laranja"); "Microsoft.WindowsCamera" = @("Câmera", "Laranja")
            "Clipchamp.Clipchamp" = @("Clipchamp (editor de vídeo)", "Verde"); "MSTeams" = @("Microsoft Teams", "Laranja")
            "MicrosoftTeams" = @("Microsoft Teams (pessoal)", "Verde"); "MicrosoftCorporationII.MicrosoftFamily" = @("Microsoft Family", "Verde")
            "MicrosoftCorporationII.QuickAssist" = @("Assistência Rápida", "Laranja"); "Microsoft.MicrosoftJournal" = @("Journal", "Verde")
        }
        # Nunca listar: componentes do sistema, codecs, bibliotecas, loja, apps essenciais e drivers de hardware
        $Bloqueio = 'Store|Calculator|WindowsTerminal|VCLibs|UI\.Xaml|NET\.Native|DesktopAppInstaller|SecHealth|AppUp\.Intel|WindowsAppRuntime|Extension|HEIF|HEVC|VP9|WebMedia|Webp|RawImage|AV1|MPEG2|WindowsNotepad|Paint|ScreenSketch|WebExperience|Winget|Edge|OneDriveSync|^Microsoft\.Windows\.(?!DevHome)|^MicrosoftWindows\.|LanguageExperiencePack|ApplicationCompatibility|WidgetsPlatform|StartExperiences|Photos|Dolby|Realtek|NVIDIA|AMD|Intel|Synaptics|Elan|Waves'
        $Painel = $script:DWindow.FindName("spAppsList")
        $Apps = Get-AppxPackage -AllUsers | Where-Object {
            -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne "System" -and $_.Name -notmatch $Bloqueio -and
            ($Dicionario.ContainsKey($_.Name) -or $_.Publisher -match 'Microsoft|Samsung|Dell|HP|Lenovo|Acer|ASUS')
        } | Sort-Object Name -Unique

        $script:DWindow.FindName("lblStatusDebloat").Visibility = "Collapsed"
        $Linhas = @()
        foreach ($App in $Apps) {
            $Exibir = $App.Name; $Risco = "Laranja"
            if ($Dicionario.ContainsKey($App.Name)) { $Exibir = $Dicionario[$App.Name][0]; $Risco = $Dicionario[$App.Name][1] }
            $Linhas += [PSCustomObject]@{ App = $App; Exibir = $Exibir; Risco = $Risco }
        }
        foreach ($Lin in ($Linhas | Sort-Object @{ Expression = { $_.Risco -ne "Verde" } }, Exibir)) {
            $App = $Lin.App
            $Fabricante = if ($App.Publisher -match 'CN=([^,]+)') { $Matches[1] } else { "$($App.Publisher)" }
            $Pilula = if ($Lin.Risco -eq "Verde") { "<Border Background=`"{DynamicResource SucessoFundo}`" CornerRadius=`"4`" Padding=`"6,1`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"Reinstalável`" FontSize=`"11`" Foreground=`"{DynamicResource Sucesso}`"/></Border>" }
                      else { "<Border Background=`"{DynamicResource AvisoFundo}`" CornerRadius=`"4`" Padding=`"6,1`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"Atenção`" FontSize=`"11`" Foreground=`"{DynamicResource Aviso}`"/></Border>" }
            $cb = Criar-Elemento @"
<CheckBox $($script:NsXaml) Style="{DynamicResource LinhaTarefa}" Tag="$(Esc $App.Name)" Uid="$($Lin.Risco)" ToolTip="Nome técnico: $(Esc $App.Name)">
    <StackPanel>
        <WrapPanel><TextBlock Text="$(Esc $Lin.Exibir)" FontSize="13.5" VerticalAlignment="Center"/>$Pilula</WrapPanel>
        <TextBlock Text="$(Esc $Fabricante)" FontSize="11.5" Foreground="{DynamicResource Texto3}" Margin="0,1,0,0"/>
    </StackPanel>
</CheckBox>
"@
            if ($script:AppsSelecionadosParaRemocao -contains $App.Name) { $cb.IsChecked = $true }
            [void]$Painel.Children.Add($cb)
        }
        if ($Painel.Children.Count -eq 0) {
            $Status = $script:DWindow.FindName("lblStatusDebloat"); $Status.Text = "Nenhum aplicativo removível encontrado."; $Status.Visibility = "Visible"
        }
        $script:DWindow.Cursor = [System.Windows.Input.Cursors]::Arrow
    })

    $script:DWindow.FindName("btnPresetRecomendado").Add_Click({
        foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = ($c.Uid -eq "Verde") }
    })
    $script:DWindow.FindName("btnPresetProfundo").Add_Click({
        $r = Mostrar-Mensagem "Isso marca também apps de fabricante e utilitários ('Atenção'), que podem não ser reinstaláveis. Continuar?" "YesNo" "Warning"
        if ($r -eq "Yes") { foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = $true } }
    })
    $script:DWindow.FindName("btnPresetLimpar").Add_Click({
        foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = $false }
    })
    $script:DWindow.FindName("btnDebloatSalvar").Add_Click({
        $script:AppsSelecionadosParaRemocao = @($script:DWindow.FindName("spAppsList").Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        $script:DWindow.DialogResult = $true
    })
    $Confirmou = $script:DWindow.ShowDialog()
    if (-not $Confirmou) { return }
    $TDebloat = $script:Tarefas | Where-Object { $_.Id -eq "Debloat" }
    if ($script:AppsSelecionadosParaRemocao.Count -gt 0 -and $TDebloat.Checkbox.IsEnabled) { $TDebloat.Checkbox.IsChecked = $true; Selecionar-Perfil "Personalizada"; Atualizar-TempoEstimado }
    Atualizar-BotaoApps
}

# ---------- Janela: programas da inicialização ----------
Function Abrir-GerenciadorInicializacao {
    $IniXAML = @"
<Window $($script:NsXaml)
        Title="Programas da inicialização" Height="620" Width="640" MinHeight="420" MinWidth="480" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
$(Obter-RecursosXaml)
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,14">
            <TextBlock Text="O que abre junto com o Windows" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Texto2}" Margin="0,6,0,0"
                Text="Desmarque o que não precisa abrir sozinho: o boot fica mais rápido e sobra memória. Os programas continuam instalados e podem ser reativados aqui ou no Gerenciador de Tarefas. Não desative antivírus, drivers (áudio, touchpad, vídeo) nem a sincronização que você usa. Vale a partir do próximo login."/>
        </StackPanel>
        <Border Grid.Row="1" Style="{StaticResource Cartao}">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel Name="spItens" Margin="6"/>
            </ScrollViewer>
        </Border>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button Name="btnCancelarIni" Style="{StaticResource BotaoBase}" Content="Cancelar" Height="36" Margin="0,0,8,0" IsCancel="True"/>
            <Button Name="btnSalvarIni" Style="{StaticResource BotaoPrimario}" Content="Aplicar alterações" Height="36"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $script:IWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$IniXAML)))
    $script:IWindow.Owner = $Window
    Aplicar-TemaJanela $script:IWindow
    $Painel = $script:IWindow.FindName("spItens")
    foreach ($Item in (Obter-ItensInicializacao | Sort-Object Nome)) {
        $cb = Criar-Elemento @"
<CheckBox $($script:NsXaml) Style="{DynamicResource LinhaTarefa}" ToolTip="$(Esc $Item.Comando)">
    <StackPanel>
        <TextBlock Text="$(Esc $Item.Nome)" FontSize="13.5"/>
        <TextBlock Text="$(Esc "$($Item.Origem) · $($Item.Comando)")" FontSize="11.5" Foreground="{DynamicResource Texto3}" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
    </StackPanel>
</CheckBox>
"@
        $cb.IsChecked = $Item.Ativo
        $cb.Tag = $Item
        [void]$Painel.Children.Add($cb)
    }
    $script:IWindow.FindName("btnSalvarIni").Add_Click({
        $Mudou = 0; $Falhou = 0
        foreach ($c in $script:IWindow.FindName("spItens").Children) {
            if ([bool]$c.IsChecked -ne $c.Tag.Ativo) {
                try { Definir-EstadoAprovado $c.Tag.Aprov $c.Tag.Nome ([bool]$c.IsChecked); $Mudou++ } catch { $Falhou++ }
            }
        }
        $Msg = "$Mudou alteração(ões) aplicada(s). Valem a partir do próximo login."
        if ($Falhou -gt 0) { $Msg += "`n$Falhou não puderam ser aplicadas." }
        Mostrar-Mensagem $Msg | Out-Null
        $script:IWindow.DialogResult = $true
    })
    $script:IWindow.ShowDialog() | Out-Null
}

# ---------- Agendamento mensal ----------
Function Obter-OrigemPrograma { if ($script:IsExe) { return $script:ProcessoExe } else { return $script:CaminhoScript } }
Function Obter-CopiaAgendada { return (Join-Path $DataDir $(if ($script:IsExe) { "ManutencaoPro.exe" } else { "ManutencaoGUI.ps1" })) }

# A tarefa agendada roda uma CÓPIA do programa: depois de uma atualização, a cópia fica antiga
Function Testar-AgendamentoDesatualizado {
    $T = Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue
    if (-not $T) { return $false }
    $Copia = Obter-CopiaAgendada
    $Acao = "$($T.Actions[0].Execute) $($T.Actions[0].Arguments)"
    if (-not $Acao.ToLower().Contains($Copia.ToLower())) { return $false } # agendada pela outra versão (.exe x .ps1)
    $Origem = Obter-OrigemPrograma
    if (-not $Origem -or -not (Test-Path -LiteralPath $Origem) -or $Origem -eq $Copia) { return $false }
    if (-not (Test-Path -LiteralPath $Copia)) { return $true }
    try { return ((Get-FileHash -LiteralPath $Origem).Hash -ne (Get-FileHash -LiteralPath $Copia).Hash) } catch { return $false }
}

Function Atualizar-CopiaAgendada {
    try {
        Copy-Item -LiteralPath (Obter-OrigemPrograma) -Destination (Obter-CopiaAgendada) -Force -ErrorAction Stop
        Remover-Aviso "agendamento"
        Mostrar-Mensagem "A manutenção agendada agora usa esta versão ($($script:Versao))." | Out-Null
    } catch { Mostrar-Mensagem "Não foi possível atualizar a cópia agendada: $($_.Exception.Message)" "OK" "Error" | Out-Null }
}

Function Alternar-Agendamento {
    if (-not (Testar-ManutencaoLiberada)) { Mostrar-Mensagem "A manutenção automática requer uma licença ativa (a avaliação terminou)." "OK" "Information" | Out-Null; return }
    $Existente = Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue
    if ($Existente) {
        $Prox = (Get-ScheduledTaskInfo -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue).NextRunTime
        $r = Mostrar-Mensagem "A manutenção automática já está agendada (próxima execução: $Prox).`n`nDeseja REMOVER o agendamento?" "YesNo" "Question"
        if ($r -eq "Yes") { Unregister-ScheduledTask -TaskName $NomeTarefaAgendada -Confirm:$false; Remover-Aviso "agendamento"; Mostrar-Mensagem "Agendamento removido." | Out-Null }
        return
    }
    $r = Mostrar-Mensagem ("Agendar a manutenção automática?`n`n- Perfil Completa (sem Lixeira, Downloads, apps, teste de memória e reparo de rede)`n- Cartão de memória e USB: apenas verificações somente leitura`n- A cada 4 semanas, domingo às 12:00`n- Se o PC estiver desligado, roda na próxima vez que for ligado`n- Só roda na tomada; nunca reinicia sozinho`n- Laudos ficam em $DirLaudos") "YesNo" "Question"
    if ($r -ne "Yes") { return }
    try {
        $Destino = Obter-CopiaAgendada
        Copy-Item -LiteralPath (Obter-OrigemPrograma) -Destination $Destino -Force
        if ($script:IsExe) { $Acao = New-ScheduledTaskAction -Execute $Destino -Argument "-Automatico -Perfil Completa" }
        else { $Acao = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Destino`" -Automatico -Perfil Completa" }
        $Gatilho = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At "12:00"
        $Config = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $NomeTarefaAgendada -Action $Acao -Trigger $Gatilho -Settings $Config -Principal $Principal `
            -Description "Manutenção automática do Manutenção PRO (limpeza, reparo, atualizações e saúde das unidades)." | Out-Null
        Mostrar-Mensagem "Manutenção mensal agendada com sucesso." | Out-Null
    } catch { Mostrar-Mensagem "Não foi possível agendar: $($_.Exception.Message)" "OK" "Error" | Out-Null }
}

# ---------- Correção manual de cartão/USB (nunca automática) ----------
Function Corrigir-Unidade([string]$Letra) {
    if (-not $Letra -or $Letra -eq $env:SystemDrive.TrimEnd(':')) { return }
    if (-not (Test-Path "${Letra}:\")) { Mostrar-Mensagem "A unidade ${Letra}: não está conectada." | Out-Null; Remover-Aviso "corrigir-$Letra"; return }
    $r = Mostrar-Mensagem ("Corrigir a unidade ${Letra}: agora?`n`n- Feche antes tudo o que estiver usando ${Letra}: (fotos, documentos, cópias de backup em andamento).`n- A unidade fica indisponível durante a correção (alguns minutos).`n- A verificação do Windows (chkdsk) abre numa janela própria; acompanhe e feche quando terminar.`n`nSe os arquivos forem importantes, tenha uma cópia em outro lugar antes.") "YesNo" "Warning"
    if ($r -ne "Yes") { return }
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/k title Corrigindo ${Letra}: & chkdsk ${Letra}: /f /x"
    Remover-Aviso "corrigir-$Letra"
}

# ---------- Controles durante a execução ----------
Function Definir-ModoExecucao([bool]$Ativo) {
    $script:ExecucaoAtiva = $Ativo
    $spTarefas.IsEnabled = -not $Ativo
    $ugPerfis.IsEnabled = -not $Ativo
    $chkLaudo.IsEnabled = -not $Ativo
    $bdFormato.IsEnabled = (-not $Ativo) -and [bool]$chkLaudo.IsChecked
    $bdAtendimento.IsEnabled = -not $Ativo
    # Durante a execução, nada de chkdsk, bcdedit, agendamento, licença ou leitura de inventário por outras páginas
    $pgFerramentas.IsEnabled = -not $Ativo
    $pgConfig.IsEnabled = -not $Ativo
    $btnLerFicha.IsEnabled = -not $Ativo
    $btnIniciar.IsEnabled = -not $Ativo
    $btnAvaliar.IsEnabled = -not $Ativo
    $btnManutencaoCompleta.IsEnabled = -not $Ativo
    if ($Ativo) { $txtIniciar.Text = "Em andamento..." } else { Atualizar-BotaoIniciar }
    $btnPausar.IsEnabled = $Ativo
    $btnCancelar.IsEnabled = $Ativo
    $txtPausar.Text = "Pausar"; $icoPausar.Text = [string][char]0xE769
}

# ---------- Carga inicial ----------
$script:IgnorarTrocaPerfil = $false
$Cfg = $script:Config
$script:AppsSelecionadosParaRemocao = @($Cfg.Apps | Where-Object { $_ })
Aplicar-Gating
foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = ((@($Cfg.Marcadas) -contains $T.Id) -and $T.Checkbox.IsEnabled) }
Selecionar-Perfil "$($Cfg.Perfil)"
# Perfis predefinidos ganham as tarefas novas desta versão automaticamente; sem config salva, começa na Completa
if ("$($Cfg.Perfil)" -in 'Diagnostico', 'Rapida', 'Completa', 'Reparo') { Aplicar-Perfil "$($Cfg.Perfil)" }
elseif (@($Cfg.Marcadas).Count -eq 0) { Selecionar-Perfil "Completa"; Aplicar-Perfil "Completa" }
$rbDetalhado.IsChecked = [bool]$Cfg.Detalhado
$rbResumido.IsChecked = -not [bool]$Cfg.Detalhado
Atualizar-BotaoApps
Atualizar-TempoEstimado
Atualizar-Unidades
Atualizar-PaginaConfig
Mostrar-Estado "Pronto" "Pronto para começar" "Escolha um perfil e clique em Iniciar."
Adicionar-LinhaLog "" "Pronto. Laudos e logs ficam em $DataDir"
if (Testar-ReinicioPendente) {
    Adicionar-Aviso -Id "reinicio" -Tipo Aviso -Texto "Há um reinício pendente (atualizações ou reparos). Reinicie antes da manutenção para que DISM e atualizações não sejam adiados."
}
if (Testar-AgendamentoDesatualizado) {
    Adicionar-Aviso -Id "agendamento" -Tipo Info -Texto "A manutenção mensal agendada ainda usa uma versão anterior do programa." -TextoBotao "Usar esta versão" -Acao { param($Info) Atualizar-CopiaAgendada }
}
$PaginaInicial = "$($Cfg.PaginaInicial)"
if ($PaginaInicial -notin 'Inicio', 'Manutencao') { $PaginaInicial = 'Inicio' }
Mostrar-Pagina $PaginaInicial

# ---------- Eventos ----------
$chkLaudo.Add_Click({ $bdFormato.IsEnabled = [bool]$chkLaudo.IsChecked })
$btnAbrirLaudo.Add_Click({ if ($script:ReportFile -and (Test-Path $script:ReportFile)) { Start-Process $script:ReportFile } })
$btnPdf.Add_Click({ Salvar-Pdf "$($script:ReportFile)" })
$btnVerPontuacao.Add_Click({ Mostrar-Pagina 'Inicio' })
$btnAvaliar.Add_Click({ Selecionar-Perfil 'Diagnostico'; Aplicar-Perfil 'Diagnostico'; Mostrar-Pagina 'Manutencao'; Iniciar-Manutencao })
$btnManutencaoCompleta.Add_Click({ Selecionar-Perfil 'Completa'; Aplicar-Perfil 'Completa'; Mostrar-Pagina 'Manutencao' })
$bdEdicao.Add_MouseLeftButtonUp({ Mostrar-Pagina 'Config' })
$btnLerFicha.Add_Click({ Ler-FichaTecnica })
$btnCopiarFicha.Add_Click({
    $t = Texto-Ficha
    if ($t) { [System.Windows.Clipboard]::SetText($t); Mostrar-Mensagem "Ficha técnica copiada para a área de transferência." | Out-Null }
    else { Mostrar-Mensagem "Leia a ficha técnica primeiro (botão 'Ler agora')." | Out-Null }
})

# Configurações: salvas automaticamente
foreach ($rb in @($rbTemaSistema, $rbTemaClaro, $rbTemaEscuro)) { $rb.Add_Checked({ if (-not $script:IgnorarConfig) { Aplicar-Tema "$($this.Tag)" } }) }
$chkMica.Add_Click({ $script:Config.Mica = [bool]$chkMica.IsChecked; Gravar-Config })
foreach ($Par in @(@($txtMarcaNome, 'Nome'), @($txtMarcaTelefone, 'Telefone'), @($txtMarcaContato, 'Contato'), @($txtMarcaTecnico, 'Tecnico'))) {
    $Par[0].Tag = $Par[1]
    $Par[0].Add_LostFocus({ if ("$($script:Config.Marca[$this.Tag])" -ne $this.Text.Trim()) { $script:Config.Marca[$this.Tag] = $this.Text.Trim(); Gravar-Config } })
}
$chkMarcaLaudo.Add_Click({ $script:Config.Marca.MostrarNoLaudo = [bool]$chkMarcaLaudo.IsChecked; Gravar-Config })
$btnLogo.Add_Click({ Escolher-Logo })
$btnLogoRemover.Add_Click({ Remover-Logo })
$btnCopiarCodigo.Add_Click({ [System.Windows.Clipboard]::SetText($lblCodigoMaquina.Text); Mostrar-Mensagem "Código copiado: $($lblCodigoMaquina.Text)`n`nInforme este código ao comprar a edição Casa." | Out-Null })
$btnAtivar.Add_Click({ Ativar-Licenca $txtLicenca.Text })
$btnRemoverLicenca.Add_Click({ Remover-Licenca })
$chkAtualizacoes.Add_Click({ $script:Config.VerificarAtualizacoes = [bool]$chkAtualizacoes.IsChecked; Gravar-Config })
$btnVerificarAtualizacao.Add_Click({ Verificar-AtualizacaoAgora })
$btnSite.Add_Click({ Start-Process $UrlSite })
$btnAbrirPasta.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })
$btnLimparHistorico.Add_Click({
    $r = Mostrar-Mensagem "Apagar o histórico de pontuações e tendências? Os laudos continuam na pasta de dados." "YesNo" "Question"
    if ($r -ne "Yes") { return }
    Remove-Item -LiteralPath $HistoricoFile -Force -ErrorAction SilentlyContinue
    Atualizar-PaginaInicio; if ($script:PaginaAtual -eq 'Historico') { Atualizar-PaginaHistorico }
})

$btnPausar.Add_Click({
    if (-not $script:Rodando -or $script:BloqueioSeguranca) { return }
    if ($script:Pausado) {
        $script:Pausado = $false; $txtPausar.Text = "Pausar"; $icoPausar.Text = [string][char]0xE769
        Mostrar-Estado "Rodando" $null "Execução retomada."
        Escrever-Log ">>> Execução retomada."
    } else {
        $script:Pausado = $true; $txtPausar.Text = "Retomar"; $icoPausar.Text = [string][char]0xE768
        Mostrar-Estado "Pausado" $null "Pausa solicitada: vale ao fim da etapa atual."
        Escrever-Log ">>> Pausa solicitada (vale ao fim da etapa atual)."
    }
})

$btnCancelar.Add_Click({
    if (-not $script:Rodando -or $script:BloqueioSeguranca) { return }
    $script:Cancelado = $true; $script:Pausado = $false
    $btnCancelar.IsEnabled = $false; $btnPausar.IsEnabled = $false
    Mostrar-Estado "Cancelado" $null "Cancelando ao fim da operação atual..."
    Escrever-Log ">>> CANCELAMENTO SOLICITADO PELO USUÁRIO!" "Aviso"
})

# Fechar a janela no meio da manutenção: nunca durante etapa crítica; nas demais, cancela e fecha ao fim da etapa
$Window.Add_Closing({
    param($Remetente, $Evento)
    if (-not $script:Rodando) { Salvar-Config; return }
    $Evento.Cancel = $true
    if ($script:BloqueioSeguranca) {
        Mostrar-Mensagem "Uma etapa crítica está em andamento (DISM, SFC ou Windows Update). Interromper agora poderia danificar o sistema.`n`nAguarde o fim desta etapa." "OK" "Warning" | Out-Null
        return
    }
    $r = Mostrar-Mensagem "A manutenção está em andamento. Cancelar e fechar o programa ao fim da etapa atual?" "YesNo" "Question"
    if ($r -eq "Yes") {
        $script:Cancelado = $true; $script:Pausado = $false; $script:FecharAoTerminar = $true
        Escrever-Log ">>> Cancelamento solicitado; o programa fecha ao fim da etapa atual." "Aviso"
    }
})

Function Iniciar-Manutencao {
    if ($script:Rodando) { return }
    $Sel = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked -and $_.Checkbox.IsEnabled })
    if ($Sel.Count -eq 0) { Mostrar-Mensagem "Marque ao menos uma tarefa." | Out-Null; return }
    if (-not (Testar-ManutencaoLiberada) -and @($Sel | Where-Object { -not $_.SomenteLeitura }).Count -gt 0) {
        Mostrar-Mensagem "A avaliação terminou: só o diagnóstico continua liberado. Ative uma licença em Configurações para executar manutenção." "OK" "Information" | Out-Null
        return
    }
    $script:Atendimento = @{ Cliente = $txtCliente.Text.Trim(); OS = $txtOS.Text.Trim(); Observacoes = $txtObservacoes.Text.Trim() }
    if (-not (Testar-RecursoTecnico)) { $script:Atendimento = @{ Cliente = ""; OS = ""; Observacoes = "" } }

    # Confirmações antes de começar: nada irreversível acontece sem você saber
    if ($Sel.Id -contains "Lixeira") {
        $Lix = Obter-InfoLixeira
        if ($Lix.Quantidade -gt 0) {
            $r = Mostrar-Mensagem ("A Lixeira tem $($Lix.Quantidade) item(ns), cerca de $(Formatar-Tamanho $Lix.Bytes).`n`nEsvaziar a Lixeira não pode ser desfeito. Esvaziar durante a manutenção?") "YesNo" "Warning"
            if ($r -ne "Yes") { $Sel = @($Sel | Where-Object { $_.Id -ne "Lixeira" }); ($script:Tarefas | Where-Object { $_.Id -eq "Lixeira" }).Checkbox.IsChecked = $false }
        }
    }
    if ($Sel.Id -contains "PontosAntigos") {
        $PrevPR = Obter-PreviaPontosRestauracao
        if ($PrevPR.Apagar -eq 0) {
            Adicionar-LinhaLog "" "Pontos de restauração: nada a apagar ($($PrevPR.Total) existente(s), mantidos $PontosRestauracaoManter); etapa ignorada."
            $Sel = @($Sel | Where-Object { $_.Id -ne "PontosAntigos" })
        } else {
            $r = Mostrar-Mensagem ("Existem $($PrevPR.Total) pontos de restauração. Serão apagados os $($PrevPR.Apagar) mais antigos e mantidos os $PontosRestauracaoManter mais recentes.`n`nIsso não pode ser desfeito. Continuar?") "YesNo" "Warning"
            if ($r -ne "Yes") { $Sel = @($Sel | Where-Object { $_.Id -ne "PontosAntigos" }); ($script:Tarefas | Where-Object { $_.Id -eq "PontosAntigos" }).Checkbox.IsChecked = $false }
        }
    }
    if ($Sel.Id -contains "Downloads") {
        $Prev = Obter-PreviaDownloads
        if ($Prev.Quantidade -eq 0) {
            Adicionar-LinhaLog "" "Downloads: nenhum arquivo com mais de $DiasDownloads dias; etapa ignorada."
            $Sel = @($Sel | Where-Object { $_.Id -ne "Downloads" })
        } else {
            $r = Mostrar-Mensagem ("$($Prev.Quantidade) arquivo(s) ($(Formatar-Tamanho $Prev.Bytes)) com mais de $DiasDownloads dias em:`n$($Prev.Pasta)`n`nEles serão movidos para a Lixeira (dá para restaurar). Continuar?") "YesNo" "Warning"
            if ($r -ne "Yes") { $Sel = @($Sel | Where-Object { $_.Id -ne "Downloads" }); ($script:Tarefas | Where-Object { $_.Id -eq "Downloads" }).Checkbox.IsChecked = $false }
        }
    }
    if ($Sel.Id -contains "Rede") {
        $r = Mostrar-Mensagem "O reparo de rede (Winsock) exige reiniciar e pode desconfigurar VPNs e alguns antivírus. Use só se a internet não estiver funcionando.`n`nIncluir o reparo de rede?" "YesNo" "Warning"
        if ($r -ne "Yes") { $Sel = @($Sel | Where-Object { $_.Id -ne "Rede" }); ($script:Tarefas | Where-Object { $_.Id -eq "Rede" }).Checkbox.IsChecked = $false }
    }
    if ($Sel.Count -eq 0) { Atualizar-TempoEstimado; return }
    Atualizar-TempoEstimado
    Salvar-Config

    foreach ($k in @($script:AvisosUI.Keys | Where-Object { $_ -like 'corrigir-*' -or $_ -eq 'reinicio' })) { Remover-Aviso $k }
    $rtbLog.Document.Blocks.Clear()
    $spAcoesLaudo.Visibility = "Collapsed"
    $script:FecharAoTerminar = $false
    $script:UltimoRelogio = $null
    Definir-ModoExecucao $true
    Mostrar-Estado "Rodando" "Iniciando" "Preparando a manutenção..."

    Executar-Manutencao -Selecionadas $Sel -Detalhado ([bool]$rbDetalhado.IsChecked) -GerarLaudo ([bool]$chkLaudo.IsChecked) -AbrirLaudo $true -NomePerfil (Nome-Perfil (Obter-PerfilAtual))

    Definir-ModoExecucao $false
    $lblDecorrido.Text = ((Get-Date) - $script:HoraInicio).ToString("hh\:mm\:ss")
    $Resumo = "$(@($script:RelatorioTarefas | Where-Object Status -eq 'Sucesso').Count) concluída(s), $(@($script:RelatorioTarefas | Where-Object Status -eq 'Aviso').Count) com aviso, $(@($script:RelatorioTarefas | Where-Object Status -eq 'Erro').Count) com erro."
    if ($script:Pontuacao) { $Resumo += " Pontuação de saúde: $($script:Pontuacao.Nota)/100 ($($script:Pontuacao.Rotulo))." }
    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { Mostrar-Estado "Erro" "Manutenção interrompida por falhas" $Resumo; [System.Console]::Beep(1000, 700) }
    elseif ($script:Cancelado) { Mostrar-Estado "Cancelado" "Manutenção cancelada" $Resumo }
    elseif ($script:ErrosEncontrados) { Mostrar-Estado "Erro" "Concluída com erros" $Resumo }
    elseif ($script:AvisosEncontrados) { Mostrar-Estado "Aviso" "Concluída com avisos" $Resumo }
    else { Mostrar-Estado "Sucesso" "Manutenção concluída" $Resumo }
    $TemLaudo = ([bool]$chkLaudo.IsChecked -and $script:ReportFile -and (Test-Path $script:ReportFile))
    $btnAbrirLaudo.Visibility = $(if ($TemLaudo) { "Visible" } else { "Collapsed" })
    $btnPdf.Visibility = $(if ($TemLaudo) { "Visible" } else { "Collapsed" })
    $btnVerPontuacao.Visibility = $(if ($script:Pontuacao) { "Visible" } else { "Collapsed" })
    $spAcoesLaudo.Visibility = "Visible"

    Atualizar-Unidades
    Atualizar-PaginaInicio
    if ($script:PaginaAtual -eq 'Historico') { Atualizar-PaginaHistorico }
    if ($script:PaginaAtual -eq 'Sistema') { Atualizar-PaginaSistema }
    foreach ($L in $script:UnidadesParaCorrigir) {
        Adicionar-Aviso -Id "corrigir-$L" -Tipo Aviso -Texto "Possíveis erros no sistema de arquivos de ${L}:. Feche os arquivos que estiverem abertos nessa unidade e corrija com a ferramenta do Windows." -TextoBotao "Corrigir ${L}:" -Dados $L -Acao { param($Info) Corrigir-Unidade $Info.Dados }
    }

    $Desligar = $chkDesligar.IsChecked -and -not $script:ErrosEncontrados -and -not $script:Cancelado
    if ($Desligar) {
        Mostrar-Estado "" "" "O computador desliga em 60 s. Para cancelar: shutdown /a"
        Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/s /t 60" -WindowStyle Hidden
    } elseif ($script:ReinicioNecessario) {
        Adicionar-Aviso -Id "reinicio" -Tipo Aviso -Texto "Reinicie o computador para concluir reparos, atualizações ou o teste de memória agendado."
        if (-not $script:FecharAoTerminar) {
            $r = Mostrar-Mensagem "É necessário reiniciar para concluir reparos/atualizações. Reiniciar agora? (salve seus trabalhos antes)" "YesNo" "Question"
            if ($r -eq "Yes") { Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /t 30" -WindowStyle Hidden }
        }
    }
    if ($script:FecharAoTerminar) { $Window.Close() }
}
$btnIniciar.Add_Click({ Iniciar-Manutencao })

Iniciar-VerificacaoAtualizacao
$Window.ShowDialog() | Out-Null
