<#
.SYNOPSIS
    Bootstrap de uma linha: instala o Git se faltar, clona este repositorio e
    dispara o deploy completo.
    One-liner bootstrap: installs Git if missing, clones this repo, runs the
    full deployment.

.DESCRIPTION
    PT-BR
      Feito para ser executado direto da web, sem clone previo:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/REPO/main/bootstrap.ps1))) `
            -FolderUrl 'https://drive.google.com/drive/folders/SEU_ID' -WlsPassword 'SUA_SENHA'

      Ele nao carrega credencial nenhuma. A senha do WebLogic vem por parametro
      ou de um config.psd1 que voce cria depois do clone.

    EN
      Meant to run straight from the web, with no prior clone:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/REPO/main/bootstrap.ps1))) `
            -FolderUrl 'https://drive.google.com/drive/folders/YOUR_ID' -WlsPassword 'YOUR_PASSWORD'

      No credentials are embedded. The WebLogic password is passed as a
      parameter or read from a config.psd1 you create after cloning.

.PARAMETER FolderUrl
    Pasta publica do Drive com as partes e o manifest.txt.
    Public Drive folder holding the parts and manifest.txt.

.PARAMETER WlsPassword
    Senha do WebLogic. Sem ela o AdminServer nao sobe.
    WebLogic password. Without it the AdminServer will not start.

.PARAMETER CheckoutDir
    Onde clonar o repositorio. / Where to clone the repository.

.PARAMETER TargetDir
    Onde instalar a instancia. / Where to install the instance.

.PARAMETER Ref
    Branch ou tag a usar. / Branch or tag to check out.
#>

[CmdletBinding()]
param(
    [string]$FolderUrl,
    [string]$WlsPassword,
    [string]$AppsPassword,
    [string]$CheckoutDir = 'C:\r12-on-container',
    [string]$TargetDir   = 'D:\R12OnContainer',
    [string]$MachineName = 'ebs',
    [string]$RepoUrl     = 'https://github.com/AleCyriaco/r12-on-container.git',
    [string]$Ref         = 'main',
    [int]$SgaGb          = 0,
    [switch]$KeepFs2,
    [ValidateSet('All','Preflight','Podman','Machine','Download','Extract','Container','Services','Verify')]
    [string]$From        = 'All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step { param([string]$m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
function Die        { param([string]$m) Write-Host "`nERRO / ERROR: $m" -ForegroundColor Red; exit 1 }

Write-Host @'

  ============================================================
   Oracle EBS R12.2.12 on Podman / Windows -- bootstrap
  ============================================================

'@ -ForegroundColor White

# ------------------------------------------------------------------------ git
Write-Step 'Git'
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "    $(git --version)"
} else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'git e winget ausentes / git and winget missing. Instale o Git: https://git-scm.com/download/win'
    }
    Write-Host '    instalando o Git via winget / installing Git via winget'
    & winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die 'Git instalado mas fora do PATH. Abra um PowerShell novo e rode de novo. / Git installed but not on PATH. Open a new PowerShell and retry.'
    }
}

# ----------------------------------------------------------------------- clone
Write-Step 'Repositorio / Repository'
if (Test-Path (Join-Path $CheckoutDir '.git')) {
    Write-Host "    ja clonado em $CheckoutDir -- atualizando / already cloned, updating"
    & git -C $CheckoutDir fetch --depth 1 origin $Ref
    & git -C $CheckoutDir reset --hard "origin/$Ref"
} else {
    Write-Host "    clonando em / cloning into $CheckoutDir"
    & git clone --depth 1 --branch $Ref $RepoUrl $CheckoutDir
    if ($LASTEXITCODE -ne 0) { Die "falha no clone / clone failed: $RepoUrl" }
}

$deploy = Join-Path $CheckoutDir 'Deploy-R12.ps1'
if (-not (Test-Path $deploy)) { Die "nao achei / not found: $deploy" }

# ---------------------------------------------------------------------- config
# Sem credencial no repositorio: ou vem por parametro, ou do config.psd1 local.
# No credentials in the repo: either passed as parameters or from local config.psd1.
$cfgFile = Join-Path $CheckoutDir 'config.psd1'
if (-not $WlsPassword -and -not (Test-Path $cfgFile)) {
    $exemplo = Join-Path $CheckoutDir 'config.example.psd1'
    Copy-Item $exemplo $cfgFile -Force
    Write-Host ''
    Write-Host '    Faltou a senha do WebLogic. / WebLogic password missing.' -ForegroundColor Yellow
    Write-Host "    Criei $cfgFile a partir do exemplo." -ForegroundColor Yellow
    Write-Host '    Preencha e rode de novo, ou passe -WlsPassword.' -ForegroundColor Yellow
    Write-Host '    Fill it in and re-run, or pass -WlsPassword.' -ForegroundColor Yellow
    Write-Host ''
    Die 'sem senha do WebLogic / no WebLogic password'
}

# ---------------------------------------------------------------------- deploy
Write-Step 'Deploy'

# Este proprio arquivo roda por scriptblock vindo da web, o que nao esbarra na
# ExecutionPolicy -- mas invocar um .ps1 DE ARQUIVO esbarra. Liberamos so no
# escopo do processo: nao persiste, nao exige Administrador, morre com a janela.
# This file runs as a scriptblock from the web, which bypasses ExecutionPolicy --
# but invoking a .ps1 FILE does not. Relax it for this process only: it does not
# persist, needs no elevation, and dies with the window.
# Best-effort: ajuda quem depois quiser rodar o .ps1 direto nesta mesma janela.
# Nao dependemos disso -- Group Policy pode vetar ate o escopo de processo.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch { }

$argumentos = @{
    TargetDir   = $TargetDir
    MachineName = $MachineName
    From        = $From
    ConfigFile  = $cfgFile      # sempre explicito: aqui nao ha $PSScriptRoot
}
if ($FolderUrl)    { $argumentos.FolderUrl    = $FolderUrl }
if ($WlsPassword)  { $argumentos.WlsPassword  = $WlsPassword }
if ($AppsPassword) { $argumentos.AppsPassword = $AppsPassword }
if ($SgaGb -gt 0)  { $argumentos.SgaGb        = $SgaGb }
if ($KeepFs2)      { $argumentos.KeepFs2      = $true }

# SEMPRE por scriptblock, nunca invocando o arquivo.
#
# A ExecutionPolicy se aplica a ARQUIVOS de script, nao a codigo ja em memoria
# -- e a mesma razao pela qual este bootstrap roda vindo do "irm". Carregar o
# conteudo e criar um scriptblock funciona sob qualquer politica, inclusive
# Restricted imposta por Group Policy, sem alterar nada na maquina.
#
# Tentar invocar o arquivo e cair num catch de PSSecurityException tambem
# funcionaria na maioria dos casos, mas depende de a excecao ser capturavel
# naquele ponto. Este caminho nao tem essa duvida.
Write-Host '    carregando Deploy-R12.ps1 em memoria (contorna a ExecutionPolicy)'
& ([scriptblock]::Create([IO.File]::ReadAllText($deploy))) @argumentos
