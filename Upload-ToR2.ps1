<#
.SYNOPSIS
    Envia o pacote do EBS para um bucket Cloudflare R2 usando rclone.
    Uploads the EBS package to a Cloudflare R2 bucket using rclone.

.DESCRIPTION
    Por que rclone e nao a interface web: o painel do Cloudflare recusa
    arquivos acima de ~300 MB ("Use the S3 Compatibility API or Workers to
    upload larger files"). O rclone fala a API S3 nativamente, faz upload
    multipart e retoma de onde parou.

    Why rclone and not the web UI: the Cloudflare dashboard rejects files
    over ~300 MB. rclone speaks the S3 API natively, does multipart uploads
    and resumes where it left off.

    SUAS CREDENCIAIS FICAM SO NA SUA MAQUINA. Este script nunca as recebe
    como parametro nem as grava em lugar nenhum -- quem as guarda e o
    proprio rclone, no rclone.conf. Passar token em linha de comando
    deixaria rastro no historico do PowerShell.
    YOUR CREDENTIALS STAY ON YOUR MACHINE. This script never takes them as
    parameters. rclone holds them in rclone.conf.

.PARAMETER SourceDir
    Pasta com as partes e o manifest.txt (a saida do Split-Package.ps1).

.PARAMETER Bucket
    Nome do bucket no R2.

.PARAMETER Remote
    Nome do remote configurado no rclone. Padrao: r2.

.PARAMETER ChunkSizeMB
    Tamanho do pedaco no upload multipart. Maior = menos operacoes Class A.
    Padrao 64 MB: 58 GB viram ~930 operacoes, contra 1 milhao gratuitas/mes.

.EXAMPLE
    .\Upload-ToR2.ps1 -SourceDir 'D:\upload' -Bucket ebs-r12

.NOTES
    Custo aproximado para 58 GB no R2: ~US$ 0,72/mes de armazenamento
    (10 GB sao gratuitos) e ZERO de egress -- e por isso que o R2 serve aqui
    e o Google Drive nao: la a cota de download por arquivo publico
    interrompe a transferencia no meio.
#>

[CmdletBinding()]
param(
    [string]$SourceDir   = 'D:\upload',
    [Parameter(Mandatory)][string]$Bucket,
    [string]$Remote      = 'r2',
    [int]$ChunkSizeMB    = 64,
    [int]$Transfers      = 4,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "    $m" }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Die        { param([string]$m) Write-Host "`nERRO: $m" -ForegroundColor Red; throw $m }

function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command } catch { } finally { $ErrorActionPreference = $old }
}

Write-Host "`n=== rclone ===" -ForegroundColor Cyan
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info 'instalando via winget'
        Invoke-Native { & winget install --id Rclone.Rclone --silent --accept-package-agreements --accept-source-agreements }
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Die 'rclone ausente. Instale: winget install Rclone.Rclone  (e abra um PowerShell novo)'
    }
}
Write-Info (Invoke-Native { & rclone version } | Select-Object -First 1)

Write-Host "`n=== remote '$Remote' ===" -ForegroundColor Cyan
$remotes = @(Invoke-Native { & rclone listremotes })
if ($remotes -notcontains "${Remote}:") {
    Write-Host @"

    O remote '$Remote' ainda nao existe. Rode:

        rclone config

    e responda:
        n                     (novo remote)
        $Remote                    (nome)
        s3                    (tipo: Amazon S3 Compliant...)
        Cloudflare            (provider)
        1                     (entrar as credenciais)
        <Access Key ID>       do token R2 que voce criar no painel
        <Secret Access Key>   idem
        <enter>               (region: deixe em branco / auto)
        https://<ACCOUNT_ID>.r2.cloudflarestorage.com    (endpoint)
        <enter> ate o fim, confirme com  y  e saia com  q

    O Access Key/Secret saem de: painel Cloudflare -> R2 -> "Manage API tokens"
    -> Create API token -> permissao "Object Read & Write".
    O ACCOUNT_ID aparece na propria pagina do R2.

    Depois rode este script de novo.

"@ -ForegroundColor Yellow
    Die "remote '$Remote' nao configurado"
}
Write-Ok "remote '$Remote' encontrado"

if (-not (Test-Path $SourceDir)) { Die "pasta nao encontrada: $SourceDir" }
$arquivos = @(Get-ChildItem $SourceDir -File)
if (-not $arquivos) { Die "nada para enviar em $SourceDir" }
$totalGb = [math]::Round((($arquivos | Measure-Object Length -Sum).Sum)/1GB, 2)

Write-Host "`n=== origem ===" -ForegroundColor Cyan
Write-Info "$SourceDir -- $($arquivos.Count) arquivos, $totalGb GB"
if (-not ($arquivos.Name -contains 'manifest.txt')) {
    Write-Host '    AVISO: sem manifest.txt -- o deploy nao tera SHA-256 para conferir' -ForegroundColor Yellow
}

if ($VerifyOnly) {
    Write-Host "`n=== conferindo o que ja esta no bucket ===" -ForegroundColor Cyan
    Invoke-Native { & rclone check $SourceDir "${Remote}:$Bucket" --size-only }
    return
}

Write-Host "`n=== enviando ===" -ForegroundColor Cyan
Write-Info "destino : ${Remote}:$Bucket"
Write-Info "pedacos : ${ChunkSizeMB} MB, $Transfers em paralelo"
Write-Info 'seguro reexecutar: o rclone pula o que ja esta la e retoma o resto'
Write-Host ''

Invoke-Native {
    & rclone copy $SourceDir "${Remote}:$Bucket" `
        --s3-chunk-size "${ChunkSizeMB}M" `
        --s3-upload-cutoff "${ChunkSizeMB}M" `
        --transfers $Transfers `
        --progress `
        --stats-one-line `
        --retries 5 `
        --low-level-retries 20
}
if ($LASTEXITCODE -ne 0) { Die "rclone copy terminou com codigo $LASTEXITCODE" }

Write-Host "`n=== conferindo ===" -ForegroundColor Cyan
Invoke-Native { & rclone check $SourceDir "${Remote}:$Bucket" --size-only }
if ($LASTEXITCODE -ne 0) {
    Write-Host '    divergencias encontradas -- rode de novo para completar' -ForegroundColor Yellow
} else {
    Write-Ok 'tudo enviado e conferido por tamanho'
}

Write-Host "`n=== conteudo do bucket ===" -ForegroundColor Cyan
Invoke-Native { & rclone ls "${Remote}:$Bucket" } | ForEach-Object { Write-Host "    $_" }

Write-Host @"

  Proximo passo: exponha o bucket para leitura e me passe a URL base.

  Opcao A -- bucket publico (mais simples):
      painel R2 -> seu bucket -> Settings -> Public access
      -> "Allow Access" no r2.dev, ou conecte um dominio proprio.
      A URL base fica tipo  https://pub-<hash>.r2.dev

  Opcao B -- URLs pre-assinadas (mais restrito, expira em ate 7 dias):
      rclone link ${Remote}:$Bucket/<arquivo> --expire 168h

  Com a URL base, a fase Download do Deploy-R12.ps1 vira um
  "curl -C -" por parte: retomavel de verdade e sem cota.

"@ -ForegroundColor White
