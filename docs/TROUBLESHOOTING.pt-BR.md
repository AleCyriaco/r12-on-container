# Solução de problemas

**Português** · [English](TROUBLESHOOTING.md)

Tudo aqui aconteceu de verdade durante um deploy. O padrão se repete: **o erro
visível acusa o componente errado.**

---

## Todos os managed servers pulados: "AdminServer is down"

```
adadminsrvctl.sh: exiting with status 1
ERROR: Skipping startup of oacore_server1 since the AdminServer is down.
ERROR: Skipping startup of forms_server1 since the AdminServer is down.
...
adstrtal.sh: Exiting with status 1
```

**Causa.** O `adstrtal.sh` pede a senha do WebLogic de forma interativa. Sob
`podman exec` *sem* `-i`, o stdin não está conectado, a senha chega vazia e o
AdminServer se recusa a subir. Todos os managed servers são então pulados, e as
mensagens de "skipping" enterram a única linha que importa.

Procure por isto logo antes da cascata:

```
Enter the WebLogic Server password: stty: standard input: Inappropriate ioctl for device
```

**Correção.** `podman exec -i` e a senha pelo stdin:

```bash
printf '%s\n' "$WLS_PASSWORD" | podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/EBSapps.env run
  $ADMIN_SCRIPTS_HOME/adstrtal.sh apps/apps'
```

**Pista falsa.** A mesma execução normalmente mostra
`adnodemgrctl.sh: exiting with status 1` e `AC-00002: Unable to create log
file`. O NodeManager na verdade subiu — confira no log dele por
`Plain socket listener started on port 5556`. Essa falha é corrida de start a
frio e se resolve sozinha; a senha é o problema real.

---

## O listener sobe com o hostname curto

Compare a origem e a máquina nova em
`$INST_TOP/logs/ora/10.1.2/network/apps_ebsdb.log`:

```
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=apps.example.com)(PORT=1626)))   <- origem
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=apps)(PORT=1626)))               <- aqui
```

**Causa.** O Podman já grava `<IP> apps ebs` no `/etc/hosts` do container por
causa do `--hostname apps`. Acrescentar uma segunda linha repetindo o alias
`apps` muda qual nome é *canônico* para aquele endereço, e o Oracle resolve o
curto.

**Correção.** Exatamente uma linha, com o nome completo primeiro:

```
10.88.0.2	apps.example.com apps ebs
```

**E o `sed -i` não faz isso.** O `/etc/hosts` é bind mount; renomear por cima
falha com `Device or resource busy`. Grave no lugar:

```bash
grep -v -e 'apps.example.com' -e 'apps ebs$' /etc/hosts > /tmp/h
printf '%s\tapps.example.com apps ebs\n' "$IP" >> /tmp/h
cat /tmp/h > /etc/hosts
```

---

## Tudo quebra depois de reiniciar o container

Sintoma após um reboot ou `podman start`: `ORA-12560: TNS:protocol adapter
error` em qualquer conexão `@EBSDB`, e o `adstrtal.sh` reportando *"Database
connection could not be established. Either the database is down or the APPS
credentials supplied are wrong"* — com o banco comprovadamente aberto e as
credenciais comprovadamente certas.

**Causa.** O Podman **regenera o `/etc/hosts` a cada start do container.** A
linha com o nome canônico completo some; sobra só o `<IP> apps ebs` que o
próprio Podman cria. O `tnsnames.ora` aponta para o nome completo, então a
resolução falha e toda conexão TNS morre.

Não é o mesmo problema de ordenação do nome canônico logo abaixo — aquele é
sobre *qual* nome vence. Este é a linha sumir por inteiro, e ele volta toda
vez que o container inicia.

**Correção.** Reaplicar a cada start, antes de subir qualquer coisa. É o que o
`scripts/bringup.sh` faz:

```bash
IP=$(podman inspect ebs --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman exec -i ebs bash -s <<EOF
grep -v -e 'apps.example.com' -e 'apps ebs\$' /etc/hosts > /tmp/h
printf '%s\tapps.example.com apps ebs\n' '$IP' >> /tmp/h
cat /tmp/h > /etc/hosts
EOF
```

Se o listener já tinha subido antes da correção, reinicie-o para ele ligar no
nome certo — `lsnrctl stop && lsnrctl start` do home 19.0.0, nunca
`pkill -f tnslsnr`.

---

## O adstrtal.sh acusa credenciais do APPS logo após o startup

Mesma mensagem enganosa da anterior, mas o banco *está* acessível quando você
confere na mão.

**Causa.** Corrida. O `startup` retorna assim que o banco abre, mas o serviço
só é registrado no listener quando o PMON o faz — até 60 segundos depois. O
`adstrtal.sh` rodando nessa janela não consegue conectar, e reporta isso como
problema de credenciais.

**Correção.** Forçar o registro e esperar uma conexão real antes de subir a
pilha de aplicação:

```bash
sqlplus -s / as sysdba <<< "alter system register;"
```

e então repetir até isto realmente retornar uma linha:

```bash
sqlplus -s -L apps/apps@EBSDB <<'SQL'
set heading off feedback off pagesize 0
select 'PRONTO' from dual;
exit
SQL
```

---

## "Database connection could not be established" depois de reiniciar

```
adstrtal.sh: Database connection could not be established.
Either the database is down or the APPS credentials supplied are wrong.
```

**Causa mais provável.** Alguém rodou `pkill -f tnslsnr`. Existem *dois*
listeners e ambos casam: o do banco na 1521 (home 19.0.0) e o do apps tier na
1626 (home 10.1.2). A mensagem culpa as credenciais; as credenciais estão certas.

**Correção.**

```bash
podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl start'
```

Depois confirme que o banco está aberto antes de tentar o `adstrtal.sh` de novo.

---

## O concurrent manager não sobe

```
Routine &ROUTINE has attempted to start the internal concurrent manager. The ICM is already running.
afpdlrq received an unsuccessful result from PL/SQL procedure or function FND_DCP.Request_Session_Lock.
Routine FND_DCP.REQUEST_SESSION_LOCK received a result code of 1 from the call to DBMS_LOCK.Request.
Call to establish_icm failed
```

**Causa.** A sessão de banco do ICM anterior ainda não tinha soltado o
`DBMS_LOCK` quando a nova tentou tomá-lo. Corrida num ciclo de parada/subida,
não corrupção.

**Correção.** Espere o lock cair e suba de novo. `cmclean.sql` não é necessário
para isso.

```bash
podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
  $ADMIN_SCRIPTS_HOME/adcmctl.sh start apps/apps'
```

Confirme que pegou, em vez de confiar no código de saída:

```sql
select running_processes from fnd_concurrent_queues where concurrent_queue_name='FNDICM';
-- 1 = no ar
```

O `adcmctl.sh` sai com 0 mesmo quando o ICM morre em seguida, então o código de
saída sozinho não prova nada.

---

## O banco não abre: ORA-27104 no startup

```
[*] banco + listener
ORA-32004: obsolete or deprecated parameter(s) specified for RDBMS instance
ORA-27104: system-defined limits for shared memory was misconfigured
[*] aguardando o servico EBSDB registrar no listener
    AVISO: servico nao respondeu em 150s -- seguindo assim mesmo
adstrtal.sh: exiting with status 1
```

**Causa.** Ovo e galinha em torno da redução de SGA (`-SgaGb`, automática em
hosts de 16 GB). A fase Machine reduzia o `kernel.shmmax` da VM para "SGA
reduzida × 1,6" — menor que a SGA de 20G do spfile **original** do pacote. O
passo de redução fazia `startup nomount` para poder alterar o spfile; o
nomount carregava o spfile original, que não cabia no limite recém-apertado, e
morria com ORA-27104 **antes** de qualquer `alter system`. Resultado: o spfile
seguia pedindo 20G, o limite seguia em ~6G, e nenhum startup posterior tinha
como funcionar — nem no deploy, nem no `ebs-iniciar.bat`.

**Correção.** Em duas frentes, ambas já no repositório: a redução de SGA
passou a ser feita de banco **fechado** (`create pfile from spfile` → edita →
`create spfile from pfile`; os dois CREATE funcionam com a instância parada,
sem nomount nenhum), e o `shmmax`/`shmall` viraram tetos folgados fixos — teto
não reserva memória, não havia o que "economizar". Numa máquina que já caiu
nessa, basta retomar dos serviços:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) -BaseUrl '<base-url-do-seu-pacote>' -From Services
```

**Variante: ORA-00821 depois da redução.**

```
ORA-00821: Specified value of sga_target 4096M is too small, needs to be at least 4240M
ORA-01078: failure in processing system parameters
```

Mesmo espírito, outro parâmetro: o spfile original também **fixa os pools**
(`shared_pool_size`, `db_cache_size`, `java_pool_size`…) em tamanhos do mundo
de 20G. A soma dos pools fixados vira um piso, e a `sga_target` reduzida fica
abaixo dele. A redução passou a remover esses parâmetros do pfile: sem valor
fixado, o ASMM os dimensiona sozinho dentro da `sga_target`.

**Pistas falsas.** Três na mesma tela: o ORA-32004 é ruído (parâmetros
obsoletos no spfile do pacote, inofensivo); o "aguardando o serviço registrar
no listener" sugere lentidão de listener quando o banco nem subiu; e o
`adstrtal.sh: exiting with status 1` reporta credenciais do APPS erradas — o
erro real é o primeiro da cascata. Desde a correção, o start é interrompido na
hora com "o banco nao abriu" em vez de deixar a cascata acontecer.

---

## A máquina não inicia: HCS_E_CONNECTION_TIMEOUT

```
Starting machine "ebs"
The operation timed out because a response was not received from the virtual machine or container.
Error code: Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT
Error: the WSL bootstrap script failed: ... exit status 0xffffffff
```

**Causa.** O Host Compute Service pediu ao WSL2 a criação da VM e não recebeu
resposta no prazo; o podman só repassa o erro. Quase sempre é uma destas:
estado preso de uma tentativa anterior (ou de um "Desligar" com Fast Startup,
que hiberna o kernel e não limpa o serviço de virtualização), pouca RAM livre
no host na hora do boot, WSL desatualizado, ou antivírus de terceiro em cima
do `vmcompute`.

**Correção.** O deploy se recupera sozinho: derruba o WSL
(`podman machine stop` + `wsl --shutdown`), espera e tenta de novo, até três
vezes. Se as três se esgotarem, na ordem do mais provável:

1. Feche o que consome RAM e rode o mesmo comando com `-From Machine` — host
   de 16 GB fica no limite para esta VM.
2. `wsl --update` e **reinicie** o Windows. Reiniciar mesmo: o "Desligar" com
   Fast Startup não limpa o serviço que travou.
3. Teste sem o antivírus de terceiro.
4. Para isolar o podman: `wsl -d podman-ebs echo ok` — falhando igual, o
   problema é do WSL, não deste deploy.

**Pista falsa.** O `exit status 0xffffffff` no fim aponta para o script de
bootstrap do podman, mas ele nem chegou a rodar: a VM não subiu. O erro real é
a linha do meio, `Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT`.

---

## Não consigo mover o disco da VM: ERROR_SHARING_VIOLATION

```
wsl --manage podman-ebs --move D:\caminho
The process cannot access the file because it is being used by another process.
```

**Causa.** O vhdx fica anexado enquanto a VM utilitária do WSL estiver viva — e
ela fica viva enquanto *qualquer* distribuição estiver rodando, não só esta.

**Correção.** Pare tudo antes:

```powershell
podman machine stop <cada máquina>
wsl --shutdown
wsl --manage podman-ebs --move D:\caminho
```

---

## O Google Drive devolve HTML em vez do arquivo

O download termina suspeitosamente rápido e o arquivo começa com `<html`.

**Causa.** Cota estourada no arquivo público, ou a pasta não está realmente
compartilhada. O Google serve uma página de erro com HTTP 200.

**Detecção.** Um `.tar.zst` começa com os bytes mágicos `28 b5 2f fd`:

```bash
head -c 4 arquivo.tar.zst | od -An -tx1
```

O deploy confere isso, e confere o SHA-256 contra o `manifest.txt` quando ele
existe. Sem essa checagem, a falha aparece meia hora depois como um erro
incompreensível do `tar`.

**Correção.** Espere a cota resetar, ou divida em mais partes — a cota é
contada por arquivo.

---

## A listagem da pasta não encontra nada

```
nao achei a listagem na pagina da pasta
```

**Causa.** Não existe API sem chave para listar pasta pública do Drive. Isto
extrai o blob `_DRIVE_ivd` do HTML da página, a mesma abordagem do `gdown`, e o
Google muda essa marcação sem aviso.

Dois detalhes fáceis de errar ao consertar:

- a atribuição é `window['_DRIVE_ivd'] = '...'` — o `']` fica entre o nome e o
  `=`
- depois de decodificar os escapes `\xNN`, cada entrada é
  `"<id>",["<idDoPai>"],"<nome>"` — o pai vem em **array aninhado**, não como
  string solta

**Correção.** Contorne com IDs explícitos:

```powershell
.\Deploy-R12.ps1 -VolumeFileId '1abc...' -ImageFileId '1xyz...'
```

Nesse caminho não há manifesto, então a verificação cai para o magic number.

---

## A VM tem mais ou menos RAM do que foi pedido

O `podman machine init --memory` é parcialmente indicativo no WSL: quem manda é
o `%USERPROFILE%\.wslconfig` global, cujo padrão é metade da RAM do host.

Veja o que você realmente ganhou:

```powershell
podman machine ssh ebs "free -g; nproc"
```

Para fixar, crie o `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=40GB
processors=8
```

---

## Liberar espaço dentro da VM não libera espaço no Windows

O `ext4.vhdx` só cresce. Apagar 37 GB dentro da VM devolve exatamente zero bytes
ao host — o espaço é reaproveitado internamente, mas nunca entregue de volta.

Para recuperar, pare a máquina e compacte o disco. Isso significa
indisponibilidade, então é um passo deliberado, não algo que o deploy faça pelas
suas costas.

---

## Verificando se a instância está realmente saudável

Códigos de saída mentem aqui. Cheque o estado observável:

```bash
# HTTP: 302 e 200 são as respostas esperadas
curl -s -o /dev/null -w '%{http_code}\n' http://apps.example.com:8000/OA_HTML/AppsLogin
curl -s -o /dev/null -w '%{http_code}\n' 'http://apps.example.com:8000/forms/frmservlet?config=EBSDB'

# WebLogic: AdminServer mais os managed servers habilitados
podman exec ebs bash -lc 'ps -eo args | grep -o "weblogic.Name=[A-Za-z0-9_-]\+" | sort -u'

# Concurrent manager
podman exec ebs bash -lc 'pgrep -c FNDLIBR'
```

`forms-c4ws_server1` e `oaea_server1` costumam estar `disabled` no context file.
A ausência deles é configuração, não falha — confirme antes de caçar:

```bash
grep -oE '<oa_service_status oa_var="s_[a-z0-9-]+status">[a-z]+' \
  $INST_TOP/appl/admin/*.xml
```
