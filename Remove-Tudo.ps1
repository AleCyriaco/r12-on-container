<#
.SYNOPSIS
    Desfaz o deploy inteiro: servicos, container, maquina Podman, disco
    virtual, pacote baixado, pasta da instancia e o que o deploy escreveu
    no Windows. Nao sobra rastro.
    Undoes the whole deployment -- services, container, Podman machine,
    virtual disk, downloaded package, instance folder and whatever the
    deploy wrote on Windows. Nothing is left behind.

.DESCRIPTION
    E o inverso do Deploy-R12.ps1 e mostra o andamento do mesmo jeito:
    "passo N/X" mais uma barra de 0 a 100%. O plano sai do que REALMENTE
    existe nesta maquina -- o que nao existe nao vira passo, entao a
    contagem fecha certo mesmo numa maquina onde metade ja foi removida
    a mao.

    Para remover SO o /u01 extraido, preservando a maquina e os 59 GB do
    pacote baixado, use o Remove-Instancia.ps1 -SomenteInstancia. Este
    aqui e o botao vermelho: leva tudo.
    To remove ONLY the extracted /u01, keeping the machine and the 59 GB
    package, use Remove-Instancia.ps1 -SomenteInstancia. This one is the
    red button: it takes everything.

    A ordem importa, e nenhuma parte dela e obvia:

      1. parar os servicos     -- para o banco fechar limpo
      2. parar a maquina
      3. remover a maquina     -- leva o disco virtual e o pacote junto
      4. limpar registro orfao -- se o podman e o WSL sairem de sincronia
      5. apagar a pasta        -- o "podman machine rm" NAO faz isso
      6. limpar o hosts        -- so a linha que o deploy escreveu

    Pular o passo 5 e o erro mais comum: apagar so a pasta deixa a maquina
    registrada apontando para um disco que nao existe mais, e o proximo
    deploy morre com "Failed to attach disk ... ERROR_PATH_NOT_FOUND".

    Skipping step 5 is the common mistake: deleting only the folder leaves
    the machine registered against a disk that no longer exists, and the
    next deploy dies with "Failed to attach disk ... ERROR_PATH_NOT_FOUND".

    Roda direto da web, sem clone, igual ao bootstrap:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/Remove-Tudo.ps1)))

.PARAMETER TargetDir
    Pasta da instancia. Quando omitido, e descoberto pelo registro do WSL:
    a distro "podman-<maquina>" guarda onde o disco virtual mora.
    Instance folder. When omitted, discovered from the WSL registration.

.PARAMETER ManterHosts
    Nao mexe no hosts do Windows.

.PARAMETER RestaurarWslConfig
    Restaura o %USERPROFILE%\.wslconfig a partir do .bak que o deploy
    deixou. Fora do padrao de proposito: se voce criou outras distros WSL
    depois do deploy, elas passaram a depender do limite de memoria que
    esta la.
    Off by default on purpose: other WSL distros may depend on it now.

.PARAMETER RemoverRepo
    Apaga tambem o clone do repositorio (-CheckoutDir).

.PARAMETER Force
    Nao pergunta antes de remover. Para automacao -- em uso normal, deixe
    o script perguntar.

.EXAMPLE
    .\Remove-Tudo.ps1

.EXAMPLE
    # tudo, inclusive o clone do repositorio, sem perguntar
    .\Remove-Tudo.ps1 -RemoverRepo -Force

.NOTES
    NADA e alterado antes da confirmacao: a descoberta e o plano so olham.
    E a confirmacao nao "falha aberta" -- sem um console para responder, o
    script para em vez de assumir que pode apagar. Isso nao e paranoia
    gratuita: com a entrada padrao redirecionada (um "< NUL", um pipe, uma
    tarefa agendada) o Read-Host devolve $null sem sequer mostrar a
    pergunta, e a comparacao ingenua com $null nao entra no ramo de
    cancelamento. Custou uma instancia extraida para aprender.

    NOTHING changes before confirmation, and the confirmation never fails
    open: with no console to answer, the script stops instead of assuming
    consent. With stdin redirected, Read-Host returns $null without even
    showing the prompt, and the naive comparison against $null skips the
    cancel branch. That cost one extracted instance to learn.
#>

[CmdletBinding()]
param(
    [string]$MachineName = 'ebs',
    [string]$TargetDir,
    [string]$AppsHost    = 'apps.example.com',
    [string]$WlsPassword = 'welcome1',
    [string]$CheckoutDir = 'C:\r12-on-container',
    [switch]$ManterHosts,
    [switch]$RestaurarWslConfig,
    [switch]$RemoverRepo,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Fase { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-W    { param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
# throw, nunca "exit": este script tambem roda como scriptblock vindo da web,
# e "exit" fecharia a janela do PowerShell levando a mensagem junto.
# throw, never "exit": loaded from the web as a scriptblock, "exit" would
# close the window and take the message with it.
function Die        { param([string]$m) Write-Host "`nERRO: $m" -ForegroundColor Red; throw "remocao interrompida: $m" }

# Executa um comando nativo sem o efeito colateral do PowerShell 5.1: sob
# ErrorActionPreference=Stop, cada linha de stderr de um executavel nativo vira
# excecao terminante. O try/catch NAO e redundante com a troca de preferencia
# -- e o que realmente segura, porque o scriptblock nao enxerga a mudanca.
# Runs a native command without the PS 5.1 side effect where stderr lines
# become terminating errors. The try/catch is the part that actually works.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Command)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Command } catch { } finally { $ErrorActionPreference = $old }
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

# ------------------------------------------------------------------- progresso
#
# Mesmo par de indicadores do Deploy-R12.ps1, pelo mesmo motivo: "passo N/X"
# diz onde estamos na lista, a porcentagem diz quanto do trabalho ja foi, e os
# dois nao sao a mesma coisa quando os passos duram tempos diferentes. Aqui a
# diferenca e menor que no deploy -- nada leva horas -- mas apagar centenas de
# GB ainda pesa mais que desregistrar uma distro.
#
# O codigo e irmao do que esta no Deploy-R12.ps1 e nao foi fatorado para um
# modulo comum de proposito: os dois precisam rodar SOZINHOS, carregados de uma
# URL por scriptblock, sem nenhum arquivo ao lado.
# Deliberately duplicated from Deploy-R12.ps1: both must run ALONE, loaded from
# a URL as a scriptblock, with no companion file to import.
$script:Plano       = New-Object Collections.Generic.List[object]
$script:Idx         = -1
$script:PesoFeito   = 0.0
$script:UltimaLinha = ''
# A pasta da instancia e um dos alvos, entao o arquivo de status mora no TEMP:
# gravar dentro do que estamos apagando nao faz sentido.
# The instance folder is one of the targets, so the status file lives in TEMP.
$script:StatusFile  = Join-Path $env:TEMP 'r12-remocao-progresso.json'

function Add-Passo {
    param([string]$Id, [string]$Nome, [double]$Peso = 1)
    $script:Plano.Add([pscustomobject]@{ Id = $Id; Nome = $Nome; Peso = [double]$Peso; Feito = $false })
}

function Get-PassoIdx {
    param([string]$Id)
    for ($k = 0; $k -lt $script:Plano.Count; $k++) {
        if ($script:Plano[$k].Id -eq $Id) { return $k }
    }
    return -1
}

function Get-Pct {
    $total = 0.0
    foreach ($p in $script:Plano) { $total += $p.Peso }
    if ($total -le 0) { return 0 }
    $frac = $script:PesoFeito / $total
    if ($frac -gt 1) { $frac = 1 }
    return [int][math]::Floor(100 * $frac)
}

function Save-Progresso {
    param([int]$Pct, [int]$Passo, [int]$Total, [string]$Nome)
    try {
        ([pscustomobject]@{
            pct = $Pct; passo = $Passo; total = $Total; nome = $Nome
            quando = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:StatusFile -Encoding UTF8
    } catch { }   # status e conveniencia: nunca derrubar a remocao por causa dele
}

function Write-Status {
    if ($script:Idx -lt 0) { return }
    $p     = $script:Plano[$script:Idx]
    $pct   = Get-Pct
    $n     = $script:Idx + 1
    $tot   = $script:Plano.Count
    $cheio = [int][math]::Round($pct / 4.0)
    if ($cheio -gt 25) { $cheio = 25 }
    $barra = ('#' * $cheio) + ('.' * (25 - $cheio))
    $linha = '  [ passo {0}/{1} ]  [{2,3}% ] [{3}]  {4}' -f $n, $tot, $pct, $barra, $p.Nome
    if ($linha -eq $script:UltimaLinha) { return }
    $script:UltimaLinha = $linha
    Write-Host $linha -ForegroundColor Cyan
    Save-Progresso -Pct $pct -Passo $n -Total $tot -Nome $p.Nome
}

function Start-Passo {
    param([string]$Id)
    $i = Get-PassoIdx $Id
    if ($i -lt 0) { return }
    # fecha o que ficou para tras: um passo pode ser pulado (nada a remover) e
    # sem isto o peso dele ficaria preso e a barra nunca chegaria a 100
    # closes anything skipped, so no weight stays stuck and the bar reaches 100
    for ($k = 0; $k -lt $i; $k++) {
        if (-not $script:Plano[$k].Feito) {
            $script:PesoFeito += $script:Plano[$k].Peso
            $script:Plano[$k].Feito = $true
        }
    }
    $script:Idx = $i
    Write-Status
}

function Complete-Passo {
    param([string]$Id)
    $i = $script:Idx
    if ($Id) { $i = Get-PassoIdx $Id }
    if ($i -lt 0) { return }
    for ($k = 0; $k -le $i; $k++) {
        if (-not $script:Plano[$k].Feito) {
            $script:PesoFeito += $script:Plano[$k].Peso
            $script:Plano[$k].Feito = $true
        }
    }
    $script:Idx = $i
    Write-Status
}

# ---------------------------------------------------------------------- inicio

Write-Host @"

  ============================================================
   Oracle EBS R12.2.12 on Podman / Windows -- remover TUDO
  ============================================================

"@ -ForegroundColor White

# ======================================================================
#  DESCOBERTA -- so olha, nao muda nada. O plano sai daqui.
#  DISCOVERY -- read-only. The plan comes from here.
# ======================================================================
Write-Fase 'O que existe / What is here'

$temPodman = [bool](Get-Command podman -ErrorAction SilentlyContinue)
$maquina   = $null
$rodando   = $false
if ($temPodman) {
    $maquina = @(Invoke-Native { & podman machine list --format '{{.Name}}' 2>$null }) |
               Where-Object { ($_ -replace '\*$','') -eq $MachineName }
    if ($maquina) {
        $rodando = [bool](@(Invoke-Native { & podman machine list --format '{{.Name}} {{.LastUp}}' 2>$null }) |
                          Where-Object { $_ -like "$MachineName*" -and $_ -like '*Currently running*' })
    }
}

# A distro do WSL e a fonte mais confiavel de ONDE o disco virtual mora: o
# registro guarda o BasePath, que e a pasta "vm" dentro da instancia. E como
# ela sobrevive a um "podman machine rm" pela metade, tambem e o que denuncia
# um registro orfao. Sem isso, uma remocao sem -TargetDir deixava para tras
# justamente a pasta com as centenas de GB.
# The WSL registration is the most reliable source for WHERE the virtual disk
# lives, and it also exposes a half-removed machine. Without it, a removal
# without -TargetDir left behind the very folder holding the hundreds of GB.
$distro    = "podman-$MachineName"
$temDistro = $false
$basePath  = $null
try {
    foreach ($k in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop) {
        $prop = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($prop.DistributionName -eq $distro) {
            $temDistro = $true
            $basePath  = $prop.BasePath -replace '^\\\\\?\\',''
        }
    }
} catch { }

if (-not $TargetDir -and $basePath -and (Split-Path $basePath -Leaf) -eq 'vm') {
    $TargetDir = Split-Path $basePath -Parent
    Write-Info "pasta descoberta pelo registro do WSL: $TargetDir"
}

$pastaExiste = ($TargetDir -and (Test-Path -LiteralPath $TargetDir))
$pastaGb     = 0
if ($pastaExiste) {
    try {
        $pastaGb = [math]::Round((Get-ChildItem -LiteralPath $TargetDir -Recurse -File -ErrorAction SilentlyContinue |
                                  Measure-Object Length -Sum).Sum / 1GB, 1)
    } catch { }
}

# A linha do hosts e casada EXATAMENTE como o deploy a escreve. Casar so pelo
# nome apagaria entradas alheias: uma maquina real pode ter
# "192.168.0.x apps.example.com" apontando para outro servidor, e essa nao e
# nossa para remover.
# The hosts line is matched EXACTLY as the deploy writes it: matching by name
# alone would delete entries that are not ours.
$hostsFile   = "$env:SystemRoot\System32\drivers\etc\hosts"
$rxHosts     = '^\s*127\.0\.0\.1\s+' + [regex]::Escape($AppsHost) + '\s*$'
$linhasHosts = @()
try { $linhasHosts = @(Get-Content -LiteralPath $hostsFile -ErrorAction Stop) } catch { }
$temHosts    = [bool](@($linhasHosts | Where-Object { $_ -match $rxHosts }).Count)

$wslCfg  = Join-Path $env:USERPROFILE '.wslconfig'
$temBak  = Test-Path -LiteralPath "$wslCfg.bak"
$temRepo = ($CheckoutDir -and (Test-Path -LiteralPath (Join-Path $CheckoutDir '.git')))

$nao = 'nao'
Write-Host ("    {0,-24} {1}" -f 'maquina podman', $(if ($maquina) { "$MachineName ($(if ($rodando) { 'rodando' } else { 'parada' }))" } else { $nao }))
Write-Host ("    {0,-24} {1}" -f 'distro WSL',     $(if ($temDistro) { "$distro em $basePath" } else { $nao }))
Write-Host ("    {0,-24} {1}" -f 'pasta',          $(if ($pastaExiste) { "$TargetDir ($pastaGb GB)" } elseif ($TargetDir) { "$TargetDir (nao existe)" } else { 'nao localizada' }))
Write-Host ("    {0,-24} {1}" -f 'linha no hosts', $(if ($temHosts) { "127.0.0.1 $AppsHost" } else { $nao }))
Write-Host ("    {0,-24} {1}" -f '.wslconfig.bak', $(if ($temBak) { 'sim' } else { $nao }))
Write-Host ("    {0,-24} {1}" -f 'clone do repo',  $(if ($temRepo) { $CheckoutDir } else { $nao }))

if (-not $maquina -and -not $temDistro -and -not $pastaExiste -and -not $temHosts) {
    Write-Host ''
    Write-Ok 'nada desta instancia foi encontrado nesta maquina -- nada a fazer'
    return
}

# ======================================================================
#  PLANO -- so entra quem existe
# ======================================================================
Write-Fase 'Plano'

if ($maquina) {
    Add-Passo -Id 'sv'      -Nome 'parar os servicos e o container'  -Peso 5
    Add-Passo -Id 'mc:stop' -Nome 'parar a maquina virtual'          -Peso 3
    Add-Passo -Id 'mc:rm'   -Nome 'remover a maquina (leva o disco)' -Peso 4
}
if ($temDistro)   { Add-Passo -Id 'wsl'   -Nome 'desregistrar a distro no WSL'          -Peso 3 }
if ($pastaExiste) { Add-Passo -Id 'dir'   -Nome "apagar $TargetDir ($pastaGb GB)"       -Peso 6 }
if ($temHosts -and -not $ManterHosts) {
                    Add-Passo -Id 'hosts' -Nome "remover 127.0.0.1 $AppsHost do hosts"  -Peso 1 }
if ($temBak -and $RestaurarWslConfig) {
                    Add-Passo -Id 'wslcfg' -Nome 'restaurar o .wslconfig do backup'     -Peso 1 }
if ($temRepo -and $RemoverRepo) {
                    Add-Passo -Id 'repo'  -Nome "apagar o clone em $CheckoutDir"        -Peso 1 }

if ($script:Plano.Count -eq 0) { Write-Ok 'nada a remover'; return }

Write-Host ''
$i = 0
foreach ($p in $script:Plano) { $i++; Write-Host ("    {0}. {1}" -f $i, $p.Nome) }
Write-Host ''
Write-Info "$($script:Plano.Count) passos"

# ======================================================================
#  CONFIRMACAO -- ultima parada antes de destruir. Nada acima daqui
#  alterou coisa alguma nesta maquina.
#  CONFIRMATION -- nothing above this point changed anything.
# ======================================================================
if (-not $Force) {
    # Sem console nao ha confirmacao possivel, e "ninguem respondeu" NAO pode
    # virar "pode apagar". Com a entrada redirecionada (um "< NUL", um pipe,
    # uma tarefa agendada) o Read-Host devolve $null na hora, sem nem mostrar
    # a pergunta -- e uma comparacao ingenua com $null deixa passar.
    # No console means no possible confirmation, and "nobody answered" must
    # never become "go ahead".
    if ([Console]::IsInputRedirected) {
        Write-W 'a entrada padrao nao e um console: nao ha como confirmar.'
        Write-W 'rode num terminal de verdade, ou passe -Force se e isso mesmo que voce quer.'
        Die 'confirmacao impossivel sem console'
    }

    Write-Host ''
    Write-W 'isso apaga a instancia, o banco, o /u01, o pacote de 59 GB e o disco virtual.'
    Write-W 'nao ha volta: o pacote tera de ser baixado de novo num proximo deploy.'
    # As aspas em "$r" nao sao enfeite: com resposta nula, a comparacao sem
    # aspas pode nao devolver booleano e o ramo de cancelamento nao roda.
    # The quotes around "$r" are not cosmetic: with a null answer, the unquoted
    # comparison may not yield a boolean and the cancel branch never runs.
    $r = Read-Host "    digite o nome da maquina ($MachineName) para confirmar"
    if ("$r".Trim() -ne $MachineName) { Write-Info 'cancelado -- nada foi alterado'; return }
}

# ======================================================================
#  EXECUCAO
# ======================================================================
Write-Fase 'Removendo'

if ($maquina) {
    Start-Passo 'sv'
    if ($rodando) {
        # Best-effort: se a instancia ja estiver quebrada isso falha, e tudo bem
        # -- o objetivo e so dar ao banco a chance de fechar limpo antes de o
        # disco virtual desaparecer debaixo dele.
        # Best-effort: the point is only to give the database a chance to close
        # cleanly before its disk vanishes underneath it.
        $parar = "podman stop -t 60 ebs >/dev/null 2>&1; podman stop -t 30 fmwdb >/dev/null 2>&1; echo 'containers parados'"
        if ($TargetDir) {
            $sh = ConvertTo-WslPath (Join-Path $TargetDir 'scripts\parar-ebs.sh')
            $parar = "if [ -f $sh ]; then WLS_PASSWORD='$WlsPassword' bash $sh 2>&1 | tail -3; else $parar; fi"
        }
        Invoke-Native { & podman machine ssh $MachineName $parar } |
            Select-Object -Last 3 | ForEach-Object { Write-Info $_ }
    } else {
        Write-Info 'a maquina ja estava parada -- nada a desligar'
    }
    Complete-Passo 'sv'

    Start-Passo 'mc:stop'
    Invoke-Native { & cmd /c "podman machine stop $MachineName 2>&1" } | ForEach-Object { Write-Info $_ }
    Complete-Passo 'mc:stop'

    Start-Passo 'mc:rm'
    Invoke-Native { & cmd /c "podman machine rm -f $MachineName 2>&1" } | ForEach-Object { Write-Info $_ }
    Complete-Passo 'mc:rm'
}

# Registro orfao no WSL. Conferir de novo aqui, e nao so na descoberta: o
# "machine rm" acima costuma levar a distro junto, e desregistrar duas vezes
# suja a tela com erro a toa.
# Re-check here and not only at discovery: "machine rm" usually takes the
# distro with it, and unregistering twice just prints a pointless error.
if ($temDistro) {
    Start-Passo 'wsl'
    $aindaTem = @(Invoke-Native { & wsl.exe -l -q } |
                  ForEach-Object { ($_ -replace "`0",'').Trim() }) -contains $distro
    if ($aindaTem) {
        Invoke-Native { & wsl.exe --unregister $distro } | ForEach-Object { Write-Info $_ }
    } else {
        Write-Info 'a distro ja saiu junto com a maquina'
    }
    Complete-Passo 'wsl'
}

if ($pastaExiste) {
    Start-Passo 'dir'
    # Trava: so apaga o que TEM CARA de pasta de instancia. Um -TargetDir
    # digitado errado (ou a raiz de um drive) apagaria muito mais do que o
    # deploy criou, e para isso nao ha desfazer.
    # Interlock: only delete something that LOOKS like an instance folder. A
    # mistyped -TargetDir (or a drive root) would take far more than the deploy
    # ever created, and there is no undo for that.
    $full  = [IO.Path]::GetFullPath($TargetDir)
    $raiz  = [IO.Path]::GetPathRoot($full)
    $marca = @('vm','logs','scripts','pkg') | Where-Object { Test-Path (Join-Path $full $_) }
    if ($full -eq $raiz -or ($full.TrimEnd('\') -split '\\').Count -lt 2) {
        Write-W "recusando apagar '$full': e a raiz de um drive. Apague na mao se for mesmo isso."
    } elseif (-not $marca) {
        Write-W "recusando apagar '$full': nao parece pasta de instancia (sem vm/logs/scripts/pkg)."
        Write-W 'apague na mao se for mesmo o que voce quer.'
    } else {
        try {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
            Write-Ok "removido ($pastaGb GB liberados)"
        } catch {
            # O vhdx fica travado enquanto a VM utilitaria do WSL estiver viva
            # (ERROR_SHARING_VIOLATION). Derrubar o WSL inteiro e o unico jeito,
            # e por isso nao e a primeira tentativa: para as outras distros junto.
            # The vhdx stays locked while the WSL utility VM is alive; tearing
            # WSL down is the only fix, which is why it is not the first try.
            Write-W 'a pasta esta travada -- derrubando o WSL para soltar o disco'
            Write-W '(outras distros WSL desta maquina tambem param)'
            & wsl --shutdown
            Start-Sleep -Seconds 5
            try {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                Write-Ok "removido ($pastaGb GB liberados)"
            } catch {
                Write-W "nao consegui apagar $full : $($_.Exception.Message)"
                Write-W 'reinicie o Windows e apague a pasta na mao.'
            }
        }
    }
    Complete-Passo 'dir'
}

if ($temHosts -and -not $ManterHosts) {
    Start-Passo 'hosts'
    if (Test-Admin) {
        try {
            Copy-Item -LiteralPath $hostsFile -Destination "$hostsFile.r12.bak" -Force
            $mantidas = @($linhasHosts | Where-Object { $_ -notmatch $rxHosts })
            [IO.File]::WriteAllLines($hostsFile, $mantidas, (New-Object Text.UTF8Encoding($false)))
            Write-Ok "removida a linha '127.0.0.1 $AppsHost' (backup em hosts.r12.bak)"
            # Entradas do mesmo nome que NAO sao do deploy ficam, e o script diz
            # quais -- silenciar isso e o que faria alguem achar que sumiram.
            $outras = @($linhasHosts | Where-Object { $_ -match [regex]::Escape($AppsHost) -and $_ -notmatch $rxHosts })
            foreach ($o in $outras) { Write-Info "mantida (nao e do deploy): $($o.Trim())" }
        } catch {
            Write-W "nao consegui editar o hosts: $($_.Exception.Message)"
        }
    } else {
        Write-W 'sem privilegio para editar o hosts. Rode como Administrador:'
        Write-Host "      (Get-Content '$hostsFile') | Where-Object { `$_ -notmatch '$rxHosts' } | Set-Content '$hostsFile'" -ForegroundColor Yellow
    }
    Complete-Passo 'hosts'
}

if ($temBak -and $RestaurarWslConfig) {
    Start-Passo 'wslcfg'
    try {
        Move-Item -LiteralPath "$wslCfg.bak" -Destination $wslCfg -Force
        Write-Ok "restaurado $wslCfg"
    } catch {
        Write-W "nao consegui restaurar o .wslconfig: $($_.Exception.Message)"
    }
    Complete-Passo 'wslcfg'
}

if ($temRepo -and $RemoverRepo) {
    Start-Passo 'repo'
    try {
        Remove-Item -LiteralPath $CheckoutDir -Recurse -Force -ErrorAction Stop
        Write-Ok "removido $CheckoutDir"
    } catch {
        # Acontece quando a propria sessao do PowerShell esta DENTRO da pasta.
        # Nao vale automatizar: e um "cd \".
        Write-W "nao consegui apagar $CheckoutDir : $($_.Exception.Message)"
        Write-W 'saia da pasta (cd \) e apague na mao.'
    }
    Complete-Passo 'repo'
}

# ======================================================================
#  ESTADO FINAL
# ======================================================================
Write-Fase 'Estado final'
if ($temPodman) {
    Invoke-Native { & podman machine list } | ForEach-Object { Write-Host "    $_" }
}
if ($temHosts -and -not $ManterHosts -and -not (Test-Admin)) {
    Write-W 'a linha do hosts continua la (faltou Administrador)'
}
if ($temBak -and -not $RestaurarWslConfig) {
    Write-Info "o deploy deixou $wslCfg.bak -- use -RestaurarWslConfig para o original de volta"
}
if ($temRepo -and -not $RemoverRepo) {
    Write-Info "o clone em $CheckoutDir foi mantido -- use -RemoverRepo para apagar tambem"
}
Write-Host ''
Write-Ok ("remocao concluida: {0} passos, 100%" -f $script:Plano.Count)
