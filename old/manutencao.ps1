# ====================================================================
# SCRIPT DE MANUTENÇÃO DO WINDOWS (POWERSHELL) - DESLIGAMENTO INTELIGENTE
# ====================================================================

# 1. VERIFICAÇÃO DE ADMINISTRADOR AUTOMÁTICA
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Solicitando privilégios de Administrador..."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. CONFIGURAÇÃO DE LOGS E VARIÁVEL DE CONTROLE
$LogFile = "C:\Manutencao_Log.txt"
$ErrosEncontrados = $false # Variável que decide se o PC vai desligar ou não

Function Escrever-Log {
    param ([string]$Mensagem, [bool]$IsErro = $false)
    $DataHora = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LinhaLog = "[$DataHora] $Mensagem"
    
    # Colore a saída na tela dependendo se é erro ou não
    if ($IsErro) {
        Write-Host $LinhaLog -ForegroundColor Red
    } else {
        Write-Host $LinhaLog -ForegroundColor Cyan
    }
    
    Add-Content -Path $LogFile -Value $LinhaLog
}

# Limpa o log antigo se existir de uma manutenção anterior
if (Test-Path $LogFile) { Remove-Item $LogFile }

Escrever-Log "=== INICIANDO MANUTENÇÃO DO SISTEMA ==="

# 3. LIMPEZA DE TEMPORÁRIOS E LIXEIRA
Escrever-Log "1. Limpando arquivos temporários e Lixeira..."
try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    cleanmgr /sagerun:1 | Out-Null
    Escrever-Log "[OK] Limpeza de arquivos temporários concluída."
} catch {
    Escrever-Log "[ERRO] Falha ao limpar temporários." $true
    $ErrosEncontrados = $true
}

# 4. LIMPEZA DE CACHE DNS
Escrever-Log "2. Limpando cache de DNS e rede..."
try {
    ipconfig /flushdns | Out-Null
    Escrever-Log "[OK] Cache de DNS limpo."
} catch {
    Escrever-Log "[ERRO] Falha ao limpar DNS." $true
    $ErrosEncontrados = $true
}

# 5. LIMPEZA DE COMPONENTES DO WINDOWS UPDATE
Escrever-Log "3. Removendo versões antigas do Windows Update..."
try {
    Dism.exe /online /Cleanup-Image /StartComponentCleanup | Out-Null
    Escrever-Log "[OK] Limpeza de componentes concluída."
} catch {
    Escrever-Log "[ERRO] Falha na limpeza de componentes." $true
    $ErrosEncontrados = $true
}

# 6. REPARO DA IMAGEM DO SISTEMA (DISM)
Escrever-Log "4. Verificando a saúde da imagem do sistema (DISM)... Isso pode demorar."
try {
    Dism.exe /Online /Cleanup-Image /RestoreHealth | Out-Null
    Escrever-Log "[OK] Verificação DISM concluída."
} catch {
    Escrever-Log "[ERRO] Falha no DISM." $true
    $ErrosEncontrados = $true
}

# 7. VERIFICAÇÃO DE ARQUIVOS (SFC)
Escrever-Log "5. Iniciando verificação de integridade (SFC)..."
try {
    sfc /scannow | Out-Null
    Escrever-Log "[OK] Verificação SFC concluída."
} catch {
    Escrever-Log "[ERRO] Falha no SFC." $true
    $ErrosEncontrados = $true
}

# 8. ATUALIZAÇÃO DE PROGRAMAS (WINGET)
Escrever-Log "6. Verificando atualizações de aplicativos (Winget)..."
try {
    winget upgrade --all --accept-package-agreements --accept-source-agreements | Out-Null
    Escrever-Log "[OK] Aplicativos verificados e atualizados."
} catch {
    Escrever-Log "[ERRO] Falha no Winget." $true
    $ErrosEncontrados = $true
}

# 9. OTIMIZAÇÃO DE DISCO (TRIM / DEFRAG)
Escrever-Log "7. Otimizando Disco C: (TRIM para SSD ou Desfragmentação para HD)..."
try {
    Optimize-Volume -DriveLetter C -ReTrim -Defrag -ErrorAction Stop | Out-Null
    Escrever-Log "[OK] Otimização de disco concluída."
} catch {
    Escrever-Log "[ERRO] Falha ao otimizar o disco." $true
    $ErrosEncontrados = $true
}

# 10. AGENDAMENTO CHKDSK
Write-Host ""
$escolha = Read-Host "Deseja agendar uma verificação de disco (CHKDSK) para o próximo reinício? (S/N)"
if ($escolha -match "^[sS]$") {
    try {
        chkdsk C: /f /r /x | Out-Null
        Escrever-Log "[OK] CHKDSK agendado para o próximo boot."
    } catch {
        Escrever-Log "[ERRO] Falha ao agendar CHKDSK." $true
        $ErrosEncontrados = $true
    }
}

Escrever-Log "=== MANUTENÇÃO CONCLUÍDA ==="
Write-Host ""

# 11. DECISÃO DE DESLIGAMENTO CONDICIONAL
if ($ErrosEncontrados) {
    Write-Host "ATENÇÃO: Foram encontrados erros durante a manutenção!" -ForegroundColor Red -BackgroundColor Black
    Write-Host "O computador NÃO será desligado automaticamente." -ForegroundColor Yellow
    
    # Emite dois alertas sonoros
    [System.Console]::Beep(1000, 400)
    [System.Console]::Beep(1000, 400)
    
    # Abre o Bloco de Notas com o log para você ver o que deu errado
    notepad.exe $LogFile
    
    Write-Host "Pressione qualquer tecla para sair..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
} else {
    Write-Host "Manutenção 100% concluída sem erros!" -ForegroundColor Green
    Write-Host "O computador será desligado em 60 segundos..." -ForegroundColor Red
    Write-Host "DICA: Para cancelar, pressione Win+R, digite 'shutdown /a' e dê Enter." -ForegroundColor Yellow
    shutdown /s /f /t 60
}