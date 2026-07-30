<#
.SYNOPSIS
    Instala o Podman (se necessario) e faz o deploy do Oracle EBS R12.2.12 +
    LAD Brasil a partir de uma pasta publica do Google Drive.

.DESCRIPTION
    Executa em fases idempotentes. Cada fase confere se o trabalho ja foi feito
    antes de refazer, entao reexecutar o script depois de uma falha e seguro.

      Preflight  requisitos de hardware, WSL2, virtualizacao
      Podman     instala o Podman se nao houver
      Machine    cria a VM WSL2 dimensionada e move o disco para -TargetDir
      Download   baixa as partes da pasta do Drive PARA DENTRO da VM
      Extract    extrai o /u01 no ext4 da VM (sem o fs2, salvo -KeepFs2)
      Container  carrega a imagem, cria o container, ajusta o /etc/hosts
      Services   sobe banco, listener e a pilha WebLogic
      Verify     confere HTTP 302/200, ICM e conteudo do banco

.PARAMETER BaseUrl
    RECOMENDADO. URL base de um bucket/host HTTP com as partes e o
    manifest.txt -- Cloudflare R2, S3, ou qualquer servidor com suporte a
    Range. Ex: https://pub-abc123.r2.dev
    Sem cota, sem scraping, retomada byte-exata via curl -C -.

.PARAMETER FolderUrl
    Alternativa: pasta publica do Google Drive com as partes e o manifest.txt.
    Funciona, mas depende de scraping do HTML e a cota de download do Drive
    interrompe transferencias grandes -- medido em campo: ~56 GB numa janela
    curta ja basta para o Drive comecar a devolver pagina de erro.
    Ex: https://drive.google.com/drive/folders/1AbC...

.PARAMETER VolumeFileId
    Saida de emergencia: ID do u01-*.tar.zst inteiro, se a leitura da pasta
    falhar. Sem manifesto nao ha conferencia de SHA-256.

.PARAMETER ImageFileId
    Saida de emergencia: ID do ebs-image-*.tar.zst.

.PARAMETER KeepFs2
    Mantem o patch filesystem (fs2). Sem esta opcao o fs2 e descartado na
    extracao: economiza ~37 GB e entrega a instancia congelada, sem adop.

.PARAMETER SgaGb
    Reduz a SGA antes do primeiro startup. Use em maquinas com menos de 48 GB
    de RAM fisica. 0 (padrao) mantem os 20 GB do pacote.

.EXAMPLE
    .\Deploy-R12.ps1 -FolderUrl 'https://drive.google.com/drive/folders/1AbC...'

.EXAMPLE
    # maquina menor, mantendo o patch filesystem, retomando da extracao
    .\Deploy-R12.ps1 -FolderUrl '...' -SgaGb 8 -KeepFs2 -From Extract

.NOTES
    O download de ~58 GB de uma pasta publica do Drive e o ponto fragil deste
    script. O Google impoe cota por arquivo publico e responde com uma pagina
    HTML de erro em vez do arquivo quando a cota estoura.

    Duas defesas contra isso:
      - divida o pacote com Split-Package.ps1, que gera partes de 5 GB e um
        manifest.txt com SHA-256 de cada uma. Aqui cada parte e conferida por
        tamanho e hash; parte ruim e refeita sozinha.
      - sem manifesto, resta conferir o magic number do zstd (28 B5 2F FD),
        que ao menos detecta HTML no lugar do arquivo.

    Com partes a extracao e por streaming (cat partes | zstd -dc | tar -x):
    os 58 GB nunca sao gravados juntos em disco.

    Nota de implementacao: os scripts bash aqui usam here-strings LITERAIS
    (@'...'@) com marcadores __ASSIM__ trocados por .Replace(). Here-string
    interpolado (@"..."@) nao serve: em PowerShell o escape e a crase, nao a
    barra invertida, entao "\$VAR" vira barra + variavel do PowerShell (vazia)
    e produz bash silenciosamente quebrado.
#>

[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$FolderUrl,
    [string]$VolumeFileId,
    [string]$ImageFileId,
    # Sem padrao de propriedade: o drive e escolhido pelo portao de
    # requisitos, entre os que tem espaco, pelo maior livre.
    [string]$TargetDir,
    [string]$PastaInstancia = 'R12OnContainer',
    [string]$MachineName = 'ebs',
    [int]$Cpus           = 0,       # 0 = automatico: min(8, CPUs do host)
    [int]$MemoryMB       = 0,       # 0 = automatico, conforme a RAM do host
    [int]$DiskGB         = 600,
    # Padrao do pacote de referencia (consta no README dele). Nao e segredo
    # de producao: e a senha de fabrica da instancia empacotada. Sobrescreva
    # com -WlsPassword ou pelo config.psd1 se a sua for outra.
    # Default from the reference package (documented in its own README).
    [string]$WlsPassword = 'welcome1',
    [string]$AppsPassword,
    [string]$ConfigFile,
    [string]$AppsHost    = 'apps.example.com',
    [int]$SgaGb          = 0,
    [switch]$KeepFs2,
    [switch]$SkipHostsEntry,
    [ValidateSet('All','Preflight','Podman','Machine','Download','Extract','Container','Services','Verify')]
    [string]$From        = 'All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest fica muito mais rapido

# Quando este script e carregado como scriptblock (para contornar a
# ExecutionPolicy), $PSScriptRoot nao existe -- por isso o default do
# ConfigFile e resolvido aqui, e nao no bloco param.
# When loaded as a scriptblock (to work around ExecutionPolicy) there is no
# $PSScriptRoot, so the ConfigFile default is resolved here, not in param().
if (-not $ConfigFile) {
    $base = $PSScriptRoot
    if (-not $base) { $base = (Get-Location).Path }
    $ConfigFile = Join-Path $base 'config.psd1'
}

# ------------------------------------------------------------------ credenciais
# Nada de senha embutida: este repositorio e publico. Os valores vem do
# config.psd1 (bloqueado pelo .gitignore) ou de parametros na linha de comando.
# Copie config.example.psd1 para config.psd1 e preencha com o que veio no
# README do SEU pacote.
if (Test-Path $ConfigFile) {
    $cfg = Import-PowerShellDataFile -Path $ConfigFile
    if (-not $WlsPassword  -and $cfg.WlsPassword)  { $WlsPassword  = $cfg.WlsPassword }
    if (-not $AppsPassword -and $cfg.AppsPassword) { $AppsPassword = $cfg.AppsPassword }
    if (-not $PSBoundParameters.ContainsKey('BaseUrl')   -and $cfg.BaseUrl)   { $BaseUrl   = $cfg.BaseUrl }
    if (-not $PSBoundParameters.ContainsKey('FolderUrl') -and $cfg.FolderUrl) { $FolderUrl = $cfg.FolderUrl }
    if (-not $PSBoundParameters.ContainsKey('AppsHost')  -and $cfg.AppsHost)  { $AppsHost  = $cfg.AppsHost }
    if (-not $PSBoundParameters.ContainsKey('TargetDir') -and $cfg.TargetDir) { $TargetDir = $cfg.TargetDir }
}
if (-not $AppsPassword) { $AppsPassword = 'apps' }   # usuario do schema, nao a senha do WLS

# ------------------------------------------------------------- dimensionamento
# A VM e a SGA se ajustam a RAM do host. Referencias do pacote de origem:
# SGA 20G pede VM de ~40 GB; SGA 8G funciona em VM de ~16 GB. Abaixo disso e
# territorio de swap: sobe, mas lento.
# VM and SGA auto-size to host RAM. From the source package: 20G SGA wants a
# ~40 GB VM; 8G SGA runs in ~16 GB. Below that it swaps: it boots, slowly.
$hw          = Get-CimInstance Win32_ComputerSystem
$hostRamGb   = [math]::Round($hw.TotalPhysicalMemory/1GB, 1)
$hostCpus    = [int]$hw.NumberOfLogicalProcessors

if ($Cpus -le 0) { $Cpus = [Math]::Max(2, [Math]::Min(8, $hostCpus)) }

if ($MemoryMB -le 0) {
    if     ($hostRamGb -ge 47) { $MemoryMB = 40960 }                                      # padrao do pacote
    elseif ($hostRamGb -ge 23) { $MemoryMB = [int]([math]::Floor($hostRamGb - 8) * 1024) } # sobra 8 pro Windows
    else                       { $MemoryMB = [int]([math]::Floor($hostRamGb - 4) * 1024) } # host de 16 GB -> VM ~11-12
}

# SGA: so mexe se o usuario nao escolheu e a VM nao comporta os 20G do pacote.
# O corte de 15 GB vem do pacote de origem: SGA 8G testada em VM de ~16 GB.
if ($SgaGb -le 0 -and $MemoryMB -lt 38912) {
    if ($MemoryMB -ge 15360) { $SgaGb = 8 } else { $SgaGb = 4 }
}

# ---------------------------------------------------------------- infraestrutura

# O -TargetDir NAO tem padrao fixo: cada maquina tem um setup de discos
# diferente, e cravar "D:" quebra em toda maquina que so tem C:. Quando nao
# informado, o portao de requisitos mais abaixo escolhe o drive com mais
# espaco livre. ScriptsDir e LogsDir sao derivados la, depois da escolha.
# -TargetDir has NO fixed default: every machine has a different disk layout,
# and hardcoding "D:" breaks on any machine with only C:. When omitted, the
# requirements gate below picks the drive with the most free space.
$script:PhaseOrder = @('Preflight','Podman','Machine','Download','Extract','Container','Services','Verify')

function Write-Phase { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Info  { param([string]$m) Write-Host "    $m" }
function Write-Ok    { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    AVISO: $m" -ForegroundColor Yellow }
# Die usa THROW, nunca "exit": quando o script roda carregado em memoria (o
# caminho normal via bootstrap), "exit" mata o processo inteiro do PowerShell
# -- a janela fecha e leva a mensagem de erro junto, parecendo um crash.
# Die THROWS, never "exit": loaded as an in-memory scriptblock (the normal
# bootstrap path), "exit" kills the whole PowerShell process -- the window
# closes taking the error message with it, looking like a crash.
function Die         { param([string]$m) Write-Host "`nERRO: $m" -ForegroundColor Red; throw "deploy interrompido: $m" }

# Executa um comando nativo com stderr redirecionado SEM o efeito colateral do
# PowerShell 5.1: sob ErrorActionPreference=Stop, "2>&1"/"2>$null" em nativo
# transforma cada linha de stderr em excecao. Aqui a preferencia e relaxada so
# durante a chamada.
# Runs a native command with stderr redirected WITHOUT the PS 5.1 side effect:
# under ErrorActionPreference=Stop, "2>&1"/"2>$null" on natives turns stderr
# lines into thrown exceptions. Preference is relaxed only for the call.
# O try/catch NAO e redundante com a troca de preferencia -- e o que realmente
# funciona. Medido: so relaxar o $ErrorActionPreference (local OU $script:) nao
# impede o aborto, porque o scriptblock nao enxerga a mudanca. Com o catch, os
# tres casos se comportam: binario ausente nao derruba o deploy, stderr de
# comando nativo e capturado normalmente, e erros fora daqui seguem propagando.
# The try/catch is NOT redundant with the preference change -- it is the part
# that actually works. Measured: relaxing $ErrorActionPreference alone (local
# OR $script:) does not prevent the abort, because the scriptblock does not see
# the change.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command } catch { } finally { $ErrorActionPreference = $old }
}

function Should-Run {
    param([string]$Phase)
    if ($From -eq 'All') { return $true }
    return ([array]::IndexOf($script:PhaseOrder, $Phase) -ge [array]::IndexOf($script:PhaseOrder, $From))
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-WslPath {
    param([string]$WinPath)
    $full  = [IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0,1).ToLower()
    return '/mnt/' + $drive + ($full.Substring(2) -replace '\\','/')
}

# Grava um script bash com quebras LF e executa dentro da VM.
# CRLF aqui e o erro classico: o bash engasga com o "\r" invisivel.
function Invoke-Vm {
    param(
        [Parameter(Mandatory)][string]$Script,
        [string]$Name = 'step',
        [switch]$Detached,
        [switch]$PassThru
    )
    $shPath = Join-Path $script:ScriptsDir "$Name.sh"
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($shPath, ($Script -replace "`r`n","`n"), $utf8NoBom)
    $wslPath = ConvertTo-WslPath $shPath

    if ($Detached) {
        $logWsl = ConvertTo-WslPath (Join-Path $script:LogsDir "$Name.log")
        $rcWsl  = "$logWsl.rc"
        # Sentinela com o codigo de saida em vez de "o processo ainda existe?".
        # Checar processo com "pgrep -f <padrao>" NAO funciona aqui: a propria
        # linha de comando do wrapper ssh contem o padrao, entao o pgrep casa
        # consigo mesmo e a espera nunca termina. O arquivo .rc so aparece
        # quando o script realmente acaba -- e ainda diz se deu certo.
        # A sentinel file with the exit code, not "does the process exist?".
        # pgrep -f <pattern> matches the ssh wrapper's OWN command line, so the
        # wait never ends. The .rc file appears only when the script truly
        # finishes, and tells us whether it succeeded.
        $cmd = "rm -f $rcWsl; setsid nohup bash -c 'bash $wslPath; echo `$? > $rcWsl' > $logWsl 2>&1 < /dev/null & echo ok"
        Invoke-Native { & podman machine ssh $MachineName $cmd } | Out-Null
        return
    }
    $out = Invoke-Native { & podman machine ssh $MachineName "bash $wslPath" 2>&1 }
    if ($PassThru) { return $out }
    $out | ForEach-Object { Write-Host "    $_" }
}

# Acompanha um passo detached ate a sentinela .rc aparecer, ecoando o log.
# Devolve o codigo de saida do script remoto.
function Wait-VmStep {
    param([string]$Name, [int]$TimeoutMin = 240)
    $logFile  = Join-Path $script:LogsDir "$Name.log"
    $rcFile   = "$logFile.rc"
    $rcWsl    = ConvertTo-WslPath $rcFile
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $shown    = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (Test-Path $logFile) {
            $lines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $shown) {
                $novas = @($lines[$shown..($lines.Count-1)])
                # nunca inundar o console: rajadas grandes viram inicio + fim
                if ($novas.Count -gt 40) {
                    $novas[0..4]                              | ForEach-Object { Write-Host "    $_" }
                    Write-Host "    ... ($($novas.Count - 15) linhas omitidas -- integra em $logFile)"
                    $novas[($novas.Count-10)..($novas.Count-1)] | ForEach-Object { Write-Host "    $_" }
                } else {
                    $novas | ForEach-Object { Write-Host "    $_" }
                }
                $shown = $lines.Count
            }
        }
        # A sentinela e gravada pelo shell remoto ao fim do script. Ler pelo
        # caminho do Windows evita mais uma ida ate a VM a cada 15 segundos.
        if (Test-Path $rcFile) {
            $rc = (Get-Content $rcFile -Raw -ErrorAction SilentlyContinue).Trim()
            Start-Sleep -Seconds 2   # deixa o log terminar de ser gravado
            if (Test-Path $logFile) {
                $lines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $shown) {
                    $lines[$shown..($lines.Count-1)] | ForEach-Object { Write-Host "    $_" }
                }
            }
            if ($rc -ne '0') { Write-Warn2 "a fase '$Name' saiu com codigo $rc" }
            return $rc
        }
    }
    Die "tempo esgotado esperando a fase '$Name' (limite de $TimeoutMin min). Veja $logFile"
}

# ---------------------------------------------------------------- Google Drive

# Le a listagem de uma pasta publica. Nao ha API sem chave para isso; o caminho
# (o mesmo que o gdown usa) e extrair a variavel _DRIVE_ivd da pagina. E
# scraping: quebra quando o Google mudar o HTML. Dai os parametros -*FileId.
function Get-GDriveFolderFiles {
    param([Parameter(Mandatory)][string]$Url)

    $id = $null
    if     ($Url -match 'folders/([a-zA-Z0-9_-]{10,})') { $id = $Matches[1] }
    elseif ($Url -match '^[a-zA-Z0-9_-]{10,}$')         { $id = $Url }
    if (-not $id) { Die "nao consegui extrair o ID da pasta de: $Url" }

    Write-Info "lendo a pasta $id"
    try {
        $resp = Invoke-WebRequest -Uri "https://drive.google.com/drive/folders/$id" `
                                  -UseBasicParsing -TimeoutSec 60
    } catch {
        Die "falha ao abrir a pasta do Drive: $($_.Exception.Message)"
    }

    # A atribuicao vem como  window['_DRIVE_ivd'] = '...'  -- procurar o nome e
    # so entao o "= '...'" evita depender do que ha entre os dois.
    $idx = $resp.Content.IndexOf('_DRIVE_ivd')
    $m = $null
    if ($idx -ge 0) { $m = [regex]::Match($resp.Content.Substring($idx), "=\s*'([^']+)'") }
    if (-not $m -or -not $m.Success) {
        Die ("nao achei a listagem na pagina da pasta. Ou a pasta nao esta publica, " +
             "ou o Google mudou o HTML. Passe -VolumeFileId e -ImageFileId na mao.")
    }

    # o blob vem todo escapado em \xNN (\x22 = aspas, \x5b = [, \x5d = ])
    $decoded = [regex]::Replace($m.Groups[1].Value, '\\x([0-9a-fA-F]{2})', {
        param($mm) [char][Convert]::ToInt32($mm.Groups[1].Value, 16)
    })
    $decoded = $decoded -replace '\\/','/' -replace '\\"','"'

    # Estrutura de cada entrada:  "<id>",["<idDoPai>"],"<nome>",...
    # O pai vem em array ANINHADO, nao como string solta -- detalhe que muda a regex.
    $files = @()
    $rx = [regex]'"([a-zA-Z0-9_-]{20,})",\["[a-zA-Z0-9_-]{20,}"\],"([^"]+)"'
    foreach ($mm in $rx.Matches($decoded)) {
        $files += [pscustomobject]@{ Id = $mm.Groups[1].Value; Name = $mm.Groups[2].Value }
    }
    $files = $files | Sort-Object Name -Unique
    if (-not $files) { Die 'a pasta foi lida mas nenhum arquivo foi reconhecido' }

    Write-Info 'arquivos encontrados:'
    $files | ForEach-Object { Write-Info "  - $($_.Name)" }
    return $files
}

# Baixa um texto pequeno por HTTP (o manifesto num bucket/host qualquer).
function Get-HttpText {
    param([Parameter(Mandatory)][string]$Url)
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
    # servidores costumam servir .txt como octet-stream; ai o PS 5.1 devolve byte[]
    if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
    return [string]$r.Content
}

# Arquivos pequenos (o manifesto) nao passam pelo interstitial de virus.
function Get-GDriveTextFile {
    param([Parameter(Mandatory)][string]$Id)
    $u = "https://drive.usercontent.google.com/download?id=$Id&export=download"
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 60
    } catch {
        Die "falha ao baixar o manifesto: $($_.Exception.Message)"
    }
    # O Drive serve o .txt como octet-stream, e ai o PowerShell 5.1 devolve
    # byte[] em .Content em vez de string. Converter na mao.
    if ($r.Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($r.Content)
    }
    return [string]$r.Content
}

# manifest.txt do Split-Package.ps1:
#   FILE|PART|EXTRA  <nome>  <bytes>  <sha256>
function ConvertFrom-Manifest {
    param([Parameter(Mandatory)][string]$Text)
    $entries = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(PART|EXTRA|FILE)\s+(\S+)\s+(\d+)\s+([0-9a-fA-F]{64})\s*$') {
            $entries[$Matches[2]] = [pscustomobject]@{
                Kind = $Matches[1]; Name = $Matches[2]
                Size = [int64]$Matches[3]; Sha = $Matches[4].ToLower()
            }
        }
    }
    return $entries
}

# ---------------------------------------------------------------------- inicio

$modo = 'CONGELADO (sem fs2, sem adop)'
if ($KeepFs2) { $modo = 'dual filesystem (fs1 + fs2)' }

$destinoTxt = $TargetDir
if (-not $destinoTxt) { $destinoTxt = '(a escolher: drive com mais espaco livre)' }

Write-Host @"

  Deploy Oracle EBS R12.2.12 + LAD Brasil
  destino : $destinoTxt
  maquina : $MachineName
  modo    : $modo

"@ -ForegroundColor White

# ======================================================================
#  PORTAO DE REQUISITOS -- roda ANTES de criar diretorio, baixar ou
#  instalar qualquer coisa. Se a maquina nao atende, nada e alterado.
#
#  Existe porque as falhas por requisito apareciam tarde e disfarcadas:
#  RAM insuficiente so estourava no "podman machine init"; virtualizacao
#  desligada so no import do WSL, com HCS_E_HYPERV_NOT_INSTALLED; e disco
#  cheio, pior ainda, no meio de uma extracao de 274 GB.
#
#  REQUIREMENTS GATE -- runs BEFORE creating directories, downloading or
#  installing anything. If the machine does not qualify, nothing changes.
# ======================================================================
$REQ_RAM_GB  = 16
$REQ_DISK_GB = 345
if ($KeepFs2) { $REQ_DISK_GB = 380 }

Write-Phase 'Requisitos / Requirements'

$falhas = New-Object Collections.Generic.List[string]
$cs     = Get-CimInstance Win32_ComputerSystem
$ramGb  = [math]::Round($cs.TotalPhysicalMemory/1GB, 1)

# --- RAM ---------------------------------------------------------------
# O Windows reporta um pouco menos que o nominal (16 GB viram ~15.9), por
# isso a comparacao usa uma margem em vez do valor cheio.
$ramOk = ($ramGb -ge ($REQ_RAM_GB - 0.7))
Write-Host ("    {0,-18} {1,-22} {2}" -f 'RAM',
    "$ramGb GB", $(if ($ramOk) { 'OK' } else { "FALHOU (minimo $REQ_RAM_GB GB)" })) `
    -ForegroundColor $(if ($ramOk) { 'Green' } else { 'Red' })
if (-not $ramOk) { $falhas.Add("RAM: $ramGb GB -- o minimo e $REQ_RAM_GB GB") }

# --- Virtualizacao -----------------------------------------------------
# HypervisorPresent=true e o sinal mais confiavel: significa que ha um
# hypervisor REALMENTE rodando. VirtualizationFirmwareEnabled=false prova
# o contrario -- VT-x/AMD-V desligado na BIOS.
$cpu       = Get-CimInstance Win32_Processor | Select-Object -First 1
$vtOk      = [bool]$cs.HypervisorPresent
$vtMotivo  = ''
if (-not $vtOk) {
    if ($cpu.VirtualizationFirmwareEnabled -eq $false) {
        $vtMotivo = 'VT-x/AMD-V desligado no firmware'
    } else {
        $vmpEstado = $null
        try { $vmpEstado = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State } catch { }
        if ($vmpEstado -eq 'Disabled') {
            $vtMotivo = 'componente "Virtual Machine Platform" desabilitado'
        } elseif ($vmpEstado -eq 'Enabled') {
            $vtMotivo = 'componente habilitado mas hypervisor parado -- falta REINICIAR o Windows'
        } else {
            $vtMotivo = 'hypervisor nao esta rodando'
        }
    }
}
Write-Host ("    {0,-18} {1,-22} {2}" -f 'Virtualizacao',
    $(if ($vtOk) { 'ativa' } else { 'inativa' }),
    $(if ($vtOk) { 'OK' } else { "FALHOU ($vtMotivo)" })) `
    -ForegroundColor $(if ($vtOk) { 'Green' } else { 'Red' })
if (-not $vtOk) { $falhas.Add("Virtualizacao: $vtMotivo") }

# --- Disco -------------------------------------------------------------
# Le todos os discos fixos e escolhe. Se o -TargetDir nao foi informado
# explicitamente, adota o drive com MAIS espaco livre entre os que servem.
$discos = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
            Select-Object DeviceID, @{n='LivreGB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
            Sort-Object LivreGB -Descending)
$servem = @($discos | Where-Object { $_.LivreGB -ge $REQ_DISK_GB })

foreach ($d in $discos) {
    $bom = ($d.LivreGB -ge $REQ_DISK_GB)
    Write-Host ("    {0,-18} {1,-22} {2}" -f "Disco $($d.DeviceID)",
        "$($d.LivreGB) GB livres",
        $(if ($bom) { 'OK' } else { "insuficiente (precisa $REQ_DISK_GB GB)" })) `
        -ForegroundColor $(if ($bom) { 'Green' } else { 'DarkGray' })
}

if ($servem.Count -eq 0) {
    $maior = if ($discos) { "$($discos[0].DeviceID) com $($discos[0].LivreGB) GB livres" } else { 'nenhum disco fixo encontrado' }
    $falhas.Add("Disco: nenhum drive tem os $REQ_DISK_GB GB necessarios (o maior e $maior)")
}
elseif (-not $TargetDir) {
    # Nao informado: adota o drive com mais espaco livre entre os que servem.
    $TargetDir = $servem[0].DeviceID + '\' + $PastaInstancia
    Write-Host ("    {0,-18} {1,-22} {2}" -f 'Destino escolhido', $TargetDir,
        "$($servem[0].LivreGB) GB livres") -ForegroundColor Cyan
}
else {
    # Informado: o drive precisa existir E ter espaco. Nao adianta seguir e
    # descobrir isso no meio de uma extracao de 274 GB.
    $driveAlvo = $TargetDir.Substring(0,2)
    $existe    = Test-Path -LiteralPath ([IO.Path]::GetPathRoot($TargetDir))
    $alvoServe = [bool]($servem | Where-Object { $_.DeviceID -eq $driveAlvo })
    $sugerido  = $servem[0].DeviceID + '\' + (Split-Path $TargetDir -Leaf)
    if (-not $existe) {
        $falhas.Add("Disco: o drive $driveAlvo nao existe nesta maquina. " +
                    "Use -TargetDir '$sugerido' ($($servem[0].LivreGB) GB livres) ou omita o parametro")
    } elseif (-not $alvoServe) {
        $livreAlvo = ($discos | Where-Object { $_.DeviceID -eq $driveAlvo }).LivreGB
        $falhas.Add("Disco: $driveAlvo tem $livreAlvo GB livres, precisa de $REQ_DISK_GB GB. " +
                    "Use -TargetDir '$sugerido' ($($servem[0].LivreGB) GB livres) ou omita o parametro")
    }
}

# --- Veredito ----------------------------------------------------------
if ($falhas.Count -gt 0) {
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Red
    Write-Host '   ESTA MAQUINA NAO ATENDE AOS REQUISITOS MINIMOS' -ForegroundColor Red
    Write-Host '   THIS MACHINE DOES NOT MEET THE MINIMUM REQUIREMENTS' -ForegroundColor Red
    Write-Host '  ================================================================' -ForegroundColor Red
    Write-Host ''
    foreach ($f in $falhas) { Write-Host "   - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '   Requisitos minimos / Minimum requirements:' -ForegroundColor Yellow
    Write-Host "     RAM            $REQ_RAM_GB GB  (48 GB recomendado para a SGA de 20 GB do pacote)"
    Write-Host "     Disco livre    $REQ_DISK_GB GB  (274 GB extraidos + 59 GB do pacote)"
    Write-Host '     Virtualizacao  VT-x / AMD-V ativo na BIOS/UEFI, com o componente'
    Write-Host '                    "Virtual Machine Platform" habilitado no Windows'
    Write-Host '                    (wsl --install --no-distribution, como Administrador,'
    Write-Host '                     seguido de REINICIO)'
    Write-Host '                    Se este Windows for uma VM: habilite virtualizacao'
    Write-Host '                    aninhada no hypervisor que a hospeda.'
    Write-Host ''
    Write-Host '   Instalacao interrompida. NADA foi alterado nesta maquina.' -ForegroundColor Yellow
    Write-Host '   Installation aborted. NOTHING was changed on this machine.' -ForegroundColor Yellow
    Write-Host ''
    throw 'requisitos minimos nao atendidos'
}

Write-Ok 'todos os requisitos atendidos'

# Os caminhos derivam do TargetDir, que pode ter sido ajustado acima.
$script:ScriptsDir = Join-Path $TargetDir 'scripts'
$script:LogsDir    = Join-Path $TargetDir 'logs'
New-Item -ItemType Directory -Force -Path $TargetDir, $script:ScriptsDir, $script:LogsDir | Out-Null

# ------------------------------------------------------------------- Preflight
if (Should-Run 'Preflight') {
    Write-Phase 'Preflight'

    # RAM, disco e virtualizacao ja foram barrados no portao de requisitos
    # la em cima. Aqui ficam so o plano de dimensionamento e o que nao
    # impede a instalacao.
    Write-Info "CPUs logicas  : $($cs.NumberOfLogicalProcessors)"
    Write-Info ("plano         : VM {0:N0} MB, {1} CPUs{2}" -f $MemoryMB, $Cpus,
        $(if ($SgaGb -gt 0) { ", SGA reduzida para ${SgaGb}G" } else { ', SGA 20G do pacote' }))

    if ($ramGb -lt 23) {
        Write-Warn2 "host com $ramGb GB: a VM fica com ~$([math]::Round($MemoryMB/1024)) GB e a SGA cai para ${SgaGb}G."
        Write-Warn2 'vai subir, mas espere swap e lentidao -- 48 GB e o recomendado.'
    }

    # A maquina alvo ja existe? Avisar ANTES de qualquer coisa comecar.
    # O -MachineName tem padrao 'ebs': numa maquina onde esse nome ja e uma
    # instancia em producao, seguir adiante significa extrair por cima dela.
    #
    # So faz sentido perguntar se o podman ja estiver instalado -- numa maquina
    # limpa ele so chega na fase seguinte, e chamar o binario aqui quebrava o
    # deploy logo no inicio com "The term 'podman' is not recognized".
    # Only ask if podman is already installed: on a clean machine it arrives in
    # the next phase, and calling it here broke the deploy right at the start.
    $jaTem = $null
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        $jaTem = @(Invoke-Native { & podman machine list --format '{{.Name}}' 2>$null }) |
                 Where-Object { ($_ -replace '\*$','') -eq $MachineName }
    }
    if ($jaTem -and $From -eq 'All') {
        Write-Host ''
        Write-Host "  ATENCAO: a maquina podman '$MachineName' JA EXISTE nesta maquina." -ForegroundColor Yellow
        Write-Host '  Se ela tiver uma instancia EBS, a fase Extract vai recusar sobrescrever' -ForegroundColor Yellow
        Write-Host '  (e uma trava proposital). Para uma instancia NOVA em paralelo, use:' -ForegroundColor Yellow
        Write-Host "      -MachineName <outro nome>  -TargetDir <outro caminho>" -ForegroundColor Yellow
        Write-Host ''
        Write-Host "  WARNING: podman machine '$MachineName' ALREADY EXISTS here." -ForegroundColor Yellow
        Write-Host '  For a separate instance, pass a different -MachineName and -TargetDir.' -ForegroundColor Yellow
        Write-Host ''
    }

    $wslOk = $false
    try { & wsl --status 2>&1 | Out-Null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
    if (-not $wslOk) {
        if (-not (Test-Admin)) {
            Die ('o WSL nao esta instalado e isso exige Administrador. ' +
                 'Abra um PowerShell elevado e rode:  wsl --install --no-distribution')
        }
        Write-Info 'instalando o WSL2 (pode exigir reinicio)'
        & wsl --install --no-distribution
        Write-Warn2 'se o Windows pedir reinicio, reinicie e rode de novo com -From Podman'
    } else {
        Write-Ok 'WSL2 presente'
    }
}

# --------------------------------------------------------------------- Podman
if (Should-Run 'Podman') {
    Write-Phase 'Podman'

    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Write-Ok "ja instalado: $(& podman --version)"
    } else {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Die ('podman e winget ausentes. Instale o Podman manualmente: ' +
                 'https://github.com/containers/podman/releases (arquivo .msi)')
        }
        if (-not (Test-Admin)) {
            Die ('a instalacao do Podman exige Administrador. Abra um PowerShell ' +
                 'elevado e rode:  winget install --id RedHat.Podman')
        }
        Write-Info 'instalando via winget'
        & winget install --id RedHat.Podman --silent `
                --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
        if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
            Die 'Podman instalado mas fora do PATH. Abra um PowerShell novo e rode com -From Machine'
        }
        Write-Ok "instalado: $(& podman --version)"
    }
}

# -------------------------------------------------------------------- Machine
if (Should-Run 'Machine') {
    Write-Phase 'Machine'

    $existing = @(Invoke-Native { & podman machine list --format '{{.Name}}' 2>$null })
    $vmDir    = Join-Path $TargetDir 'vm'
    $jaExiste = $existing | Where-Object { $_ -replace '\*$','' -eq $MachineName }

    # MAQUINA FANTASMA: registrada no podman e no WSL, mas com o disco virtual
    # ausente. Acontece quando a pasta da instancia e apagada a mao sem remover
    # a maquina antes -- o registro do WSL continua apontando para um vhdx que
    # nao existe mais. O erro que aparece sem esta checagem nao ajuda em nada:
    #   Failed to attach disk '...\ext4.vhdx' to WSL2: The system cannot find
    #   the path specified.  Error code: ...MountDisk/HCS/ERROR_PATH_NOT_FOUND
    # Como o disco ja se foi, nao ha o que preservar: limpamos e recriamos.
    # GHOST MACHINE: registered in podman and WSL, but its virtual disk is
    # gone -- typically after deleting the instance folder by hand without
    # removing the machine first. Nothing is left to preserve, so we clean up
    # the stale registration and recreate.
    if ($jaExiste) {
        $vhdx = Join-Path $vmDir 'ext4.vhdx'
        $temDisco = Test-Path -LiteralPath $vhdx
        if (-not $temDisco) {
            # o disco pode nao ter sido movido para o TargetDir; conferir o
            # local padrao antes de declarar fantasma
            $padrao = Join-Path $env:LOCALAPPDATA "containers\podman\machine\wsl\wsldist\$MachineName\ext4.vhdx"
            $temDisco = Test-Path -LiteralPath $padrao
        }
        if (-not $temDisco) {
            Write-Warn2 "a maquina '$MachineName' esta registrada mas o disco virtual sumiu."
            Write-Warn2 'registro orfao (a pasta da instancia foi apagada?) -- limpando para recriar.'
            Invoke-Native { & wsl.exe --unregister "podman-$MachineName" } 2>&1 | Out-Null
            Invoke-Native { & cmd /c "podman machine rm -f $MachineName >nul 2>&1" }
            Start-Sleep -Seconds 2
            $jaExiste = $null
            Write-Ok 'registro removido; a maquina sera criada do zero'
        }
    }

    # O WSL limita a VM a ~metade da RAM do host por padrao, ignorando o que o
    # podman pedir. Num host de 16 GB a VM ficaria com 8 GB -- insuficiente ate
    # para a SGA reduzida. Se o padrao do WSL nao comporta o que precisamos,
    # ajustamos o %USERPROFILE%\.wslconfig (com backup) e derrubamos o WSL para
    # a mudanca valer. Em hosts grandes, onde a metade ja basta, nada e tocado.
    # WSL caps the VM at ~half the host RAM regardless of what podman asks.
    # If that default is not enough, patch %USERPROFILE%\.wslconfig (backed up)
    # and restart WSL. On big hosts where half is already enough, touch nothing.
    $vmGbAlvo = [int][math]::Ceiling($MemoryMB / 1024)
    if (($hostRamGb / 2) -lt $vmGbAlvo) {
        $wslCfg  = Join-Path $env:USERPROFILE '.wslconfig'
        $memLine = "memory=${vmGbAlvo}GB"
        $mudou   = $false
        if (Test-Path $wslCfg) {
            $txt = [IO.File]::ReadAllText($wslCfg)
            $m = [regex]::Match($txt, '(?im)^\s*memory\s*=\s*(\d+)\s*GB')
            if ($m.Success -and [int]$m.Groups[1].Value -ge $vmGbAlvo) {
                # ja comporta; nao tocar
            } else {
                Copy-Item $wslCfg "$wslCfg.bak" -Force
                if ($m.Success) {
                    $txt = ([regex]'(?im)^\s*memory\s*=.*$').Replace($txt, $memLine, 1)
                } elseif ($txt -match '(?im)^\s*\[wsl2\]') {
                    $txt = ([regex]'(?im)^(\s*\[wsl2\]\s*)$').Replace($txt, "`$1`r`n$memLine", 1)
                } else {
                    $txt = "[wsl2]`r`n$memLine`r`n" + $txt
                }
                [IO.File]::WriteAllText($wslCfg, $txt)
                Write-Ok "ajustado $wslCfg -> $memLine (backup em .wslconfig.bak)"
                $mudou = $true
            }
        } else {
            $novo = "[wsl2]`r`n$memLine`r`nprocessors=$Cpus`r`nswap=16GB`r`n"
            [IO.File]::WriteAllText($wslCfg, $novo)
            Write-Ok "criado $wslCfg ($memLine, processors=$Cpus, swap=16GB)"
            $mudou = $true
        }
        if ($mudou) {
            Write-Info 'reiniciando o WSL para o novo limite valer (para outras distros tambem)'
            & wsl --shutdown
            Start-Sleep -Seconds 5
        }
    }

    if ($jaExiste) {
        Write-Ok "a maquina '$MachineName' ja existe"
    } else {
        Write-Info "criando a maquina ($Cpus CPUs, $MemoryMB MB, $DiskGB GB)"
        # via cmd /c com redirecionamento do PROPRIO cmd: no PowerShell 5.1,
        # "2>&1" em comando nativo com ErrorActionPreference=Stop transforma
        # cada linha de stderr em excecao -- e o erro real morre no meio.
        # cmd /c with cmd's own redirection: in PS 5.1, "2>&1" on a native
        # command under ErrorActionPreference=Stop turns stderr into thrown
        # exceptions, killing the real error message mid-flight.
        $initLog = Join-Path $script:LogsDir 'podman-init.log'
        & cmd /c "podman machine init $MachineName --cpus $Cpus --memory $MemoryMB --disk-size $DiskGB > `"$initLog`" 2>&1"
        $initRc  = $LASTEXITCODE
        Get-Content $initLog -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        if ($initRc -ne 0) {
            # nao deixar registro pela metade: um init que falhou no import do
            # WSL as vezes registra a maquina sem VM por tras, e a proxima
            # execucao acharia que "ja existe"
            & cmd /c "podman machine rm -f $MachineName >nul 2>&1"
            $initTxt = ''
            if (Test-Path $initLog) { $initTxt = Get-Content $initLog -Raw }
            if ($initTxt -match 'HCS_E_HYPERV_NOT_INSTALLED|virtualization is not enabled') {
                Write-Host ''
                Write-Host 'A virtualizacao nao esta funcional neste Windows. O conserto (uma vez so):' -ForegroundColor Yellow
                Write-Host '  1. PowerShell COMO ADMINISTRADOR:  wsl.exe --install --no-distribution' -ForegroundColor Yellow
                Write-Host '  2. REINICIE o Windows' -ForegroundColor Yellow
                Write-Host '  3. Rode este mesmo comando de novo' -ForegroundColor Yellow
                Write-Host 'Se falhar de novo com o MESMO erro: maquina fisica -> habilite VT-x/AMD-V na BIOS;' -ForegroundColor Yellow
                Write-Host 'maquina virtual -> habilite a virtualizacao aninhada no hypervisor dela.' -ForegroundColor Yellow
                Write-Host '---' -ForegroundColor Yellow
                Write-Host 'Virtualisation is not functional on this Windows. One-time fix:' -ForegroundColor Yellow
                Write-Host '  1. PowerShell AS ADMINISTRATOR:  wsl.exe --install --no-distribution' -ForegroundColor Yellow
                Write-Host '  2. REBOOT Windows' -ForegroundColor Yellow
                Write-Host '  3. Re-run this same command' -ForegroundColor Yellow
                Die 'virtualizacao indisponivel (HCS_E_HYPERV_NOT_INSTALLED)'
            }
            Die 'falha no podman machine init'
        }

        # Mover o disco para o -TargetDir. O vhdx guarda ext4 de verdade: tudo
        # fica no drive escolhido SEM passar por 9p/drvfs, que mata desempenho e
        # quebra permissoes. Extrair em /mnt/<letra> e exatamente o que evitar.
        if (-not (Test-Path $vmDir)) {
            Write-Info "movendo o disco da VM para $vmDir"
            # o vhdx fica travado enquanto a VM utilitaria do WSL estiver viva
            # (ERROR_SHARING_VIOLATION); derrubar o WSL inteiro e o unico jeito.
            & cmd /c "podman machine stop $MachineName >nul 2>&1"
            & wsl --shutdown
            Start-Sleep -Seconds 5
            & wsl --manage "podman-$MachineName" --move $vmDir
            if ($LASTEXITCODE -ne 0) {
                Write-Warn2 'nao consegui mover o disco; ele fica no perfil do usuario (C:)'
            } else {
                Write-Ok "disco em $vmDir\ext4.vhdx"
            }
        }
        & podman machine set $MachineName --rootful | Out-Null
    }

    $running = @(Invoke-Native { & podman machine list --format '{{.Name}} {{.LastUp}}' 2>$null }) |
               Where-Object { $_ -like "$MachineName*" -and $_ -like '*Currently running*' }
    if (-not $running) {
        Write-Info 'iniciando a maquina'
        & podman machine start $MachineName
        if ($LASTEXITCODE -ne 0) { Die 'falha ao iniciar a maquina' }
    }

    # O WSL ignora parte do dimensionamento do podman: quem manda e o .wslconfig
    # global (padrao: metade da RAM do host). Conferir o que a VM REALMENTE tem.
    $vmInfo = Invoke-Vm -Name 'vm-info' -PassThru -Script @'
echo "cpus=$(nproc)"
echo "memgb=$(free -g | awk '/^Mem:/{print $2}')"
echo "freegb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
'@
    $vmMem = 0; $vmFree = 0
    foreach ($l in $vmInfo) {
        if ($l -match 'memgb=(\d+)')  { $vmMem  = [int]$Matches[1] }
        if ($l -match 'freegb=(\d+)') { $vmFree = [int]$Matches[1] }
    }
    Write-Info "a VM tem $vmMem GB de RAM e $vmFree GB livres (alvo: ~$([math]::Round($MemoryMB/1024)) GB)"
    $sgaNecessariaGb = 20
    if ($SgaGb -gt 0) { $sgaNecessariaGb = $SgaGb }
    if ($vmMem -lt ($sgaNecessariaGb + 6)) {
        Write-Warn2 "a VM tem $vmMem GB para uma SGA de ${sgaNecessariaGb}G + WebLogic: nao deve caber."
        Write-Warn2 'confira o %USERPROFILE%\.wslconfig (memory=...) e rode de novo com -From Machine'
    }

    Write-Info 'aplicando os ajustes de kernel do Oracle'
    $shmmax = 34359738368
    if ($SgaGb -gt 0) { $shmmax = [int64]($SgaGb * 1.6 * 1GB) }

    $sysctlTpl = @'
sudo tee /etc/sysctl.d/98-oracle.conf >/dev/null <<EOF
kernel.shmmax = __SHMMAX__
kernel.shmall = 8388608
kernel.sem = 250 32000 100 128
fs.file-max = 6815744
fs.aio-max-nr = 1048576
vm.max_map_count = 262144
EOF
sudo sysctl --system >/dev/null
echo "shmmax = $(sysctl -n kernel.shmmax)"
'@
    Invoke-Vm -Name 'sysctl' -Script $sysctlTpl.Replace('__SHMMAX__', "$shmmax")
}

# ------------------------------------------------------------------- Download
if (Should-Run 'Download') {
    Write-Phase 'Download'

    # lista "id nome bytes sha256" do que baixar
    # (com -BaseUrl o "id" e a URL completa; com Drive, o file id)
    $baixar = New-Object Collections.Generic.List[string]

    if ($BaseUrl) {
        # ---- HTTP simples (Cloudflare R2, S3, qualquer host com Range) ----
        # Muito melhor que o Drive: sem cota, sem scraping de HTML, sem
        # interstitial de virus, e a retomada do curl -C - e byte-exata.
        $raiz = $BaseUrl.TrimEnd('/')
        Write-Info "origem HTTP: $raiz"

        $man = @{}
        try {
            $man = ConvertFrom-Manifest -Text (Get-HttpText "$raiz/manifest.txt")
            Write-Ok "manifesto lido: $($man.Count) entradas"
        } catch {
            Write-Warn2 'sem manifest.txt acessivel: nao havera conferencia de SHA-256'
        }

        if ($man.Count -gt 0) {
            $extra = @($man.Values | Where-Object { $_.Kind -eq 'EXTRA' })
            $parts = @($man.Values | Where-Object { $_.Kind -eq 'PART' } | Sort-Object Name)
            foreach ($e in $extra) { $baixar.Add("$raiz/$($e.Name) $($e.Name) $($e.Size) $($e.Sha)") }
            if ($parts.Count -gt 0) {
                Write-Info "volume: $($parts.Count) partes"
                foreach ($p in $parts) { $baixar.Add("$raiz/$($p.Name) $($p.Name) $($p.Size) $($p.Sha)") }
            } else {
                $f = @($man.Values | Where-Object { $_.Kind -eq 'FILE' })[0]
                if (-not $f) { Die 'manifesto sem PART nem FILE' }
                $baixar.Add("$raiz/$($f.Name) $($f.Name) $($f.Size) $($f.Sha)")
                Write-Info "volume: $($f.Name) (arquivo unico)"
            }
        } else {
            # sem manifesto: nomes padrao do pacote, conferencia so pelo magic
            $baixar.Add("$raiz/ebs-image-ol7-cll-ok.tar.zst ebs-image-ol7-cll-ok.tar.zst 0 -")
            $baixar.Add("$raiz/u01-r12-lad-brasil.tar.zst u01-r12-lad-brasil.tar.zst 0 -")
        }
    }
    elseif ($VolumeFileId -and $ImageFileId) {
        $baixar.Add("$ImageFileId ebs-image.tar.zst 0 -")
        $baixar.Add("$VolumeFileId u01.tar.zst 0 -")
        Write-Warn2 'IDs passados na mao: sem manifesto, a conferencia fica so no magic number'
    } else {
        if (-not $FolderUrl) { Die 'informe -FolderUrl, ou -VolumeFileId e -ImageFileId' }
        $files = Get-GDriveFolderFiles -Url $FolderUrl

        $man = @{}
        $mf = $files | Where-Object { $_.Name -eq 'manifest.txt' } | Select-Object -First 1
        if ($mf) {
            $man = ConvertFrom-Manifest -Text (Get-GDriveTextFile -Id $mf.Id)
            Write-Ok "manifesto lido: $($man.Count) entradas"
        } else {
            Write-Warn2 'sem manifest.txt na pasta: nao havera conferencia de SHA-256'
        }

        $img = $files | Where-Object { $_.Name -like '*image*.tar.zst' } | Select-Object -First 1
        if (-not $img) { Die 'nao achei o *image*.tar.zst na pasta' }
        $sz = 0; $sh = '-'
        if ($man[$img.Name]) { $sz = $man[$img.Name].Size; $sh = $man[$img.Name].Sha }
        $baixar.Add("$($img.Id) $($img.Name) $sz $sh")
        Write-Info "imagem: $($img.Name)"

        $parts = @($files | Where-Object { $_.Name -match '\.part\d{3}$' } | Sort-Object Name)
        if ($parts.Count -gt 0) {
            Write-Info "volume: $($parts.Count) partes"
            foreach ($p in $parts) {
                $sz = 0; $sh = '-'
                if ($man[$p.Name]) { $sz = $man[$p.Name].Size; $sh = $man[$p.Name].Sha }
                $baixar.Add("$($p.Id) $($p.Name) $sz $sh")
            }
        } else {
            $vol = $files | Where-Object { $_.Name -like '*u01*.tar.zst' } | Select-Object -First 1
            if (-not $vol) { Die 'nao achei nem partes (*.partNNN) nem *u01*.tar.zst na pasta' }
            $sz = 0; $sh = '-'
            if ($man[$vol.Name]) { $sz = $man[$vol.Name].Size; $sh = $man[$vol.Name].Sha }
            $baixar.Add("$($vol.Id) $($vol.Name) $sz $sh")
            Write-Info "volume: $($vol.Name) (arquivo unico)"
        }
    }

    Write-Info 'baixando para dentro da VM (ext4) -- pode levar horas'
    Write-Info 'ha retomada: reexecutar com -From Download continua de onde parou'

    $dlTpl = @'
#!/bin/bash
set -uo pipefail
PKG=/var/ebs-pkg
mkdir -p "$PKG"

# O Drive intercala uma pagina de aviso de virus em arquivo grande. O fluxo e:
# pegar a pagina, extrair os campos do formulario (confirm/uuid) e repetir.
gdrive_get() {
  local ID="$1" OUT="$2"
  local CK TMP
  CK=$(mktemp); TMP=$(mktemp)
  curl -sL -c "$CK" -o "$TMP" "https://drive.usercontent.google.com/download?id=${ID}&export=download"
  if head -c 512 "$TMP" | grep -qi '<html'; then
    local UUID CONF
    UUID=$(grep -o 'name="uuid" value="[^"]*"' "$TMP" | sed 's/.*value="//;s/"//')
    CONF=$(grep -o 'name="confirm" value="[^"]*"' "$TMP" | sed 's/.*value="//;s/"//')
    [ -z "$CONF" ] && CONF=t
    rm -f "$TMP"
    # -sS: sem o medidor de progresso o log nao incha (o medidor gera linhas
    # imensas cheias de \r que depois inundam o console de quem acompanha),
    # mas erros continuam visiveis. O progresso vira UMA linha por minuto,
    # impressa pelo watcher abaixo.
    curl -sS -L -C - -b "$CK" --retry 5 --retry-delay 10 --retry-all-errors \
         -o "$OUT" \
         "https://drive.usercontent.google.com/download?id=${ID}&export=download&confirm=${CONF}&uuid=${UUID}" &
    local CPID=$!
    while kill -0 $CPID 2>/dev/null; do
      sleep 60
      kill -0 $CPID 2>/dev/null && echo "      ... $(du -h "$OUT" 2>/dev/null | cut -f1 || echo 0) de $(basename "$OUT")"
    done
    wait $CPID
  else
    mv "$TMP" "$OUT"
  fi
  rm -f "$CK" "$TMP" 2>/dev/null
}

# Sem manifesto so da para olhar o magic do zstd (28 B5 2F FD). Se o Drive
# devolveu HTML -- cota do arquivo publico estourada, ou compartilhamento que
# nao esta realmente publico -- o magic nao bate e paramos aqui, em vez de
# entregar uma pagina de erro para o tar e falhar meia hora depois.
magic_ok() {
  local M
  M=$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')
  [ "$M" = "28b52ffd" ] && return 0
  echo "    ERRO: $(basename "$1") nao e zstd (magic=$M)"
  head -c 300 "$1"; echo
  return 1
}

baixa() {
  local ID="$1" NAME="$2" SIZE="$3" SHA="$4"
  local OUT="$PKG/$NAME"
  local tent atual h

  for tent in 1 2; do
    if [ -s "$OUT" ] && [ "$SIZE" != "0" ]; then
      atual=$(stat -c %s "$OUT")
      if [ "$atual" = "$SIZE" ]; then
        h=$(sha256sum "$OUT" | cut -d' ' -f1)
        if [ "$h" = "$SHA" ]; then echo "    $NAME: ja baixado e conferido"; return 0; fi
        echo "    $NAME: sha divergente -- refazendo"
      fi
      rm -f "$OUT"
    fi

    echo "    $NAME: baixando (tentativa $tent)"
    case "$ID" in
      http://*|https://*)
        # HTTP direto: -C - retoma byte-exato de onde parou, sem cota nem
        # interstitial. E o caminho bom; o do Drive abaixo e o contorno.
        curl -sS -L -C - --retry 5 --retry-delay 10 --retry-all-errors \
             -o "$OUT" "$ID" &
        CPID=$!
        while kill -0 $CPID 2>/dev/null; do
          sleep 60
          kill -0 $CPID 2>/dev/null && echo "      ... $(du -h "$OUT" 2>/dev/null | cut -f1 || echo 0) de $NAME"
        done
        wait $CPID
        ;;
      *) gdrive_get "$ID" "$OUT" ;;
    esac

    if [ "$SIZE" != "0" ]; then
      atual=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
      if [ "$atual" != "$SIZE" ]; then
        echo "    $NAME: tamanho $atual, esperado $SIZE"
        # A cota do Drive nao adianta insistir em segundos: e limite por
        # janela de tempo. Melhor parar na hora com a instrucao certa do que
        # gastar a segunda tentativa e terminar com uma pagina HTML na tela.
        if grep -qi 'Quota exceeded' "$OUT" 2>/dev/null; then
          echo ""
          echo "    >>> COTA DO GOOGLE DRIVE ESTOURADA <<<"
          echo "    O Drive limita quanto um arquivo publico pode ser baixado por"
          echo "    janela de tempo, e responde com uma pagina HTML em vez do arquivo."
          echo "    Nao adianta repetir agora: espere algumas horas (ate 24h) e rode"
          echo "    de novo com -From Download. As partes ja conferidas sao mantidas;"
          echo "    so a que faltou sera baixada."
          echo ""
          echo "    >>> GOOGLE DRIVE QUOTA EXCEEDED <<<"
          echo "    Wait a few hours (up to 24h) and re-run with -From Download."
          echo "    Verified parts are kept; only the missing one is fetched."
          echo ""
          rm -f "$OUT"
          return 1
        fi
        head -c 200 "$OUT" 2>/dev/null; echo
        rm -f "$OUT"; continue
      fi
      h=$(sha256sum "$OUT" | cut -d' ' -f1)
      if [ "$h" != "$SHA" ]; then
        echo "    $NAME: SHA-256 nao confere"
        rm -f "$OUT"; continue
      fi
      echo "    $NAME OK ($(du -h "$OUT" | cut -f1), sha conferido)"
      return 0
    else
      case "$NAME" in
        *.part000|*.tar.zst) magic_ok "$OUT" || { rm -f "$OUT"; continue; } ;;
      esac
      echo "    $NAME OK ($(du -h "$OUT" | cut -f1), sem sha)"
      return 0
    fi
  done
  return 1
}

date +'[*] inicio: %H:%M:%S'
while read -r ID NAME SIZE SHA; do
  [ -z "${ID:-}" ] && continue
  baixa "$ID" "$NAME" "$SIZE" "$SHA" || { echo "ERRO: falhou em $NAME"; exit 1; }
done <<'LISTA'
__LISTA__
LISTA
date +'[*] fim: %H:%M:%S'

echo "[*] download OK"
df -h /var | tail -1
'@

    Invoke-Vm -Name 'download' -Detached -Script $dlTpl.Replace('__LISTA__', ($baixar -join "`n"))
    $null = Wait-VmStep -Name 'download' -TimeoutMin 720

    $dlLog = Get-Content (Join-Path $script:LogsDir 'download.log') -Raw
    if ($dlLog -notmatch 'download OK') {
        if ($dlLog -match 'COTA DO GOOGLE DRIVE ESTOURADA|Quota exceeded') {
            Die ('cota do Google Drive estourada. Espere algumas horas e rode de novo com ' +
                 '-From Download -- as partes ja conferidas sao mantidas. / Google Drive ' +
                 'quota exceeded; wait a few hours and re-run with -From Download.')
        }
        Die "o download falhou; veja $($script:LogsDir)\download.log"
    }
    Write-Ok 'pacote baixado e conferido'
}

# -------------------------------------------------------------------- Extract
if (Should-Run 'Extract') {
    Write-Phase 'Extract'

    $excl = ''
    if (-not $KeepFs2) {
        $excl = "--exclude='*APPS/fs2' --exclude='*APPS/fs2/*'"
        Write-Info 'descartando o fs2 na extracao (instancia congelada)'
    }

    $exTpl = @'
#!/bin/bash
set -uo pipefail
PKG=/var/ebs-pkg
MNT=/var/ebs-u01
mkdir -p "$MNT"

# TRAVA DE SEGURANCA: nunca extrair por cima de uma instancia existente.
#
# Aprendido do jeito ruim: um deploy disparado com o -MachineName no padrao,
# numa maquina onde esse nome ja era uma instancia em producao, comecou a
# extrair sobre o /u01 com o banco ABERTO. Datafiles de SYSTEM, SYSAUX, UNDO e
# TX_DATA foram sobrescritos sob os pes do Oracle. O tar nao tem como saber
# que aquilo era um banco vivo -- essa checagem tem.
#
# SAFETY INTERLOCK: never extract over an existing instance. A deploy launched
# with the default -MachineName, on a host where that name was already a live
# instance, started extracting over /u01 with the database OPEN.
# A trava so vale para uma instancia COMPLETA, marcada pela sentinela abaixo.
# Uma extracao interrompida (VM parada no meio, queda de energia) deixa
# install/APPS existindo pela metade -- barrar isso obrigaria o usuario a
# limpar na mao para retomar, e a diferenca entre "instancia viva" e "sobra de
# extracao morta" e exatamente o que a sentinela distingue.
# The interlock only applies to a COMPLETE instance, marked by the sentinel
# below. An interrupted extraction leaves install/APPS half-written; blocking
# that would force manual cleanup to resume.
COMPLETA="$MNT/.deploy-complete"
if [ -d "$MNT/install/APPS" ] && [ -f "$COMPLETA" ]; then
  echo ""
  echo "ERRO: ja existe uma instancia EBS COMPLETA em $MNT/install/APPS"
  echo "      (implantada em $(cat "$COMPLETA" 2>/dev/null))"
  echo ""
  echo "  Extrair por cima destroi a instancia existente -- e se o banco"
  echo "  estiver no ar, corrompe os datafiles em uso."
  echo ""
  echo "  Se voce QUER outra instancia nesta maquina, use nomes distintos:"
  echo "      -MachineName <outro>  -TargetDir <outro caminho>"
  echo ""
  echo "  Se voce QUER MESMO substituir esta, pare tudo e limpe antes:"
  echo "      podman stop <container>"
  echo "      rm -rf $MNT/install $COMPLETA"
  echo ""
  echo "ERROR: a COMPLETE EBS instance already exists at $MNT/install/APPS."
  echo "  Extracting over it destroys that instance and, if the database is"
  echo "  running, corrupts datafiles in use. Use a different -MachineName and"
  echo "  -TargetDir, or stop everything and remove $MNT/install first."
  echo ""
  exit 1
fi

# As ferramentas AD (adop, adadmin, frmcmp_batch, sqlplus do home 10.1.2) sao
# ELF de 32 bits: inode acima de 2^32 estoura o stat() delas com EOVERFLOW e o
# erro aparece disfarcado (FRM-40735, ORA-12154 em tnsnames valido...). No ext4
# da VM o teto e proporcional ao filesystem e fica muito abaixo disso, mas
# conferir custa nada.
echo "[*] inode de teste"
touch "$MNT/.probe"; INO=$(stat -c %i "$MNT/.probe"); rm -f "$MNT/.probe"
echo "    $INO (limite 4294967295)"
[ "$INO" -lt 4294967295 ] || { echo "ERRO: inode acima do limite de 32 bits"; exit 1; }

# Sobra de uma extracao anterior interrompida: limpar antes, porque extrair
# por cima de arquivos parciais mistura duas copias e o resultado nao presta.
if [ -d "$MNT/install" ]; then
  echo "[*] restos de uma extracao anterior incompleta -- removendo antes"
  rm -rf "$MNT/install"
fi
rm -f "$MNT/.deploy-complete"

echo "[*] extraindo -- demora"
date +'    inicio: %H:%M:%S'
# Com partes, reassembla por STREAMING: o cat alimenta o zstd direto, sem nunca
# gravar os 58 GB juntos em disco. O zero a esquerda (.part000) faz o glob do
# shell ordenar certo.
if ls "$PKG"/*.part000 >/dev/null 2>&1; then
  echo "    reassemblando $(ls "$PKG"/*.part[0-9][0-9][0-9] | wc -l) partes por streaming"
  cat "$PKG"/*.part[0-9][0-9][0-9] | zstd -dc | tar -xf - -C "$MNT" __EXCL__
else
  zstd -dc "$PKG"/u01*.tar.zst | tar -xf - -C "$MNT" __EXCL__
fi
date +'    fim: %H:%M:%S'

[ -d "$MNT/install/APPS" ] || { echo "ERRO: extracao nao produziu install/APPS"; exit 1; }
chown -R 54321:54321 "$MNT/install" 2>/dev/null || true

# Sentinela: so agora existe uma instancia COMPLETA aqui. E ela que a trava do
# inicio consulta -- sem isso, uma extracao interrompida seria confundida com
# uma instancia viva e exigiria limpeza manual para retomar.
date +'%Y-%m-%d %H:%M:%S' > "$MNT/.deploy-complete"

echo "[*] filesystems presentes"
ls -d "$MNT"/install/APPS/fs* 2>/dev/null

echo "[*] extracao OK"
df -h "$MNT" | tail -1
'@

    Invoke-Vm -Name 'extract' -Detached -Script $exTpl.Replace('__EXCL__', $excl)
    $null = Wait-VmStep -Name 'extract' -TimeoutMin 360

    $exLog = Get-Content (Join-Path $script:LogsDir 'extract.log') -Raw
    if ($exLog -notmatch 'extracao OK') { Die 'a extracao falhou; veja logs\extract.log' }
    Write-Ok 'volume /u01 extraido'
}

# ------------------------------------------------------------------ Container
if (Should-Run 'Container') {
    Write-Phase 'Container'

    $ctTpl = @'
#!/bin/bash
set -uo pipefail
PKG=/var/ebs-pkg
MNT=/var/ebs-u01
IMG=ebs-single:ol7-cll-ok
CTR=ebs

if podman image exists "$IMG"; then
  echo "imagem ja carregada"
else
  echo "carregando a imagem"
  zstd -dc "$PKG"/*image*.tar.zst | podman load
fi

echo "criando o container"
podman rm -f "$CTR" >/dev/null 2>&1 || true
# --pids-limit=0: o padrao (2048) estoura com os workers do adop e o adpatch
#   falha com "usdsop cannot create a new process".
# -p em vez de socat: no Linux quem expoe as portas e o socat no host; no
#   Windows o Podman encaminha ate o localhost do Windows automaticamente.
podman run -d --name "$CTR" --hostname apps \
  --ipc=host --pids-limit=0 --restart unless-stopped \
  --security-opt label=disable \
  -p 8000:8000 -p 1521:1521 \
  -v "$MNT":/u01 \
  "$IMG" sleep infinity
sleep 4

# /etc/hosts do container: UMA linha, com o nome longo primeiro.
# O Podman ja cria "<IP> apps ebs" por causa do --hostname. Acrescentar outra
# linha com os mesmos aliases muda o nome CANONICO do IP, e o listener sobe em
# HOST=apps em vez de HOST=__APPSHOST__ como na origem.
# E "sed -i" falha aqui com "Device or resource busy": /etc/hosts e bind mount,
# tem que gravar no lugar com "cat >".
IP=$(podman inspect "$CTR" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman exec -i "$CTR" bash -s <<EOF
grep -v -e '__APPSHOST__' -e 'apps ebs\$' /etc/hosts > /tmp/h
printf '%s\t%s apps ebs\n' '$IP' '__APPSHOST__' >> /tmp/h
cat /tmp/h > /etc/hosts
EOF

podman inspect "$CTR" --format '    pids={{.HostConfig.PidsLimit}} restart={{.HostConfig.RestartPolicy.Name}}'
podman exec "$CTR" bash -lc 'getent hosts __APPSHOST__'
'@

    Invoke-Vm -Name 'container' -Script $ctTpl.Replace('__APPSHOST__', $AppsHost)
    Write-Ok 'container criado'

    # hosts do Windows: sem isso o login falha, porque o AppsLogin redireciona
    # para o hostname e o EBS o grava no contexto e nos perfis.
    if (-not $SkipHostsEntry) {
        $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
        $entry     = "127.0.0.1    $AppsHost"
        $atual     = Get-Content $hostsFile -ErrorAction SilentlyContinue
        if ($atual -match [regex]::Escape($AppsHost)) {
            Write-Ok "$AppsHost ja resolve no hosts do Windows"
        } elseif (Test-Admin) {
            Add-Content -Path $hostsFile -Value "`n$entry"
            Write-Ok "adicionado ao hosts: $entry"
        } else {
            Write-Warn2 'sem privilegio para editar o hosts do Windows. Rode como Administrador:'
            Write-Host "      Add-Content '$hostsFile' `"`n$entry`"" -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------------- Services
if (Should-Run 'Services') {
    Write-Phase 'Services'

    if ($SgaGb -gt 0) {
        Write-Info "reduzindo a SGA para $SgaGb GB antes do primeiro startup"
        $sgaMax = $SgaGb + 2
        $pga    = [math]::Max(2, [int]($SgaGb/4))
        $sgaTpl = @'
podman exec -i -u oracle ebs bash -lc 'source /u01/install/APPS/19.0.0/EBSCDB_apps.env; sqlplus -s / as sysdba' <<'SQL'
startup nomount;
alter system set sga_target=__SGA__G scope=spfile;
alter system set sga_max_size=__SGAMAX__G scope=spfile;
alter system set pga_aggregate_target=__PGA__G scope=spfile;
shutdown immediate;
exit
SQL
'@
        Invoke-Vm -Name 'sga' -Script `
            $sgaTpl.Replace('__SGA__',"$SgaGb").Replace('__SGAMAX__',"$sgaMax").Replace('__PGA__',"$pga")
    }

    if (-not $WlsPassword) {
        Die ("falta a senha do WebLogic. Passe -WlsPassword, ou copie " +
             "config.example.psd1 para config.psd1 e preencha. " +
             "O valor esta no README do seu pacote -- nao vem neste repositorio.")
    }

    Write-Info 'subindo banco, listener e a pilha WebLogic -- varios minutos'

    $svcTpl = @'
#!/bin/bash
set -uo pipefail
CTR=ebs

# O podman REGENERA o /etc/hosts a cada start do container, perdendo a linha do
# nome canonico. O tnsnames aponta para esse nome: sem reaplicar, o banco fica
# inacessivel com ORA-12560 e o adstrtal acusa "credenciais erradas".
# podman REGENERATES /etc/hosts on every container start; without re-applying
# the canonical-name line the database is unreachable and adstrtal blames the
# credentials for what is a name-resolution problem.
echo "[*] reaplicando o nome canonico no /etc/hosts"
IP=$(podman inspect "$CTR" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman exec -i "$CTR" bash -s <<EOF
grep -v -e '__APPSHOST__' -e 'apps ebs\$' /etc/hosts > /tmp/h
printf '%s\t%s apps ebs\n' '$IP' '__APPSHOST__' >> /tmp/h
cat /tmp/h > /etc/hosts
EOF

echo "[*] banco + listener"
# stop+start: se o listener subiu antes da correcao do /etc/hosts esta com o
# binding errado. Sempre "lsnrctl stop" no ORACLE_HOME certo, nunca
# "pkill -f tnslsnr" -- esse padrao derruba tambem o listener do apps tier.
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl stop  >/dev/null 2>&1
  lsnrctl start >/dev/null 2>&1
  sqlplus -s / as sysdba <<< "startup;"
  sqlplus -s / as sysdba <<< "alter system register;" >/dev/null 2>&1' 2>&1 | tail -6

# Esperar o servico aceitar conexao ANTES do adstrtal: rodar na janela entre
# "banco aberto" e "servico registrado" produz a mesma mensagem enganosa sobre
# credenciais do APPS.
echo "[*] aguardando o servico EBSDB registrar"
db_pronto() {
  podman exec -i -u oracle "$CTR" bash -lc "
    source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
    sqlplus -s -L apps/__APPSPWD__@EBSDB" <<'SQL' 2>/dev/null | grep -q PRONTO
set heading off feedback off pagesize 0
select 'PRONTO' from dual;
exit
SQL
}
for i in $(seq 1 30); do
  if db_pronto; then echo "    disponivel apos $((i*5))s"; break; fi
  [ "$i" = "30" ] && echo "    AVISO: sem resposta em 150s -- seguindo assim mesmo"
  sleep 5
done

echo "[*] pilha de aplicacao"
# adstrtal.sh pede a senha do WebLogic NO STDIN. Sem "podman exec -i" ela chega
# vazia, o AdminServer falha com status 1 e todos os managed servers sao pulados
# com "Skipping startup ... AdminServer is down" -- mensagem que despista, porque
# o erro real (senha) fica escondido atras da cascata sobre o AdminServer.
printf '%s\n' '__WLSPWD__' | podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/EBSapps.env run
  $ADMIN_SCRIPTS_HOME/adstrtal.sh apps/__APPSPWD__' 2>&1 |
  grep -E "exiting with status|Exiting with status|ERROR"

# O ICM as vezes perde a corrida com o lock da sessao anterior e morre com
# "FND_DCP.Request_Session_Lock ... result code of 1 / establish_icm failed".
# Nao e corrupcao e nao precisa de cmclean.sql: basta subir de novo.
echo "[*] concurrent manager"
CM=$(podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
  $ADMIN_SCRIPTS_HOME/adcmctl.sh status apps/apps' 2>&1 | grep -ioE "is Active|is Not Active")
echo "    $CM"
if ! echo "$CM" | grep -qi "is Active"; then
  echo "    ICM fora -- nova tentativa"
  sleep 20
  podman exec -i -u oracle "$CTR" bash -lc '
    source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
    $ADMIN_SCRIPTS_HOME/adcmctl.sh start apps/apps' 2>&1 | grep -iE "starting|exiting with status"
  sleep 60
fi

echo "[*] services OK"
'@

    Invoke-Vm -Name 'services' -Detached -Script `
        $svcTpl.Replace('__WLSPWD__', $WlsPassword).Replace('__APPSPWD__', $AppsPassword).Replace('__APPSHOST__', $AppsHost)
    $null = Wait-VmStep -Name 'services' -TimeoutMin 90
    Write-Ok 'servicos iniciados'
}

# --------------------------------------------------------------------- Verify
if (Should-Run 'Verify') {
    Write-Phase 'Verify'

    $vfTpl = @'
#!/bin/bash
CTR=ebs
echo "-- filesystem --"
podman exec -i -u oracle "$CTR" bash -lc 'source /u01/install/APPS/EBSapps.env run 2>&1 | grep -E "File System Type|RUN File|PATCH File"'
echo "-- WebLogic --"
podman exec "$CTR" bash -lc 'ps -eo args | grep -o "weblogic.Name=[A-Za-z0-9_-]\+" | sort -u'
echo "-- concurrent manager --"
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
  $ADMIN_SCRIPTS_HOME/adcmctl.sh status apps/apps' 2>&1 | grep -iE "Concurrent Manager is"
echo "-- HTTP (de dentro do container) --"
podman exec "$CTR" bash -lc '
  printf "AppsLogin  : "; curl -s -o /dev/null -w "%{http_code}\n" http://__APPSHOST__:8000/OA_HTML/AppsLogin
  printf "frmservlet : "; curl -s -o /dev/null -w "%{http_code}\n" "http://__APPSHOST__:8000/forms/frmservlet?config=EBSDB"'
echo "-- banco --"
podman exec -i -u oracle "$CTR" bash -lc 'source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1; sqlplus -s apps/__APPSPWD__@EBSDB' <<'SQL'
set heading off feedback off pagesize 0
select 'release          : '||release_name from fnd_product_groups;
select 'CLL objetos      : '||count(*) from all_objects where owner='CLL';
select 'CLL_F189 tabelas : '||count(*) from all_tables where owner='CLL' and table_name like 'CLL_F189%';
select 'patches RT       : '||count(distinct bug_number) from ad_bugs
 where bug_number in ('38278491','38278928','38680086','38767278','39347871',
                      '38704679','38753479','38941559','39200574');
exit
SQL
echo "-- espaco --"
df -h /var/ebs-u01 | tail -1
'@

    Invoke-Vm -Name 'verify' -Script `
        $vfTpl.Replace('__APPSHOST__', $AppsHost).Replace('__APPSPWD__', $AppsPassword)

    Write-Host "`n-- HTTP a partir do Windows --" -ForegroundColor Cyan
    # "-o NUL" nao vale aqui: chamado pelo PowerShell, o curl.exe cria um
    # ARQUIVO chamado NUL no diretorio atual em vez de descartar a saida.
    $lixo = Join-Path $env:TEMP 'r12-curl.tmp'
    foreach ($u in @('http://127.0.0.1:8000/OA_HTML/AppsLogin',
                     'http://127.0.0.1:8000/forms/frmservlet?config=EBSDB')) {
        $code = & curl.exe -s -o $lixo -w '%{http_code}' --max-time 30 $u
        Write-Info ('{0,-52} -> {1}' -f $u, $code)
    }
    Remove-Item $lixo -ErrorAction SilentlyContinue

    # Painel local com credenciais e atalhos. Gerado aqui, nunca commitado:
    # carrega todas as senhas em texto puro e este repositorio e publico.
    Write-Host "`n-- painel local --" -ForegroundColor Cyan
    $gerador = Join-Path $PSScriptRoot 'New-Painel.ps1'
    if (-not (Test-Path $gerador)) { $gerador = Join-Path (Get-Location).Path 'New-Painel.ps1' }
    if (Test-Path $gerador) {
        try {
            & $gerador -TargetDir $TargetDir -MachineName $MachineName -AppsHost $AppsHost `
                       -WlsPassword $WlsPassword -AppsPassword $AppsPassword
        } catch {
            Write-Warn2 "nao consegui gerar o painel: $($_.Exception.Message)"
        }
    }

    Write-Host @"

  Painel: $TargetDir\painel.html  (abra no navegador)

  Esperado: AppsLogin 302, frmservlet 200

  Acesso : http://${AppsHost}:8000/OA_HTML/AppsLogin
  Login  : as credenciais estao no README do SEU pacote -- este repositorio
           nao carrega senha nenhuma, de proposito.

  Depois de reiniciar o Windows:
      podman machine start $MachineName
      .\Deploy-R12.ps1 -From Services -TargetDir '$TargetDir'

"@ -ForegroundColor White
}
