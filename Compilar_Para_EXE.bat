@echo off
setlocal
cd /d "%~dp0"
set "PROBLEMAS="

rem A versao vem do proprio ManutencaoGUI.ps1 ($script:Versao), para nunca ficar desatualizada aqui
set "VERSAO="
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "$m = @(Select-String -Path '.\ManutencaoGUI.ps1' -Pattern ('^\$script:Versao = ' + [char]34 + '([0-9.]+)'))[0]; if ($m) { $m.Matches[0].Groups[1].Value }"`) do set "VERSAO=%%v"
if not defined VERSAO (
    echo ERRO: nao consegui ler a versao em ManutencaoGUI.ps1 [linha $script:Versao = "x.y"].
    pause
    exit /b 1
)

echo =========================================================
echo  GERADOR DE EXECUTAVEL (.EXE) - MANUTENCAO PRO %VERSAO%
echo =========================================================
echo.
echo Passo 1: Verificando o compilador PS2EXE...
powershell -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name ps2exe)) { Set-ExecutionPolicy Bypass -Scope Process -Force; Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber } else { 'PS2EXE ja instalado.' }"

echo.
echo Passo 2: Conferindo a chave publica de licenca...
powershell -NoProfile -Command "$t = Get-Content '.\ManutencaoGUI.ps1' -Raw; if ($t -match ('ChavePublicaLicenca = ' + [char]34 + [char]34)) { exit 1 } else { exit 0 }"
if errorlevel 1 (
    echo.
    echo ATENCAO: o script NAO tem chave publica de licenca embutida.
    echo O .exe gerado sera uma COMPILACAO DE DESENVOLVIMENTO: tudo liberado, sem avaliacao nem licenca.
    echo Para uma versao de venda, rode antes:  powershell -File ferramentas\Licencas.ps1 -GerarChaves
    echo.
    choice /C SN /M "Continuar mesmo assim (compilacao de desenvolvimento)"
    if errorlevel 2 exit /b 1
) else (
    echo Chave publica presente: licencas serao verificadas.
)

echo.
echo Passo 3: Compilando o ManutencaoGUI.ps1 para ManutencaoPro.exe...
rem O .exe antigo e apagado antes: se a compilacao falhar, ele nao fica na pasta parecendo novo
tasklist /FI "IMAGENAME eq ManutencaoPro.exe" 2>nul | find /I "ManutencaoPro.exe" >nul
if not errorlevel 1 (
    echo.
    echo ERRO: o ManutencaoPro.exe esta aberto. Feche o programa e rode este arquivo de novo.
    pause
    exit /b 1
)
if exist "ManutencaoPro.exe" del /f /q "ManutencaoPro.exe"
if exist "ManutencaoPro.exe" (
    echo.
    echo ERRO: nao consegui apagar o ManutencaoPro.exe antigo [arquivo em uso ou sem permissao].
    pause
    exit /b 1
)
powershell -NoProfile -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; Invoke-ps2exe -inputFile '.\ManutencaoGUI.ps1' -outputFile '.\ManutencaoPro.exe' -iconFile '.\icone\ManutencaoPro.ico' -noConsole -requireAdmin -STA -title 'Manutencao PRO' -product 'Manutencao PRO' -description 'Manutencao preventiva e corretiva do Windows com ferramentas nativas' -version '%VERSAO%.0.0'"
if not exist "ManutencaoPro.exe" (
    echo.
    echo ERRO: a compilacao falhou e o ManutencaoPro.exe NAO foi gerado. Veja as mensagens acima.
    pause
    exit /b 1
)
for %%F in ("ManutencaoPro.exe") do echo ManutencaoPro.exe %VERSAO% gerado em %%~tF.

echo.
echo Passo 4: Assinatura de codigo (opcional)...
if exist "assinar.cmd" (
    call assinar.cmd "ManutencaoPro.exe"
    if errorlevel 1 (
        echo AVISO: a assinatura falhou. O .exe foi gerado SEM assinatura.
        set "PROBLEMAS=1"
    )
) else (
    echo Sem assinar.cmd: o .exe NAO foi assinado. Para vender, assine com um certificado de codigo
    echo Veja docs\COMERCIALIZACAO.md e o modelo assinar.cmd.exemplo.
)

echo.
echo Passo 5: Instalador (opcional, requer Inno Setup 6.3 ou mais novo)...
set "ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if defined ISCC (
    "%ISCC%" /Q "instalador\ManutencaoPro.iss"
    if errorlevel 1 (
        echo AVISO: o instalador NAO foi gerado. Veja as mensagens acima.
        set "PROBLEMAS=1"
    ) else (
        echo Instalador gerado em saida\ManutencaoPro-%VERSAO%-Instalador.exe
        if exist "assinar.cmd" (
            call assinar.cmd "saida\ManutencaoPro-%VERSAO%-Instalador.exe"
            if errorlevel 1 (
                echo AVISO: a assinatura do instalador falhou.
                set "PROBLEMAS=1"
            )
        )
    )
) else (
    echo Inno Setup nao encontrado: instale de https://jrsoftware.org/isdl.php para gerar o instalador.
)

echo.
echo =========================================================
if defined PROBLEMAS (
    echo CONCLUIDO COM AVISOS: ManutencaoPro.exe foi gerado, mas a assinatura
    echo ou o instalador falharam. Veja as mensagens acima antes de distribuir.
) else (
    echo SUCESSO! O arquivo ManutencaoPro.exe foi criado na pasta.
)
echo Se o Explorer ainda mostrar o icone antigo, e o cache de icones
echo do Windows: rode  ie4uinit.exe -show  ou reinicie o computador.
echo Se a manutencao mensal ja estiver agendada, abra o programa:
echo ele avisa que a tarefa usa a versao anterior e oferece o
echo botao "Usar esta versao" para atualizar a copia agendada.
echo =========================================================
pause
