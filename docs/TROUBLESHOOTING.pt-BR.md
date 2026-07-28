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
