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

.PARAMETER FolderUrl
    Link da pasta publica do Google Drive com as partes e o manifest.txt.
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
    [string]$FolderUrl,
    [string]$VolumeFileId,
    [string]$ImageFileId,
    [string]$TargetDir   = 'D:\R12OnContainer',
    [string]$MachineName = 'ebs',
    [int]$Cpus           = 8,
    [int]$MemoryMB       = 40960,
    [int]$DiskGB         = 600,
    [string]$WlsPassword,
    [string]$AppsPassword,
    [string]$ConfigFile  = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$AppsHost    = 'apps.example.com',
    [int]$SgaGb          = 0,
    [switch]$KeepFs2,
    [switch]$SkipHostsEntry,
    [ValidateSet('All','Preflight','Podman','Machine','Download','Extract','Container','Services','Verify')]
    [string]$From        = 'All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest fica muito mais rapido

# ------------------------------------------------------------------ credenciais
# Nada de senha embutida: este repositorio e publico. Os valores vem do
# config.psd1 (bloqueado pelo .gitignore) ou de parametros na linha de comando.
# Copie config.example.psd1 para config.psd1 e preencha com o que veio no
# README do SEU pacote.
if (Test-Path $ConfigFile) {
    $cfg = Import-PowerShellDataFile -Path $ConfigFile
    if (-not $WlsPassword  -and $cfg.WlsPassword)  { $WlsPassword  = $cfg.WlsPassword }
    if (-not $AppsPassword -and $cfg.AppsPassword) { $AppsPassword = $cfg.AppsPassword }
    if (-not $PSBoundParameters.ContainsKey('FolderUrl') -and $cfg.FolderUrl) { $FolderUrl = $cfg.FolderUrl }
    if (-not $PSBoundParameters.ContainsKey('AppsHost')  -and $cfg.AppsHost)  { $AppsHost  = $cfg.AppsHost }
    if (-not $PSBoundParameters.ContainsKey('TargetDir') -and $cfg.TargetDir) { $TargetDir = $cfg.TargetDir }
}
if (-not $AppsPassword) { $AppsPassword = 'apps' }   # usuario do schema, nao a senha do WLS

# ---------------------------------------------------------------- infraestrutura

$script:PhaseOrder = @('Preflight','Podman','Machine','Download','Extract','Container','Services','Verify')
$script:ScriptsDir = Join-Path $TargetDir 'scripts'
$script:LogsDir    = Join-Path $TargetDir 'logs'

function Write-Phase { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Info  { param([string]$m) Write-Host "    $m" }
function Write-Ok    { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    AVISO: $m" -ForegroundColor Yellow }
function Die         { param([string]$m) Write-Host "`nERRO: $m" -ForegroundColor Red; exit 1 }

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
        & podman machine ssh $MachineName "setsid nohup bash $wslPath > $logWsl 2>&1 < /dev/null & echo ok" | Out-Null
        return
    }
    $out = & podman machine ssh $MachineName "bash $wslPath" 2>&1
    if ($PassThru) { return $out }
    $out | ForEach-Object { Write-Host "    $_" }
}

# Acompanha um passo detached ate o processo morrer, ecoando o log.
function Wait-VmStep {
    param([string]$Name, [int]$TimeoutMin = 240)
    $logFile  = Join-Path $script:LogsDir "$Name.log"
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $shown    = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (Test-Path $logFile) {
            $lines = @(Get-Content $logFile -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $shown) {
                $lines[$shown..($lines.Count-1)] | ForEach-Object { Write-Host "    $_" }
                $shown = $lines.Count
            }
        }
        $alive = & podman machine ssh $MachineName "pgrep -f 'bash /mnt/.*/$Name.sh' >/dev/null && echo vivo || echo fim"
        if ($alive -match 'fim') { return }
    }
    Die "tempo esgotado esperando a fase '$Name' (limite de $TimeoutMin min)"
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

Write-Host @"

  Deploy Oracle EBS R12.2.12 + LAD Brasil
  destino : $TargetDir
  maquina : $MachineName
  modo    : $modo

"@ -ForegroundColor White

New-Item -ItemType Directory -Force -Path $TargetDir, $script:ScriptsDir, $script:LogsDir | Out-Null

# ------------------------------------------------------------------- Preflight
if (Should-Run 'Preflight') {
    Write-Phase 'Preflight'

    $cs     = Get-CimInstance Win32_ComputerSystem
    $ramGb  = [math]::Round($cs.TotalPhysicalMemory/1GB, 1)
    $drive  = $TargetDir.Substring(0,2)
    $disk   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
    $freeGb = [math]::Round($disk.FreeSpace/1GB, 1)
    $needGb = 345
    if ($KeepFs2) { $needGb = 380 }

    Write-Info "RAM fisica    : $ramGb GB"
    Write-Info "CPUs logicas  : $($cs.NumberOfLogicalProcessors)"
    Write-Info "livre em $drive    : $freeGb GB  (necessario ~$needGb GB)"

    if ($freeGb -lt $needGb) { Die "espaco insuficiente em $drive" }

    if ($ramGb -lt 48 -and $SgaGb -eq 0) {
        Write-Warn2 'menos de 48 GB de RAM com SGA de 20 GB: o banco pode nao subir.'
        Write-Warn2 'considere reexecutar com -SgaGb 8 (funciona com ~16 GB de VM).'
    }

    if (-not $cs.HypervisorPresent) {
        Write-Warn2 'hypervisor nao detectado. Habilite a virtualizacao na BIOS/UEFI.'
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

    $existing = @(& podman machine list --format '{{.Name}}' 2>$null)
    $vmDir    = Join-Path $TargetDir 'vm'
    $jaExiste = $existing | Where-Object { $_ -replace '\*$','' -eq $MachineName }

    if ($jaExiste) {
        Write-Ok "a maquina '$MachineName' ja existe"
    } else {
        Write-Info "criando a maquina ($Cpus CPUs, $MemoryMB MB, $DiskGB GB)"
        & podman machine init $MachineName --cpus $Cpus --memory $MemoryMB --disk-size $DiskGB
        if ($LASTEXITCODE -ne 0) { Die 'falha no podman machine init' }

        # Mover o disco para o -TargetDir. O vhdx guarda ext4 de verdade: tudo
        # fica no drive escolhido SEM passar por 9p/drvfs, que mata desempenho e
        # quebra permissoes. Extrair em /mnt/<letra> e exatamente o que evitar.
        if (-not (Test-Path $vmDir)) {
            Write-Info "movendo o disco da VM para $vmDir"
            # o vhdx fica travado enquanto a VM utilitaria do WSL estiver viva
            # (ERROR_SHARING_VIOLATION); derrubar o WSL inteiro e o unico jeito.
            & podman machine stop $MachineName 2>&1 | Out-Null
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

    $running = @(& podman machine list --format '{{.Name}} {{.LastUp}}' 2>$null) |
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
    Write-Info "a VM tem $vmMem GB de RAM e $vmFree GB livres"
    if ($vmMem -lt 40 -and $SgaGb -eq 0) {
        Write-Warn2 'a VM tem menos de 40 GB: a SGA de 20 GB nao vai caber.'
        Write-Warn2 'ajuste o %USERPROFILE%\.wslconfig (memory=40GB) ou use -SgaGb 8'
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
    $baixar = New-Object Collections.Generic.List[string]

    if ($VolumeFileId -and $ImageFileId) {
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
    curl -L -C - -b "$CK" --retry 5 --retry-delay 10 --retry-all-errors \
         -o "$OUT" \
         "https://drive.usercontent.google.com/download?id=${ID}&export=download&confirm=${CONF}&uuid=${UUID}"
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
    gdrive_get "$ID" "$OUT"

    if [ "$SIZE" != "0" ]; then
      atual=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
      if [ "$atual" != "$SIZE" ]; then
        echo "    $NAME: tamanho $atual, esperado $SIZE"
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
    Wait-VmStep -Name 'download' -TimeoutMin 720

    $dlLog = Get-Content (Join-Path $script:LogsDir 'download.log') -Raw
    if ($dlLog -notmatch 'download OK') { Die 'o download falhou; veja logs\download.log' }
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

# As ferramentas AD (adop, adadmin, frmcmp_batch, sqlplus do home 10.1.2) sao
# ELF de 32 bits: inode acima de 2^32 estoura o stat() delas com EOVERFLOW e o
# erro aparece disfarcado (FRM-40735, ORA-12154 em tnsnames valido...). No ext4
# da VM o teto e proporcional ao filesystem e fica muito abaixo disso, mas
# conferir custa nada.
echo "[*] inode de teste"
touch "$MNT/.probe"; INO=$(stat -c %i "$MNT/.probe"); rm -f "$MNT/.probe"
echo "    $INO (limite 4294967295)"
[ "$INO" -lt 4294967295 ] || { echo "ERRO: inode acima do limite de 32 bits"; exit 1; }

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

echo "[*] filesystems presentes"
ls -d "$MNT"/install/APPS/fs* 2>/dev/null

echo "[*] extracao OK"
df -h "$MNT" | tail -1
'@

    Invoke-Vm -Name 'extract' -Detached -Script $exTpl.Replace('__EXCL__', $excl)
    Wait-VmStep -Name 'extract' -TimeoutMin 360

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

echo "[*] banco + listener"
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl start
  sqlplus -s / as sysdba <<< "startup;"' 2>&1 | tail -6

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
        $svcTpl.Replace('__WLSPWD__', $WlsPassword).Replace('__APPSPWD__', $AppsPassword)
    Wait-VmStep -Name 'services' -TimeoutMin 90
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

    Write-Host @"

  Esperado: AppsLogin 302, frmservlet 200

  Acesso : http://${AppsHost}:8000/OA_HTML/AppsLogin
  Login  : as credenciais estao no README do SEU pacote -- este repositorio
           nao carrega senha nenhuma, de proposito.

  Depois de reiniciar o Windows:
      podman machine start $MachineName
      .\Deploy-R12.ps1 -From Services -TargetDir '$TargetDir'

"@ -ForegroundColor White
}
