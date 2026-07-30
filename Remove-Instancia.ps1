<#
.SYNOPSIS
    Remove uma instancia EBS: servicos, container, maquina Podman e arquivos.
    Removes an EBS instance: services, container, Podman machine and files.

.DESCRIPTION
    A ordem importa, e nenhuma parte dela e obvia:

      1. parar os servicos     -- para o banco fechar limpo
      2. parar o container
      3. remover a maquina     -- leva o disco virtual junto, e o espaco
                                  volta ao Windows na hora
      4. apagar a pasta        -- o "podman machine rm" NAO faz isso
      5. limpar registro orfao -- se o podman e o WSL sairem de sincronia

    Pular o passo 4 e o erro mais comum: apagar so a pasta deixa a maquina
    registrada apontando para um disco que nao existe mais, e o proximo
    deploy morre com "Failed to attach disk ... ERROR_PATH_NOT_FOUND".

    Skipping step 4 is the common mistake: deleting only the folder leaves
    the machine registered against a disk that no longer exists, and the next
    deploy dies with "Failed to attach disk ... ERROR_PATH_NOT_FOUND".

.PARAMETER SomenteInstancia
    Apaga apenas o /u01 extraido, preservando a maquina e o pacote baixado.
    Use quando so quer refazer o deploy: economiza rebaixar 59 GB.
    Deletes only the extracted /u01, keeping the machine and the downloaded
    package -- use when you just want to redeploy.

.PARAMETER Force
    Nao pergunta antes de remover.

.EXAMPLE
    .\Remove-Instancia.ps1 -MachineName ebs -TargetDir 'C:\R12OnContainer'

.EXAMPLE
    # so o /u01, para refazer o deploy sem rebaixar o pacote
    .\Remove-Instancia.ps1 -MachineName ebs -SomenteInstancia
#>

[CmdletBinding()]
param(
    [string]$MachineName = 'ebs',
    [string]$TargetDir,
    [string]$WlsPassword = 'welcome1',
    [switch]$SomenteInstancia,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "    $m" }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-W    { param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Command } catch { } finally { $ErrorActionPreference = $old }
}

Write-Host "`n=== O que existe ===" -ForegroundColor Cyan
Invoke-Native { & podman machine list } | ForEach-Object { Write-Host "    $_" }

$existe = @(Invoke-Native { & podman machine list --format '{{.Name}}' 2>$null }) |
          Where-Object { ($_ -replace '\*$','') -eq $MachineName }

if (-not $existe -and -not $TargetDir) {
    Write-W "a maquina '$MachineName' nao existe e nenhum -TargetDir foi informado."
    Write-W 'nada a fazer.'
    return
}

# ------------------------------------------------------- so o /u01
if ($SomenteInstancia) {
    if (-not $existe) { throw "a maquina '$MachineName' nao existe" }
    Write-Host "`n=== Remover apenas o /u01 extraido ===" -ForegroundColor Cyan
    Write-Info 'a maquina, o container e o pacote baixado sao preservados'
    if (-not $Force) {
        $r = Read-Host "    apagar o /u01 da maquina '$MachineName'? [s/N]"
        if ($r -notmatch '^[sSyY]') { Write-Info 'cancelado'; return }
    }
    Invoke-Native { & podman machine ssh $MachineName "podman stop -t 60 ebs >/dev/null 2>&1; rm -rf /var/ebs-u01/install /var/ebs-u01/.deploy-complete; df -h /var/ebs-u01 | tail -1" } |
        ForEach-Object { Write-Info $_ }
    Write-Ok 'pronto -- rode o deploy com -From Extract'
    return
}

# ------------------------------------------------------- remocao completa
Write-Host "`n=== Remocao COMPLETA ===" -ForegroundColor Cyan
Write-Info "maquina  : $MachineName"
if ($TargetDir) { Write-Info "pasta    : $TargetDir" }
Write-W 'isso apaga a instancia, o banco, o /u01 e o pacote baixado.'

if (-not $Force) {
    $r = Read-Host "    digite o nome da maquina ($MachineName) para confirmar"
    if ($r -ne $MachineName) { Write-Info 'cancelado'; return }
}

if ($existe) {
    Write-Host "`n[1/4] parando os servicos" -ForegroundColor Cyan
    # Best-effort: se a instancia ja estiver quebrada isso falha, e tudo bem --
    # o objetivo aqui e so dar ao banco a chance de fechar limpo.
    Invoke-Native {
        & podman machine ssh $MachineName "WLS_PASSWORD=$WlsPassword bash /mnt/*/R12OnContainer/scripts/parar-ebs.sh 2>/dev/null || podman stop -t 60 ebs 2>/dev/null || true"
    } 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Info $_ }

    Write-Host "`n[2/4] parando a maquina" -ForegroundColor Cyan
    Invoke-Native { & cmd /c "podman machine stop $MachineName 2>&1" } | ForEach-Object { Write-Info $_ }

    Write-Host "`n[3/4] removendo a maquina (leva o disco virtual junto)" -ForegroundColor Cyan
    Invoke-Native { & cmd /c "podman machine rm -f $MachineName 2>&1" } | ForEach-Object { Write-Info $_ }
} else {
    Write-Info "a maquina '$MachineName' nao esta registrada no podman"
}

# Registro orfao no WSL: sobra quando o podman e o WSL saem de sincronia,
# tipicamente apos um init interrompido ou uma remocao pela metade.
$distro = "podman-$MachineName"
$distros = @(Invoke-Native { & wsl.exe -l -q } | ForEach-Object { ($_ -replace "`0",'').Trim() } | Where-Object { $_ })
if ($distros -contains $distro) {
    Write-Host "`n[3b] removendo o registro orfao no WSL" -ForegroundColor Cyan
    Invoke-Native { & wsl.exe --unregister $distro } | ForEach-Object { Write-Info $_ }
}

if ($TargetDir -and (Test-Path -LiteralPath $TargetDir)) {
    Write-Host "`n[4/4] apagando $TargetDir" -ForegroundColor Cyan
    $gb = [math]::Round((Get-ChildItem $TargetDir -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object Length -Sum).Sum/1GB, 1)
    Remove-Item -LiteralPath $TargetDir -Recurse -Force
    Write-Ok "removido ($gb GB)"
} elseif ($TargetDir) {
    Write-Info "$TargetDir ja nao existe"
}

Write-Host "`n=== Estado final ===" -ForegroundColor Cyan
Invoke-Native { & podman machine list } | ForEach-Object { Write-Host "    $_" }
Write-Ok 'remocao concluida'
