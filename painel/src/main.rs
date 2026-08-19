// Painel local do EBS R12.2.12: uma janela nativa (WebView2) cujos botoes
// executam os comandos direto no Windows, em vez de copiar o caminho de um
// .bat para a area de transferencia como fazia o painel em HTML puro.
//
// A interface e o mesmo HTML de antes; o que muda e ter um processo por tras.
// Isso permite tres coisas que o arquivo estatico nao permitia: rodar
// iniciar/parar/status de dentro do painel, mostrar a saida ao vivo enquanto o
// comando roda, e testar o listener do banco por conexao TCP -- o navegador so
// fala HTTP, entao o painel antigo tinha de omitir o banco.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::io::{BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::window::WindowBuilder;
use wry::WebViewBuilder;

#[cfg(windows)]
use std::os::windows::process::CommandExt;
// Sem isto cada podman/cmd disparado pela janela pisca um console preto por
// cima do painel. O executavel ja e subsystem=windows; os filhos precisam da
// flag para herdar esse comportamento.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Mensagem da thread de trabalho para a thread do event loop. A WebView nao e
/// Send: so a thread do loop pode chamar evaluate_script, entao todo retorno
/// para a interface passa por aqui.
enum Ev {
    Eval(String),
}

// ------------------------------------------------------------------ config

/// Chave=valor simples lido de painel.conf, ao lado do executavel. Mantido sem
/// dependencia de parser: sao dez chaves e o arquivo e gerado por script.
struct Cfg(HashMap<String, String>);

impl Cfg {
    fn carregar() -> Cfg {
        let mut m = HashMap::new();
        for base in locais_de_config() {
            let p = base.join("painel.conf");
            if let Ok(txt) = std::fs::read_to_string(&p) {
                for linha in txt.lines() {
                    let l = linha.trim();
                    if l.is_empty() || l.starts_with('#') {
                        continue;
                    }
                    if let Some((k, v)) = l.split_once('=') {
                        m.insert(k.trim().to_string(), v.trim().to_string());
                    }
                }
                break;
            }
        }
        Cfg(m)
    }

    fn get(&self, chave: &str, padrao: &str) -> String {
        self.0
            .get(chave)
            .map(|s| s.to_string())
            .unwrap_or_else(|| padrao.to_string())
    }
}

fn locais_de_config() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            v.push(d.to_path_buf());
        }
    }
    if let Ok(d) = std::env::current_dir() {
        v.push(d);
    }
    v
}

/// C:\R12OnContainer -> /mnt/c/R12OnContainer
fn caminho_wsl(win: &str) -> String {
    let s = win.replace('\\', "/");
    let bytes = s.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' {
        let letra = (bytes[0] as char).to_ascii_lowercase();
        return format!("/mnt/{}{}", letra, &s[2..]);
    }
    s
}

// ------------------------------------------------------------------ passos

/// Um passo do fluxo. `tolerante` marca o que pode falhar sem abortar o resto:
/// "podman machine start" retorna erro quando a maquina ja esta rodando, que e
/// exatamente o caso normal.
struct Passo {
    titulo: String,
    prog: String,
    args: Vec<String>,
    tolerante: bool,
}

fn montar(cfg: &Cfg, acao: &str) -> Vec<Passo> {
    let maquina = cfg.get("machine", "ebs");
    let container = cfg.get("container", "ebs");
    let alvo = cfg.get("target_dir", "C:\\R12OnContainer");
    let raiz = caminho_wsl(&alvo);
    let wls = cfg.get("wls_password", "welcome1");
    let apps = cfg.get("apps_password", "apps");

    let ssh = |titulo: &str, remoto: String, tolerante: bool| Passo {
        titulo: titulo.to_string(),
        prog: "podman".into(),
        args: vec![
            "machine".into(),
            "ssh".into(),
            maquina.clone(),
            remoto,
        ],
        tolerante,
    };

    match acao {
        "iniciar" => vec![
            Passo {
                titulo: "iniciando a maquina Podman".into(),
                prog: "podman".into(),
                args: vec!["machine".into(), "start".into(), maquina.clone()],
                tolerante: true,
            },
            ssh(
                "banco, listener, WebLogic e concurrent manager",
                format!(
                    "WLS_PASSWORD={} APPS_PASSWORD={} bash {}/scripts/bringup.sh",
                    wls, apps, raiz
                ),
                false,
            ),
        ],
        "parar" => vec![ssh(
            "parando aplicacao, banco e container",
            format!(
                "WLS_PASSWORD={} APPS_PASSWORD={} bash {}/scripts/parar-ebs.sh",
                wls, apps, raiz
            ),
            false,
        )],
        "status" => vec![ssh(
            "estado detalhado",
            format!("APPS_PASSWORD={} bash {}/scripts/status-ebs.sh", apps, raiz),
            false,
        )],
        "log" => vec![ssh(
            "ultimas 80 linhas do adstrtal.log",
            format!(
                "podman exec {} bash -lc 'tail -80 /u01/install/APPS/fs1/inst/apps/EBSDB_apps/logs/appl/admin/log/adstrtal.log'",
                container
            ),
            false,
        )],
        _ => Vec::new(),
    }
}

// --------------------------------------------------------------- execucao

fn escapar_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn classe(linha: &str) -> &'static str {
    let l = linha.trim_start();
    if l.starts_with("ERRO") || l.starts_with("ERROR") || l.contains("Invalid credentials") {
        "l-erro"
    } else if l.starts_with("[*]") {
        "l-passo"
    } else if l.starts_with("===") {
        "l-meta"
    } else {
        ""
    }
}

fn emitir(proxy: &EventLoopProxy<Ev>, linha: &str) {
    let js = format!(
        "window.pnl.linha(\"{}\",\"{}\")",
        escapar_json(linha),
        classe(linha)
    );
    let _ = proxy.send_event(Ev::Eval(js));
}

fn comando(prog: &str, args: &[String]) -> Command {
    let mut c = Command::new(prog);
    c.args(args);
    #[cfg(windows)]
    c.creation_flags(CREATE_NO_WINDOW);
    c
}

/// Le um pipe linha a linha e joga cada uma na interface assim que chega. A
/// leitura e por bytes, com from_utf8_lossy: a saida do EBS mistura mensagens
/// do Oracle em codificacoes que nem sempre sao UTF-8 validas, e um unico byte
/// invalido nao pode derrubar o streaming.
fn bombear<R: Read + Send + 'static>(
    fonte: R,
    proxy: EventLoopProxy<Ev>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut leitor = BufReader::new(fonte);
        let mut buf: Vec<u8> = Vec::with_capacity(256);
        let mut byte = [0u8; 1];
        loop {
            match leitor.read(&mut byte) {
                Ok(0) => break,
                Ok(_) => {
                    if byte[0] == b'\n' {
                        let s = String::from_utf8_lossy(&buf).trim_end().to_string();
                        emitir(&proxy, &s);
                        buf.clear();
                    } else {
                        buf.push(byte[0]);
                    }
                }
                Err(_) => break,
            }
        }
        if !buf.is_empty() {
            let s = String::from_utf8_lossy(&buf).trim_end().to_string();
            emitir(&proxy, &s);
        }
    })
}

fn rodar_passo(proxy: &EventLoopProxy<Ev>, passo: &Passo) -> Result<i32, String> {
    let mut cmd = comando(&passo.prog, &passo.args);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut filho = cmd
        .spawn()
        .map_err(|e| format!("nao consegui executar {}: {}", passo.prog, e))?;

    let saida = filho.stdout.take().map(|s| bombear(s, proxy.clone()));
    let erro = filho.stderr.take().map(|s| bombear(s, proxy.clone()));

    let st = filho.wait().map_err(|e| e.to_string())?;
    if let Some(h) = saida {
        let _ = h.join();
    }
    if let Some(h) = erro {
        let _ = h.join();
    }
    Ok(st.code().unwrap_or(-1))
}

fn executar(proxy: EventLoopProxy<Ev>, cfg: Arc<Cfg>, acao: String, ocupado: Arc<AtomicBool>) {
    thread::spawn(move || {
        let mut codigo = 0;
        for passo in montar(&cfg, &acao) {
            emitir(&proxy, &format!("[*] {}", passo.titulo));
            match rodar_passo(&proxy, &passo) {
                Ok(c) if c != 0 && !passo.tolerante => {
                    emitir(&proxy, &format!("ERRO: o passo terminou com codigo {}", c));
                    codigo = c;
                    break;
                }
                Ok(_) => {}
                Err(e) => {
                    emitir(&proxy, &format!("ERRO: {}", e));
                    codigo = -1;
                    break;
                }
            }
        }
        ocupado.store(false, Ordering::SeqCst);
        let _ = proxy.send_event(Ev::Eval(format!("window.pnl.fim({})", codigo)));
    });
}

/// Terminal interativo: nao da para transmitir um TTY para dentro da webview,
/// entao abre uma janela de console propria e devolve o controle na hora.
fn abrir_shell(proxy: EventLoopProxy<Ev>, cfg: Arc<Cfg>, ocupado: Arc<AtomicBool>) {
    thread::spawn(move || {
        let maquina = cfg.get("machine", "ebs");
        let container = cfg.get("container", "ebs");
        let remoto = format!("podman exec -it -u oracle {} bash -l", container);
        let args: Vec<String> = vec![
            "/c".into(),
            "start".into(),
            "EBS - shell oracle".into(),
            "cmd".into(),
            "/k".into(),
            "podman".into(),
            "machine".into(),
            "ssh".into(),
            maquina,
            remoto,
        ];
        emitir(&proxy, "[*] abrindo um terminal dentro do container");
        let codigo = match Command::new("cmd").args(&args).spawn() {
            Ok(_) => {
                emitir(&proxy, "terminal aberto em uma janela separada.");
                0
            }
            Err(e) => {
                emitir(&proxy, &format!("ERRO: {}", e));
                -1
            }
        };
        ocupado.store(false, Ordering::SeqCst);
        let _ = proxy.send_event(Ev::Eval(format!("window.pnl.fim({})", codigo)));
    });
}

// ----------------------------------------------------------------- sondas

fn tcp_ok(porta: u16, espera: Duration) -> bool {
    let addr: SocketAddr = ([127, 0, 0, 1], porta).into();
    TcpStream::connect_timeout(&addr, espera).is_ok()
}

/// GET minimo em HTTP/1.1, so para ler a primeira linha da resposta. O Host vai
/// com o nome canonico porque o OHS do EBS responde por virtual host.
fn http_codigo(porta: u16, host: &str, caminho: &str, espera: Duration) -> Option<u16> {
    let addr: SocketAddr = ([127, 0, 0, 1], porta).into();
    let mut s = TcpStream::connect_timeout(&addr, espera).ok()?;
    s.set_read_timeout(Some(espera)).ok()?;
    s.set_write_timeout(Some(espera)).ok()?;
    let req = format!(
        "GET {} HTTP/1.1\r\nHost: {}:{}\r\nUser-Agent: painel-ebs\r\nConnection: close\r\n\r\n",
        caminho, host, porta
    );
    s.write_all(req.as_bytes()).ok()?;
    let mut buf = [0u8; 256];
    let n = s.read(&mut buf).ok()?;
    let cabeca = String::from_utf8_lossy(&buf[..n]);
    cabeca
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse::<u16>().ok())
}

fn maquina_rodando(maquina: &str) -> bool {
    let args: Vec<String> = vec![
        "machine".into(),
        "inspect".into(),
        maquina.into(),
        "--format".into(),
        "{{.State}}".into(),
    ];
    match comando("podman", &args).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .to_lowercase()
            .contains("running"),
        Err(_) => false,
    }
}

/// Le o hosts do Windows e diz se o nome canonico aponta mesmo para 127.0.0.1.
/// Uma entrada antiga com o IP de LAN da maquina sobrevive a tudo e para de
/// valer no proximo lease do DHCP -- o sintoma e o EBS no ar e o navegador em
/// timeout, que e dificil de ligar ao hosts sem uma dica.
fn checar_hosts(nome: &str) -> (bool, String) {
    let txt = match std::fs::read_to_string(caminho_hosts()) {
        Ok(t) => t,
        Err(_) => return (true, String::new()), // sem leitura, nao acusa nada
    };
    let mut achadas: Vec<String> = Vec::new();
    for linha in txt.lines() {
        let l = linha.trim();
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        let mut campos = l.split_whitespace();
        let ip = match campos.next() {
            Some(i) => i,
            None => continue,
        };
        if campos.any(|n| n.eq_ignore_ascii_case(nome)) {
            achadas.push(ip.to_string());
        }
    }
    if achadas.is_empty() {
        return (
            false,
            format!(
                "Nao ha nenhuma linha para {} no hosts. Adicione, como Administrador: 127.0.0.1    {}",
                nome, nome
            ),
        );
    }
    if achadas.len() > 1 {
        return (
            false,
            format!(
                "Ha {} linhas para {} ({}). Nome duplicado resolve para enderecos diferentes e falha de forma intermitente: deixe so 127.0.0.1.",
                achadas.len(),
                nome,
                achadas.join(", ")
            ),
        );
    }
    if achadas[0] != "127.0.0.1" {
        return (
            false,
            format!(
                "Aponta para {}. Troque por 127.0.0.1 no hosts do Windows (precisa de Administrador); ate la use http://127.0.0.1 no lugar do nome.",
                achadas[0]
            ),
        );
    }
    (true, String::new())
}

fn caminho_hosts() -> String {
    let raiz = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
    format!("{}\\System32\\drivers\\etc\\hosts", raiz)
}

/// Reescreve o hosts deixando exatamente uma linha `127.0.0.1 <nome>`.
///
/// Nao apaga a linha inteira onde o nome aparece: um mesmo IP costuma listar
/// varios nomes, e descartar a linha levaria junto os outros. Remove so o nome
/// em questao e mantem o resto; a linha some apenas se ficar sem nenhum nome.
/// Roda elevado -- e chamado pela propria janela via --corrigir-hosts.
fn corrigir_hosts(nome: &str) -> Result<String, String> {
    let caminho = caminho_hosts();
    let txt = std::fs::read_to_string(&caminho)
        .map_err(|e| format!("nao consegui ler {}: {}", caminho, e))?;

    let mut saida: Vec<String> = Vec::new();
    let mut removidas: Vec<String> = Vec::new();

    for linha in txt.lines() {
        let cru = linha.trim_end_matches('\r');
        let l = cru.trim();
        if l.is_empty() || l.starts_with('#') {
            saida.push(cru.to_string());
            continue;
        }
        // separa um comentario no fim da linha para nao embaralhar os campos
        let (corpo, comentario) = match cru.find('#') {
            Some(i) => (&cru[..i], Some(&cru[i..])),
            None => (cru, None),
        };
        let mut campos = corpo.split_whitespace();
        let ip = match campos.next() {
            Some(i) => i.to_string(),
            None => {
                saida.push(cru.to_string());
                continue;
            }
        };
        let nomes: Vec<&str> = campos.collect();
        if !nomes.iter().any(|n| n.eq_ignore_ascii_case(nome)) {
            saida.push(cru.to_string());
            continue;
        }
        removidas.push(format!("{} {}", ip, nomes.join(" ")));
        let restantes: Vec<&str> = nomes
            .into_iter()
            .filter(|n| !n.eq_ignore_ascii_case(nome))
            .collect();
        if restantes.is_empty() {
            continue; // a linha existia so para este nome
        }
        let mut nova = format!("{}\t{}", ip, restantes.join(" "));
        if let Some(c) = comentario {
            nova.push(' ');
            nova.push_str(c);
        }
        saida.push(nova);
    }

    while saida.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        saida.pop();
    }
    saida.push(format!("127.0.0.1\t{}", nome));

    let novo = saida.join("\r\n") + "\r\n";
    if novo == txt {
        return Ok(format!("{} ja estava correto.", nome));
    }

    // O hosts e arquivo de sistema: guarda uma copia antes de gravar.
    let bak = format!("{}.painel-bak", caminho);
    std::fs::write(&bak, &txt).map_err(|e| format!("nao consegui salvar a copia: {}", e))?;
    std::fs::write(&caminho, &novo)
        .map_err(|e| format!("nao consegui gravar o hosts: {} (rodou como Administrador?)", e))?;

    let detalhe = if removidas.is_empty() {
        format!("adicionada a linha 127.0.0.1 {}", nome)
    } else {
        format!(
            "substituida: {} -> 127.0.0.1 {}",
            removidas.join(" | "),
            nome
        )
    };
    Ok(format!("{}. Copia do original em {}", detalhe, bak))
}

/// Relanca o proprio executavel elevado so para mexer no hosts. Usa o
/// Start-Process do PowerShell em vez de ShellExecute para nao trazer uma
/// dependencia de FFI so por causa do verbo runas. Se o usuario recusar o UAC,
/// o PowerShell termina com erro e a recusa e reportada como tal.
fn pedir_elevacao(proxy: EventLoopProxy<Ev>, cfg: Arc<Cfg>, ocupado: Arc<AtomicBool>) {
    thread::spawn(move || {
        let nome = cfg.get("apps_host", "apps.example.com");
        emitir(
            &proxy,
            &format!("[*] corrigindo {} no hosts do Windows", nome),
        );
        emitir(
            &proxy,
            "Isso exige Administrador: aceite o aviso do Windows que vai aparecer.",
        );

        let exe = match std::env::current_exe() {
            Ok(e) => e.to_string_lossy().to_string(),
            Err(e) => {
                emitir(&proxy, &format!("ERRO: {}", e));
                ocupado.store(false, Ordering::SeqCst);
                let _ = proxy.send_event(Ev::Eval("window.pnl.fim(-1)".into()));
                return;
            }
        };
        let exe_ps = exe.replace('\'', "''");
        let ps = format!(
            "Start-Process -FilePath '{}' -ArgumentList '--corrigir-hosts' -Verb RunAs -Wait",
            exe_ps
        );
        let args: Vec<String> = vec![
            "-NoProfile".into(),
            "-WindowStyle".into(),
            "Hidden".into(),
            "-Command".into(),
            ps,
        ];

        let codigo = match comando("powershell", &args).output() {
            Ok(o) if o.status.success() => {
                // O processo elevado deixa o resultado num arquivo; o daqui nao
                // tem como ler a saida dele.
                let relato = locais_de_config()
                    .into_iter()
                    .next()
                    .map(|d| d.join("painel-hosts.txt"))
                    .and_then(|p| std::fs::read_to_string(p).ok())
                    .unwrap_or_default();
                for l in relato.lines() {
                    emitir(&proxy, l);
                }
                let (ok, txt) = checar_hosts(&nome);
                if ok {
                    emitir(&proxy, "[*] pronto: o nome agora resolve para 127.0.0.1");
                    0
                } else {
                    emitir(&proxy, &format!("ERRO: ainda incorreto. {}", txt));
                    1
                }
            }
            Ok(o) => {
                let e = String::from_utf8_lossy(&o.stderr);
                if e.contains("cancel") || e.contains("Cancel") || e.contains("1223") {
                    emitir(
                        &proxy,
                        "Elevacao recusada. Nada foi alterado -- use http://127.0.0.1 no lugar do nome, ou clique de novo para tentar outra vez.",
                    );
                } else {
                    emitir(&proxy, &format!("ERRO: {}", e.trim()));
                }
                1
            }
            Err(e) => {
                emitir(&proxy, &format!("ERRO: {}", e));
                -1
            }
        };

        ocupado.store(false, Ordering::SeqCst);
        let _ = proxy.send_event(Ev::Eval(format!("window.pnl.fim({})", codigo)));
    });
}

fn sondar(proxy: EventLoopProxy<Ev>, cfg: Arc<Cfg>) {
    thread::spawn(move || {
        let espera = Duration::from_secs(4);
        let host = cfg.get("apps_host", "apps.example.com");
        let porta_app: u16 = cfg.get("apps_port", "8000").parse().unwrap_or(8000);
        let porta_db: u16 = cfg.get("db_port", "1521").parse().unwrap_or(1521);
        let maquina = cfg.get("machine", "ebs");

        let cod = http_codigo(porta_app, &host, "/OA_HTML/AppsLogin", espera);
        // 302 e a resposta correta do AppsLogin; 503 e o OHS no ar com os
        // managed servers fora, que e justamente o estado que confunde.
        let (app_ok, app_txt) = match cod {
            Some(302) | Some(200) => (true, format!("no ar (HTTP {})", cod.unwrap())),
            Some(503) => (
                false,
                "HTTP 503 - o OHS responde, mas os managed servers estao fora".to_string(),
            ),
            Some(c) => (false, format!("HTTP {} (esperado 302)", c)),
            None => (false, "fora do ar".to_string()),
        };

        let db_ok = tcp_ok(porta_db, espera);
        let db_txt = if db_ok {
            format!("listener aceitando conexao na {}", porta_db)
        } else {
            "fora do ar".to_string()
        };

        let vm_ok = maquina_rodando(&maquina);
        let vm_txt = if vm_ok {
            format!("{} rodando", maquina)
        } else {
            format!("{} parada", maquina)
        };

        let (hosts_ok, hosts_txt) = checar_hosts(&host);

        let js = format!(
            "window.pnl.estado({{\"app_ok\":{},\"app_txt\":\"{}\",\"db_ok\":{},\"db_txt\":\"{}\",\"vm_ok\":{},\"vm_txt\":\"{}\",\"hosts_ok\":{},\"hosts_txt\":\"{}\"}})",
            app_ok,
            escapar_json(&app_txt),
            db_ok,
            escapar_json(&db_txt),
            vm_ok,
            escapar_json(&vm_txt),
            hosts_ok,
            escapar_json(&hosts_txt)
        );
        let _ = proxy.send_event(Ev::Eval(js));
    });
}

// ------------------------------------------------------------------- main

fn montar_html(cfg: &Cfg) -> String {
    let bruto = include_str!("../ui/index.html");
    let readme = "(veja o README do seu pacote)";
    let pares: Vec<(&str, String)> = vec![
        ("__MACHINE__", cfg.get("machine", "ebs")),
        ("__TARGET__", cfg.get("target_dir", "C:\\R12OnContainer")),
        ("__APPSHOST__", cfg.get("apps_host", "apps.example.com")),
        ("__APPSPORT__", cfg.get("apps_port", "8000")),
        ("__DBPORT__", cfg.get("db_port", "1521")),
        ("__SERVICE__", cfg.get("service", "EBSDB")),
        ("__CDB__", cfg.get("cdb", "EBSCDB")),
        ("__U01__", cfg.get("u01_volume", "/var/ebs-u01")),
        ("__WLSPWD__", cfg.get("wls_password", "welcome1")),
        ("__APPSPWD__", cfg.get("apps_password", "apps")),
        ("__SYSADMIN__", cfg.get("sysadmin_password", readme)),
        ("__EBSSYSTEM__", cfg.get("ebs_system_password", readme)),
        ("__SYSTEMPWD__", cfg.get("system_password", readme)),
        ("__SYSPWD__", cfg.get("sys_password", readme)),
        ("__CLLPWD__", cfg.get("cll_password", readme)),
    ];
    let mut html = bruto.to_string();
    for (chave, valor) in pares {
        html = html.replace(chave, &valor);
    }
    html
}

/// `painel-ebs.exe --diagnostico` escreve painel-diag.txt e sai sem abrir a
/// janela. Como o executavel e subsystem=windows, ele nao tem console para
/// imprimir: por isso o relatorio vai para arquivo. Mostra a configuracao
/// resolvida, o comando exato de cada botao e o resultado das sondas -- que e
/// o que se quer saber quando um botao "nao faz nada".
fn diagnostico(cfg: &Cfg) {
    let mut r = String::new();
    r.push_str("painel-ebs -- diagnostico\n\n[config resolvida]\n");
    for chave in [
        "machine",
        "container",
        "target_dir",
        "apps_host",
        "apps_port",
        "db_port",
        "service",
        "cdb",
        "u01_volume",
    ] {
        r.push_str(&format!("  {:<12} = {}\n", chave, cfg.get(chave, "(padrao)")));
    }
    for chave in [
        "wls_password",
        "apps_password",
        "sysadmin_password",
        "ebs_system_password",
        "system_password",
        "sys_password",
        "cll_password",
    ] {
        let definida = cfg.0.contains_key(chave);
        r.push_str(&format!(
            "  {:<12} = {}\n",
            chave,
            if definida {
                "(definida no painel.conf)"
            } else {
                "(padrao embutido)"
            }
        ));
    }

    r.push_str("\n[comandos de cada botao]\n");
    let segredo = cfg.get("wls_password", "welcome1");
    for acao in ["iniciar", "parar", "status", "log"] {
        r.push_str(&format!("  {}:\n", acao));
        for p in montar(cfg, acao) {
            let linha = format!("{} {}", p.prog, p.args.join(" "));
            // O relatorio pode ser colado num chamado: a senha sai fora.
            let linha = linha.replace(&segredo, "********");
            r.push_str(&format!("    {}\n", linha));
        }
    }

    r.push_str("\n[sondas]\n");
    let espera = Duration::from_secs(4);
    let host = cfg.get("apps_host", "apps.example.com");
    let porta_app: u16 = cfg.get("apps_port", "8000").parse().unwrap_or(8000);
    let porta_db: u16 = cfg.get("db_port", "1521").parse().unwrap_or(1521);
    let maquina = cfg.get("machine", "ebs");
    r.push_str(&format!(
        "  AppsLogin  : {:?}\n",
        http_codigo(porta_app, &host, "/OA_HTML/AppsLogin", espera)
    ));
    r.push_str(&format!(
        "  frmservlet : {:?}\n",
        http_codigo(porta_app, &host, "/forms/frmservlet?config=EBSDB", espera)
    ));
    r.push_str(&format!("  TCP {}    : {}\n", porta_db, tcp_ok(porta_db, espera)));
    r.push_str(&format!("  maquina    : {}\n", maquina_rodando(&maquina)));
    let (ok, txt) = checar_hosts(&host);
    r.push_str(&format!("  hosts ok   : {}\n", ok));
    if !ok {
        r.push_str(&format!("  hosts       : {}\n", txt));
    }

    let destino = locais_de_config()
        .into_iter()
        .next()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("painel-diag.txt");
    let _ = std::fs::write(&destino, &r);
    print!("{}", r);
}

fn main() -> wry::Result<()> {
    let cfg = Arc::new(Cfg::carregar());

    if std::env::args().skip(1).any(|a| a == "--diagnostico") {
        diagnostico(&cfg);
        return Ok(());
    }

    // Instancia elevada: so conserta o hosts, deixa o relato em arquivo para a
    // janela que a chamou poder mostrar, e sai sem abrir interface nenhuma.
    if std::env::args().skip(1).any(|a| a == "--corrigir-hosts") {
        let nome = cfg.get("apps_host", "apps.example.com");
        let relato = match corrigir_hosts(&nome) {
            Ok(m) => m,
            Err(e) => format!("ERRO: {}", e),
        };
        if let Some(d) = locais_de_config().into_iter().next() {
            let _ = std::fs::write(d.join("painel-hosts.txt"), &relato);
        }
        return Ok(());
    }

    let html = montar_html(&cfg);

    let event_loop = EventLoopBuilder::<Ev>::with_user_event().build();
    let janela = WindowBuilder::new()
        .with_title("Oracle EBS R12.2.12 - Painel local")
        .with_inner_size(LogicalSize::new(1180.0, 920.0))
        .build(&event_loop)
        .expect("nao consegui criar a janela");

    let proxy = event_loop.create_proxy();
    let ocupado = Arc::new(AtomicBool::new(false));

    let cfg_ipc = cfg.clone();
    let proxy_ipc = proxy.clone();
    let ocupado_ipc = ocupado.clone();

    let webview = WebViewBuilder::new()
        .with_html(html)
        .with_ipc_handler(move |req| {
            let acao = req.body().trim().to_string();
            if acao == "probe" {
                sondar(proxy_ipc.clone(), cfg_ipc.clone());
                return;
            }
            // Uma acao por vez: iniciar e parar mexem nos mesmos servicos, e
            // deixar as duas correrem juntas produz falhas que nao se explicam
            // pelo log de nenhuma das duas.
            if ocupado_ipc.swap(true, Ordering::SeqCst) {
                return;
            }
            match acao.as_str() {
                "corrigir_hosts" => {
                    pedir_elevacao(proxy_ipc.clone(), cfg_ipc.clone(), ocupado_ipc.clone())
                }
                "shell" => abrir_shell(proxy_ipc.clone(), cfg_ipc.clone(), ocupado_ipc.clone()),
                "iniciar" | "parar" | "status" | "log" => executar(
                    proxy_ipc.clone(),
                    cfg_ipc.clone(),
                    acao,
                    ocupado_ipc.clone(),
                ),
                _ => {
                    ocupado_ipc.store(false, Ordering::SeqCst);
                }
            }
        })
        .build(&janela)?;

    event_loop.run(move |evento, _alvo, fluxo| {
        *fluxo = ControlFlow::Wait;
        match evento {
            Event::UserEvent(Ev::Eval(js)) => {
                let _ = webview.evaluate_script(&js);
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => *fluxo = ControlFlow::Exit,
            _ => {}
        }
    });
}
