<#
  Mostra o resultado do último teste de memória e as telas azuis recentes.
  Rode DEPOIS de cada teste, informando qual configuração de pentes foi testada:
    .\VerificarTesteMemoria.ps1 -Config "So Kingston no slot 1"
  Somente leitura. Cada execução é anexada ao histórico HistoricoTestesRAM.csv (Área de Trabalho)
  para comparar as configurações. Execute como Administrador para também listar os dumps.
#>
param([string]$Config = "(nao informada)", [int]$Dias = 3)

$Desktop = [Environment]::GetFolderPath('Desktop')
$Historico = Join-Path $Desktop 'HistoricoTestesRAM.csv'
$Agora = Get-Date
$Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$Desde = $Agora.AddDays(-$Dias)

function Evt($Filtro) { @(Get-WinEvent -FilterHashtable $Filtro -ErrorAction SilentlyContinue) }

Write-Host "=== Configuração: $Config ===" -ForegroundColor Cyan
Write-Host ("Último boot: {0:dd/MM/yyyy HH:mm}" -f $Boot)

# ---------- Pentes instalados ----------
Write-Host "`n--- Pentes de RAM detectados ---"
$Pentes = @(Get-CimInstance Win32_PhysicalMemory)
foreach ($P in $Pentes) {
    Write-Host ("{0}  {1} GB  {2} MHz  {3}" -f $P.DeviceLocator, ($P.Capacity / 1GB), $P.ConfiguredClockSpeed, $P.PartNumber)
}
$Resumo = "$($Pentes.Count) pente(s): " + (($Pentes | ForEach-Object { "$([int]($_.Capacity / 1GB))GB" }) -join ' + ')
Write-Host "Total: $Resumo"

# ---------- Teste de memória ----------
Write-Host "`n--- Teste de memória do Windows ---"
$Resultados = Evt @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } | Sort-Object TimeCreated -Descending
$Agend = Evt @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Schedule' } | Sort-Object TimeCreated -Descending
$UltRes = $Resultados | Where-Object { $_.Id -in 1101, 1102, 1103 } | Select-Object -First 1
$UltAgend = $Agend | Where-Object { $_.Id -in 1001, 1002 } | Select-Object -First 1

$Teste = 'Nenhum teste registrado'
if ($UltAgend -and (-not $UltRes -or $UltAgend.TimeCreated -gt $UltRes.TimeCreated)) {
    $Teste = 'SEM RESULTADO'
    Write-Host ("Teste agendado em {0:dd/MM HH:mm}, mas não há resultado depois." -f $UltAgend.TimeCreated) -ForegroundColor Yellow
    Write-Host "Provável: foi interrompido/desligado à força, travou ou ainda não rodou. Isso NÃO é aprovação da RAM." -ForegroundColor Yellow
    if ($UltRes) { Write-Host ("Resultado anterior: {0:dd/MM HH:mm} (Id {1})" -f $UltRes.TimeCreated, $UltRes.Id) }
} elseif ($UltRes) {
    switch ($UltRes.Id) {
        1101 { $Teste = 'APROVADO (sem erros)'; $Cor = 'Green' }
        1102 { $Teste = 'ERROS DETECTADOS'; $Cor = 'Red' }
        1103 { $Teste = 'CANCELADO'; $Cor = 'Yellow' }
    }
    Write-Host ("{0:dd/MM HH:mm}  {1}" -f $UltRes.TimeCreated, $Teste) -ForegroundColor $Cor
    if ($UltRes.Id -eq 1102) { Write-Host (($UltRes.Message -split "`n")[0]) -ForegroundColor Red }
    if ($UltRes.Id -eq 1101) { Write-Host "Teste padrão sem erros não descarta a RAM: bit flips esporádicos podem passar." }
} else { Write-Host $Teste }

# ---------- Telas azuis e desligamentos ----------
Write-Host "`n--- Telas azuis e desligamentos inesperados (últimos $Dias dias) ---"
$Bug = Evt @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $Desde }
$Kp = Evt @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Desde }
$NBug = $Bug.Count; $NKp = $Kp.Count
foreach ($B in $Bug) {
    $M = [regex]::Match($B.Message, '0x[0-9a-fA-F]{8}')
    Write-Host ("{0:dd/MM HH:mm}  tela azul {1}" -f $B.TimeCreated, $M.Value) -ForegroundColor Red
}
foreach ($K in $Kp) { Write-Host ("{0:dd/MM HH:mm}  reinício sem desligar corretamente (Kernel-Power 41)" -f $K.TimeCreated) -ForegroundColor Yellow }
if (-not $Bug -and -not $Kp) { Write-Host "Nenhuma." -ForegroundColor Green }

$Whea = Evt @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Desde }
Write-Host ("Erros de hardware (WHEA): {0}" -f $Whea.Count)
foreach ($W in ($Whea | Select-Object -First 5)) { Write-Host ("  {0:dd/MM HH:mm}  Id {1}" -f $W.TimeCreated, $W.Id) -ForegroundColor Red }

# ---------- Dumps ----------
$Dumps = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Desde })
Write-Host ("Dumps recentes: {0}" -f $Dumps.Count)
if ($Dumps.Count -gt 0) { Write-Host "  Rode AnalisarDumps.ps1 (como Administrador) para ver se é bit flip." }

# ---------- Veredito desta configuração ----------
Write-Host "`n--- Leitura ---"
if ($Teste -eq 'ERROS DETECTADOS' -or $Whea.Count -gt 0) {
    $Leitura = 'RUIM: erro de memória/hardware nesta configuração'
} elseif ($NBug -gt 0 -or $NKp -gt 0) {
    $Leitura = 'SUSPEITA: houve crash nesta janela'
} elseif ($Teste -eq 'SEM RESULTADO') {
    $Leitura = 'INCONCLUSIVO: teste não terminou'
} elseif ($Teste -like 'APROVADO*') {
    $Leitura = 'OK ate agora (sem erros e sem crashes)'
} else { $Leitura = 'SEM DADOS' }
Write-Host $Leitura

# ---------- Histórico ----------
[pscustomobject]@{
    Data = $Agora.ToString('yyyy-MM-dd HH:mm'); Config = $Config; Pentes = $Resumo
    Teste = $Teste; TelasAzuis = $NBug; KernelPower41 = $NKp; WHEA = $Whea.Count; Leitura = $Leitura
} | Export-Csv $Historico -Append -NoTypeInformation -Encoding UTF8
Write-Host "`nHistórico: $Historico" -ForegroundColor DarkGray
