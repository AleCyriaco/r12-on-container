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

## Os três comandos

Tudo o que se faz aqui cabe em três, todos rodando direto da web, sem clone
prévio, num PowerShell **como Administrador**:

```powershell
# 1. INSTALAR -- do zero até o EBS no ar
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-SEUHASH.r2.dev'

# 2. RETOMAR -- continua de uma fase, sem refazer o que já ficou pronto
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-SEUHASH.r2.dev' -From Services

# 3. REMOVER TUDO -- máquina, disco virtual, pacote, pasta e a linha do hosts
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))
```

Os três mostram o andamento do mesmo jeito: **`passo N/X`**, uma barra de
**0 a 100%** e três relógios — quanto já correu, quanto falta e o total até o
fim de tudo. O X é fixado antes de começar (as partes do pacote entram na
conta) e o peso de cada passo **é** o tempo que ele costuma levar, então a
barra anda em ritmo de relógio, não de contagem: download e extração sozinhos
valem quase 80% dela.

```
  [ passo 12/35 ]  [ 20% ] [#####....................]  baixar u01-...part001  (decorrido 0:42:03 | falta 2:41:18 | total 3:23:21)
```

A previsão começa num nominal (45 Mbps de banda, extração média) e **se corrige
sozinha**: assim que uma fase começa, o ritmo real medido nela substitui o
nominal — se as primeiras partes vêm a um terço da velocidade esperada, as
restantes já são contadas a um terço. Espere um salto na estimativa quando o
download engrenar; é a medição entrando no lugar do chute. O mesmo estado fica
em `<TargetDir>\logs\progresso.json`, para consultar de outro terminal.

Detalhes de cada um: [instalar](#início-rápido) · [retomar](#retomando) ·
[remover](#removendo).

## Requisitos

| | Mínimo | Recomendado | Porquê |
|---|---|---|---|
| Windows | 11 ou Server 2022 | — | WSL2 |
| RAM | **16 GB** | 48 GB | com 48 GB+ a SGA de 20 GB do pacote roda como veio |
| Disco livre | ~345 GB | — | 274 GB extraídos + 58 GB do pacote |
| CPUs | 2 | 8 | o `adop` usa 32 workers; com menos funciona, só mais lento |

**O dimensionamento é automático.** O script lê a RAM do host e ajusta a VM
WSL2 e a SGA do Oracle — inclusive corrigindo o `%USERPROFILE%\.wslconfig`
(com backup) quando o teto padrão do WSL, metade da RAM do host, não basta:

| RAM do host | VM | SGA |
|---|---|---|
| 48 GB+ | 40 GB | 20 GB (padrão do pacote) |
| 23–47 GB | host − 8 GB | 8 GB |
| 16–22 GB | host − 4 GB | 4 GB |

Num host de 16 GB sobe e funciona, mas com swap — espere lentidão. Se souber
melhor, sobrescreva com `-MemoryMB`, `-Cpus`, `-SgaGb`.

A virtualização precisa estar habilitada na BIOS/UEFI.

**Para conferir antes de instalar qualquer coisa**, sem tocar na máquina:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Deploy-R12.ps1))) -SomenteRequisitos
```

Ele lê RAM, virtualização e discos, diz o que falta e sai. O deploy normal roda
esse mesmo portão antes de tudo — inclusive antes de instalar o Git — então uma
máquina que não atende termina com **zero alteração**.

## Início rápido

Comando testado em campo — rode num PowerShell **como Administrador**:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) `
    -BaseUrl 'https://pub-SEUHASH.r2.dev' `
    -WlsPassword 'welcome1' `
    -TargetDir 'C:\R12OnContainer'
```

> **`-WlsPassword` é a senha que a imagem já tem, não uma que você escolhe.** O
> deploy usa essa senha para autenticar no NodeManager; ele não troca a senha do
> WebLogic. O pacote de referência sai de fábrica com `welcome1` — só passe
> outra coisa se a sua imagem tiver sido alterada. Uma senha inventada aqui não
> falha na hora: o deploy roda até o fim, só o WebLogic fica fora do ar, e o
> motivo (`Invalid credentials passed`) fica enterrado no `services.log`.

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

Divide o volume em partes de 5 GB com um manifesto de checksums:

```powershell
.\Split-Package.ps1 `
    -SourceFile '\\servidor\share\u01-r12-lad-brasil.tar.zst' `
    -ExtraFile  '\\servidor\share\ebs-image-ol7-cll-ok.tar.zst' `
    -OutDir     'D:\upload'
```

Depois suba **todo** o conteúdo de `D:\upload` — partes, imagem do container e
`manifest.txt`. É o manifesto que permite ao deploy conferir cada parte por
tamanho e SHA-256.

### Onde hospedar

**Use object storage com HTTP puro.** O Cloudflare R2 custa cerca de
**US$ 0,72/mês** para 58 GB e **não cobra egress**; o Backblaze B2 é
equivalente. Suba com o [Upload-ToR2.ps1](Upload-ToR2.ps1) — o painel do
Cloudflare recusa arquivos acima de ~300 MB, então ele usa rclone e a API S3.
Depois habilite leitura pública no bucket e passe a URL como `-BaseUrl`.

**Serviços de compartilhamento de arquivo não servem para isso**, e medimos
o porquê:

| Serviço | Impedimento |
|---|---|
| Google Drive | cota de download — após ~56 GB numa janela, devolve uma página HTML *"Quota exceeded"* com HTTP 200 no lugar do arquivo. Ainda exige scraping do HTML para listar pasta. |
| Proton Drive | criptografia ponta a ponta. O fragmento da URL é a chave; baixar exigiria implementar SRP-6a e a hierarquia de chaves OpenPGP. |
| file.kiwi | também ponta a ponta — AES-GCM num web worker, chave no fragmento da URL. |

Todos são feitos para humano com navegador, não para script. Object storage com
URL pública ou assinada é feito exatamente para isto.

### Por que dividir

Não é por armazenamento — 58 GB são 58 GB de qualquer jeito. O ganho é:

- **Integridade granular.** Uma parte de 5 GB corrompida é detectada e
  rebaixada sozinha.
- **Reassembly por streaming.** `cat partes | zstd -dc | tar -x` nunca grava os
  58 GB de volta em disco.
- **Alívio de cota por arquivo**, se você estiver preso a um serviço que impõe uma.

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
| `WlsPassword` | senha que **já existe** no domínio da imagem (fábrica: `welcome1`) |
| `AppsPassword` | senha do schema APPS (padrão `apps`) |
| `AppsHost` | hostname gravado no contexto do EBS |
| `TargetDir` | onde instalar |

## Retomando

**Reexecutar o mesmo comando é seguro.** As fases são idempotentes: cada uma
confere se o trabalho já foi feito antes de refazer. Depois de uma falha — ou
de um reinício do Windows no meio — repetir o comando é a primeira coisa a
tentar, e nada do que já ficou pronto se perde.

Para pular direto para uma fase, use `-From`:

| Fase | O que faz | Retome por aqui quando |
|---|---|---|
| `Preflight` | WSL2 e plano de dimensionamento | — |
| `Podman` | instala o Podman se faltar | "Podman instalado mas fora do PATH" |
| `Machine` | cria a VM WSL2, move o disco, ajusta o kernel | depois de reiniciar por causa do erro 1223 ou `HCS_E_SERVICE_NOT_AVAILABLE` |
| `Download` | baixa e confere o pacote dentro da VM | queda de rede, cota do Drive estourada |
| `Extract` | extrai o `/u01` no ext4 da VM | depois de limpar uma instância anterior |
| `Container` | carrega a imagem e cria o container | — |
| `Services` | sobe banco, listener, WebLogic e o CM | **depois de reiniciar o Windows** |
| `Verify` | confere HTTP, ICM e conteúdo do banco | só para reconferir |

O que cada retomada preserva:

- **Download.** A retomada é byte-exata (`curl -C -`) e cada parte é reconferida
  por tamanho e SHA-256 contra o manifesto. Parte já íntegra é pulada em
  segundos; só a que faltou ou veio corrompida é baixada de novo. Foi para isso
  que o pacote é dividido em pedaços de 5 GB.
- **Extract.** A extração é **pulada** quando já existe uma instância completa —
  nunca sobrescrita. A trava existe porque um deploy com o `-MachineName` no
  padrão já começou a extrair sobre um `/u01` com o banco **aberto**; pular é ao
  mesmo tempo a resposta idempotente e a segura, já que extrair era a única ação
  destrutiva possível ali. Sobra de uma extração interrompida, essa sim, é limpa
  sozinha antes de recomeçar.
- **Diretório de destino.** Sem `-TargetDir`, uma instância existente é adotada
  (achada pelo `vm\ext4.vhdx`) em vez de reescolher "o drive com mais espaço
  livre" — que numa retomada já não é o drive da instância, justamente porque
  ela o ocupa. O requisito de espaço livre não se aplica a um disco que já
  contém a instância.
- **Services.** Não depende de nada baixado: reaplica o nome canônico no
  `/etc/hosts` do container, sobe o banco, espera o serviço realmente aceitar
  conexão e só então chama o `adstrtal.sh`.

Para **substituir** uma instância completa existente, em vez de mantê-la, você
tem três saídas — todas explicadas na própria mensagem: usar `-MachineName` e
`-TargetDir` diferentes para uma instância paralela; apagar só o `/u01` com
`Remove-Instancia.ps1 -SomenteInstancia` e retomar com `-From Extract`,
aproveitando os 59 GB já baixados; ou [remover tudo](#removendo).

Para acompanhar de fora, sem atrapalhar: `<TargetDir>\logs\progresso.json` tem
o passo, a porcentagem, a fase e os três tempos (`decorrido`, `falta`,
`tempo_total`), e `<TargetDir>\logs\*.log` tem a saída íntegra de cada fase
longa (`download.log`, `extract.log`, `services.log`).

## Depois de reiniciar o Windows

O container tem `--restart unless-stopped` e volta sozinho, mas roda
`sleep infinity` — os serviços do EBS não. Qualquer um destes o traz de volta:

```powershell
podman machine start ebs
cd C:\r12-on-container
.\Deploy-R12.ps1 -From Services
```

Ou direto de dentro da máquina, com o `scripts/bringup.sh`:

```powershell
podman machine start ebs
podman machine ssh ebs 'WLS_PASSWORD=xxx bash /mnt/c/r12-on-container/scripts/bringup.sh'
```

Os dois fazem o mesmo, nesta ordem: reaplicam o nome canônico no `/etc/hosts`
do container (o Podman o apaga a cada start), reiniciam o listener do banco,
abrem o banco, **esperam o serviço realmente aceitar conexão**, e só então
sobem a pilha de aplicação e conferem o concurrent manager. Pular qualquer um
desses passos vira um enganoso *"APPS credentials are wrong"* — veja
[docs/TROUBLESHOOTING.pt-BR.md](docs/TROUBLESHOOTING.pt-BR.md#tudo-quebra-depois-de-reiniciar-o-container).

## Removendo

Dois scripts, com propósitos diferentes:

```powershell
# apaga TUDO: serviços, container, máquina, disco virtual, pacote de 59 GB,
# a pasta da instância e a linha que o deploy escreveu no hosts
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))

# apaga só o /u01 extraído, preservando a máquina e o pacote já baixado
.\Remove-Instancia.ps1 -SomenteInstancia
```

O `Remove-Tudo.ps1` primeiro **olha** — descobre a pasta da instância pelo
registro do WSL (não precisa de `-TargetDir`), lista o que encontrou, monta o
plano com o que existe de fato e mostra `passo N/X` mais a barra de 0 a 100%,
igual ao deploy. Nada é alterado antes de você digitar o nome da máquina para
confirmar. Sem um console para responder — um pipe, um `< NUL`, uma tarefa
agendada — ele **para** em vez de assumir que pode apagar; use `-Force` se é
isso mesmo que você quer.

Duas coisas que ele recusa a fazer: apagar uma pasta que não tenha cara de
instância (sem `vm/logs/scripts/pkg`) ou a raiz de um drive; e remover do
`hosts` qualquer linha que não seja exatamente a `127.0.0.1 <AppsHost>` que o
deploy escreveu — uma entrada sua apontando o mesmo nome para outro servidor
fica onde está, e o script diz que a manteve.

Por padrão ele preserva o clone do repositório e o `.wslconfig`; use
`-RemoverRepo` e `-RestaurarWslConfig` para levar esses também.

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

**Um arquivo chamado `NUL` na pasta da instância a torna indelével.** Um
`curl -o NUL` chamado do PowerShell não descarta a saída: cria um arquivo
`NUL` de verdade. A partir daí `<TargetDir>\NUL` resolve para o *dispositivo*
nul, não para o arquivo, e apagar a pasta falha com *"Incorrect function"* —
mensagem que não dá nenhuma pista da causa. O `Remove-Tudo.ps1` contorna
sozinho com o prefixo `\\?\`; na mão é `cmd /c rd /s /q "\\?\<caminho>"`.
Pela mesma razão o deploy escreve num arquivo temporário em vez de `-o NUL`.

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
