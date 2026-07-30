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

.PARAMETER BaseUrl
    RECOMENDADO. URL base de um bucket/host HTTP com as partes e o
    manifest.txt (Cloudflare R2, S3, qualquer servidor com Range).
    RECOMMENDED. Base URL of an HTTP bucket/host with the parts and manifest.

.PARAMETER FolderUrl
    Alternativa: pasta publica do Drive. Sujeita a cota de download.
    Alternative: public Drive folder. Subject to download quota.

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
    [string]$BaseUrl,
    [string]$FolderUrl,
    # Padrao do pacote de referencia; sobrescreva se a sua instancia usa outra.
    [string]$WlsPassword = 'welcome1',
    [string]$AppsPassword,
    [string]$CheckoutDir = 'C:\r12-on-container',
    # Sem padrao: cada maquina tem um setup de discos diferente. Omitido, o
    # Deploy-R12.ps1 escolhe o drive com mais espaco livre.
    # No default: every machine has a different disk layout. When omitted,
    # Deploy-R12.ps1 picks the drive with the most free space.
    [string]$TargetDir,
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

# git, winget e afins escrevem progresso em STDERR. No PowerShell 5.1, com
# ErrorActionPreference=Stop, cada linha de stderr de um executavel nativo
# vira um ErrorRecord terminante -- e um "Cloning into ..." perfeitamente
# normal derruba o script. Rodar essas chamadas por aqui isola o efeito.
# git, winget and friends write progress to STDERR. In PowerShell 5.1 with
# ErrorActionPreference=Stop, every stderr line from a native executable
# becomes a terminating ErrorRecord -- a perfectly normal "Cloning into ..."
# kills the script. Running those calls through here contains it.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command } catch { } finally { $ErrorActionPreference = $old }
}

function Write-Step { param([string]$m) Write-Host "`n>>> $m" -ForegroundColor Cyan }
# throw, nunca "exit": este script roda como scriptblock direto no console --
# "exit" fecharia a janela do PowerShell levando a mensagem de erro junto.
# throw, never "exit": this runs as a scriptblock right in the console --
# "exit" would close the PowerShell window taking the error message with it.
function Die        { param([string]$m) Write-Host "`nERRO / ERROR: $m" -ForegroundColor Red; throw "bootstrap interrompido: $m" }

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
    Invoke-Native { & winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements }
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
    Invoke-Native { & git -C $CheckoutDir fetch --depth 1 origin $Ref }
    Invoke-Native { & git -C $CheckoutDir reset --hard "origin/$Ref" }
    if ($LASTEXITCODE -ne 0) { Die "falha ao atualizar / update failed: $CheckoutDir" }
} else {
    Write-Host "    clonando em / cloning into $CheckoutDir"
    Invoke-Native { & git clone --depth 1 --branch $Ref $RepoUrl $CheckoutDir }
    if ($LASTEXITCODE -ne 0) { Die "falha no clone / clone failed: $RepoUrl" }
}

$deploy = Join-Path $CheckoutDir 'Deploy-R12.ps1'
if (-not (Test-Path $deploy)) { Die "nao achei / not found: $deploy" }

# ---------------------------------------------------------------------- config
# A senha do WebLogic tem padrao (o do pacote de referencia). O config.psd1
# local, quando existe, sobrescreve parametros -- e o lugar certo para
# credenciais proprias, ja que passar em linha de comando deixa rastro no
# historico do PowerShell.
# The WebLogic password has a default (the reference package's). A local
# config.psd1, when present, overrides parameters -- the right place for your
# own credentials, since the command line leaks into PowerShell history.
$cfgFile = Join-Path $CheckoutDir 'config.psd1'

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
    MachineName = $MachineName
    From        = $From
    ConfigFile  = $cfgFile      # sempre explicito: aqui nao ha $PSScriptRoot
}
# So repassa o TargetDir se foi realmente informado: passar vazio faria o
# Deploy-R12.ps1 pensar que houve escolha explicita e pular a selecao de disco.
if ($TargetDir)    { $argumentos.TargetDir    = $TargetDir }
if ($BaseUrl)      { $argumentos.BaseUrl      = $BaseUrl }
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
