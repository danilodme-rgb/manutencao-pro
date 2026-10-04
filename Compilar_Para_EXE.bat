@echo off
cd /d "%~dp0"
echo =========================================================
echo  GERADOR DE EXECUTAVEL (.EXE) - MANUTENCAO PRO
echo =========================================================
echo.
echo Este script converte o ManutencaoGUI.ps1 em ManutencaoPro.exe usando o PS2EXE.
echo.
echo Passo 1: Verificando o compilador PS2EXE...
powershell -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name ps2exe)) { Set-ExecutionPolicy Bypass -Scope Process -Force; Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber } else { 'PS2EXE ja instalado.' }"

echo.
echo Passo 2: Compilando o ManutencaoGUI.ps1 para .exe...
powershell -NoProfile -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; Invoke-ps2exe -inputFile '.\ManutencaoGUI.ps1' -outputFile '.\ManutencaoPro.exe' -iconFile '.\icone\ManutencaoPro.ico' -noConsole -requireAdmin -STA -title 'Manutencao PRO' -product 'Manutencao PRO' -description 'Manutencao do Windows com ferramentas nativas' -version '5.0.0.0'"
if errorlevel 1 (
    echo.
    echo ERRO: a compilacao falhou. Veja as mensagens acima.
    pause
    exit /b 1
)

echo.
echo =========================================================
echo SUCESSO! O arquivo ManutencaoPro.exe foi criado na pasta.
echo Se a manutencao mensal ja estiver agendada, abra o programa:
echo ele avisa que a tarefa usa a versao anterior e oferece o
echo botao "Usar esta versao" para atualizar a copia agendada.
echo =========================================================
pause
