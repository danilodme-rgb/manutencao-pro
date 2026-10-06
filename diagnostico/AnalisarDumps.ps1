<#
  Analisa os dumps de tela azul (C:\Windows\Minidump e MEMORY.DMP).
  Execute como Administrador. Somente leitura: não altera o sistema.
    -SemSimbolos  não baixa símbolos da Microsoft (análise do cdb fica menos precisa)
  Relatório salvo na Área de Trabalho: RelatorioDumps_<data>.txt
#>
param([switch]$SemSimbolos)

$Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Admin) { Write-Host "Abra o PowerShell como Administrador e execute de novo." -ForegroundColor Red; exit 1 }

$Relatorio = Join-Path ([Environment]::GetFolderPath('Desktop')) ("RelatorioDumps_{0:yyyyMMdd_HHmm}.txt" -f (Get-Date))
$Saida = [System.Collections.Generic.List[string]]::new()
function Log([string]$T) { $Saida.Add($T); Write-Host $T }

# Códigos mais comuns e o que costumam indicar
$Significado = @{
    0x0A  = 'IRQL_NOT_LESS_OR_EQUAL: driver ou RAM'
    0x1A  = 'MEMORY_MANAGEMENT: forte indício de RAM defeituosa'
    0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED: driver'
    0x3B  = 'SYSTEM_SERVICE_EXCEPTION: driver'
    0x4E  = 'PFN_LIST_CORRUPT: RAM ou driver'
    0x50  = 'PAGE_FAULT_IN_NONPAGED_AREA: RAM ou driver'
    0x7A  = 'KERNEL_DATA_INPAGE_ERROR: disco/cabo ou RAM'
    0x7E  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: driver'
    0x9F  = 'DRIVER_POWER_STATE_FAILURE: driver/energia'
    0xC2  = 'BAD_POOL_CALLER: driver'
    0xD1  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver'
    0xEF  = 'CRITICAL_PROCESS_DIED'
    0xF7  = 'DRIVER_OVERRAN_STACK_BUFFER: driver, mas também corrupção de memória'
    0x101 = 'CLOCK_WATCHDOG_TIMEOUT: CPU/BIOS'
    0x109 = 'CRITICAL_STRUCTURE_CORRUPTION: RAM ou driver'
    0x124 = 'WHEA_UNCORRECTABLE_ERROR: hardware (CPU/RAM)'
    0x139 = 'KERNEL_SECURITY_CHECK_FAILURE: driver ou RAM'
    0x13A = 'KERNEL_MODE_HEAP_CORRUPTION: corrupção de memória (RAM ou driver)'
    0x1C6 = 'FAST_ERASE_OR_CORRUPTION'
}

$Dumps = @(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue)
if (Test-Path 'C:\Windows\MEMORY.DMP') { $Dumps += Get-Item 'C:\Windows\MEMORY.DMP' }
if (-not $Dumps) { Log "Nenhum dump encontrado."; $Saida | Set-Content $Relatorio -Encoding UTF8; exit 0 }
$Dumps = $Dumps | Sort-Object LastWriteTime -Descending

# ---------- 1) Cabeçalho do dump (não depende de ferramentas externas) ----------
Log "=== 1) TELAS AZUIS (cabeçalho dos dumps) ==="
$Contagem = @{}
foreach ($D in $Dumps) {
    try {
        $FS = [IO.File]::Open($D.FullName, 'Open', 'Read', 'ReadWrite')
        $B = New-Object byte[] 96
        [void]$FS.Read($B, 0, 96); $FS.Close()
        if ([Text.Encoding]::ASCII.GetString($B, 0, 8) -ne 'PAGEDU64') { Log "$($D.Name): formato não reconhecido (32 bits ou corrompido)."; continue }
        $Cod = [BitConverter]::ToUInt32($B, 56)
        $P = 0..3 | ForEach-Object { '0x{0:X}' -f [BitConverter]::ToUInt64($B, 64 + 8 * $_) }
        $Desc = $Significado[[int]$Cod]; if (-not $Desc) { $Desc = 'ver documentação do código' }
        $Contagem[$Cod] = 1 + [int]$Contagem[$Cod]
        Log ("{0:dd/MM/yyyy HH:mm}  {1,-22} 0x{2:X}  {3}" -f $D.LastWriteTime, $D.Name, $Cod, $Desc)
        Log ("      parâmetros: {0}" -f ($P -join ', '))
    } catch { Log "$($D.Name): falha ao ler ($($_.Exception.Message))" }
}

# ---------- 2) Depurador (cdb/kd) ----------
Log ""
Log "=== 2) ANÁLISE COM DEPURADOR ==="
$Cdb = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
    "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Cdb) {
    $Cdb = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.WinDbg*" -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Cdb) {
    Log "cdb/kd não encontrado. Para a análise de drivers instale o WinDbg:  winget install Microsoft.WinDbg"
    Log "(ou 'Debugging Tools for Windows' do Windows SDK) e rode este script de novo."
} else {
    $Sym = if ($SemSimbolos) { 'srv*' } else { 'srv*C:\Symbols*https://msdl.microsoft.com/download/symbols' }
    foreach ($D in ($Dumps | Select-Object -First 3)) {
        Log ""; Log "--- $($D.Name) ($($D.LastWriteTime)) ---"
        $Copia = Join-Path $env:TEMP $D.Name
        Copy-Item $D.FullName $Copia -Force
        $Out = & $Cdb -z $Copia -y $Sym -c '!analyze -v; q' 2>&1 | Out-String
        Remove-Item $Copia -Force -ErrorAction SilentlyContinue
        foreach ($Campo in 'BUGCHECK_CODE','BUGCHECK_STR','IMAGE_NAME','MODULE_NAME','FAILURE_BUCKET_ID','PROCESS_NAME','SYMBOL_NAME','STACK_TEXT') {
            $M = [regex]::Match($Out, "(?m)^$Campo\s*:\s*(.+)$")
            if ($M.Success) { Log ("{0,-18} {1}" -f $Campo, $M.Groups[1].Value.Trim()) }
        }
    }
}

# ---------- 3) Eventos relacionados ----------
Log ""
Log "=== 3) ERROS DE HARDWARE (WHEA) E TESTES DE RAM ==="
$W = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger' } -MaxEvents 10 -ErrorAction SilentlyContinue)
if ($W) { $W | ForEach-Object { Log ("{0:dd/MM HH:mm}  Id {1}  {2}" -f $_.TimeCreated, $_.Id, (($_.Message -split "`n")[0]).Trim()) } } else { Log "Nenhum evento WHEA." }
Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 3 -ErrorAction SilentlyContinue |
    ForEach-Object { Log ("{0:dd/MM HH:mm}  Teste de memória Id {1}: {2}" -f $_.TimeCreated, $_.Id, (($_.Message -split "`n")[0]).Trim()) }

# ---------- 4) Pentes de RAM ----------
Log ""
Log "=== 4) PENTES DE RAM ==="
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    Log ("{0}  {1}  {2} GB  {3} MHz  {4} mV  {5}" -f $_.DeviceLocator, $_.Manufacturer, ($_.Capacity / 1GB), $_.ConfiguredClockSpeed, $_.ConfiguredVoltage, $_.PartNumber)
}

# ---------- Conclusão ----------
Log ""
Log "=== LEITURA ==="
$Mem = @(0x1A,0x4E,0x50,0x109,0x124,0x13A,0xF7,0x139) | Where-Object { $Contagem.ContainsKey([uint32]$_) } | ForEach-Object { $Contagem[[uint32]$_] } | Measure-Object -Sum
Log "$($Mem.Sum) de $($Dumps.Count) dump(s) com código típico de corrupção de memória."
Log "Se o depurador apontou um driver (IMAGE_NAME/MODULE_NAME) repetido: atualize/remova esse driver."
Log "Se apontou 'ntkrnlmp' ou 'memory_corruption' sem driver fixo: confirme a RAM com MemTest86, um pente por vez."

$Saida | Set-Content $Relatorio -Encoding UTF8
Write-Host "`nRelatório salvo em: $Relatorio" -ForegroundColor Green
