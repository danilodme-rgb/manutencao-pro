<#
  Ferramenta do VENDEDOR: gera o par de chaves e emite/verifica licenças do Manutenção PRO.
  Nunca distribua este arquivo nem a chave privada com o produto.

  Uso (PowerShell no Windows, qualquer versão):
    .\Licencas.ps1 -GerarChaves
        Cria chave-privada.txt (GUARDE em local seguro; está no .gitignore) e chave-publica.txt,
        e grava a chave pública em ..\ManutencaoGUI.ps1 ($script:ChavePublicaLicenca). Depois recompile o .exe.

    .\Licencas.ps1 -Emitir -Cliente "Nome do cliente" -Edicao Casa -Maquina "ABCD-EFGH-JKLM-NPQR" [-Validade 2027-12-31]
        Edição Casa: presa ao código do computador que o cliente vê em Configurações > Licença.
    .\Licencas.ps1 -Emitir -Cliente "Assistência X" -Edicao Tecnico [-Validade 2027-12-31]
        Edição Técnico: sem vínculo com computador (roda em qualquer PC, inclusive do pendrive com licenca.txt ao lado do .exe).
        Sem -Validade a licença não vence. O texto da licença é impresso, salvo em licencas\licenca-<id>.txt e anotado em licencas-emitidas.csv.

    .\Licencas.ps1 -Verificar -Licenca "MPRO1.xxxx.yyyy"
        Confere a assinatura com a chave pública e mostra os campos.

  Formato: MPRO1.<base64url(json)>.<base64url(assinatura ECDSA P-256, r||s)>
  JSON: n = cliente, e = edição (Casa|Tecnico), m = código do computador (só Casa), v = validade AAAA-MM-DD, i = emissão, id = número
#>
[CmdletBinding(DefaultParameterSetName = 'Ajuda')]
param(
    [Parameter(ParameterSetName = 'Gerar')][switch]$GerarChaves,
    [Parameter(ParameterSetName = 'Gerar')][switch]$Forcar,
    [Parameter(ParameterSetName = 'Emitir')][switch]$Emitir,
    [Parameter(ParameterSetName = 'Emitir', Mandatory = $true)][string]$Cliente,
    [Parameter(ParameterSetName = 'Emitir', Mandatory = $true)][ValidateSet('Casa', 'Tecnico')][string]$Edicao,
    [Parameter(ParameterSetName = 'Emitir')][string]$Maquina = "",
    [Parameter(ParameterSetName = 'Emitir')][string]$Validade = "",
    [Parameter(ParameterSetName = 'Emitir')][string]$Id = "",
    [Parameter(ParameterSetName = 'Verificar')][switch]$Verificar,
    [Parameter(ParameterSetName = 'Verificar', Mandatory = $true)][string]$Licenca
)

$ErrorActionPreference = 'Stop'
$Pasta = Split-Path -Parent $MyInvocation.MyCommand.Path
$ArqPrivada = Join-Path $Pasta 'chave-privada.txt'
$ArqPublica = Join-Path $Pasta 'chave-publica.txt'
$ArqEmitidas = Join-Path $Pasta 'licencas-emitidas.csv'
$PastaLicencas = Join-Path $Pasta 'licencas'
$Script = Join-Path (Split-Path -Parent $Pasta) 'ManutencaoGUI.ps1'

Function ConvertTo-Base64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
Function ConvertFrom-Base64Url([string]$Texto) {
    $t = $Texto.Trim().Replace('-', '+').Replace('_', '/')
    switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
    return [Convert]::FromBase64String($t)
}
Function Nova-Ecdsa([byte[]]$Blob, [string]$Formato) {
    $Chave = [System.Security.Cryptography.CngKey]::Import($Blob, [System.Security.Cryptography.CngKeyBlobFormat]::$Formato)
    return New-Object System.Security.Cryptography.ECDsaCng $Chave
}

switch ($PSCmdlet.ParameterSetName) {
    'Gerar' {
        if ((Test-Path $ArqPrivada) -and -not $Forcar) { throw "Já existe $ArqPrivada. Gerar outra chave invalida TODAS as licenças já emitidas. Use -Forcar se for isso mesmo." }
        $Params = New-Object System.Security.Cryptography.CngKeyCreationParameters
        $Params.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        $Params.KeyUsage = [System.Security.Cryptography.CngKeyUsages]::Signing
        $Chave = [System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::ECDsaP256, [NullString]::Value, $Params)
        $Privada = [Convert]::ToBase64String($Chave.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob))
        $Publica = [Convert]::ToBase64String($Chave.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob))
        $Chave.Dispose()
        Set-Content -Path $ArqPrivada -Value $Privada -Encoding ASCII
        Set-Content -Path $ArqPublica -Value $Publica -Encoding ASCII
        Write-Host "Chave privada gravada em $ArqPrivada (guarde em local seguro; NUNCA versione nem distribua)." -ForegroundColor Yellow
        Write-Host "Chave pública: $Publica"
        if (Test-Path $Script) {
            $Conteudo = Get-Content -Path $Script -Raw -Encoding UTF8
            $Padrao = New-Object System.Text.RegularExpressions.Regex '(?m)^\$script:ChavePublicaLicenca = "[^"]*"'
            $Novo = $Padrao.Replace($Conteudo, ('$script:ChavePublicaLicenca = "' + $Publica + '"'), 1)
            if ($Novo -ne $Conteudo) { Set-Content -Path $Script -Value $Novo -Encoding UTF8 -NoNewline; Write-Host "Chave pública gravada em $Script. Recompile o executável." -ForegroundColor Green }
            else { Write-Warning "Não encontrei a linha `$script:ChavePublicaLicenca em $Script; cole a chave pública manualmente." }
        } else { Write-Warning "Script principal não encontrado em $Script; cole a chave pública manualmente." }
    }
    'Emitir' {
        if (-not (Test-Path $ArqPrivada)) { throw "Chave privada não encontrada. Rode primeiro: .\Licencas.ps1 -GerarChaves" }
        $Maquina = $Maquina.Trim().ToUpper()
        if ($Edicao -eq 'Casa') {
            if ($Maquina -notmatch '^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$') { throw "Edição Casa exige -Maquina no formato XXXX-XXXX-XXXX-XXXX (o cliente vê o código em Configurações > Licença)." }
        } else { $Maquina = "" }
        if ($Validade) { $null = [datetime]::ParseExact($Validade, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        if (-not $Id) {
            $Seq = 1
            if (Test-Path $ArqEmitidas) { $Seq = @(Get-Content $ArqEmitidas | Select-Object -Skip 1 | Where-Object { $_ }).Count + 1 }
            $Id = 'L-{0:0000}' -f $Seq
        }
        $Dados = [ordered]@{ n = $Cliente.Trim(); e = $Edicao; m = $Maquina; v = $Validade; i = (Get-Date).ToString('yyyy-MM-dd'); id = $Id }
        $Json = ConvertTo-Json -InputObject $Dados -Compress
        $Payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($Json))
        $Ecdsa = Nova-Ecdsa ([Convert]::FromBase64String((Get-Content $ArqPrivada -Raw).Trim())) 'EccPrivateBlob'
        $Assinatura = $Ecdsa.SignData([Text.Encoding]::UTF8.GetBytes($Payload), [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $Texto = "MPRO1.$Payload.$(ConvertTo-Base64Url $Assinatura)"
        if (-not (Test-Path $PastaLicencas)) { New-Item -ItemType Directory -Path $PastaLicencas | Out-Null }
        $ArqLic = Join-Path $PastaLicencas "licenca-$Id.txt"
        Set-Content -Path $ArqLic -Value $Texto -Encoding ASCII
        if (-not (Test-Path $ArqEmitidas)) { Set-Content -Path $ArqEmitidas -Value 'Id;Emissao;Cliente;Edicao;Maquina;Validade' -Encoding UTF8 }
        Add-Content -Path $ArqEmitidas -Value ("{0};{1};{2};{3};{4};{5}" -f $Id, $Dados.i, $Cliente.Trim().Replace(';', ','), $Edicao, $Maquina, $Validade) -Encoding UTF8
        Write-Host ""
        Write-Host "Licença $Id emitida para '$Cliente' (edição $Edicao$(if ($Maquina) { ", computador $Maquina" })$(if ($Validade) { ", válida até $Validade" } else { ", sem vencimento" }))." -ForegroundColor Green
        Write-Host "Arquivo: $ArqLic"
        Write-Host ""
        Write-Host $Texto
        Write-Host ""
        Write-Host "Envie o texto acima ao cliente: ele cola em Configurações > Licença > Ativar. Técnicos também podem salvar como licenca.txt ao lado do .exe."
    }
    'Verificar' {
        if (-not (Test-Path $ArqPublica)) { throw "Chave pública não encontrada ($ArqPublica)." }
        $Partes = @($Licenca.Trim() -split '\.')
        if ($Partes.Count -ne 3 -or $Partes[0] -ne 'MPRO1') { throw "Formato inválido." }
        $Ecdsa = Nova-Ecdsa ([Convert]::FromBase64String((Get-Content $ArqPublica -Raw).Trim())) 'EccPublicBlob'
        $Ok = $Ecdsa.VerifyData([Text.Encoding]::UTF8.GetBytes($Partes[1]), (ConvertFrom-Base64Url $Partes[2]), [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $Dados = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $Partes[1])) | ConvertFrom-Json
        Write-Host ("Assinatura: {0}" -f $(if ($Ok) { "VÁLIDA" } else { "INVÁLIDA" })) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
        Write-Host ("Cliente: {0} | Edição: {1} | Computador: {2} | Validade: {3} | Emissão: {4} | Id: {5}" -f $Dados.n, $Dados.e, $(if ($Dados.m) { $Dados.m } else { '(qualquer)' }), $(if ($Dados.v) { $Dados.v } else { '(sem vencimento)' }), $Dados.i, $Dados.id)
    }
    default { Get-Help $MyInvocation.MyCommand.Path }
}
