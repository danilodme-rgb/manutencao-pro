<#
  Monitora o uso de memória ao longo do dia e grava um CSV. Somente leitura, não precisa de Administrador.
    (padrão)       coleta uma amostra a cada -IntervaloSeg até ser interrompido (Ctrl+C) ou até -Horas
    -Resumo        não coleta; lê o CSV mais recente e imprime o resumo (pico, média, horários críticos)
    -Arquivo       CSV específico para o -Resumo (padrão: o mais recente na Área de Trabalho)
  CSV salvo na Área de Trabalho: MonitorMemoria_<data>.csv
  Dica: desative suspensão/hibernação durante a coleta (o notebook precisa ficar ligado).
#>
param(
    [int]$IntervaloSeg = 60,
    [double]$Horas = 12,
    [switch]$Resumo,
    [string]$Arquivo
)

$Desktop = [Environment]::GetFolderPath('Desktop')

if ($Resumo) {
    if (-not $Arquivo) {
        $Arquivo = Get-ChildItem $Desktop -Filter 'MonitorMemoria_*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $Arquivo -or -not (Test-Path $Arquivo)) { Write-Host "Nenhum CSV encontrado." -ForegroundColor Red; exit 1 }
    $d = Import-Csv $Arquivo
    if (-not $d) { Write-Host "CSV vazio." -ForegroundColor Red; exit 1 }
    $n = @($d).Count
    $ini = [datetime]$d[0].Hora; $fim = [datetime]$d[-1].Hora
    $totalGB = [double]$d[0].TotalGB
    function Num($v) { [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) }
    $usada = $d | ForEach-Object { Num $_.UsadaGB }
    $commit = $d | ForEach-Object { Num $_.CommitGB }
    $pf = $d | ForEach-Object { Num $_.PagefileMB }
    $pgs = $d | ForEach-Object { Num $_.PaginasPorSeg }
    $cpu = $d | ForEach-Object { Num $_.CPUPct }
    $pico = $d | Sort-Object { Num $_.CommitGB } -Descending | Select-Object -First 1

    Write-Host ("Arquivo: $Arquivo")
    Write-Host ("Período: {0:dd/MM HH:mm} a {1:dd/MM HH:mm}  ({2} amostras)" -f $ini, $fim, $n)
    Write-Host ("RAM total: {0:N1} GB" -f $totalGB)
    Write-Host ("RAM em uso   - média {0:N1} GB | pico {1:N1} GB ({2:N0}%)" -f ($usada | Measure-Object -Average).Average, ($usada | Measure-Object -Maximum).Maximum, (($usada | Measure-Object -Maximum).Maximum / $totalGB * 100))
    Write-Host ("Commit       - média {0:N1} GB | pico {1:N1} GB às {2:HH:mm}" -f ($commit | Measure-Object -Average).Average, ($commit | Measure-Object -Maximum).Maximum, [datetime]$pico.Hora)
    Write-Host ("Pagefile     - média {0:N0} MB | pico {1:N0} MB" -f ($pf | Measure-Object -Average).Average, ($pf | Measure-Object -Maximum).Maximum)
    Write-Host ("Páginas/seg  - média {0:N1} | pico {1:N0}  (leitura de disco por falta de RAM)" -f ($pgs | Measure-Object -Average).Average, ($pgs | Measure-Object -Maximum).Maximum)
    Write-Host ("CPU          - média {0:N0}% | pico {1:N0}%" -f ($cpu | Measure-Object -Average).Average, ($cpu | Measure-Object -Maximum).Maximum)

    $acima85 = @($usada | Where-Object { $_ / $totalGB -gt 0.85 }).Count
    $acima95 = @($usada | Where-Object { $_ / $totalGB -gt 0.95 }).Count
    $comPag = @($pgs | Where-Object { $_ -gt 100 }).Count
    Write-Host ("Amostras com RAM > 85%: {0} ({1:N0}%) | > 95%: {2} | com paginação > 100/s: {3}" -f $acima85, ($acima85 / $n * 100), $acima95, $comPag)

    Write-Host "`nMaiores consumidores no momento de pico de commit:"
    Write-Host ("  " + $pico.Top3)
    Write-Host "`nProcessos mais frequentes no top 3 ao longo do dia:"
    $d | ForEach-Object { $_.Top3 -split ' \| ' } | ForEach-Object { ($_ -replace ' \(.*$', '') } |
        Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 6 |
        ForEach-Object { Write-Host ("  {0,-28} {1} amostras" -f $_.Name, $_.Count) }

    Write-Host "`nLeitura:"
    if ($acima95 -gt 0 -or $comPag -gt ($n * 0.05)) { Write-Host "  Houve pressão real de memória: 32 GB tendem a trazer ganho perceptível." -ForegroundColor Yellow }
    elseif ($acima85 -gt ($n * 0.10)) { Write-Host "  Uso alto com frequência, mas sem paginação relevante: 32 GB seriam conforto, não necessidade." -ForegroundColor Yellow }
    else { Write-Host "  RAM com folga no período: 16 GB suficientes." -ForegroundColor Green }
    exit 0
}

$Csv = Join-Path $Desktop ("MonitorMemoria_{0:yyyyMMdd_HHmm}.csv" -f (Get-Date))
$Fim = (Get-Date).AddHours($Horas)
$inv = [Globalization.CultureInfo]::InvariantCulture
Write-Host "Coletando a cada $IntervaloSeg s até $($Fim.ToString('dd/MM HH:mm')) (Ctrl+C para parar). Saída: $Csv"
'Hora,TotalGB,UsadaGB,CommitGB,PagefileMB,PaginasPorSeg,CPUPct,Top3' | Set-Content $Csv -Encoding utf8

while ((Get-Date) -lt $Fim) {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        $pf = (Get-CimInstance Win32_PageFileUsage | Measure-Object CurrentUsage -Sum).Sum
        $total = $os.TotalVisibleMemorySize / 1MB
        $usada = $total - $os.FreePhysicalMemory / 1MB
        $top = Get-Process | Group-Object ProcessName |
            ForEach-Object { [pscustomobject]@{ N = $_.Name; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) } } |
            Sort-Object MB -Descending | Select-Object -First 3
        $top3 = ($top | ForEach-Object { "{0} ({1} MB)" -f $_.N, $_.MB }) -join ' | '
        $linha = '{0:yyyy-MM-dd HH:mm:ss},{1},{2},{3},{4},{5},{6},"{7}"' -f (Get-Date),
            $total.ToString('F2', $inv), $usada.ToString('F2', $inv), ($mem.CommittedBytes / 1GB).ToString('F2', $inv),
            $pf, $mem.PagesInputPersec, $cpu, $top3
        Add-Content $Csv $linha -Encoding utf8
    } catch { }
    Start-Sleep -Seconds $IntervaloSeg
}
Write-Host "Coleta concluída. Para o resumo: .\MonitorarMemoria.ps1 -Resumo"
