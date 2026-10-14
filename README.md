# Manutenção PRO 6.0

Manutenção preventiva e corretiva do Windows 10/11 feita **só com ferramentas nativas** (DISM, SFC, chkdsk, cleanmgr, Microsoft Defender, defrag, winget, Windows Update, bcdedit, powercfg, Agendador de Tarefas e o log de eventos). Um único script PowerShell 5.1 + WPF, compilado em `.exe` com ps2exe, com modo gráfico e modo agendado sem interface.

> Prévias na pasta `previas_v5/` ainda mostram a versão 5. A versão 6 tem navegação lateral, painel inicial com pontuação de saúde, histórico, ficha técnica e configurações.

## O que torna o produto diferente dos concorrentes

Comparado com CCleaner, Advanced SystemCare e Glary Utilities (análise completa em `docs/COMPARATIVO.md`):

| Diferencial | Manutenção PRO | Concorrentes |
|---|---|---|
| **Pontuação de saúde honesta (0 a 100)** com o motivo e a ação de cada ponto perdido | Sim | Nenhum tem nota; o Advanced SystemCare infla "5.156 problemas" contando cada arquivo temporário |
| **Histórico e evolução** entre manutenções (nota, espaço, desgaste do SSD, bateria, boot, telas azuis) | Sim | Nenhum |
| **Laudo técnico** HTML/PDF com marca do técnico, cliente e ordem de serviço | Sim | Nenhum exporta laudo |
| **Telas azuis com causa provável**, lendo os dumps do Windows | Sim | Nenhum |
| SMART dos discos, saúde da bateria, teste de memória, DISM + SFC, fim do suporte do Windows, ativação | Sim | Parciais ou ausentes |
| Ficha técnica do computador (CPU, módulos de RAM, BIOS, discos, vídeo, monitores, rede, Windows) | Sim | Glary tem "System Information", sem laudo |
| Sem instaladores embutidos, sem pop-ups de venda, sem serviço residente, sem limpador de registro | Sim | Todos têm alguma dessas práticas |
| Diagnóstico e laudo gratuitos para sempre; manutenção por licença offline | Sim | Assinatura anual com ativação online |

## Edições e licença

| Edição | O que libera |
|---|---|
| **Avaliação** (30 dias) | Tudo |
| **Avaliação encerrada** | Diagnóstico, ficha técnica, histórico e laudo (gratuitos para sempre) |
| **Casa** | Todas as tarefas de manutenção neste computador (licença presa ao código do computador) |
| **Técnico** | Tudo da Casa, laudo com marca/logotipo, campos Cliente e OS, exportação em PDF e uso em qualquer computador (inclusive de um pendrive com `licenca.txt` ao lado do `.exe`) |

A licença é um texto assinado com ECDSA P-256 e verificado offline; não há servidor. O vendedor gera o par de chaves e emite as licenças com `ferramentas\Licencas.ps1` (veja `docs/COMERCIALIZACAO.md`). Sem chave pública embutida (compilação de desenvolvimento), tudo fica liberado.

## Estrutura

| Caminho | Função |
|---|---|
| `ManutencaoGUI.ps1` | O programa inteiro (núcleo, tarefas, laudo, interface) |
| `Abrir_Manutencao.bat` | Executa o script sem compilar |
| `Compilar_Para_EXE.bat` | Gera `ManutencaoPro.exe` (ps2exe), assina se houver `assinar.cmd` e gera o instalador se o Inno Setup estiver instalado |
| `instalador/ManutencaoPro.iss` | Script do instalador (Inno Setup 6, pt-BR, remove o agendamento ao desinstalar e pergunta se mantém os dados) |
| `ferramentas/Licencas.ps1` | Ferramenta do vendedor: gera chaves, emite e verifica licenças |
| `versao.json` | Arquivo de versão consultado pelo programa para avisar sobre atualizações |
| `diagnostico/` | Scripts avulsos de diagnóstico (dumps, MemTest86, monitor de memória) |
| `docs/` | Comparativo com concorrentes e guia de comercialização |

Dados do programa (laudos, logs, `historico.json`, `config.json`, `licenca.txt`, logotipo) ficam em `%ProgramData%\ManutencaoPRO`, fora do OneDrive.

## Uso

1. Abra `Abrir_Manutencao.bat` (ou o `.exe`). O programa pede elevação.
2. Na página **Início**, clique em **Avaliar agora**: perfil Diagnóstico, somente leitura, cerca de 1 minuto. A pontuação aparece no anel, com os indicadores e o que puxou a nota para baixo.
3. Na página **Manutenção**, escolha um perfil (Diagnóstico, Rápida, Completa, Reparo ou Personalizada) e clique em **Iniciar manutenção**. Nada destrutivo acontece sem confirmação; cartões de memória e USB só recebem verificações.
4. O laudo abre ao final; **Salvar em PDF** usa o Microsoft Edge em modo headless. O **Histórico** guarda a evolução e permite reabrir cada laudo.
5. Em **Ferramentas**: programas da inicialização, remoção de apps, agendamento mensal (roda como SYSTEM, só na tomada, nunca reinicia sozinho), teste de memória e correção manual de cartão/USB.
6. Em **Configurações**: tema (igual ao Windows, claro ou escuro), efeito Mica, identidade do laudo (nome, telefone, contato, logotipo), licença e verificação de versão.

Modo agendado: `ManutencaoPro.exe -Automatico -Perfil Completa` (ou `Diagnostico`, `Rapida`, `Reparo`). O desinstalador usa `-RemoverAgendamento`.

## Compilar e distribuir

```
Compilar_Para_EXE.bat
```

Para vender: gere as chaves de licença (`ferramentas\Licencas.ps1 -GerarChaves`), recompile, assine o `.exe` e o instalador com um certificado de assinatura de código e publique o instalador num endereço fixo. O passo a passo, com custos e armadilhas (SmartScreen, falsos positivos do ps2exe), está em `docs/COMERCIALIZACAO.md`.

## Validação

Sem Windows à mão, o código é validado com o parser do PowerShell 7, testes unitários das funções puras (pontuação, histórico, licença, configuração, HTML) e checagem do XAML gerado. A interface WPF e os cmdlets de Windows (CIM, Defender, Storage) precisam ser exercitados num Windows real antes de uma versão pública.
