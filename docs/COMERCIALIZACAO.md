# Guia de comercialização do Manutenção PRO

Este guia cobre o que falta entre "o programa funciona" e "o programa é vendido": licenças, assinatura de código, instalador, distribuição, atualizações e os riscos específicos de um executável gerado por ps2exe. Pesquisa feita em outubro de 2026; confira preços e políticas antes de contratar.

## 1. Modelo de venda sugerido

| Público | Edição | Como ativa | Preço de referência dos concorrentes |
|---|---|---|---|
| Usuário doméstico | **Casa** | Licença presa ao código do computador (mostrado em Configurações > Licença) | CCleaner Pro US$ 44,95/ano; ASC Pro R$ 74,99/ano; Glary Pro US$ 19,97 a 39,95/ano |
| Assistência técnica | **Técnico** | Licença sem vínculo com máquina; pode ficar em `licenca.txt` ao lado do `.exe` num pendrive | Glary "Technician" US$ 169/ano |

Argumentos de venda que nenhum concorrente tem: pontuação honesta com histórico, laudo com a marca do técnico (HTML e PDF), análise de telas azuis, uso só de ferramentas nativas (sem instalar nada no PC do cliente), diagnóstico gratuito para sempre.

Sugestão: licença anual com validade (`-Validade`) para a edição Técnico e licença sem vencimento para a Casa, com upgrade pago entre versões maiores.

## 2. Licenças (já implementado)

1. Gere o par de chaves uma única vez: `powershell -File ferramentas\Licencas.ps1 -GerarChaves`. A chave privada fica em `ferramentas\chave-privada.txt` (no `.gitignore`); guarde cópia em local seguro. Perder a chave obriga a reemitir todas as licenças; vazá-la permite a qualquer um emitir licenças.
2. A chave pública é gravada automaticamente em `ManutencaoGUI.ps1` (`$script:ChavePublicaLicenca`). Recompile o `.exe`.
3. Emitir: `ferramentas\Licencas.ps1 -Emitir -Cliente "Nome" -Edicao Casa -Maquina XXXX-XXXX-XXXX-XXXX` ou `-Edicao Tecnico [-Validade 2027-12-31]`. O texto `MPRO1.…` vai por e-mail ou WhatsApp; o cliente cola em Configurações > Licença. As emissões ficam em `licencas-emitidas.csv`.
4. Período de avaliação: 30 dias com tudo liberado, contados do primeiro uso (data gravada em `config.json` e em `HKLM\SOFTWARE\ManutencaoPRO`). Depois, diagnóstico, ficha técnica, histórico e laudo continuam gratuitos; a manutenção pede licença.

Limites conhecidos: o script dentro do `.exe` é legível, então um atacante determinado pode alterar a verificação (é a mesma postura de qualquer software desktop; a assinatura impede gerar chaves, não impede patch). Trocar de placa-mãe ou reinstalar o Windows muda o código do computador da edição Casa: preveja reemissão gratuita algumas vezes por ano.

## 3. Assinatura de código (obrigatória para vender)

Sem assinatura, o SmartScreen mostra "O Windows protegeu o seu PC" na primeira abertura e o Defender tende a classificar executáveis do ps2exe como `Trojan:Win32/Wacatac.*!ml` (verdito de modelo de aprendizado, não de assinatura de vírus). O próprio projeto ps2exe recomenda assinar.

- **Azure Trusted Signing (agora "Artifact Signing")**: barato (US$ 9,99/mês), mas desde abril de 2025 aceita só organizações dos EUA/Canadá com 3+ anos de histórico; pessoas físicas e empresas do Brasil não conseguem aderir. Não conte com ele.
- **Certificado OV (empresa, CNPJ) ou IV (pessoa física)**: é o caminho. Desde 2023 a chave precisa ficar em token FIPS ou em HSM em nuvem; escolha assinatura em nuvem para não depender de token físico: Certum SimplySign (cerca de EUR 109 a 169/ano), SSL.com OV (US$ 129/ano + eSigner), Sectigo via revendas (cerca de US$ 220/ano). Desde março de 2026 a validade máxima é de 460 dias: orce renovação anual.
- **EV não vale a pena**: desde 2024 o EV não dá mais reputação imediata no SmartScreen; a reputação vem do volume de downloads limpos a partir de um mesmo endereço, igual ao OV. EV só importa para drivers de kernel.
- Certificados ICP-Brasil (e-CNPJ/e-CPF) **não** servem para assinatura de código.
- Comando (modelo em `assinar.cmd.exemplo`, que o `Compilar_Para_EXE.bat` chama se existir como `assinar.cmd`):
  `signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /a /d "Manutencao PRO" ManutencaoPro.exe`
  Use sempre carimbo de tempo RFC 3161 (`/tr` + `/td`) para a assinatura sobreviver ao vencimento do certificado. Assine o `.exe` e o instalador.

## 4. Falsos positivos de antivírus (ps2exe)

- Compile com `-noConsole -requireAdmin -STA` (já é o padrão do `.bat`); **não** use `-DPIAware` (há relatos de detecção só por essa opção).
- Envie cada versão ao VirusTotal e, se houver detecção do Defender, submeta como desenvolvedor em `microsoft.com/wdsi/filesubmission` (costuma ser liberado em 1 a 2 dias).
- Mantenha nome, ícone, versão e editor estáveis entre versões e publique o download sempre no mesmo domínio HTTPS: é assim que o SmartScreen acumula reputação.
- O código evita padrões típicos de malware: não usa `Invoke-Expression`, comandos codificados, download e execução de scripts, exclusões do Defender nem `vssadmin delete shadows` (a limpeza de pontos de restauração usa `Win32_ShadowCopy` pela WMI).
- Alternativa mais robusta a médio prazo: um pequeno host em C# (.NET Framework 4.8) assinado, com manifesto `requireAdministrator`, que embute o script e o executa em uma thread STA. Faz o mesmo que o ps2exe sem a "impressão digital" do ps2exe.

## 5. Instalador

`instalador\ManutencaoPro.iss` (Inno Setup 6.7 ou mais novo; o 7.x saiu em julho de 2026, espere alguns meses de uso em campo). O `Compilar_Para_EXE.bat` chama o ISCC se ele estiver instalado e gera `saida\ManutencaoPro-6.0-Instalador.exe`.

O instalador: exige administrador, instala em `Program Files\ManutencaoPro`, cria atalhos, remove a tarefa agendada "ManutencaoPRO - Mensal" ao desinstalar e pergunta se os dados em `%ProgramData%\ManutencaoPRO` (laudos, histórico, licença, configurações) devem ser apagados. Edite `#define Editor` com a razão social e descomente `SignTool`/`SignedUninstaller` quando tiver o certificado. Atualização silenciosa: `Instalador.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS`.

## 6. Atualizações

O programa lê `versao.json` em `https://raw.githubusercontent.com/danilodme-rgb/manutencao-pro/main/versao.json` ao abrir (desligável em Configurações) e mostra um aviso com botão "Baixar" se a versão for maior. Ele nunca baixa nem instala nada sozinho. Para publicar uma versão: atualize `$script:Versao`, o `.bat`, o `.iss`, gere e assine o instalador, publique no endereço de `url` e só então altere `versao.json`. Se preferir sair do GitHub, mude `$UrlVersao` e `$UrlSite` no topo do script.

## 7. Mudanças do Windows que afetam o produto (2025 a 2026)

- WMIC foi removido do Windows 11 24H2/25H2; o programa usa só `Get-CimInstance`.
- O PowerShell 5.1 continua embutido no Windows; o PowerShell 7 não. O programa exige só o 5.1.
- No 24H2 em diante o Windows apaga pontos de restauração com mais de 60 dias; a tarefa de restauração avisa isso.
- `cleanmgr.exe` segue presente e funcional; `MpCmdRun.exe` mudou de pasta e o programa já localiza a versão atual.
- `winget` não existe no Windows LTSC (sem Loja); a tarefa avisa em vez de falhar.
- Fim do suporte das edições Home/Pro usado pelo check-up: Windows 10 22H2 em 14/10/2025; Windows 11 23H2 em 11/11/2025; 24H2 em 13/10/2026; 25H2 em 12/10/2027. Atualize a tabela em `Executar-Checkup` a cada versão nova do Windows.

## 8. Checklist antes da primeira venda

1. Testar em Windows 10 22H2 e Windows 11 24H2/25H2, com e sem Mica, tema claro e escuro, notebook e desktop, cartão SD/USB conectado.
2. Testar o modo agendado (`-Automatico`) como SYSTEM e o desinstalador.
3. Gerar chaves, emitir uma licença Casa e uma Técnico, testar avaliação expirada (altere `PrimeiroUso` no `config.json` e no registro).
4. Assinar `.exe` e instalador; VirusTotal; submeter ao Microsoft se houver detecção.
5. Publicar o instalador num endereço fixo e só então atualizar `versao.json`.
6. Preparar a página de venda com o comparativo (`docs/COMPARATIVO.md`) e um laudo de exemplo em PDF.
