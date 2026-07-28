# Oracle EBS R12.2 em Podman no Windows

**Português** · [English](README.md)

Deploy automatizado de uma instância do Oracle E-Business Suite R12.2 num
container Podman no Windows, a partir de um pacote hospedado no Google Drive.
Um comando: instala o Podman, dimensiona a VM WSL2, baixa e confere o pacote,
extrai, cria o container e sobe a pilha inteira.

> **Este repositório contém apenas a automação.** Nenhum binário da Oracle,
> nenhum banco, nenhuma credencial, nenhum link para pacote. O Oracle
> E-Business Suite é software licenciado — o pacote é seu, e distribuí-lo é
> responsabilidade sua sob a sua licença Oracle.

## Requisitos

| | Mínimo | Porquê |
|---|---|---|
| Windows | 11 ou Server 2022 | WSL2 |
| RAM | 48 GB | SGA de 20 GB + PGA de 4 GB + WebLogic (~8 GB) + folga |
| Disco livre | ~345 GB | 274 GB extraídos + 58 GB do pacote |
| CPUs | 6–8 | o `adop` usa 32 workers; abaixo disso funciona, mas fica lento |

Com menos de 48 GB de RAM, reduza a SGA com `-SgaGb 8` — isso roda numa VM de
~16 GB.

A virtualização precisa estar habilitada na BIOS/UEFI.

## Início rápido

Comando testado em campo — rode num PowerShell **como Administrador**:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -FolderUrl 'https://drive.google.com/drive/folders/SEU_ID_DA_PASTA' `
    -WlsPassword 'SUA_SENHA_DO_WEBLOGIC' `
    -TargetDir 'C:\R12OnContainer'
```

Isso instala o Git se faltar, clona este repositório em `C:\r12-on-container` e
dispara o deploy completo. Conte com algumas horas, dominadas pelo download.

Duas lições de execuções reais:

- **O `-TargetDir` precisa apontar para um disco de verdade.** O padrão é
  `D:\R12OnContainer`; em máquinas onde o `D:` não existe ou é CD-ROM/leitor de
  cartão, o script agora para na hora e diz isso. Apontar para o `C:` (ou o
  drive que tiver ~345 GB livres) evita a ida e volta. Liste os discos reais
  com `Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"`.
- **A URL raw de `main` fica em cache no CDN por alguns minutos após um push.**
  Se você acabou de atualizar o repositório, fixe o commit:
  `https://raw.githubusercontent.com/AleCyriaco/r12-on-container/<sha-do-commit>/bootstrap.ps1`
  — URL por SHA é imutável e nunca serve versão velha.

Se preferir clonar antes:

```powershell
git clone https://github.com/AleCyriaco/r12-on-container.git C:\r12-on-container
cd C:\r12-on-container
Copy-Item config.example.psd1 config.psd1   # depois preencha
.\Deploy-R12.ps1
```

## Preparando o pacote

Divide o volume em partes de 5 GB e gera um manifesto com checksums. Depois suba
tudo para uma pasta do Drive compartilhada como *Qualquer pessoa com o link →
Leitor*:

```powershell
.\Split-Package.ps1 `
    -SourceFile '\\servidor\share\u01-r12-lad-brasil.tar.zst' `
    -ExtraFile  '\\servidor\share\ebs-image-ol7-cll-ok.tar.zst' `
    -OutDir     'D:\upload'
```

Suba **todo** o conteúdo de `D:\upload`: as partes, a imagem do container e o
`manifest.txt`. É o manifesto que permite ao deploy conferir cada parte por
tamanho e SHA-256.

Dividir não é sobre armazenamento — 58 GB são 58 GB de qualquer jeito. O que
você ganha:

- **Cota de download por arquivo.** O Google limita arquivos públicos
  individualmente.
- **Retomada de verdade.** Uma parte ruim de 5 GB custa 5 GB, não 58.
- **Reassembly por streaming.** `cat partes | zstd -dc | tar -x` nunca grava os
  58 GB de volta em disco.

## Como funciona

Oito fases idempotentes. Cada uma confere se o trabalho já foi feito, então
reexecutar depois de uma falha é seguro. Retome com `-From <Fase>`.

| Fase | O que faz |
|---|---|
| `Preflight` | hardware, WSL2, virtualização |
| `Podman` | instala o Podman via winget, se faltar |
| `Machine` | cria a VM WSL2, move o disco para `-TargetDir`, aplica os ajustes de kernel do Oracle |
| `Download` | baixa as partes para dentro da VM, conferindo tamanho e SHA-256 |
| `Extract` | extrai o `/u01` no ext4 da VM |
| `Container` | carrega a imagem, cria o container, ajusta o `/etc/hosts` |
| `Services` | banco, listener, pilha WebLogic, concurrent manager |
| `Verify` | HTTP 302/200, estado do ICM, conteúdo do banco |

### Onde os dados ficam

O disco virtual da VM vai para `-TargetDir\vm\ext4.vhdx`, e o `/u01` é extraído
no **ext4 dentro dele** — nunca em `/mnt/c` ou `/mnt/d`. Extrair num caminho do
Windows passa por 9p/drvfs, que destrói o desempenho e quebra permissões. Pôr o
vhdx no drive que você quer é como se escolhe onde os dados ficam fisicamente
sem pagar esse preço.

### Congelado por padrão

O `fs2`, o patch filesystem, é descartado na extração. O EBS detecta e reporta
`File System Type: SINGLE` / `PATCH File System: NOT APPLICABLE` — uma
configuração que ele suporta nativamente, não um remendo. Isso economiza ~37 GB
e significa que **o `adop` não roda mais**. Use `-KeepFs2` para uma instalação
dual filesystem, que aceita patches.

## Configuração

`config.psd1` (bloqueado pelo `.gitignore`) ou parâmetros na linha de comando:

| Chave | Significado |
|---|---|
| `FolderUrl` | pasta pública do Drive com as partes |
| `WlsPassword` | senha do WebLogic — **obrigatória** |
| `AppsPassword` | senha do schema APPS (padrão `apps`) |
| `AppsHost` | hostname gravado no contexto do EBS |
| `TargetDir` | onde instalar |

## Depois de reiniciar o Windows

O container tem `--restart unless-stopped` e volta sozinho, mas roda
`sleep infinity` — os serviços do EBS não.

```powershell
podman machine start ebs
cd C:\r12-on-container
.\Deploy-R12.ps1 -From Services
```

## Hostname

O `AppsLogin` redireciona para o hostname que o EBS gravou no contexto e nos
perfis, então ele precisa resolver no Windows. O deploy adiciona sozinho quando
rodado elevado; caso contrário, faça na mão:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "`n127.0.0.1    apps.example.com"
```

## Notas de segurança

- Nenhuma credencial neste repositório, de propósito. O `config.psd1` é
  bloqueado pelo `.gitignore`.
- Os arquivos `.sh` gerados em tempo de execução em `<TargetDir>\scripts\`
  **contêm** a senha do WebLogic já substituída. Estão no `.gitignore`, mas
  ficam em texto puro na máquina — trate esse diretório de acordo.
- Passar `-WlsPassword` na linha de comando deixa a senha no histórico do
  PowerShell. O `config.psd1` evita isso.

## Armadilhas conhecidas

Resumidas aqui, detalhadas em
[docs/TROUBLESHOOTING.pt-BR.md](docs/TROUBLESHOOTING.pt-BR.md).

**O `adstrtal.sh` lê a senha do WebLogic no stdin.** Sem `podman exec -i` ela
chega vazia, o AdminServer sai com status 1 e todos os managed servers são
pulados com *"Skipping startup … AdminServer is down"* — mensagem que te manda
caçar o NodeManager enquanto a causa real é a senha.

**O `/etc/hosts` do container é bind mount.** O `sed -i` falha com *Device or
resource busy*; grave no lugar com `cat > /etc/hosts`. E não duplique os aliases
`apps`/`ebs` que o Podman já cria a partir do `--hostname` — isso muda o nome
canônico do IP e o listener sobe em `HOST=apps` em vez do nome completo com que
a instância foi construída.

**`pkill -f tnslsnr` derruba os dois listeners** — o do banco na 1521 e o do
apps tier na 1626 casam com o mesmo padrão. Depois disso o `adstrtal.sh`
reclama de credenciais do APPS, o que não aponta nem perto do problema real.

**O ICM perde uma corrida com o lock da sessão anterior**, morrendo com
`FND_DCP.Request_Session_Lock … result code of 1`. Não é corrupção e não precisa
de `cmclean.sql` — basta subir de novo. Os scripts já detectam e tentam
novamente.

**Ler uma pasta do Drive é scraping.** Não existe API sem chave para listar
pasta pública, então isto extrai o blob `_DRIVE_ivd` da página, como o `gdown`
faz. Vai quebrar quando o Google mudar o HTML. Os parâmetros `-VolumeFileId` e
`-ImageFileId` são a saída de emergência.
