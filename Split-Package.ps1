<#
.SYNOPSIS
    Divide o pacote do EBS em partes menores para subir no Google Drive,
    gerando um manifesto com SHA-256 de cada parte.

.DESCRIPTION
    O Deploy-R12.ps1 baixa as partes, confere o SHA-256 de cada uma contra o
    manifesto e reassembla por streaming (cat partes | zstd -dc | tar -x), sem
    nunca gravar o arquivo de 58 GB inteiro na VM.

    O que dividir resolve:
      - cota de download por arquivo publico do Drive (cada parte tem a sua)
      - retomada de verdade: uma parte ruim custa o tamanho dela, nao 58 GB
      - upload menos sujeito a queda no meio

    O que NAO resolve:
      - a cota de ARMAZENAMENTO da conta. 58 GB sao 58 GB, divididos ou nao.

.PARAMETER SourceFile
    O .tar.zst a dividir. Ex: \\servidor\share\u01-r12-lad-brasil.tar.zst

.PARAMETER OutDir
    Onde gravar as partes e o manifesto. Precisa do mesmo espaco do original.

.PARAMETER PartSizeGB
    Tamanho de cada parte. Padrao 5 GB (58 GB viram 12 partes).

.PARAMETER ExtraFile
    Arquivo pequeno para apenas registrar no manifesto, sem dividir.
    Use para a imagem do container.

.EXAMPLE
    .\Split-Package.ps1 `
        -SourceFile '\\servidor\share\u01-r12-lad-brasil.tar.zst' `
        -ExtraFile  '\\servidor\share\ebs-image-ol7-cll-ok.tar.zst' `
        -OutDir     'D:\upload'

    Depois suba TODO o conteudo de D:\upload para uma pasta do Drive e
    compartilhe como "Qualquer pessoa com o link".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceFile,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$PartSizeGB = 5,
    [string]$ExtraFile
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "    $m" }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }

if (-not (Test-Path $SourceFile)) { throw "arquivo nao encontrado: $SourceFile" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$src      = Get-Item -LiteralPath $SourceFile
$baseName = $src.Name
$partSize = [int64]$PartSizeGB * 1GB
$nParts   = [math]::Ceiling($src.Length / $partSize)

# espaco no destino
$outDrive = (Get-Item $OutDir).PSDrive.Name + ':'
$free     = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$outDrive'").FreeSpace
if ($free -lt $src.Length) {
    throw ("espaco insuficiente em {0}: {1} GB livres, precisa de {2} GB" -f `
           $outDrive, [math]::Round($free/1GB,1), [math]::Round($src.Length/1GB,1))
}

Write-Host "`n=== dividindo ===" -ForegroundColor Cyan
Write-Info "origem  : $($src.FullName)"
Write-Info "tamanho : $([math]::Round($src.Length/1GB,2)) GB"
Write-Info "partes  : $nParts de $PartSizeGB GB"
Write-Info "destino : $OutDir"
Write-Host ''

$sha256Total = [Security.Cryptography.IncrementalHash]::CreateHash(
                   [Security.Cryptography.HashAlgorithmName]::SHA256)
$manifest = New-Object Collections.Generic.List[string]
$bufSize  = 64MB
$buffer   = New-Object byte[] $bufSize
$sw       = [Diagnostics.Stopwatch]::StartNew()

$in = [IO.File]::OpenRead($src.FullName)
try {
    for ($i = 0; $i -lt $nParts; $i++) {
        $partName = '{0}.part{1:D3}' -f $baseName, $i
        $partPath = Join-Path $OutDir $partName
        $written  = [int64]0

        $shaPart = [Security.Cryptography.IncrementalHash]::CreateHash(
                       [Security.Cryptography.HashAlgorithmName]::SHA256)
        $out = [IO.File]::Create($partPath)
        try {
            while ($written -lt $partSize) {
                $want = [int][math]::Min([int64]$bufSize, $partSize - $written)
                $read = $in.Read($buffer, 0, $want)
                if ($read -le 0) { break }
                $out.Write($buffer, 0, $read)
                $shaPart.AppendData($buffer, 0, $read)
                $sha256Total.AppendData($buffer, 0, $read)
                $written += $read
            }
        } finally { $out.Dispose() }

        $hash = [BitConverter]::ToString($shaPart.GetHashAndReset()).Replace('-','').ToLower()
        $manifest.Add("PART $partName $written $hash")

        $pct = [math]::Round((($i+1) / $nParts) * 100)
        Write-Info ("{0}  {1,8:N2} GB  {2}  [{3}%]" -f `
                    $partName, ($written/1GB), $hash.Substring(0,16), $pct)
    }
} finally { $in.Dispose() }

$totalHash = [BitConverter]::ToString($sha256Total.GetHashAndReset()).Replace('-','').ToLower()
$sw.Stop()

# manifesto: formato de linha simples, para o bash da VM ler com awk
$lines = New-Object Collections.Generic.List[string]
$lines.Add('# manifesto do pacote EBS R12.2.12 + LAD Brasil')
$lines.Add('# gerado por Split-Package.ps1')
$lines.Add("FILE $baseName $($src.Length) $totalHash")
$manifest | ForEach-Object { $lines.Add($_) }

if ($ExtraFile) {
    if (-not (Test-Path $ExtraFile)) { throw "arquivo extra nao encontrado: $ExtraFile" }
    $ex = Get-Item -LiteralPath $ExtraFile
    Write-Host ''
    Write-Info "copiando o extra: $($ex.Name)"
    Copy-Item -LiteralPath $ex.FullName -Destination (Join-Path $OutDir $ex.Name) -Force
    $exHash = (Get-FileHash -LiteralPath $ex.FullName -Algorithm SHA256).Hash.ToLower()
    $lines.Add("EXTRA $($ex.Name) $($ex.Length) $exHash")
    Write-Info "  $($ex.Name)  $([math]::Round($ex.Length/1GB,2)) GB  $($exHash.Substring(0,16))"
}

$manifestPath = Join-Path $OutDir 'manifest.txt'
[IO.File]::WriteAllLines($manifestPath, $lines, (New-Object Text.UTF8Encoding($false)))

Write-Host "`n=== pronto ===" -ForegroundColor Cyan
Write-Info "partes    : $nParts"
Write-Info "sha256    : $totalHash"
Write-Info "manifesto : $manifestPath"
Write-Info "tempo     : $([math]::Round($sw.Elapsed.TotalMinutes,1)) min"
Write-Host @"

  Proximo passo: suba TODO o conteudo de
      $OutDir
  para uma pasta do Google Drive e compartilhe como
      "Qualquer pessoa com o link" -> Leitor

  O manifest.txt precisa subir junto: o Deploy-R12.ps1 confere o SHA-256
  de cada parte contra ele antes de extrair.

"@ -ForegroundColor White
