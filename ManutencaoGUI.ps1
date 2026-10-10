# ====================================================================
# MANUTENÇÃO PRO - APLICATIVO DE MANUTENÇÃO DO WINDOWS (POWERSHELL + WPF) - V5
# Usa apenas ferramentas nativas do Windows.
# Modo gráfico (padrão) ou automático/silencioso: -Automatico [-Perfil Rapida|Completa|Reparo]
# Regras de segurança: nada destrutivo sem confirmação; unidades removíveis (cartão SD/USB)
# só recebem verificações somente leitura; tarefas críticas nunca são interrompidas à força.
# ====================================================================
param(
    [switch]$Automatico,
    [ValidateSet("Rapida", "Completa", "Reparo")]
    [string]$Perfil = "Completa"
)

# Evita janelas de progresso/aviso extras quando compilado com ps2exe -noConsole
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$script:Versao = "5.0"

# Caminho do executável atual (.ps1 via powershell.exe ou .exe compilado pelo ps2exe)
$script:ProcessoExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:IsExe = ([IO.Path]::GetFileName($script:ProcessoExe) -notmatch '^(powershell|powershell_ise|pwsh)\.exe$')
$script:CaminhoScript = $PSCommandPath

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $ArgsExtras = "-Perfil $Perfil"
    if ($Automatico) { $ArgsExtras = "-Automatico $ArgsExtras" }
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
// Barra de título escura/colorida no Windows 10/11 (ignorado em versões sem suporte)
public static class JanelaPRO {
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int valor, int tamanho);
    public static void AplicarTema(IntPtr hwnd, bool escuro, int corRgb) {
        int v = escuro ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref v, 4);
        int bgr = ((corRgb & 0xFF) << 16) | (corRgb & 0xFF00) | ((corRgb >> 16) & 0xFF);
        DwmSetWindowAttribute(hwnd, 35, ref bgr, 4);
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

Function Limpar-Historico {
    foreach ($Pasta in @($DirLogs, $DirLaudos)) {
        Get-ChildItem -Path $Pasta -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

Function Mostrar-Mensagem {
    param ([string]$Texto, [string]$Botoes = "OK", [string]$Icone = "Information")
    return [System.Windows.MessageBox]::Show($Texto, "Manutenção PRO", $Botoes, $Icone)
}

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
Function Novo-ItemCheckup([string]$Area, [string]$Item, [string]$Resultado, [string]$Nivel = "OK") {
    return [PSCustomObject]@{ Area = $Area; Item = $Item; Resultado = $Resultado; Nivel = $Nivel }
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
        if ($UsoPct -ge 90) { [void]$L.Add((Novo-ItemCheckup "Memória" "Memória RAM" "$Desc Quase cheia: feche programas ou reduza os apps da inicialização." "Atencao")) }
        else { [void]$L.Add((Novo-ItemCheckup "Memória" "Memória RAM" $Desc)) }
    } catch {}
    $PoucaMem = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = $Desde }
    if ($PoucaMem -gt 0) { [void]$L.Add((Novo-ItemCheckup "Memória" "Falta de memória (30 dias)" "O Windows ficou com pouca memória $PoucaMem vez(es). Feche programas pesados, revise a inicialização ou considere mais RAM." "Atencao")) }
    else { [void]$L.Add((Novo-ItemCheckup "Memória" "Falta de memória (30 dias)" "Nenhum episódio registrado.")) }
    try {
        $Ult = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction Stop
        $Quando = $Ult.TimeCreated.ToString('dd/MM/yyyy')
        if ($Ult.Id -in 1102, 1202 -or $Ult.Level -in 1, 2) { [void]$L.Add((Novo-ItemCheckup "Memória" "Teste de memória" "O último teste ($Quando) ENCONTROU erros na RAM. Memória com defeito corrompe arquivos: procure assistência técnica." "Critico")) }
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
    if ($Blocos -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "$Blocos aviso(s) de bloco defeituoso e $ErrDisco evento(s) de erro de disco. Faça backup e acompanhe a saúde dos discos." "Critico")) }
    elseif ($ErrDisco -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "$ErrDisco evento(s) de erro de disco ou do sistema de arquivos. Pode ser um cartão/USB removido sem segurança; se repetir, faça backup." "Atencao")) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de disco (30 dias)" "Nenhum erro registrado.")) }

    $WheaErro = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = @(1, 2); StartTime = $Desde }
    $WheaAviso = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 3; StartTime = $Desde }
    if ($WheaErro -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaErro erro(s) de hardware NÃO corrigido(s) (processador, memória ou barramento). Se repetir, procure assistência técnica." "Critico")) }
    elseif ($WheaAviso -ge 10) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaAviso erro(s) corrigido(s) automaticamente pelo hardware. Costuma ser inofensivo; acompanhe se aumentar." "Atencao")) }
    elseif ($WheaAviso -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "$WheaAviso erro(s) corrigido(s) automaticamente pelo hardware (inofensivo)." "Info")) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Erros de hardware (30 dias)" "Nenhum erro registrado.")) }

    $Telas = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Desde }
    if ($Telas -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Telas azuis (30 dias)" "$Telas tela(s) azul(is). Se repetir, verifique drivers, temperatura e a memória (teste de RAM)." $(if ($Telas -ge 2) { "Critico" } else { "Atencao" }))) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Telas azuis (30 dias)" "Nenhuma registrada.")) }

    $Quedas = Contar-Eventos @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Desde }
    if ($Quedas -gt 0) { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Desligamentos inesperados (30 dias)" "$Quedas desligamento(s) sem encerramento correto (queda de energia, travamento ou botão de energia segurado)." "Atencao")) }
    else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Desligamentos inesperados (30 dias)" "Nenhum registrado.")) }

    try {
        $Prob = @(Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0" -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 })
        if ($Prob.Count -gt 0) {
            $Nomes = ($Prob | Select-Object -First 4 | ForEach-Object { if ($_.Name) { $_.Name } else { $_.PNPDeviceID } }) -join '; '
            [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Dispositivos e drivers" "$($Prob.Count) dispositivo(s) com erro: $Nomes. Veja no Gerenciador de Dispositivos." "Atencao"))
        } else { [void]$L.Add((Novo-ItemCheckup "Estabilidade" "Dispositivos e drivers" "Todos os dispositivos funcionando.")) }
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
        if ($Mp.AntivirusSignatureAge -gt 7) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Microsoft Defender ativo, mas as definições têm $($Mp.AntivirusSignatureAge) dias. A tarefa do Defender atualiza." "Atencao")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Microsoft Defender ativo, com proteção em tempo real.")) }
    } elseif ($OutrosAV.Count -gt 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Antivírus ativo: $($OutrosAV -join ', ').")) }
    elseif ($Mp -and $Mp.AntivirusEnabled) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "A proteção em tempo real do Defender está DESLIGADA. Ligue em Segurança do Windows." "Critico")) }
    else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Antivírus" "Nenhum antivírus ativo foi encontrado." "Critico")) }

    try {
        $NomesPerfil = @{ Domain = 'Domínio'; Private = 'Privado'; Public = 'Público' }
        $Desl = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { "$($_.Enabled)" -eq 'False' } | ForEach-Object { $NomesPerfil["$($_.Name)"] })
        if ($Desl.Count -eq 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Ativo em todos os perfis de rede.")) }
        else {
            $FwTerc = @()
            try { $FwTerc = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch {}
            if ($FwTerc.Count -gt 0) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Firewall ativo: $($FwTerc -join ', ').")) }
            else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Firewall" "Firewall do Windows desligado nos perfis: $($Desl -join ', ')." "Critico")) }
        }
    } catch {}

    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { [void]$L.Add((Novo-ItemCheckup "Segurança" "Inicialização Segura" "Ativa.")) }
        else { [void]$L.Add((Novo-ItemCheckup "Segurança" "Inicialização Segura" "Desativada no firmware (UEFI). Ela protege contra malware que age antes do Windows." "Atencao")) }
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
        if ($Dias -ge 7) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Tempo sem reiniciar" "Ligado há $Dias dias sem reiniciar. Use 'Reiniciar': com a Inicialização Rápida, 'Desligar' não zera o sistema." "Atencao")) }
        else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Tempo sem reiniciar" "Último reinício em $($Boot.ToString('dd/MM HH:mm')).")) }
    } catch {}

    try {
        $Pontos = @(Get-ComputerRestorePoint -ErrorAction Stop)
        if ($Pontos.Count -eq 0) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Pontos de restauração" "Nenhum disponível. A tarefa 'Criar ponto de restauração' resolve." "Atencao")) }
        else {
            $UltP = $Pontos[-1].ConvertToDateTime($Pontos[-1].CreationTime)
            [void]$L.Add((Novo-ItemCheckup "Sistema" "Pontos de restauração" "$($Pontos.Count) disponível(is); o mais recente em $($UltP.ToString('dd/MM/yyyy')).")) }
    } catch {}

    try {
        $UltWU = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
        if ($UltWU -and $UltWU.Year -gt 2000) {
            $DiasWU = [math]::Floor(((Get-Date).ToUniversalTime() - $UltWU).TotalDays)
            if ($DiasWU -gt 40) { [void]$L.Add((Novo-ItemCheckup "Sistema" "Windows Update" "Última instalação bem-sucedida há $DiasWU dias. Rode a tarefa de atualizações." "Atencao")) }
            else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Windows Update" "Última instalação bem-sucedida em $($UltWU.ToLocalTime().ToString('dd/MM/yyyy')).")) }
        }
    } catch {}

    if (@(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.MediaType)" -eq 'SSD' }).Count -gt 0) {
        $R = Executar-Comando -Comando "$env:SystemRoot\System32\fsutil.exe" -Argumentos "behavior query DisableDeleteNotify" -PodeCancelar $false -TimeoutMinutos 2
        if ($R.Saida -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') {
            if ($Matches[1] -eq '0') { [void]$L.Add((Novo-ItemCheckup "Sistema" "TRIM do SSD" "Ativo: o SSD recebe a limpeza de blocos livres.")) }
            else { [void]$L.Add((Novo-ItemCheckup "Sistema" "TRIM do SSD" "Desativado: o SSD perde desempenho com o tempo. Para reativar: fsutil behavior set DisableDeleteNotify 0" "Atencao")) }
        }
    }

    try {
        $TD = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        if ("$($TD.State)" -eq 'Disabled') { [void]$L.Add((Novo-ItemCheckup "Sistema" "Otimização automática" "A otimização agendada das unidades está desativada no Windows." "Atencao")) }
        else { [void]$L.Add((Novo-ItemCheckup "Sistema" "Otimização automática" "Ativa (o Windows otimiza as unidades sozinho).")) }
    } catch {}

    return $L
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
       Dica = "Salva o estado do sistema antes das mudanças. Ativa a Proteção do Sistema em C: se estiver desligada."
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

    @{ Id = "Saude"; Grupo = "Diagnóstico"; Nome = "Saúde dos discos e unidades"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1
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

    @{ Id = "Checkup"; Grupo = "Diagnóstico"; Nome = "Check-up do sistema e da memória"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1
       Resumo = "Memória RAM, erros de hardware, telas azuis, drivers, bateria e segurança."
       Dica = "Somente leitura. Confere uso da memória RAM, episódios de falta de memória e o resultado do último teste de RAM; erros de disco e de hardware, telas azuis e desligamentos inesperados dos últimos 30 dias; dispositivos com erro; saúde da bateria; antivírus, firewall, Inicialização Segura, TPM e criptografia; tempo sem reiniciar, pontos de restauração e Windows Update."
       Acao = { param($Nome)
            $script:Checkup = @(Executar-Checkup)
            foreach ($I in $script:Checkup) {
                $Marca = switch ($I.Nivel) { 'Critico' { 'CRÍTICO' } 'Atencao' { 'ATENÇÃO' } 'Info' { 'info' } default { 'ok' } }
                Escrever-Log (" -> [{0}] {1}: {2}" -f $Marca, $I.Item, $I.Resultado)
            }
            $Pontos = @($script:Checkup | Where-Object { $_.Nivel -in 'Critico', 'Atencao' })
            if ($Pontos.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" ("$($Pontos.Count) ponto(s) para atenção: " + (($Pontos | ForEach-Object { $_.Item }) -join '; ') + ".") }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "$($script:Checkup.Count) verificações sem problemas (memória, hardware, drivers e segurança)." }
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
            while ($Atual -gt $PontosRestauracaoManter) {
                $R = Executar-Comando -Comando "$env:SystemRoot\System32\vssadmin.exe" -Argumentos "delete shadows /for=$env:SystemDrive /oldest /quiet" -PodeCancelar $false -TimeoutMinutos 5
                $Novo = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
                if ($Novo -ge $Atual) {
                    Registrar-ResultadoTarefa $Nome "Aviso" "Só foi possível reduzir de $Antes para $Novo ponto(s). $(Resumo-Saida $R.Saida 2)"
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
            if (-not $W) { Registrar-ResultadoTarefa $Nome "Aviso" "Winget não encontrado. Instale o 'Instalador de Aplicativo' pela Microsoft Store." }
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

Function Gerar-LaudoHTML {
    param ([bool]$Detalhado, [bool]$Abrir)
    $Antes = $script:MetricasAntes; $Depois = $script:MetricasDepois
    $Liberado = [math]::Max([int64]0, [int64]($Depois.BytesLivres - $Antes.BytesLivres)) # Int64: mais de 2 GB estourava o Int32
    $Ok = @($script:RelatorioTarefas | Where-Object Status -eq "Sucesso").Count
    $Av = @($script:RelatorioTarefas | Where-Object Status -eq "Aviso").Count
    $Er = @($script:RelatorioTarefas | Where-Object Status -eq "Erro").Count
    $Criticos = @($script:Checkup | Where-Object { $_.Nivel -eq 'Critico' })
    $Atencao = @($script:Checkup | Where-Object { $_.Nivel -eq 'Atencao' })
    $Reiniciar = $Depois.ReinicioPendente -or $script:ReinicioNecessario

    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { $Rec = "Manutenção interrompida por falhas críticas. Veja os erros abaixo; pode ser necessária análise técnica."; $ClasseRec = "erro" }
    elseif ($Criticos.Count -gt 0) { $Rec = "O check-up encontrou pontos críticos. Faça backup dos seus arquivos e veja os alertas abaixo."; $ClasseRec = "erro" }
    elseif ($script:Ameacas.Count -gt 0) { $Rec = "Ameaças foram detectadas. Confira a Segurança do Windows."; $ClasseRec = "erro" }
    elseif ($script:AlertasSaude.Count -gt 0) { $Rec = "Atenção às unidades: veja os alertas abaixo e mantenha o backup em dia."; $ClasseRec = "aviso" }
    elseif ($Reiniciar) { $Rec = "Reinicie o computador para concluir reparos e atualizações."; $ClasseRec = "aviso" }
    elseif ($Er -gt 0) { $Rec = "Manutenção concluída com erros: veja os detalhes abaixo."; $ClasseRec = "aviso" }
    elseif ($Atencao.Count -gt 0 -or $Av -gt 0) { $Rec = "Manutenção concluída. Há alguns pontos de atenção abaixo."; $ClasseRec = "aviso" }
    else { $Rec = "Sistema em ordem. Próxima manutenção completa em cerca de 1 mês (a rápida pode ser semanal)."; $ClasseRec = "ok" }

    $Alertas = @($script:AlertasSaude)
    foreach ($I in @($Criticos + $Atencao)) { $Alertas += "$($I.Item): $($I.Resultado)" }
    foreach ($L in $script:UnidadesParaCorrigir) { $Alertas += "${L}: possíveis erros no sistema de arquivos. Feche os arquivos da unidade e use 'Corrigir ${L}:' no programa." }
    if ($Reiniciar) { $Alertas += "Há um reinício pendente." }
    if ($script:Ameacas.Count -gt 0) { $Alertas += "Ameaças detectadas: $($script:Ameacas -join ', ')." }
    if ($Depois.Inicializacao -gt 10) { $Alertas += "$($Depois.Inicializacao) programas abrem junto com o Windows. Desativar os desnecessários (botão 'Inicialização') acelera o boot e libera memória." }
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
        $HtmlCheckup = "<section><h2>Check-up do sistema</h2><table><thead><tr><th style='width:14%'>Área</th><th style='width:24%'>Verificação</th><th>Resultado</th><th style='width:11%'>Situação</th></tr></thead><tbody>"
        foreach ($I in $script:Checkup) {
            $HtmlCheckup += "<tr><td>$(Codificar-Html $I.Area)</td><td>$(Codificar-Html $I.Item)</td><td>$(Codificar-Html $I.Resultado)</td><td><span class='pill $(Classe-Status $I.Nivel)'>$(Codificar-Html (Rotulo-Nivel $I.Nivel))</span></td></tr>"
        }
        $HtmlCheckup += "</tbody></table></section>"
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
        $Tend = if ($B.Tendencia) { "<p class='nota' style='margin:8px 0 0'>$(Codificar-Html $B.Tendencia.Texto)</p>" } else { "" }
        $HtmlBateria = "<section><h2>Saúde da bateria</h2>" +
            "<div class='u-topo'><b style='font-size:22px'>$($B.Saude)%</b><span class='pill $ClasseB'>$RotuloB</span><span>da capacidade original</span></div>" +
            "<div class='barra'><span class='$(if ($B.Nivel -ne 'OK') { 'aviso' })' style='width:$($B.Saude)%'></span></div>" +
            "<div class='u-pe'>$('{0:N0}' -f $B.AtualMWh) mWh hoje, de $('{0:N0}' -f $B.ProjetadaMWh) mWh quando nova · desgaste de $(100 - $B.Saude)%</div>" +
            "<p style='margin:12px 0'>$(Codificar-Html $B.Recomendacao)</p>" +
            "<div class='metricas' style='margin-bottom:0'>$HtmlInfo</div>$Tend$HtmlEvol$Dica" +
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

    $Titulo = if ($script:ContadorFalhas -ge $script:LimiteFalhas) { "Laudo de emergência" } elseif ($Detalhado) { "Laudo técnico detalhado" } else { "Laudo de manutenção" }
    $Modo = if ($script:ModoAutomatico) { "automática (agendada)" } else { "manual" }
    $Duracao = ((Get-Date) - $script:HoraInicio).ToString("hh\:mm\:ss")
    $Subtitulo = "$(Codificar-Html $env:COMPUTERNAME) · $(Get-Date -Format 'dd/MM/yyyy HH:mm') · execução $Modo"
    $ResumoStatus = "$Ok tarefa(s) concluída(s), $Av com aviso, $Er com erro."

    $HTML = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$Titulo - Manutenção PRO</title>
<style>
:root{--fundo:#f3f3f3;--painel:#fff;--borda:#e5e5e5;--texto:#1b1b1b;--texto2:#5c5c5c;--destaque:#c15f3c;--sobre:#fff;--ok:#0f7b0f;--okf:#dff6dd;--aviso:#9d5d00;--avisof:#fff4ce;--erro:#c42b1c;--errof:#fde7e9;--info:#c15f3c;--infof:#fbeee8;--trilha:#e0e0e0;--log:#fafafa}
@media (prefers-color-scheme:dark){:root{--fundo:#202020;--painel:#2b2b2b;--borda:#3a3a3a;--texto:#fff;--texto2:#c8c8c8;--destaque:#d97757;--sobre:#000;--ok:#6ccb5f;--okf:#393d1b;--aviso:#fce100;--avisof:#433519;--erro:#ff99a4;--errof:#442726;--info:#d97757;--infof:#3d2a22;--trilha:#3d3d3d;--log:#1c1c1c}}
*{box-sizing:border-box}
body{margin:0;background:var(--fundo);color:var(--texto);font:14px/1.5 'Segoe UI',system-ui,sans-serif}
.pagina{max-width:1000px;margin:0 auto;padding:32px 16px 48px}
header{display:flex;align-items:center;gap:14px;margin-bottom:24px}
.logo{width:44px;height:44px;border-radius:10px;background:var(--destaque);color:var(--sobre);display:grid;place-items:center;flex:none}
h1{margin:0;font-size:22px;font-weight:600;line-height:1.3}
h2{margin:0 0 12px;font-size:15px;font-weight:600}
.sub{color:var(--texto2);font-size:13px}
section{background:var(--painel);border:1px solid var(--borda);border-radius:8px;padding:18px 20px;margin-bottom:16px;overflow-x:auto}
.status{display:flex;gap:12px;align-items:flex-start;border:1px solid var(--borda);border-radius:8px;padding:14px 18px;margin-bottom:16px}
.status.ok{background:var(--okf)}.status.aviso{background:var(--avisof)}.status.erro{background:var(--errof)}
.ponto{width:10px;height:10px;border-radius:50%;margin-top:7px;flex:none}
.ok .ponto{background:var(--ok)}.aviso .ponto{background:var(--aviso)}.erro .ponto{background:var(--erro)}
.status strong{display:block;font-size:15px;font-weight:600}
.metricas{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}
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
pre.log{background:var(--log);border:1px solid var(--borda);border-radius:6px;padding:12px;font:12px/1.5 'Cascadia Mono',Consolas,monospace;max-height:420px;overflow:auto;white-space:pre-wrap;margin:0}
footer{color:var(--texto2);font-size:12px;text-align:center;margin-top:24px}
@media print{body{background:#fff;color:#000}section,.metrica,.status{break-inside:avoid}pre.log{max-height:none}}
</style>
</head>
<body>
<div class="pagina">
<header>
  <div class="logo"><svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M22.7 19l-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.4 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.5-.4.5-1.1.1-1.4z"/></svg></div>
  <div><h1>$Titulo</h1><div class="sub">$Subtitulo</div></div>
</header>
<div class="status $ClasseRec"><div class="ponto"></div><div><strong>$(Codificar-Html $Rec)</strong><span class="sub">$ResumoStatus</span></div></div>
<div class="metricas">
  <div class="metrica"><span>Duração</span><b>$Duracao</b></div>
  <div class="metrica"><span>Espaço liberado em $env:SystemDrive</span><b>$(Formatar-Tamanho $Liberado)</b></div>
  <div class="metrica"><span>Tarefas: ok / aviso / erro</span><b>$Ok / $Av / $Er</b></div>
  <div class="metrica"><span>Apps na inicialização</span><b>$($Depois.Inicializacao)</b></div>
  <div class="metrica"><span>Plano de energia</span><b>$(Codificar-Html $Depois.PlanoEnergia)</b></div>
  $CardBateria
</div>
$HtmlAlertas
$HtmlUnidades
$HtmlCheckup
$HtmlBateria
$HtmlDiscos
$HtmlMemTest
$HtmlPendentes
$HtmlTarefas
<footer>Manutenção PRO $($script:Versao) · somente ferramentas nativas do Windows</footer>
</div>
</body>
</html>
"@
    Set-Content -Path $script:ReportFile -Value $HTML -Encoding UTF8
    if ($Abrir) { Start-Process $script:ReportFile }
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

Function Executar-Manutencao {
    param ([object[]]$Selecionadas, [bool]$Detalhado, [bool]$GerarLaudo, [bool]$AbrirLaudo)
    $Carimbo = Get-Date -Format "yyyy-MM-dd_HHmm"
    $script:LogFile = Join-Path $DirLogs "Manutencao_$Carimbo.txt"
    $script:ReportFile = Join-Path $DirLaudos "Laudo_$Carimbo.html"
    $script:LogBuffer = New-Object System.Text.StringBuilder
    $script:HoraInicio = Get-Date
    $script:ContadorFalhas = 0; $script:ErrosEncontrados = $false; $script:AvisosEncontrados = $false
    $script:Cancelado = $false; $script:Pausado = $false; $script:ReinicioNecessario = $false
    $script:RelatorioTarefas = @(); $script:SaudeDiscos = @(); $script:AlertasSaude = @(); $script:Ameacas = @()
    $script:Checkup = @(); $script:AtualizacoesPendentes = @(); $script:UnidadesParaCorrigir = @(); $script:Unidades = @()
    $script:Bateria = $null; $script:BateriaLida = $false
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
    Definir-Etapa "Finalizando" "Medindo o resultado e gerando o laudo..."
    $script:MetricasDepois = Obter-Metricas
    if ($script:MetricasDepois.ReinicioPendente) { $script:ReinicioNecessario = $true }
    $script:Rodando = $false

    if ($GerarLaudo) {
        Escrever-Log "Gerando laudo HTML..."
        Gerar-LaudoHTML -Detalhado $Detalhado -Abrir $AbrirLaudo
        Escrever-Log "[OK] Laudo salvo em: $script:ReportFile"
    }
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
    Executar-Manutencao -Selecionadas $Sel -Detalhado $true -GerarLaudo $true -AbrirLaudo $false
    if ($script:ErrosEncontrados) { exit 1 } else { exit 0 }
}

# ==========================================
# INTERFACE GRÁFICA
# ==========================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------- Tema: segue o claro/escuro do Windows ----------
$script:TemaEscuro = $false
try { $script:TemaEscuro = ((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch {}

Function Obter-Paleta([bool]$Escuro) {
    if ($Escuro) {
        return [ordered]@{
            Fundo = '#202020'; Painel = '#2B2B2B'; PainelAlt = '#262626'; Hover = '#353535'; Pressionado = '#303030'
            Borda = '#3A3A3A'; BordaForte = '#5A5A5A'; Texto = '#FFFFFF'; Texto2 = '#C8C8C8'; Texto3 = '#9A9A9A'
            Destaque = '#D97757'; DestaqueHover = '#C96A4B'; DestaquePress = '#B85F43'; SobreDestaque = '#000000'
            Sucesso = '#6CCB5F'; Aviso = '#FCE100'; Erro = '#FF99A4'
            SucessoFundo = '#393D1B'; AvisoFundo = '#433519'; ErroFundo = '#442726'; InfoFundo = '#3D2A22'
            LogFundo = '#1C1C1C'; LogTexto = '#D6D6D6'; Trilha = '#3D3D3D'
        }
    }
    return [ordered]@{
        Fundo = '#F3F3F3'; Painel = '#FFFFFF'; PainelAlt = '#F9F9F9'; Hover = '#F0F0F0'; Pressionado = '#E8E8E8'
        Borda = '#E5E5E5'; BordaForte = '#C4C4C4'; Texto = '#1B1B1B'; Texto2 = '#5C5C5C'; Texto3 = '#8A8A8A'
        Destaque = '#C15F3C'; DestaqueHover = '#CA6B49'; DestaquePress = '#D27856'; SobreDestaque = '#FFFFFF'
        Sucesso = '#0F7B0F'; Aviso = '#9D5D00'; Erro = '#C42B1C'
        SucessoFundo = '#DFF6DD'; AvisoFundo = '#FFF4CE'; ErroFundo = '#FDE7E9'; InfoFundo = '#FBEEE8'
        LogFundo = '#FAFAFA'; LogTexto = '#242424'; Trilha = '#E0E0E0'
    }
}
$script:Paleta = Obter-Paleta $script:TemaEscuro
$script:NsXaml = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$script:FonteIcones = 'Segoe Fluent Icons, Segoe MDL2 Assets'

Function Esc([object]$Texto) { return [Security.SecurityElement]::Escape("$Texto") }

# Caixinha de marcação: o preenchimento azul com o "visto" aparece/some esmaecendo (gatilho IsChecked -> 'preenchimento')
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

# Cores + estilos compartilhados por todas as janelas (botões, caixas, segmentos, barras de rolagem, dicas)
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
            <ControlTemplate TargetType="Button">
                <Grid SnapsToDevicePixels="True">
                    <Border Background="{TemplateBinding Background}" CornerRadius="5"/>
                    <Border x:Name="realce" Background="{DynamicResource DestaqueHover}" CornerRadius="5" Opacity="0"/>
                    <Border x:Name="pressao" Background="{DynamicResource DestaquePress}" CornerRadius="5" Opacity="0"/>
                    <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
                </Grid>
                <ControlTemplate.Triggers>
                    $(Xaml-Esmaecer 'IsMouseOver' 'realce')
                    $(Xaml-Esmaecer 'IsPressed' 'pressao' 60 180)
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
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
                    <Border Background="Transparent" Padding="12,6">
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

# Barra de título no mesmo tom da janela (escura no tema escuro) e ícone próprio
Function Aplicar-TemaJanela($Janela) {
    $Janela.Add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($this)).Handle
            [JanelaPRO]::AplicarTema($h, $script:TemaEscuro, [Convert]::ToInt32($script:Paleta.Fundo.TrimStart('#'), 16))
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

# ---------- Janela principal ----------
$RecursosXaml = Obter-RecursosXaml
[xml]$XAML = @"
<Window $($script:NsXaml)
        Title="Manutenção PRO" Width="1120" Height="780" MinWidth="980" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
$RecursosXaml
    </Window.Resources>
    <Grid Margin="24,18,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Cabeçalho -->
        <Grid Grid.Row="0" Margin="0,0,0,18">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal">
                <Border Width="40" Height="40" CornerRadius="9" Background="{DynamicResource Destaque}">
                    <TextBlock Style="{StaticResource Icone}" Text="&#xE90F;" FontSize="19" Foreground="{DynamicResource SobreDestaque}" HorizontalAlignment="Center"/>
                </Border>
                <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="Manutenção PRO" FontSize="20" FontWeight="SemiBold"/>
                    <TextBlock Name="lblSubtitulo" Text="Manutenção preventiva do Windows" Foreground="{DynamicResource Texto2}" FontSize="12.5"/>
                </StackPanel>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button Name="btnAgendar" Style="{StaticResource BotaoSutil}" ToolTip="Cria (ou remove) a manutenção automática mensal do Windows">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icone}" Text="&#xE787;"/><TextBlock Name="txtAgendar" Text="Agendar mensal" Margin="8,0,0,0"/></StackPanel>
                </Button>
                <Button Name="btnInicializacao" Style="{StaticResource BotaoSutil}" Margin="4,0,0,0" ToolTip="Escolha quais programas abrem junto com o Windows">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icone}" Text="&#xE7E8;"/><TextBlock Text="Inicialização" Margin="8,0,0,0"/></StackPanel>
                </Button>
                <Button Name="btnLaudos" Style="{StaticResource BotaoSutil}" Margin="4,0,0,0" ToolTip="Abre a pasta com o histórico de laudos e logs">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icone}" Text="&#xED25;"/><TextBlock Text="Laudos e logs" Margin="8,0,0,0"/></StackPanel>
                </Button>
            </StackPanel>
        </Grid>

        <!-- Avisos (reinício pendente, agendamento desatualizado, correção de unidade...) -->
        <StackPanel Grid.Row="1" Name="spAvisos"/>

        <!-- Unidades -->
        <WrapPanel Grid.Row="2" Name="wpUnidades"/>

        <Grid Grid.Row="3" Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="5*" MinWidth="440"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="6*" MinWidth="380"/>
            </Grid.ColumnDefinitions>

            <!-- Tarefas -->
            <Border Style="{StaticResource Cartao}">
                <DockPanel>
                    <StackPanel DockPanel.Dock="Top" Margin="16,16,16,6">
                        <TextBlock Text="Perfil" Style="{StaticResource Rotulo}"/>
                        <Border Background="{DynamicResource Fundo}" BorderBrush="{DynamicResource Borda}" BorderThickness="1" CornerRadius="7" Padding="3" Margin="0,6,0,0">
                            <Grid>
                                <Border Style="{StaticResource Pilula}" IsEnabled="{Binding IsEnabled, ElementName=ugPerfis}"/>
                                <UniformGrid Name="ugPerfis" Rows="1">
                                    <RadioButton Name="rbRapida" GroupName="perfil" Tag="Rapida" Content="Rápida" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbCompleta" GroupName="perfil" Tag="Completa" Content="Completa" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbReparo" GroupName="perfil" Tag="Reparo" Content="Reparo" Style="{StaticResource Segmento}"/>
                                    <RadioButton Name="rbPersonalizada" GroupName="perfil" Tag="Personalizada" Content="Personalizada" Style="{StaticResource Segmento}"/>
                                </UniformGrid>
                            </Grid>
                        </Border>
                        <TextBlock Name="lblPerfilDesc" Foreground="{DynamicResource Texto2}" FontSize="12" Margin="2,8,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="6,0,2,8">
                        <StackPanel Name="spTarefas" Margin="4,0,8,4"/>
                    </ScrollViewer>
                </DockPanel>
            </Border>

            <!-- Atividade -->
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
                            <Button Name="btnAbrirLaudo" Style="{StaticResource BotaoLink}" Content="Abrir o laudo" HorizontalAlignment="Left" Margin="0,4,0,0" Visibility="Collapsed"/>
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

        <!-- Rodapé -->
        <Grid Grid.Row="4" Margin="0,16,0,0">
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
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $XAML))
foreach ($n in @("lblSubtitulo", "btnAgendar", "txtAgendar", "btnInicializacao", "btnLaudos", "spAvisos", "wpUnidades", "ugPerfis",
                 "rbRapida", "rbCompleta", "rbReparo", "rbPersonalizada", "lblPerfilDesc", "spTarefas", "bdEstado", "icoEstado",
                 "lblEtapa", "lblDetalhe", "btnAbrirLaudo", "lblDecorrido", "pbStatus", "rtbLog", "chkLaudo", "bdFormato",
                 "ugFormato", "rbResumido", "rbDetalhado", "chkDesligar", "lblTempo", "btnPausar", "icoPausar", "txtPausar", "btnCancelar",
                 "btnIniciar", "icoIniciar", "txtIniciar")) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}
Aplicar-TemaJanela $Window
$lblSubtitulo.Text = "Manutenção preventiva do Windows · versão $($script:Versao)"
$Window.Height = [math]::Min(780, [System.Windows.SystemParameters]::WorkArea.Height - 24)

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

# ---------- Avisos no topo da janela ----------
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
}
foreach ($G in $script:Grupos) {
    $DoGrupo = @($script:Tarefas | Where-Object { $_.Grupo -eq $G })
    if ($DoGrupo.Count -eq 0) { continue }
    $Margem = if ($spTarefas.Children.Count -eq 0) { "10,6,0,4" } else { "10,16,0,4" }
    [void]$spTarefas.Children.Add((Criar-Elemento "<TextBlock $($script:NsXaml) Text=`"$(Esc $G)`" Style=`"{DynamicResource Rotulo}`" Margin=`"$Margem`"/>"))
    foreach ($T in $DoGrupo) {
        $SeloXaml = ""
        if ($T.Selo) {
            $S = $script:SeloEstilo[$T.Selo]
            if (-not $S) { $S = @{ Fundo = 'Hover'; Cor = 'Texto2' } }
            $SeloXaml = "<Border Background=`"{DynamicResource $($S.Fundo)}`" CornerRadius=`"4`" Padding=`"6,1`" Margin=`"8,0,0,0`" VerticalAlignment=`"Center`"><TextBlock Text=`"$(Esc $T.Selo)`" FontSize=`"11`" Foreground=`"{DynamicResource $($S.Cor)}`"/></Border>"
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

# ---------- Segmentos com pílula deslizante (Perfil e formato do laudo) ----------
# A pílula é o 1º filho do Grid que contém o UniformGrid dos botões; ela corre até o item marcado
# com desaceleração suave e, se o clique vier no meio do caminho, muda de rumo sem dar salto.
$script:DuracaoPilulaMs = 380
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
    }
    # Na abertura e ao redimensionar a janela a pílula vai direto ao lugar; se estiver correndo, só corrige o destino
    $Painel.Add_SizeChanged({
        $Fim = $this.Parent.Children[0].Tag
        Mover-Pilula $this (($Fim -is [datetime]) -and ((Get-Date) -lt $Fim))
    })
}
Ativar-SegmentoDeslizante $ugPerfis
Ativar-SegmentoDeslizante $ugFormato

# ---------- Perfis ----------
$script:DescricaoPerfis = @{
    Rapida = "Semanal: diagnóstico, limpeza leve, apps atualizados e verificação rápida de vírus."
    Completa = "Mensal: ponto de restauração, diagnóstico, limpeza, reparo, atualizações, antivírus em todas as unidades e otimização."
    Reparo = "Quando algo não vai bem: diagnóstico, teste de memória, reparo do sistema, das unidades e da rede."
    Personalizada = "Marque abaixo só as tarefas que quiser executar."
}
$script:RadiosPerfil = @{ Rapida = $rbRapida; Completa = $rbCompleta; Reparo = $rbReparo; Personalizada = $rbPersonalizada }
$script:IgnorarTrocaPerfil = $false

Function Atualizar-TempoEstimado {
    $Total = ($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Minutos } | Measure-Object -Sum).Sum
    if (-not $Total) { $Total = 0 }
    $lblTempo.Text = "Tempo estimado ≈ $Total min"
}

Function Aplicar-Perfil([string]$Id) {
    foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = ($T.Perfis -contains $Id) }
    Atualizar-TempoEstimado
}

Function Selecionar-Perfil([string]$Id) {
    if (-not $script:RadiosPerfil.ContainsKey("$Id")) { $Id = "Personalizada" }
    $script:IgnorarTrocaPerfil = $true
    $script:RadiosPerfil[$Id].IsChecked = $true
    $lblPerfilDesc.Text = $script:DescricaoPerfis[$Id]
    $script:IgnorarTrocaPerfil = $false
}

foreach ($rb in $script:RadiosPerfil.Values) {
    $rb.Add_Checked({
        $lblPerfilDesc.Text = $script:DescricaoPerfis["$($this.Tag)"]
        if (-not $script:IgnorarTrocaPerfil -and $this.Tag -ne "Personalizada") { Aplicar-Perfil "$($this.Tag)" }
    })
}

Function Obter-PerfilAtual {
    foreach ($k in $script:RadiosPerfil.Keys) { if ($script:RadiosPerfil[$k].IsChecked) { return $k } }
    return "Personalizada"
}

Function Salvar-Config {
    $Cfg = [PSCustomObject]@{
        Perfil = Obter-PerfilAtual
        Marcadas = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Id })
        Detalhado = [bool]$rbDetalhado.IsChecked
        Apps = @($script:AppsSelecionadosParaRemocao)
    }
    try { $Cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 } catch {}
}

Function Atualizar-BotaoApps {
    ($script:Tarefas | Where-Object { $_.Id -eq "Debloat" }).Botao.Content = "Escolher apps ($($script:AppsSelecionadosParaRemocao.Count))"
}

# ---------- Janela: seleção de apps para remover (Debloat) ----------
Function Abrir-SeletorDebloat {
    $DebloatXAML = @"
<Window $($script:NsXaml)
        Title="Remover aplicativos" Height="660" Width="560" MinHeight="480" MinWidth="460" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
$RecursosXaml
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
    if ($script:AppsSelecionadosParaRemocao.Count -gt 0) { $TDebloat.Checkbox.IsChecked = $true; Selecionar-Perfil "Personalizada"; Atualizar-TempoEstimado }
    Atualizar-BotaoApps
}

# ---------- Janela: programas da inicialização ----------
Function Abrir-GerenciadorInicializacao {
    $IniXAML = @"
<Window $($script:NsXaml)
        Title="Programas da inicialização" Height="620" Width="640" MinHeight="420" MinWidth="480" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource Fundo}" Foreground="{DynamicResource Texto}" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
$RecursosXaml
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

Function Atualizar-BotaoAgendar {
    $txtAgendar.Text = if (Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue) { "Agendada (mensal)" } else { "Agendar mensal" }
}

Function Alternar-Agendamento {
    $Existente = Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue
    if ($Existente) {
        $Prox = (Get-ScheduledTaskInfo -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue).NextRunTime
        $r = Mostrar-Mensagem "A manutenção automática já está agendada (próxima execução: $Prox).`n`nDeseja REMOVER o agendamento?" "YesNo" "Question"
        if ($r -eq "Yes") { Unregister-ScheduledTask -TaskName $NomeTarefaAgendada -Confirm:$false; Remover-Aviso "agendamento"; Mostrar-Mensagem "Agendamento removido." | Out-Null }
        Atualizar-BotaoAgendar
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
    Atualizar-BotaoAgendar
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
    $spTarefas.IsEnabled = -not $Ativo
    $ugPerfis.IsEnabled = -not $Ativo
    $chkLaudo.IsEnabled = -not $Ativo
    $bdFormato.IsEnabled = (-not $Ativo) -and [bool]$chkLaudo.IsChecked
    $btnAgendar.IsEnabled = -not $Ativo
    $btnInicializacao.IsEnabled = -not $Ativo
    $btnIniciar.IsEnabled = -not $Ativo
    $txtIniciar.Text = if ($Ativo) { "Em andamento..." } else { "Iniciar manutenção" }
    $btnPausar.IsEnabled = $Ativo
    $btnCancelar.IsEnabled = $Ativo
    $txtPausar.Text = "Pausar"; $icoPausar.Text = [string][char]0xE769
}

# ---------- Carga inicial ----------
$script:IgnorarTrocaPerfil = $false
$CfgCarregada = $false
if (Test-Path $ConfigFile) {
    try {
        $Cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:AppsSelecionadosParaRemocao = @($Cfg.Apps | Where-Object { $_ })
        foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = (@($Cfg.Marcadas) -contains $T.Id) }
        Selecionar-Perfil "$($Cfg.Perfil)"
        # Perfis predefinidos ganham as tarefas novas desta versão automaticamente
        if ("$($Cfg.Perfil)" -in 'Rapida', 'Completa', 'Reparo') { Aplicar-Perfil "$($Cfg.Perfil)" }
        $rbDetalhado.IsChecked = [bool]$Cfg.Detalhado
        $rbResumido.IsChecked = -not [bool]$Cfg.Detalhado
        $CfgCarregada = $true
    } catch {}
}
if (-not $CfgCarregada) { Selecionar-Perfil "Completa"; Aplicar-Perfil "Completa" }
Atualizar-BotaoApps
Atualizar-TempoEstimado
Atualizar-Unidades
Atualizar-BotaoAgendar
Mostrar-Estado "Pronto" "Pronto para começar" "Escolha um perfil e clique em Iniciar manutenção."

Adicionar-LinhaLog "" "Pronto. Laudos e logs ficam em $DataDir"
if (Testar-ReinicioPendente) {
    Adicionar-Aviso -Id "reinicio" -Tipo Aviso -Texto "Há um reinício pendente (atualizações ou reparos). Reinicie antes da manutenção para que DISM e atualizações não sejam adiados."
}
if (Testar-AgendamentoDesatualizado) {
    Adicionar-Aviso -Id "agendamento" -Tipo Info -Texto "A manutenção mensal agendada ainda usa uma versão anterior do programa." -TextoBotao "Usar esta versão" -Acao { param($Info) Atualizar-CopiaAgendada }
}

# ---------- Eventos ----------
$chkLaudo.Add_Click({ $bdFormato.IsEnabled = [bool]$chkLaudo.IsChecked })
$btnAgendar.Add_Click({ Alternar-Agendamento })
$btnInicializacao.Add_Click({ Abrir-GerenciadorInicializacao })
$btnLaudos.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })
$btnAbrirLaudo.Add_Click({ if ($script:ReportFile -and (Test-Path $script:ReportFile)) { Start-Process $script:ReportFile } })

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

$btnIniciar.Add_Click({
    if ($script:Rodando) { return }
    $Sel = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked })
    if ($Sel.Count -eq 0) { Mostrar-Mensagem "Marque ao menos uma tarefa." | Out-Null; return }

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
    $btnAbrirLaudo.Visibility = "Collapsed"
    $script:FecharAoTerminar = $false
    $script:UltimoRelogio = $null
    Definir-ModoExecucao $true
    Mostrar-Estado "Rodando" "Iniciando" "Preparando a manutenção..."

    Executar-Manutencao -Selecionadas $Sel -Detalhado ([bool]$rbDetalhado.IsChecked) -GerarLaudo ([bool]$chkLaudo.IsChecked) -AbrirLaudo $true

    Definir-ModoExecucao $false
    $lblDecorrido.Text = ((Get-Date) - $script:HoraInicio).ToString("hh\:mm\:ss")
    $Resumo = "$(@($script:RelatorioTarefas | Where-Object Status -eq 'Sucesso').Count) concluída(s), $(@($script:RelatorioTarefas | Where-Object Status -eq 'Aviso').Count) com aviso, $(@($script:RelatorioTarefas | Where-Object Status -eq 'Erro').Count) com erro."
    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { Mostrar-Estado "Erro" "Manutenção interrompida por falhas" $Resumo; [System.Console]::Beep(1000, 700) }
    elseif ($script:Cancelado) { Mostrar-Estado "Cancelado" "Manutenção cancelada" $Resumo }
    elseif ($script:ErrosEncontrados) { Mostrar-Estado "Erro" "Concluída com erros" $Resumo }
    elseif ($script:AvisosEncontrados) { Mostrar-Estado "Aviso" "Concluída com avisos" $Resumo }
    else { Mostrar-Estado "Sucesso" "Manutenção concluída" $Resumo }
    if ($chkLaudo.IsChecked -and $script:ReportFile -and (Test-Path $script:ReportFile)) { $btnAbrirLaudo.Visibility = "Visible" }

    Atualizar-Unidades
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
})

$Window.ShowDialog() | Out-Null
