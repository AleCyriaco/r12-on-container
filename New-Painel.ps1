<#
.SYNOPSIS
    Gera um painel local (painel.html) e atalhos .bat para operar a instancia.
    Generates a local dashboard (painel.html) and .bat shortcuts.

.DESCRIPTION
    O painel reune as credenciais com botao de copiar, atalhos para iniciar,
    parar e inspecionar o EBS, e um indicador de estado da aplicacao.

    POR QUE UM GERADOR, E NAO UM ARQUIVO PRONTO NO REPOSITORIO: o painel
    carrega TODAS as senhas em texto puro. Este repositorio e publico, entao
    o arquivo pronto nunca pode entrar nele. O gerador vive aqui; o painel
    preenchido nasce na sua maquina e e bloqueado pelo .gitignore.

    WHY A GENERATOR INSTEAD OF A READY FILE: the dashboard carries every
    password in plaintext. This repository is public, so the filled-in file
    must never land here. The generator lives in the repo; the dashboard is
    produced on your machine and is gitignored.

    O Deploy-R12.ps1 chama este script sozinho ao fim de um deploy bem
    sucedido, entao normalmente voce nao precisa roda-lo na mao.

.PARAMETER TargetDir
    Onde gravar painel.html e os .bat. Padrao: o diretorio da instancia.

.PARAMETER WlsPassword
    Senha do WebLogic. Sem ela os .bat de iniciar/parar nao funcionam.

.EXAMPLE
    .\New-Painel.ps1 -TargetDir 'C:\R12OnContainer' -WlsPassword 'xxx'
#>

[CmdletBinding()]
param(
    [string]$TargetDir    = 'C:\R12OnContainer',
    [string]$MachineName  = 'ebs',
    [string]$AppsHost     = 'apps.example.com',
    [string]$WlsPassword,
    [string]$AppsPassword = 'apps',
    [string]$SysadminPassword,
    [string]$SystemPassword,
    [string]$SysPassword,
    [string]$EbsSystemPassword,
    [string]$CllPassword,
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigFile) { $ConfigFile = Join-Path $TargetDir 'config.psd1' }
if (Test-Path $ConfigFile) {
    $cfg = Import-PowerShellDataFile -Path $ConfigFile
    foreach ($k in 'WlsPassword','AppsPassword','SysadminPassword','SystemPassword',
                   'SysPassword','EbsSystemPassword','CllPassword','AppsHost') {
        if (-not (Get-Variable $k -ValueOnly -ErrorAction SilentlyContinue) -and $cfg[$k]) {
            Set-Variable -Name $k -Value $cfg[$k]
        }
    }
}

# Valores do pacote de referencia. Servem de rotulo quando nao informados --
# se a sua instancia usa outros, passe por parametro ou pelo config.psd1.
if (-not $SysadminPassword)  { $SysadminPassword  = '(veja o README do seu pacote)' }
if (-not $SystemPassword)    { $SystemPassword    = '(veja o README do seu pacote)' }
if (-not $SysPassword)       { $SysPassword       = '(veja o README do seu pacote)' }
if (-not $EbsSystemPassword) { $EbsSystemPassword = '(veja o README do seu pacote)' }
if (-not $CllPassword)       { $CllPassword       = '(veja o README do seu pacote)' }
if (-not $WlsPassword)       { $WlsPassword       = '(veja o README do seu pacote)' }

New-Item -ItemType Directory -Force -Path $TargetDir, (Join-Path $TargetDir 'scripts') | Out-Null
$utf8 = New-Object Text.UTF8Encoding($true)   # com BOM: o navegador acerta o encoding
$wslTarget = '/mnt/' + $TargetDir.Substring(0,1).ToLower() + ($TargetDir.Substring(2) -replace '\\','/')

# Copiar os .sh do repositorio para a pasta da instancia, com quebras LF.
# Sem isso os .bat apontariam para o checkout do git, e parariam de funcionar
# se ele fosse movido ou apagado -- a instancia tem que se bastar.
# Copy the repo's .sh into the instance folder, with LF endings: otherwise the
# .bat files would point at the git checkout and break if it moved.
$origem = $PSScriptRoot
if (-not $origem) { $origem = (Get-Location).Path }
$origemScripts = Join-Path $origem 'scripts'
if (Test-Path $origemScripts) {
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    foreach ($sh in @('bringup.sh','parar-ebs.sh','status-ebs.sh')) {
        $src = Join-Path $origemScripts $sh
        if (Test-Path $src) {
            $txt = [IO.File]::ReadAllText($src) -replace "`r`n","`n"
            [IO.File]::WriteAllText((Join-Path $TargetDir "scripts\$sh"), $txt, $utf8NoBom)
        }
    }
}

# ------------------------------------------------------------------- .bat
$batIniciar = @"
@echo off
title Iniciando EBS R12.2.12
color 0A
echo.
echo   ============================================================
echo    Iniciando Oracle EBS R12.2.12
echo   ============================================================
echo.
echo [1/2] iniciando a maquina Podman...
podman machine start $MachineName 2>nul
if errorlevel 1 echo       (ja estava rodando)
echo.
echo [2/2] banco, listener, WebLogic e concurrent manager...
echo       Isso demora de 10 a 20 minutos. Nao feche esta janela.
echo.
podman machine ssh $MachineName "WLS_PASSWORD=$WlsPassword APPS_PASSWORD=$AppsPassword bash $wslTarget/scripts/bringup.sh"
echo.
echo   Acesse: http://${AppsHost}:8000/OA_HTML/AppsLogin
echo.
pause
"@

$batParar = @"
@echo off
title Parando EBS R12.2.12
color 0E
echo.
echo   Isso derruba a aplicacao, fecha o banco e para o container.
echo   Leva alguns minutos.
echo.
choice /C SN /M "Continuar"
if errorlevel 2 goto :fim
echo.
podman machine ssh $MachineName "WLS_PASSWORD=$WlsPassword APPS_PASSWORD=$AppsPassword bash $wslTarget/scripts/parar-ebs.sh"
echo.
set /p D="Desligar tambem a maquina Podman (libera RAM)? [s/N]: "
if /I "%D%"=="s" podman machine stop $MachineName
echo.
echo   EBS parado.
:fim
echo.
pause
"@

$batStatus = @"
@echo off
title Status EBS R12.2.12
color 0B
echo.
echo   ============================================================
echo    Status do Oracle EBS R12.2.12
echo   ============================================================
echo.
echo [maquina Podman]
podman machine list
echo.
echo [container e servicos]
podman machine ssh $MachineName "APPS_PASSWORD=$AppsPassword bash $wslTarget/scripts/status-ebs.sh"
echo.
pause
"@

[IO.File]::WriteAllText((Join-Path $TargetDir 'ebs-iniciar.bat'), $batIniciar, $utf8)
[IO.File]::WriteAllText((Join-Path $TargetDir 'ebs-parar.bat'),   $batParar,   $utf8)
[IO.File]::WriteAllText((Join-Path $TargetDir 'ebs-status.bat'),  $batStatus,  $utf8)

# ------------------------------------------------------------------- painel
$html = @'
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>EBS R12.2.12 — Painel local</title>
<style>
  :root{
    --bg:#0f1115; --card:#171a21; --line:#262b36; --tx:#e6e9ef; --dim:#8b94a7;
    --ok:#3fb950; --warn:#d29922; --err:#f85149; --acc:#4493f8;
    --mono:ui-monospace,"Cascadia Code",Consolas,monospace;
  }
  @media (prefers-color-scheme: light){
    :root{ --bg:#f6f7f9; --card:#fff; --line:#e3e6ea; --tx:#1c2028; --dim:#5c6470; }
  }
  *{box-sizing:border-box}
  body{margin:0;padding:24px;background:var(--bg);color:var(--tx);
       font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
  .wrap{max-width:1080px;margin:0 auto}
  h1{font-size:22px;margin:0 0 4px}
  .sub{color:var(--dim);font-size:13px;margin-bottom:20px}
  .grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(320px,1fr))}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px}
  .card h2{font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);
           margin:0 0 14px;font-weight:600}
  table{width:100%;border-collapse:collapse;font-size:14px}
  td{padding:7px 0;border-bottom:1px solid var(--line);vertical-align:middle}
  tr:last-child td{border-bottom:none}
  td:first-child{color:var(--dim);width:42%}
  code{font-family:var(--mono);font-size:13px}
  .cp{cursor:pointer;background:none;border:1px solid var(--line);color:var(--tx);
      border-radius:6px;padding:3px 9px;font-family:var(--mono);font-size:13px;
      transition:.15s;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .cp:hover{border-color:var(--acc);color:var(--acc)}
  .cp.done{border-color:var(--ok);color:var(--ok)}
  .btn{display:block;width:100%;text-align:left;padding:11px 14px;margin-bottom:8px;
       background:var(--bg);border:1px solid var(--line);border-radius:8px;color:var(--tx);
       text-decoration:none;font-size:14px;cursor:pointer;transition:.15s}
  .btn:hover{border-color:var(--acc)}
  .btn b{display:block;font-size:14px}
  .btn span{color:var(--dim);font-size:12px}
  .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;
       background:var(--dim);vertical-align:middle}
  .dot.up{background:var(--warn)} .dot.on{background:var(--ok)} .dot.off{background:var(--err)}
  .alert{background:rgba(210,153,34,.1);border:1px solid var(--warn);border-radius:8px;
         padding:13px 15px;font-size:13px;margin-bottom:16px}
  .alert b{color:var(--warn)}
  .foot{color:var(--dim);font-size:12px;margin-top:22px;padding-top:16px;border-top:1px solid var(--line)}
  .pre{font-family:var(--mono);font-size:12px;background:var(--bg);border:1px solid var(--line);
       border-radius:6px;padding:9px 11px;margin-top:8px;overflow-x:auto;white-space:pre-wrap}
</style>
</head>
<body>
<div class="wrap">

  <h1>Oracle EBS R12.2.12 + LAD Brasil</h1>
  <div class="sub">Painel local &middot; máquina Podman <code>__MACHINE__</code> &middot; gerado em __DATA__</div>

  <div class="alert">
    <b>Este arquivo contém todas as senhas em texto puro.</b>
    Ele é local, está fora do repositório e não deve ser compartilhado nem
    copiado para nenhum lugar público.
  </div>

  <div class="grid">

    <div class="card">
      <h2>Estado</h2>
      <table>
        <tr><td>Aplicação (porta 8000)</td>
            <td><span class="dot up" id="d8000"></span><span id="s8000">verificando…</span></td></tr>
        <tr><td>Verificado em</td><td id="hora">—</td></tr>
      </table>
      <button class="btn" style="margin-top:12px" onclick="checar()">Verificar de novo</button>
      <div class="pre">O banco na 1521 não aparece aqui de propósito: o listener fala TNS, não HTTP, então o navegador não tem como testá-lo — qualquer indicador daria vermelho com o banco no ar. Use "Ver status detalhado" para o estado real.</div>
    </div>

    <div class="card">
      <h2>Atalhos</h2>
      <a class="btn" href="http://__HOST__:8000/OA_HTML/AppsLogin" target="_blank">
        <b>Abrir o EBS ↗</b><span>SYSADMIN / __SYSADMIN__</span></a>
      <button class="btn" onclick="cmd(this,'__DIR__\\ebs-iniciar.bat')">
        <b>Iniciar EBS</b><span>copia o caminho do .bat — 10 a 20 min</span></button>
      <button class="btn" onclick="cmd(this,'__DIR__\\ebs-parar.bat')">
        <b>Parar EBS</b><span>copia o caminho do .bat</span></button>
      <button class="btn" onclick="cmd(this,'__DIR__\\ebs-status.bat')">
        <b>Ver status detalhado</b><span>copia o caminho do .bat</span></button>
      <div class="pre">Os .bat estão em __DIR__ — duplo clique ou fixe na barra de tarefas. O navegador não pode executá-los por segurança, então aqui só copiamos o caminho.</div>
    </div>

    <div class="card">
      <h2>Aplicação</h2>
      <table>
        <tr><td>SYSADMIN</td><td><button class="cp" onclick="cp(this,'__SYSADMIN__')">__SYSADMIN__</button></td></tr>
        <tr><td>URL</td><td><button class="cp" onclick="cp(this,'http://__HOST__:8000/OA_HTML/AppsLogin')">…/OA_HTML/AppsLogin</button></td></tr>
      </table>
    </div>

    <div class="card">
      <h2>Banco de dados</h2>
      <table>
        <tr><td>APPS</td><td><button class="cp" onclick="cp(this,'__APPS__')">__APPS__</button></td></tr>
        <tr><td>APPLSYS</td><td><button class="cp" onclick="cp(this,'__APPS__')">__APPS__</button></td></tr>
        <tr><td>EBS_SYSTEM</td><td><button class="cp" onclick="cp(this,'__EBSSYS__')">__EBSSYS__</button></td></tr>
        <tr><td>SYSTEM</td><td><button class="cp" onclick="cp(this,'__SYSTEM__')">__SYSTEM__</button></td></tr>
        <tr><td>SYS</td><td><button class="cp" onclick="cp(this,'__SYS__')">__SYS__</button></td></tr>
        <tr><td>CLL</td><td><button class="cp" onclick="cp(this,'__CLL__')">__CLL__</button></td></tr>
      </table>
    </div>

    <div class="card">
      <h2>WebLogic</h2>
      <table>
        <tr><td>weblogic</td><td><button class="cp" onclick="cp(this,'__WLS__')">__WLS__</button></td></tr>
        <tr><td>Console</td><td><code>:7001/console</code></td></tr>
      </table>
      <div class="pre">O AdminServer sobe na 7001, mas essa porta não é publicada para o Windows — só é acessível de dentro do container.</div>
    </div>

    <div class="card">
      <h2>Conexão ao banco</h2>
      <table>
        <tr><td>Host</td><td><button class="cp" onclick="cp(this,'localhost')">localhost</button></td></tr>
        <tr><td>Porta</td><td><button class="cp" onclick="cp(this,'1521')">1521</button></td></tr>
        <tr><td>Service</td><td><button class="cp" onclick="cp(this,'EBSDB')">EBSDB</button></td></tr>
        <tr><td>CDB</td><td><code>EBSCDB</code></td></tr>
        <tr><td>JDBC</td><td><button class="cp" onclick="cp(this,'jdbc:oracle:thin:@//localhost:1521/EBSDB')">jdbc:oracle:thin:@…</button></td></tr>
      </table>
    </div>

    <div class="card">
      <h2>Comandos úteis</h2>
      <button class="btn" onclick="cmd(this,'podman machine ssh __MACHINE__ \'podman exec -it -u oracle __MACHINE__ bash -l\'')">
        <b>Shell como oracle</b><span>dentro do container</span></button>
      <button class="btn" onclick="cmd(this,'podman machine ssh __MACHINE__ \'podman exec ebs bash -lc &quot;tail -50 /u01/install/APPS/fs1/inst/apps/EBSDB_apps/logs/appl/admin/log/adstrtal.log&quot;\'')">
        <b>Log do último start</b><span>adstrtal.log</span></button>
    </div>

    <div class="card">
      <h2>Ambiente</h2>
      <table>
        <tr><td>Máquina Podman</td><td><code>__MACHINE__</code></td></tr>
        <tr><td>Instância</td><td><code>__DIR__</code></td></tr>
        <tr><td>Volume /u01</td><td><code>/var/ebs-u01</code> (ext4)</td></tr>
        <tr><td>Repositório</td><td><a href="https://github.com/AleCyriaco/r12-on-container" target="_blank" style="color:var(--acc)">r12-on-container ↗</a></td></tr>
      </table>
    </div>

  </div>

  <div class="foot">
    Se <code>__HOST__</code> não abrir, confira o <code>hosts</code> do Windows em
    <code>C:\Windows\System32\drivers\etc\hosts</code>: precisa de
    <code>127.0.0.1 __HOST__</code> e de nenhuma outra linha com esse mesmo nome —
    nome duplicado resolve para dois endereços e causa falhas intermitentes.
    <br><br>
    Após reiniciar o Windows, o container volta sozinho mas os serviços não —
    use <b>Iniciar EBS</b>.
  </div>

</div>

<script>
function flash(el, txt){
  const orig = el.textContent;
  el.textContent = txt; el.classList.add('done');
  setTimeout(() => { el.textContent = orig; el.classList.remove('done'); }, 1100);
}
function cp(el, txt){ navigator.clipboard.writeText(txt).then(() => flash(el, 'copiado')); }
function cmd(el, txt){
  navigator.clipboard.writeText(txt);
  const b = el.querySelector('b'), orig = b.textContent;
  b.textContent = 'copiado para a área de transferência';
  setTimeout(() => { b.textContent = orig; }, 1400);
}
// Sonda de alcance: o navegador bloqueia LER a resposta de outra origem, mas a
// requisicao no-cors resolve quando o servidor atende e falha quando a conexao
// e recusada -- suficiente para um indicador de no ar / fora do ar.
function checar(){
  const d = document.getElementById('d8000'), s = document.getElementById('s8000');
  d.className = 'dot up'; s.textContent = 'verificando…';
  const t = setTimeout(() => { d.className = 'dot off'; s.textContent = 'fora do ar'; }, 6000);
  fetch('http://__HOST__:8000/OA_HTML/AppsLogin', {mode:'no-cors', cache:'no-store'})
    .then(() => { clearTimeout(t); d.className = 'dot on'; s.textContent = 'no ar'; })
    .catch(() => { clearTimeout(t); d.className = 'dot off'; s.textContent = 'fora do ar'; });
  document.getElementById('hora').textContent = new Date().toLocaleTimeString('pt-BR');
}
checar(); setInterval(checar, 30000);
</script>
</body>
</html>
'@

$html = $html.
    Replace('__MACHINE__',  $MachineName).
    Replace('__HOST__',     $AppsHost).
    Replace('__DIR__',      $TargetDir).
    Replace('__DATA__',     (Get-Date -Format 'dd/MM/yyyy HH:mm')).
    Replace('__SYSADMIN__', $SysadminPassword).
    Replace('__APPS__',     $AppsPassword).
    Replace('__EBSSYS__',   $EbsSystemPassword).
    Replace('__SYSTEM__',   $SystemPassword).
    Replace('__SYS__',      $SysPassword).
    Replace('__CLL__',      $CllPassword).
    Replace('__WLS__',      $WlsPassword)

$painel = Join-Path $TargetDir 'painel.html'
[IO.File]::WriteAllText($painel, $html, $utf8)

Write-Host "    painel  : $painel" -ForegroundColor Green
Write-Host "    atalhos : ebs-iniciar.bat, ebs-parar.bat, ebs-status.bat"
Write-Host "    (contem senhas em texto puro -- nao commitar, nao compartilhar)" -ForegroundColor Yellow
