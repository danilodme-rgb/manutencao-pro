# ====================================================================
# MANUTENÇÃO PRO - APLICATIVO DE MANUTENÇÃO DO WINDOWS (POWERSHELL + WPF) - V4
# Usa apenas ferramentas nativas do Windows.
# Modo gráfico (padrão) ou automático/silencioso: -Automatico [-Perfil Rapida|Completa|Reparo]
# ====================================================================
param(
    [switch]$Automatico,
    [ValidateSet("Rapida", "Completa", "Reparo")]
    [string]$Perfil = "Completa"
)

# Evita janelas de progresso/aviso extras quando compilado com ps2exe -noConsole
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

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
"@

# ==========================================
# UTILITÁRIOS
# ==========================================
Function Atualizar-Tela {
    if ($script:ModoAutomatico) { return }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

Function Escrever-Log {
    param ([string]$Mensagem, [ValidateSet("Info", "Aviso", "Erro")][string]$Tipo = "Info")
    $Prefixo = switch ($Tipo) { "Erro" { "[ERRO] " } "Aviso" { "[AVISO] " } default { "" } }
    $Linha = "[$(Get-Date -Format 'HH:mm:ss')] $Prefixo$Mensagem"
    [void]$script:LogBuffer.AppendLine($Linha)
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $Linha -Encoding UTF8 } catch {} }
    if (-not $script:ModoAutomatico) { $txtLog.AppendText("`n$Linha"); $txtLog.ScrollToEnd(); Atualizar-Tela }
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

Function Obter-VolumesFixos {
    @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -in 'NTFS', 'ReFS' } | Sort-Object DriveLetter)
}

Function Obter-TipoMidia([string]$Letra) {
    try {
        $Numero = (Get-Partition -DriveLetter $Letra -ErrorAction Stop).DiskNumber
        $Disco = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$Numero" } | Select-Object -First 1
        if ($Disco) { return "$($Disco.MediaType)" }
    } catch {}
    return "Desconhecido"
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
        $Linha = "/s /c `"`"$Comando`" $Argumentos > `"$ArqSaida`" 2>&1`""
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

# Apaga arquivos de uma pasta (opcionalmente só os antigos, ou enviando para a Lixeira) sem travar a interface
Function Limpar-Pasta {
    param ([string]$Caminho, [int]$IdadeMinimaHoras = 0, [switch]$ParaLixeira)
    $Liberado = [int64]0; $Falhas = 0; $Qtd = 0
    if (-not $Caminho -or -not (Test-Path -LiteralPath $Caminho)) { return [PSCustomObject]@{ Bytes = 0; Falhas = 0; Arquivos = 0 } }
    $Limite = (Get-Date).AddHours(-$IdadeMinimaHoras)
    $i = 0
    foreach ($Arq in @(Get-ChildItem -LiteralPath $Caminho -Recurse -File -Force -ErrorAction SilentlyContinue)) {
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
    if (-not $ParaLixeira) {
        # Remove subpastas que ficaram vazias (da mais profunda para a mais rasa)
        Get-ChildItem -LiteralPath $Caminho -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }
    return [PSCustomObject]@{ Bytes = $Liberado; Falhas = $Falhas; Arquivos = $Qtd }
}

Function Obter-PreviaDownloads {
    $Pasta = Obter-PastaDownloads
    $Limite = (Get-Date).AddDays(-$DiasDownloads)
    $Arqs = @(Get-ChildItem -LiteralPath $Pasta -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -le $Limite -and $_.CreationTime -le $Limite })
    return [PSCustomObject]@{ Pasta = $Pasta; Quantidade = $Arqs.Count; Bytes = [int64]($Arqs | Measure-Object Length -Sum).Sum }
}

# ==========================================
# DIAGNÓSTICOS (saúde dos discos, inicialização, CBS, DISM)
# ==========================================
Function Obter-SaudeDiscos {
    $Lista = @()
    foreach ($Disco in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $R = $null
        try { $R = $Disco | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $Lista += [PSCustomObject]@{
            Nome = $Disco.FriendlyName
            Tipo = "$($Disco.MediaType)"
            Barramento = "$($Disco.BusType)"
            TamanhoGB = [math]::Round($Disco.Size / 1GB)
            Saude = "$($Disco.HealthStatus)"
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

# ==========================================
# TABELA DE TAREFAS
# Perfis: Rapida (semanal), Completa (mensal), Reparo (quando há problemas)
# Auto = pode rodar no modo automático/agendado (sem ninguém na frente do PC)
# Critica = Pausar/Cancelar ficam bloqueados (interromper seria perigoso)
# ==========================================
$script:Tarefas = @(
    @{ Id = "Restore"; Nome = "Criar ponto de restauração (backup)"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 3; Cor = "#005A9E"
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

    @{ Id = "Saude"; Nome = "Diagnóstico de saúde dos discos (SSD/HD)"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1
       Dica = "Lê desgaste, temperatura e erros (SMART) dos discos e confere o espaço livre."
       Acao = { param($Nome)
            $script:SaudeDiscos = @(Obter-SaudeDiscos)
            $Alertas = @()
            foreach ($D in $script:SaudeDiscos) {
                $Desg = if ($null -ne $D.Desgaste) { "$($D.Desgaste)%" } else { "n/d" }
                $Temp = if ($null -ne $D.Temperatura) { "$($D.Temperatura) °C" } else { "n/d" }
                Escrever-Log (" -> {0} ({1}, {2} GB): saúde {3}, desgaste {4}, temperatura {5}" -f $D.Nome, $D.Tipo, $D.TamanhoGB, $D.Saude, $Desg, $Temp)
                $Alertas += Obter-AlertasDisco $D
            }
            $Esp = Obter-EspacoSistema
            if ($Esp.Percentual -lt 15) { $Alertas += "Pouco espaço livre em $env:SystemDrive ($($Esp.Percentual)%). Manter ao menos 15% livre preserva o desempenho e a vida útil do SSD." }
            $script:AlertasSaude = $Alertas
            if ($Alertas.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" ($Alertas -join " ") }
            else { Registrar-ResultadoTarefa $Nome "Sucesso" "$($script:SaudeDiscos.Count) disco(s) saudável(is); $($Esp.Percentual)% livre em $env:SystemDrive." }
       } }

    @{ Id = "Temp"; Nome = "Limpar temporários e Lixeira"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 2
       Dica = "Apaga arquivos temporários com mais de 24 h (Windows e todos os usuários) e esvazia a Lixeira."
       Acao = { param($Nome)
            if (-not $script:ModoAutomatico) { try { Clear-RecycleBin -Force -ErrorAction Stop } catch {} }
            $Pastas = @("$env:SystemRoot\Temp") + @(Obter-PerfisUsuario | ForEach-Object { Join-Path $_ 'AppData\Local\Temp' })
            $Total = [int64]0; $Falhas = 0
            foreach ($P in $Pastas) { $R = Limpar-Pasta -Caminho $P -IdadeMinimaHoras 24; $Total += $R.Bytes; $Falhas += $R.Falhas }
            $Extra = if ($script:ModoAutomatico) { "" } else { " Lixeira esvaziada." }
            Registrar-ResultadoTarefa $Nome "Sucesso" "$(Formatar-Tamanho $Total) apagados em $($Pastas.Count) pasta(s) temporária(s); $Falhas arquivo(s) em uso mantido(s).$Extra"
       } }

    @{ Id = "Nav"; Nome = "Limpar cache dos navegadores"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 1
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

    @{ Id = "CleanMgr"; Nome = "Limpeza de Disco do Windows (cleanmgr)"; Perfis = @("Completa"); Auto = $true; Minutos = 8
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

    @{ Id = "DNS"; Nome = "Limpar cache DNS"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 1
       Dica = "Resolve sites que não abrem por endereço antigo em cache. Não exige reinício."
       Acao = { param($Nome)
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\ipconfig.exe" -Argumentos "/flushdns"
            if ($R.ExitCode -ne 0) { throw "ipconfig /flushdns retornou $(Formatar-Codigo $R.ExitCode)." }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Cache DNS limpo."
       } }

    @{ Id = "Rede"; Nome = "Reparo de rede (Winsock) - requer reinício"; Perfis = @("Reparo"); Auto = $false; Minutos = 1; Cor = "#D2691E"
       Dica = "Use só quando a internet não funciona. Exige reinício e pode desconfigurar VPNs e alguns antivírus."
       Acao = { param($Nome)
            $R = Executar-Comando -Comando "$env:SystemRoot\System32\netsh.exe" -Argumentos "winsock reset"
            if ($R.ExitCode -ne 0) { throw "netsh winsock reset retornou $(Formatar-Codigo $R.ExitCode). $(Resumo-Saida $R.Saida 2)" }
            $script:ReinicioNecessario = $true
            Registrar-ResultadoTarefa $Nome "Sucesso" "Winsock redefinido. REINICIE o computador para concluir."
       } }

    @{ Id = "DISM"; Nome = "Verificar e reparar imagem do Windows (DISM)"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 15; Critica = $true; Cor = "#B30000"
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

    @{ Id = "SFC"; Nome = "Verificar arquivos do sistema (SFC)"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 15; Critica = $true; Cor = "#B30000"
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

    @{ Id = "Volume"; Nome = "Verificar sistema de arquivos (sem reiniciar)"; Perfis = @("Completa", "Reparo"); Auto = $true; Minutos = 5
       Dica = "Verifica os discos com o Windows ligado (Repair-Volume -Scan). Se achar erros, agenda a correção para o próximo reinício."
       Acao = { param($Nome)
            $Det = @(); $Aviso = $false
            foreach ($V in Obter-VolumesFixos) {
                $L = "$($V.DriveLetter)"
                Escrever-Log " -> Verificando ${L}: ..."
                $R = Executar-PSIsolado -AvisoMinutos 20 -TimeoutMinutos 90 -Script ("try { Write-Output ('ESTADO=' + (Repair-Volume -DriveLetter LETRA -Scan -ErrorAction Stop)) } catch { Write-Output ('FALHA=' + `$_.Exception.Message) }" -replace 'LETRA', $L)
                if ($R.Cancelado) { return }
                $Estado = if ($R.Saida -match 'ESTADO=(\w+)') { $Matches[1] } else { "Desconhecido" }
                switch ($Estado) {
                    'NoErrorsFound' { $Det += "${L}: sem erros" }
                    'ScanNeeded' { $Det += "${L}: verificação incompleta, repita depois"; $Aviso = $true }
                    'Desconhecido' { $Det += "${L}: não foi possível verificar ($(Resumo-Saida $R.Saida 1))"; $Aviso = $true }
                    default {
                        $null = Executar-Comando -Comando "$env:SystemRoot\System32\fsutil.exe" -Argumentos "dirty set ${L}:"
                        $script:ReinicioNecessario = $true; $Aviso = $true
                        $Det += "${L}: ERROS encontrados ($Estado); correção agendada para o próximo reinício"
                    }
                }
            }
            Registrar-ResultadoTarefa $Nome $(if ($Aviso) { "Aviso" } else { "Sucesso" }) (($Det -join "; ") + ".")
       } }

    @{ Id = "WU"; Nome = "Instalar atualizações do Windows e drivers"; Perfis = @("Completa"); Auto = $true; Minutos = 20; Critica = $true
       Dica = "Usa o Windows Update nativo: atualizações de segurança/qualidade e drivers. Drivers opcionais só são instalados se forem mais novos que o atual. Versões prévias são ignoradas."
       Acao = { param($Nome)
            $R = Executar-PSIsolado -PodeCancelar $false -AvisoMinutos 45 -Script @'
try {
    $Sessao = New-Object -ComObject Microsoft.Update.Session
    $Sessao.ClientApplicationID = 'ManutencaoPRO'
    $Res = $Sessao.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    $Instalados = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID })
    $Lista = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($U in $Res.Updates) {
        if ($U.Type -eq 2) {
            # Driver: instala só se for mais novo que o driver atual do mesmo dispositivo
            $Atual = $Instalados | Where-Object { $_.HardwareID -eq $U.DriverHardwareID } | Select-Object -First 1
            if ($Atual -and $Atual.DriverDate -and $Atual.DriverDate -ge $U.DriverVerDate) { Write-Output ('PULADO=' + $U.Title); continue }
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
            if ($R.Saida -match 'FALHA=(.+)') { throw "Windows Update falhou: $($Matches[1].Trim())" }
            if ($R.Saida -match 'RESULTADO=NENHUMA') { Registrar-ResultadoTarefa $Nome "Sucesso" "Windows e drivers já estão atualizados."; return }
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

    @{ Id = "Winget"; Nome = "Atualizar aplicativos (winget + Microsoft Store)"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 10
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

    @{ Id = "WinUpLimpeza"; Nome = "Limpar resíduos do Windows Update"; Perfis = @("Completa"); Auto = $true; Minutos = 10; Critica = $true
       Dica = "Remove versões antigas de componentes (DISM StartComponentCleanup), o cache de downloads do Windows Update e o cache de Otimização de Entrega."
       Acao = { param($Nome)
            $Det = @()
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; $Det += "cache de Otimização de Entrega limpo" } catch {}
            if (Testar-ReinicioPendente) {
                Registrar-ResultadoTarefa $Nome "Aviso" "Há atualizações aguardando reinício; a limpeza de componentes foi adiada. Reinicie e rode de novo. $($Det -join '; ')"
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

    @{ Id = "Defender"; Nome = "Verificação rápida (Windows Defender)"; Perfis = @("Rapida", "Completa", "Reparo"); Auto = $true; Minutos = 5
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
            $script:Ameacas = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $Inicio } | ForEach-Object {
                $n = (Get-MpThreat -ThreatID $_.ThreatID -ErrorAction SilentlyContinue).ThreatName; if ($n) { $n } else { "ID $($_.ThreatID)" } } | Select-Object -Unique)
            if ($script:Ameacas.Count -gt 0) { Registrar-ResultadoTarefa $Nome "Aviso" "$($script:Ameacas.Count) ameaça(s) detectada(s): $($script:Ameacas -join ', '). Confira em Segurança do Windows > Proteção contra vírus e ameaças." }
            elseif ($R.ExitCode -eq 0) { Registrar-ResultadoTarefa $Nome "Sucesso" "Nenhuma ameaça encontrada na verificação rápida." }
            elseif ($R.ExitCode -eq 2) { Registrar-ResultadoTarefa $Nome "Aviso" "O Defender relatou ameaças. Confira em Segurança do Windows > Histórico de proteção." }
            else { throw "MpCmdRun retornou $(Formatar-Codigo $R.ExitCode). $(Resumo-Saida $R.Saida 2)" }
       } }

    @{ Id = "Otimizar"; Nome = "Otimizar discos (TRIM no SSD / desfragmentar HD)"; Perfis = @("Rapida", "Completa"); Auto = $true; Minutos = 5
       Dica = "Usa 'defrag /O', que escolhe sozinho a otimização certa para cada tipo de disco: SSD recebe TRIM e nunca é desfragmentado."
       Acao = { param($Nome)
            $Det = @(); $Falhou = $false
            foreach ($V in Obter-VolumesFixos) {
                $L = "$($V.DriveLetter)"
                $Tipo = Obter-TipoMidia $L
                Escrever-Log " -> ${L}: ($Tipo) otimizando..."
                $R = Executar-Comando -Comando "$env:SystemRoot\System32\defrag.exe" -Argumentos "${L}: /O" -AvisoMinutos 30
                if ($R.Cancelado) { return }
                if ($R.ExitCode -eq 0) { $Det += "${L}: ($Tipo) OK" } else { $Det += "${L}: falhou ($(Formatar-Codigo $R.ExitCode))"; $Falhou = $true }
            }
            Registrar-ResultadoTarefa $Nome $(if ($Falhou) { "Aviso" } else { "Sucesso" }) (($Det -join "; ") + ".")
       } }

    @{ Id = "StorageSense"; Nome = "Ativar Sensor de Armazenamento (limpeza contínua)"; Perfis = @("Completa"); Auto = $false; Minutos = 1
       Dica = "Configura o recurso nativo do Windows para limpar temporários e a Lixeira (itens com mais de 30 dias) todo mês. A pasta Downloads não é tocada."
       Acao = { param($Nome)
            $Chave = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
            if (-not (Test-Path $Chave)) { New-Item -Path $Chave -Force | Out-Null }
            $Valores = @{ '01' = 1; '2048' = 30; '04' = 1; '08' = 1; '256' = 30 }
            foreach ($k in $Valores.Keys) { Set-ItemProperty -Path $Chave -Name $k -Value $Valores[$k] -Type DWord }
            Registrar-ResultadoTarefa $Nome "Sucesso" "Sensor de Armazenamento ativo: roda mensalmente (temporários e Lixeira com mais de 30 dias)."
       } }

    @{ Id = "Debloat"; Nome = "Remover aplicativos escolhidos (Debloat)"; Perfis = @(); Auto = $false; Minutos = 3; Cor = "#2E7D32"
       Dica = "Remove só os apps que você escolher em 'Selecionar Apps'. Sem seleção, nada é removido."
       Acao = { param($Nome)
            if ($script:AppsSelecionadosParaRemocao.Count -eq 0) { Registrar-ResultadoTarefa $Nome "Aviso" "Nenhum aplicativo selecionado em 'Selecionar Apps'; nada foi removido."; return }
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

    @{ Id = "Downloads"; Nome = "Limpar Downloads antigos (vai para a Lixeira)"; Perfis = @(); Auto = $false; Minutos = 2; Cor = "#D2691E"
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
# LAUDO HTML
# ==========================================
Function Codificar-Html([object]$Texto) { return [System.Net.WebUtility]::HtmlEncode("$Texto") }

Function Gerar-LaudoHTML {
    param ([bool]$Detalhado, [bool]$Abrir)
    $Antes = $script:MetricasAntes; $Depois = $script:MetricasDepois
    $Liberado = [math]::Max(0, $Depois.BytesLivres - $Antes.BytesLivres)
    $Ok = @($script:RelatorioTarefas | Where-Object Status -eq "Sucesso").Count
    $Av = @($script:RelatorioTarefas | Where-Object Status -eq "Aviso").Count
    $Er = @($script:RelatorioTarefas | Where-Object Status -eq "Erro").Count

    if ($script:ContadorFalhas -ge $script:LimiteFalhas) { $Rec = "MANUTENÇÃO ABORTADA POR FALHAS CRÍTICAS. Veja os erros abaixo; pode ser necessária análise técnica."; $CorRec = "#B30000" }
    elseif ($script:AlertasSaude.Count -gt 0) { $Rec = "Atenção aos discos: faça backup dos seus arquivos e acompanhe os alertas abaixo."; $CorRec = "#B30000" }
    elseif ($script:Ameacas.Count -gt 0) { $Rec = "Ameaças foram detectadas. Confira a Segurança do Windows."; $CorRec = "#B30000" }
    elseif ($Depois.ReinicioPendente) { $Rec = "Reinicie o computador para concluir reparos e atualizações."; $CorRec = "#E65100" }
    elseif ($Er -gt 0) { $Rec = "Concluída com erros: veja os detalhes abaixo."; $CorRec = "#E65100" }
    else { $Rec = "Sistema em ordem. Próxima manutenção completa em cerca de 1 mês (a rápida pode ser semanal)."; $CorRec = "#388E3C" }

    $Alertas = @($script:AlertasSaude)
    if ($Depois.ReinicioPendente) { $Alertas += "Há um reinício pendente." }
    if ($script:Ameacas.Count -gt 0) { $Alertas += "Ameaças detectadas: $($script:Ameacas -join ', ')" }
    if ($Depois.Inicializacao -gt 10) { $Alertas += "$($Depois.Inicializacao) programas abrem junto com o Windows. Desativar os desnecessários (botão 'Inicialização') acelera o boot e libera memória." }
    $HtmlAlertas = if ($Alertas.Count -gt 0) { "<div class='alertas'><h3>Alertas</h3><ul>" + (($Alertas | ForEach-Object { "<li>$(Codificar-Html $_)</li>" }) -join "") + "</ul></div>" } else { "" }

    $HtmlDiscos = ""
    if ($script:SaudeDiscos.Count -gt 0) {
        $HtmlDiscos = "<h2>Saúde dos Discos</h2><table><thead><tr><th>Disco</th><th>Tipo</th><th>Saúde</th><th>Desgaste</th><th>Temperatura</th><th>Erros (leit./escr.)</th><th>Horas ligado</th></tr></thead><tbody>"
        foreach ($D in $script:SaudeDiscos) {
            $CorS = if ($D.Saude -eq "Healthy") { "#2E7D32" } else { "#C62828" }
            $Desg = if ($null -ne $D.Desgaste) { "$($D.Desgaste)%" } else { "n/d" }
            $Temp = if ($null -ne $D.Temperatura) { "$($D.Temperatura) °C" } else { "n/d" }
            $HtmlDiscos += "<tr><td>$(Codificar-Html $D.Nome) ($($D.TamanhoGB) GB)</td><td>$(Codificar-Html "$($D.Tipo) / $($D.Barramento)")</td><td style='color:$CorS;font-weight:bold'>$(Codificar-Html $D.Saude)</td><td>$Desg</td><td>$Temp</td><td>$(Codificar-Html "$($D.ErrosLeitura) / $($D.ErrosEscrita)")</td><td>$(Codificar-Html $D.HorasLigado)</td></tr>"
        }
        $HtmlDiscos += "</tbody></table>"
    }

    if ($Detalhado) {
        $Tarefas = "<h2>Detalhamento das Tarefas</h2><table><thead><tr><th style='width:9%'>Hora</th><th style='width:28%'>Tarefa</th><th style='width:11%'>Status</th><th>Detalhes</th></tr></thead><tbody>"
        foreach ($i in $script:RelatorioTarefas) {
            $Cor = switch ($i.Status) { "Sucesso" { "#2E7D32" } "Aviso" { "#E65100" } default { "#C62828" } }
            $Tarefas += "<tr><td>$(Codificar-Html $i.Hora)</td><td><strong>$(Codificar-Html $i.Tarefa)</strong></td><td style='color:$Cor;font-weight:bold'>$(Codificar-Html $i.Status)</td><td>$(Codificar-Html $i.Detalhe)</td></tr>"
        }
        $Tarefas += "</tbody></table><h2>Log Completo</h2><pre class='log'>$(Codificar-Html $script:LogBuffer.ToString())</pre>"
    } else {
        $Tarefas = "<h2>Resumo das Ações</h2><ul class='resumo'>"
        foreach ($i in $script:RelatorioTarefas) {
            $Icone = switch ($i.Status) { "Sucesso" { "✅" } "Aviso" { "⚠️" } default { "❌" } }
            $Tarefas += "<li>$Icone <strong>$(Codificar-Html $i.Tarefa)</strong> - $(Codificar-Html $i.Detalhe)</li>"
        }
        $Tarefas += "</ul>"
    }

    $Titulo = if ($script:ContadorFalhas -ge $script:LimiteFalhas) { "LAUDO DE EMERGÊNCIA (FALHAS)" } elseif ($Detalhado) { "LAUDO TÉCNICO DETALHADO" } else { "LAUDO DE MANUTENÇÃO" }
    $Modo = if ($script:ModoAutomatico) { "Automática (agendada)" } else { "Manual" }
    $Duracao = ((Get-Date) - $script:HoraInicio).ToString("hh\:mm\:ss")

    $HTML = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$Titulo</title>
<style>
    body { font-family: 'Segoe UI', sans-serif; background: #f4f6f9; padding: 20px; color: #222; }
    .container { max-width: 960px; background: #fff; margin: auto; padding: 30px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,.1); }
    .header { border-bottom: 3px solid #005A9E; padding-bottom: 12px; margin-bottom: 20px; }
    .header h1 { margin: 0; color: #005A9E; }
    .cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 20px; }
    .card { flex: 1 1 180px; background: #f8f9fa; border: 1px solid #e9ecef; padding: 14px; text-align: center; border-radius: 6px; }
    .card h3 { margin: 0 0 6px; font-size: 12px; color: #6c757d; text-transform: uppercase; }
    .card p { margin: 0; font-size: 17px; font-weight: bold; color: #005A9E; }
    .recomendacao { background: #f8f9fa; border-left: 5px solid $CorRec; padding: 12px 15px; margin-bottom: 20px; }
    .alertas { background: #fff4e5; border-left: 5px solid #E65100; padding: 10px 15px; margin-bottom: 20px; }
    .alertas h3 { margin: 4px 0; color: #E65100; }
    table { width: 100%; border-collapse: collapse; margin-bottom: 25px; }
    th, td { padding: 9px; text-align: left; border-bottom: 1px solid #e9ecef; font-size: 13px; vertical-align: top; }
    th { background: #005A9E; color: #fff; }
    ul.resumo { list-style: none; padding: 0; } ul.resumo li { padding: 8px 0; border-bottom: 1px solid #eee; }
    pre.log { background: #1e1e1e; color: #00ff00; padding: 15px; font-family: Consolas, monospace; font-size: 11px; max-height: 320px; overflow: auto; white-space: pre-wrap; }
</style>
</head>
<body>
<div class="container">
    <div class="header"><h1>$Titulo</h1><p>Manutenção PRO - $(Codificar-Html $env:COMPUTERNAME) - $(Get-Date -Format "dd/MM/yyyy HH:mm") - Execução: $Modo</p></div>
    <div class="cards">
        <div class="card"><h3>Duração</h3><p>$Duracao</p></div>
        <div class="card"><h3>Espaço livre $env:SystemDrive</h3><p>$($Antes.Espaco.LivreGB) → $($Depois.Espaco.LivreGB) GB</p></div>
        <div class="card"><h3>Espaço liberado</h3><p>$(Formatar-Tamanho $Liberado)</p></div>
        <div class="card"><h3>Tarefas</h3><p>✅ $Ok · ⚠️ $Av · ❌ $Er</p></div>
        <div class="card"><h3>Plano de energia</h3><p>$(Codificar-Html $Depois.PlanoEnergia)</p></div>
        <div class="card"><h3>Apps na inicialização</h3><p>$($Depois.Inicializacao)</p></div>
    </div>
    <div class="recomendacao"><h3>Diagnóstico e próximos passos</h3><p style="color:$CorRec;font-weight:bold;font-size:17px">$(Codificar-Html $Rec)</p></div>
    $HtmlAlertas
    $HtmlDiscos
    $Tarefas
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
    }
}

# ==========================================
# EXECUÇÃO DA MANUTENÇÃO (usada pela interface e pelo modo automático)
# ==========================================
Function Definir-Progresso([double]$Valor) {
    if (-not $script:ModoAutomatico) { $pbStatus.Value = $Valor; Atualizar-Tela }
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
    $script:Rodando = $true
    Limpar-Historico

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
        if ($T.Critica) { $script:BloqueioSeguranca = $true }
        $LivreAntes = Obter-BytesLivres
        $QtdAntes = $script:RelatorioTarefas.Count
        try { & $T.Acao $T.Nome }
        catch { Processar-Erro $T.Nome $_.Exception.Message }
        finally { $script:BloqueioSeguranca = $false }
        if ($script:RelatorioTarefas.Count -eq $QtdAntes -and $script:Cancelado) { Registrar-ResultadoTarefa $T.Nome "Cancelada" "Interrompida pelo cancelamento." }
        $Delta = (Obter-BytesLivres) - $LivreAntes
        if ($Delta -gt 50MB) { Escrever-Log " -> Espaço liberado nesta etapa: $(Formatar-Tamanho $Delta)" }
        Definir-Progresso (($Indice / $Selecionadas.Count) * 100)
    }

    Definir-Progresso 100
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

[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Manutenção Inteligente do Sistema PRO" Height="860" Width="840" WindowStartupLocation="CenterScreen" Background="#F0F0F0" ResizeMode="CanMinimize">
    <Grid Margin="15">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="410"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Column="0" Grid.Row="0" Margin="0,0,15,0">
            <StackPanel DockPanel.Dock="Top">
                <TextBlock Text="Perfil de manutenção:" FontWeight="Bold" FontSize="15"/>
                <ComboBox Name="cbPerfil" Margin="0,4,0,8" FontSize="13" Height="28">
                    <ComboBoxItem Content="⚡ Rápida (semanal)" Tag="Rapida"/>
                    <ComboBoxItem Content="🛠️ Completa (mensal)" Tag="Completa"/>
                    <ComboBoxItem Content="🚑 Reparo (quando há problemas)" Tag="Reparo"/>
                    <ComboBoxItem Content="✏️ Personalizada" Tag="Personalizada"/>
                </ComboBox>
                <TextBlock Text="Tarefas (passe o mouse para ver detalhes):" FontWeight="Bold" FontSize="13" Margin="0,0,0,4"/>
            </StackPanel>

            <StackPanel DockPanel.Dock="Bottom">
                <Separator Margin="0,6,0,6"/>
                <CheckBox Name="chkLaudo" Content="Gerar laudo HTML ao final" IsChecked="True" FontSize="13" Foreground="#005A9E" FontWeight="SemiBold"/>
                <StackPanel Orientation="Horizontal" Margin="25,4,0,0">
                    <RadioButton Name="rbResumido" Content="Resumido" IsChecked="True" FontSize="12" Margin="0,0,10,0"/>
                    <RadioButton Name="rbDetalhado" Content="Detalhado (com log)" FontSize="12"/>
                </StackPanel>
                <CheckBox Name="chkDesligar" Content="Desligar ao concluir (se não houver erros)" IsChecked="False" FontWeight="Bold" Foreground="DarkRed" Margin="0,6,0,0"/>
                <Separator Margin="0,8,0,8"/>
                <UniformGrid Columns="3">
                    <Button Name="btnAgendar" Content="📅 Agendar mensal" Height="30" Margin="0,0,4,0" Cursor="Hand" ToolTip="Cria (ou remove) a manutenção automática mensal do Windows"/>
                    <Button Name="btnInicializacao" Content="🚀 Inicialização" Height="30" Margin="0,0,4,0" Cursor="Hand" ToolTip="Escolha quais programas abrem junto com o Windows"/>
                    <Button Name="btnLaudos" Content="📂 Laudos e logs" Height="30" Cursor="Hand" ToolTip="Abre a pasta com o histórico de laudos e logs"/>
                </UniformGrid>
            </StackPanel>

            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Name="spTarefas"/>
            </ScrollViewer>
        </DockPanel>

        <GroupBox Header="Terminal de Execução" Grid.Column="1" Grid.Row="0" FontWeight="Bold">
            <TextBox Name="txtLog" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Consolas" Background="#1E1E1E" Foreground="#00FF00" FontSize="12" Margin="5" FontWeight="Normal"/>
        </GroupBox>

        <StackPanel Grid.Column="0" Grid.ColumnSpan="2" Grid.Row="1" Margin="0,15,0,0">
            <DockPanel Margin="0,0,0,5">
                <TextBlock Name="lblEspaco" Text="Espaço livre: calculando..." FontWeight="Bold" FontSize="13" Foreground="#005A9E" DockPanel.Dock="Left"/>
                <TextBlock Name="lblTempo" Text="Tempo estimado: ~ 0 min" FontWeight="Bold" FontSize="13" Foreground="#D2691E" HorizontalAlignment="Right" DockPanel.Dock="Right"/>
            </DockPanel>
            <ProgressBar Name="pbStatus" Height="15" Margin="0,0,0,10" Minimum="0" Maximum="100"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="110"/>
                </Grid.ColumnDefinitions>
                <Button Name="btnIniciar" Grid.Column="0" Content="INICIAR MANUTENÇÃO" Height="45" FontSize="15" FontWeight="Bold" Background="#005A9E" Cursor="Hand" Foreground="White"/>
                <Button Name="btnPausar" Grid.Column="2" Content="PAUSAR" Height="45" FontSize="14" FontWeight="Bold" Background="#FFD600" Cursor="Hand" Foreground="Black"/>
                <Button Name="btnCancelar" Grid.Column="4" Content="CANCELAR" Height="45" FontSize="14" FontWeight="Bold" Background="#CC0000" Cursor="Hand" Foreground="White"/>
            </Grid>
        </StackPanel>
    </Grid>
</Window>
"@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $XAML))
foreach ($n in @("txtLog", "pbStatus", "btnIniciar", "btnPausar", "btnCancelar", "lblEspaco", "lblTempo", "cbPerfil", "spTarefas",
                 "chkLaudo", "rbResumido", "rbDetalhado", "chkDesligar", "btnAgendar", "btnInicializacao", "btnLaudos")) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

Function Atualizar-Espaco {
    $E = Obter-EspacoSistema
    $lblEspaco.Text = "Espaço livre ${env:SystemDrive} $($E.LivreGB) GB de $($E.TotalGB) GB ($($E.Percentual)%)"
}

Function Atualizar-TempoEstimado {
    $Total = ($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Minutos } | Measure-Object -Sum).Sum
    if (-not $Total) { $Total = 0 }
    $lblTempo.Text = "Tempo estimado: ~ $Total min"
}

Function Aplicar-Perfil([string]$Id) {
    foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = ($T.Perfis -contains $Id) }
    Atualizar-TempoEstimado
}

Function Selecionar-Perfil([string]$Id) {
    $script:IgnorarTrocaPerfil = $true
    foreach ($Item in $cbPerfil.Items) { if ($Item.Tag -eq $Id) { $cbPerfil.SelectedItem = $Item } }
    $script:IgnorarTrocaPerfil = $false
}

Function Salvar-Config {
    $Cfg = [PSCustomObject]@{
        Perfil = $cbPerfil.SelectedItem.Tag
        Marcadas = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked } | ForEach-Object { $_.Id })
        Detalhado = [bool]$rbDetalhado.IsChecked
        Apps = @($script:AppsSelecionadosParaRemocao)
    }
    try { $Cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 } catch {}
}

# ---------- Janela: seleção de apps para remover (Debloat) ----------
Function Abrir-SeletorDebloat {
    $DebloatXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Remover Aplicativos (Debloat)" Height="650" Width="540" WindowStartupLocation="CenterScreen" Background="#F4F6F9">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="Quais aplicativos você deseja remover?" FontWeight="Bold" FontSize="16" Foreground="#005A9E"/>
            <Border Background="#E8F4F8" BorderBrush="#005A9E" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,8,0,0">
                <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#003366"
                    Text="Os apps da Microsoft (verde) podem ser reinstalados de graça pela Microsoft Store. Apps de fabricante e utilitários (laranja) podem NÃO estar disponíveis para reinstalar: remova só se tiver certeza. Componentes do sistema, codecs e bibliotecas não aparecem nesta lista."/>
            </Border>
        </StackPanel>
        <StackPanel Grid.Row="1" Margin="0,5,0,10">
            <UniformGrid Columns="3">
                <Button Name="btnPresetRecomendado" Content="✅ Recomendados" ToolTip="Marca apenas os apps verdes" Background="#E8F5E9" BorderBrush="#2E7D32" Foreground="#2E7D32" FontWeight="Bold" Height="30" Margin="0,0,5,0" Cursor="Hand"/>
                <Button Name="btnPresetProfundo" Content="🔥 Marcar todos" ToolTip="Marca verdes e laranjas (pede confirmação)" Background="#FFF3E0" BorderBrush="#E65100" Foreground="#E65100" FontWeight="Bold" Height="30" Margin="0,0,5,0" Cursor="Hand"/>
                <Button Name="btnPresetLimpar" Content="❌ Desmarcar todos" Background="#F5F5F5" BorderBrush="#9E9E9E" Foreground="#616161" FontWeight="Bold" Height="30" Cursor="Hand"/>
            </UniformGrid>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <TextBlock Text="Legenda: " FontWeight="Bold" FontSize="11"/>
                <TextBlock Text="🟩 Seguro (reinstalável)  " Foreground="#2E7D32" FontSize="11" FontWeight="SemiBold"/>
                <TextBlock Text="🟧 Atenção (fabricante/utilitário)" Foreground="#D2691E" FontSize="11" FontWeight="SemiBold"/>
            </StackPanel>
        </StackPanel>
        <TextBlock Name="lblStatusDebloat" Grid.Row="2" Text="🔍 Procurando aplicativos instalados..." Foreground="Blue" Margin="0,15,0,0" FontStyle="Italic"/>
        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Background="White" BorderBrush="#CCC" BorderThickness="1" Margin="0,5,0,15">
            <StackPanel Name="spAppsList" Margin="10"/>
        </ScrollViewer>
        <Button Name="btnDebloatSalvar" Grid.Row="3" Content="Confirmar seleção" Height="45" FontSize="14" Background="#005A9E" Foreground="White" FontWeight="Bold" Cursor="Hand"/>
    </Grid>
</Window>
"@
    $script:DWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$DebloatXAML)))
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
        foreach ($App in $Apps) {
            $Exibir = $App.Name; $Risco = "Laranja"
            if ($Dicionario.ContainsKey($App.Name)) { $Exibir = $Dicionario[$App.Name][0]; $Risco = $Dicionario[$App.Name][1] }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $Exibir
            $cb.ToolTip = "Nome técnico: $($App.Name)`nFabricante: $($App.Publisher)"
            $cb.Tag = $App.Name
            $cb.Uid = $Risco
            $cb.Foreground = $(if ($Risco -eq "Verde") { "#2E7D32" } else { "#D2691E" })
            $cb.FontWeight = "SemiBold"; $cb.Margin = "0,5,0,5"; $cb.FontSize = 13
            if ($script:AppsSelecionadosParaRemocao -contains $App.Name) { $cb.IsChecked = $true }
            $Painel.Children.Add($cb) | Out-Null
        }
        $script:DWindow.Cursor = [System.Windows.Input.Cursors]::Arrow
    })

    $script:DWindow.FindName("btnPresetRecomendado").Add_Click({
        foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = ($c.Uid -eq "Verde") }
    })
    $script:DWindow.FindName("btnPresetProfundo").Add_Click({
        $r = Mostrar-Mensagem "Isso marca também apps de fabricante e utilitários (laranja), que podem não ser reinstaláveis. Continuar?" "YesNo" "Warning"
        if ($r -eq "Yes") { foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = $true } }
    })
    $script:DWindow.FindName("btnPresetLimpar").Add_Click({
        foreach ($c in $script:DWindow.FindName("spAppsList").Children) { $c.IsChecked = $false }
    })
    $script:DWindow.FindName("btnDebloatSalvar").Add_Click({
        $script:AppsSelecionadosParaRemocao = @($script:DWindow.FindName("spAppsList").Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        $script:DWindow.Close()
    })
    $script:DWindow.ShowDialog() | Out-Null
    $TDebloat = $script:Tarefas | Where-Object { $_.Id -eq "Debloat" }
    if ($script:AppsSelecionadosParaRemocao.Count -gt 0) { $TDebloat.Checkbox.IsChecked = $true; Selecionar-Perfil "Personalizada"; Atualizar-TempoEstimado }
    $TDebloat.Botao.Content = "⚙️ Selecionar Apps ($($script:AppsSelecionadosParaRemocao.Count))"
}

# ---------- Janela: programas da inicialização ----------
Function Abrir-GerenciadorInicializacao {
    $IniXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Programas da Inicialização" Height="600" Width="620" WindowStartupLocation="CenterScreen" Background="#F4F6F9">
    <Grid Margin="15">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#E8F4F8" BorderBrush="#005A9E" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,10">
            <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#003366"
                Text="Desmarque os programas que não precisam abrir junto com o Windows: o boot fica mais rápido e sobra memória. Eles continuam instalados e podem ser reativados aqui ou no Gerenciador de Tarefas. Não desative antivírus, drivers (áudio, touchpad, vídeo) nem apps de sincronização que você usa. Vale a partir do próximo login."/>
        </Border>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Background="White" BorderBrush="#CCC" BorderThickness="1">
            <StackPanel Name="spItens" Margin="10"/>
        </ScrollViewer>
        <Button Name="btnSalvarIni" Grid.Row="2" Content="Aplicar alterações" Height="42" FontSize="14" Background="#005A9E" Foreground="White" FontWeight="Bold" Margin="0,12,0,0" Cursor="Hand"/>
    </Grid>
</Window>
"@
    $script:IWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$IniXAML)))
    $Painel = $script:IWindow.FindName("spItens")
    foreach ($Item in (Obter-ItensInicializacao | Sort-Object Nome)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($Item.Nome)   ($($Item.Origem))"
        $cb.ToolTip = $Item.Comando
        $cb.IsChecked = $Item.Ativo
        $cb.Tag = $Item
        $cb.Margin = "0,4,0,4"; $cb.FontSize = 13
        $Painel.Children.Add($cb) | Out-Null
    }
    $script:IWindow.FindName("btnSalvarIni").Add_Click({
        $Mudou = 0
        foreach ($c in $script:IWindow.FindName("spItens").Children) {
            if ([bool]$c.IsChecked -ne $c.Tag.Ativo) {
                try { Definir-EstadoAprovado $c.Tag.Aprov $c.Tag.Nome ([bool]$c.IsChecked); $Mudou++ } catch {}
            }
        }
        Mostrar-Mensagem "$Mudou alteração(ões) aplicada(s). Valem a partir do próximo login." | Out-Null
        $script:IWindow.Close()
    })
    $script:IWindow.ShowDialog() | Out-Null
}

# ---------- Agendamento mensal ----------
Function Alternar-Agendamento {
    $Existente = Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue
    if ($Existente) {
        $Prox = (Get-ScheduledTaskInfo -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue).NextRunTime
        $r = Mostrar-Mensagem "A manutenção automática já está agendada (próxima execução: $Prox).`n`nDeseja REMOVER o agendamento?" "YesNo" "Question"
        if ($r -eq "Yes") { Unregister-ScheduledTask -TaskName $NomeTarefaAgendada -Confirm:$false; Mostrar-Mensagem "Agendamento removido." | Out-Null }
        return
    }
    $r = Mostrar-Mensagem ("Agendar a manutenção automática?`n`n- Perfil Completa (sem Debloat, Downloads e reparo de rede)`n- A cada 4 semanas, domingo às 12:00`n- Se o PC estiver desligado, roda na próxima vez que for ligado`n- Só roda na tomada; nunca reinicia sozinho`n- Laudos ficam em $DirLaudos") "YesNo" "Question"
    if ($r -ne "Yes") { return }
    try {
        if ($script:IsExe) {
            $Destino = Join-Path $DataDir "ManutencaoPro.exe"
            Copy-Item -Path $script:ProcessoExe -Destination $Destino -Force
            $Acao = New-ScheduledTaskAction -Execute $Destino -Argument "-Automatico -Perfil Completa"
        } else {
            $Destino = Join-Path $DataDir "ManutencaoGUI.ps1"
            Copy-Item -Path $script:CaminhoScript -Destination $Destino -Force
            $Acao = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Destino`" -Automatico -Perfil Completa"
        }
        $Gatilho = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At "12:00"
        $Config = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $NomeTarefaAgendada -Action $Acao -Trigger $Gatilho -Settings $Config -Principal $Principal `
            -Description "Manutenção automática do Manutenção PRO (limpeza, reparo, atualizações e saúde do disco)." | Out-Null
        Mostrar-Mensagem "Manutenção mensal agendada com sucesso.`n`nObs.: se você atualizar o programa, agende de novo para usar a versão nova." | Out-Null
    } catch { Mostrar-Mensagem "Não foi possível agendar: $($_.Exception.Message)" "OK" "Error" | Out-Null }
}

# ---------- Montagem da lista de tarefas ----------
foreach ($T in $script:Tarefas) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $T.Nome
    $cb.ToolTip = $T.Dica
    $cb.FontSize = 13
    $cb.Margin = "0,3"
    $cb.VerticalAlignment = "Center"
    if ($T.Cor) { $cb.Foreground = $T.Cor; $cb.FontWeight = "SemiBold" }
    $cb.Add_Click({ Selecionar-Perfil "Personalizada"; Atualizar-TempoEstimado; $btnIniciar.Background = "#005A9E"; $btnIniciar.Content = "INICIAR MANUTENÇÃO" })
    $T.Checkbox = $cb
    if ($T.Id -eq "Debloat") {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = "Horizontal"
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = "⚙️ Selecionar Apps (0)"; $btn.Margin = "8,0,0,0"; $btn.Padding = "6,0"; $btn.FontSize = 11; $btn.Cursor = "Hand"
        $btn.Add_Click({ Abrir-SeletorDebloat })
        $T.Botao = $btn
        $sp.Children.Add($cb) | Out-Null
        $sp.Children.Add($btn) | Out-Null
        $spTarefas.Children.Add($sp) | Out-Null
    } else {
        $spTarefas.Children.Add($cb) | Out-Null
    }
}

$cbPerfil.Add_SelectionChanged({
    if ($script:IgnorarTrocaPerfil) { return }
    $Id = $cbPerfil.SelectedItem.Tag
    if ($Id -ne "Personalizada") { Aplicar-Perfil $Id }
})

# Carrega a última configuração usada (ou o perfil Completa na primeira vez)
$script:IgnorarTrocaPerfil = $false
$CfgCarregada = $false
if (Test-Path $ConfigFile) {
    try {
        $Cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($T in $script:Tarefas) { $T.Checkbox.IsChecked = (@($Cfg.Marcadas) -contains $T.Id) }
        Selecionar-Perfil $Cfg.Perfil
        $rbDetalhado.IsChecked = [bool]$Cfg.Detalhado
        $rbResumido.IsChecked = -not [bool]$Cfg.Detalhado
        $script:AppsSelecionadosParaRemocao = @($Cfg.Apps | Where-Object { $_ })
        ($script:Tarefas | Where-Object { $_.Id -eq "Debloat" }).Botao.Content = "⚙️ Selecionar Apps ($($script:AppsSelecionadosParaRemocao.Count))"
        $CfgCarregada = $true
    } catch {}
}
if (-not $CfgCarregada) { Selecionar-Perfil "Completa"; Aplicar-Perfil "Completa" }
Atualizar-TempoEstimado
Atualizar-Espaco

$txtLog.Text = "Pronto. Escolha um perfil ou marque as tarefas e clique em INICIAR.`nLaudos e logs: $DataDir"
if (Testar-ReinicioPendente) { $txtLog.AppendText("`n[AVISO] Há um reinício pendente. Recomenda-se reiniciar antes da manutenção.") }
if (Get-ScheduledTask -TaskName $NomeTarefaAgendada -ErrorAction SilentlyContinue) { $txtLog.AppendText("`nManutenção automática mensal: AGENDADA.") }

$btnAgendar.Add_Click({ Alternar-Agendamento })
$btnInicializacao.Add_Click({ Abrir-GerenciadorInicializacao })
$btnLaudos.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$DataDir`"" })

$btnPausar.Add_Click({
    if (-not $script:Rodando) { return }
    if ($script:BloqueioSeguranca) { Escrever-Log "AÇÃO BLOQUEADA: tarefa crítica em andamento; interromper agora poderia danificar o sistema." "Aviso"; return }
    if ($script:Pausado) { $script:Pausado = $false; $btnPausar.Content = "PAUSAR"; Escrever-Log ">>> Execução retomada." }
    else { $script:Pausado = $true; $btnPausar.Content = "RETOMAR"; Escrever-Log ">>> Pausa solicitada (vale ao fim da etapa atual)." }
})

$btnCancelar.Add_Click({
    if (-not $script:Rodando) { return }
    if ($script:BloqueioSeguranca) { Escrever-Log "AÇÃO BLOQUEADA: tarefa crítica em andamento; interromper agora poderia danificar o sistema." "Aviso"; return }
    $script:Cancelado = $true; $script:Pausado = $false
    Escrever-Log ">>> CANCELAMENTO SOLICITADO PELO USUÁRIO!" "Aviso"
})

$btnIniciar.Add_Click({
    if ($script:Rodando) { return }
    $Sel = @($script:Tarefas | Where-Object { $_.Checkbox.IsChecked })
    if ($Sel.Count -eq 0) { Mostrar-Mensagem "Marque ao menos uma tarefa." | Out-Null; return }

    if ($Sel.Id -contains "Downloads") {
        $Prev = Obter-PreviaDownloads
        if ($Prev.Quantidade -eq 0) {
            Escrever-Log "Downloads: nenhum arquivo com mais de $DiasDownloads dias; etapa ignorada."
            $Sel = @($Sel | Where-Object { $_.Id -ne "Downloads" })
        } else {
            $r = Mostrar-Mensagem ("$($Prev.Quantidade) arquivo(s) ($(Formatar-Tamanho $Prev.Bytes)) com mais de $DiasDownloads dias em:`n$($Prev.Pasta)`n`nEles serão movidos para a Lixeira. Continuar?") "YesNo" "Warning"
            if ($r -ne "Yes") { $Sel = @($Sel | Where-Object { $_.Id -ne "Downloads" }); ($script:Tarefas | Where-Object { $_.Id -eq "Downloads" }).Checkbox.IsChecked = $false }
        }
    }
    if ($Sel.Count -eq 0) { return }
    Salvar-Config

    $btnIniciar.IsEnabled = $false
    $spTarefas.IsEnabled = $false; $cbPerfil.IsEnabled = $false
    $btnIniciar.Background = "#005A9E"; $btnIniciar.Content = "MANUTENÇÃO EM ANDAMENTO..."
    $txtLog.Text = ""

    Executar-Manutencao -Selecionadas $Sel -Detalhado ([bool]$rbDetalhado.IsChecked) -GerarLaudo ([bool]$chkLaudo.IsChecked) -AbrirLaudo $true

    $btnPausar.Content = "PAUSAR"
    Atualizar-Espaco
    if ($script:ContadorFalhas -ge $script:LimiteFalhas) {
        $btnIniciar.Content = "OPERAÇÃO ABORTADA (FALHAS)"; $btnIniciar.Background = "#B30000"
        [System.Console]::Beep(1000, 1000)
    } elseif ($script:Cancelado) {
        $btnIniciar.Content = "OPERAÇÃO CANCELADA"; $btnIniciar.Background = "#D13438"
    } elseif ($script:ErrosEncontrados) {
        $btnIniciar.Content = "CONCLUÍDO COM ERROS"; $btnIniciar.Background = "#E65100"
    } else {
        $btnIniciar.Content = $(if ($script:AvisosEncontrados) { "CONCLUÍDO COM AVISOS" } else { "CONCLUÍDO COM SUCESSO!" })
        $btnIniciar.Background = $(if ($script:AvisosEncontrados) { "#E65100" } else { "#008000" })
        if ($chkDesligar.IsChecked) {
            $btnIniciar.Content = "DESLIGANDO EM 60 s... (cancelar: shutdown /a)"
            Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/s /t 60" -WindowStyle Hidden
        }
    }
    if ($script:ReinicioNecessario -and -not ($chkDesligar.IsChecked -and -not $script:ErrosEncontrados -and -not $script:Cancelado)) {
        $r = Mostrar-Mensagem "É necessário reiniciar para concluir reparos/atualizações. Reiniciar agora? (salve seus trabalhos antes)" "YesNo" "Question"
        if ($r -eq "Yes") { Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /t 30" -WindowStyle Hidden }
    }
    $spTarefas.IsEnabled = $true; $cbPerfil.IsEnabled = $true
    $btnIniciar.IsEnabled = $true
})

$Window.ShowDialog() | Out-Null
