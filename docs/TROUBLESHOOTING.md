# Troubleshooting

[Português](TROUBLESHOOTING.pt-BR.md) · **English**

Every entry here was hit for real during a deployment. The pattern that repeats:
**the visible error names the wrong component.**

---

## All managed servers skipped: "AdminServer is down"

```
adadminsrvctl.sh: exiting with status 1
ERROR: Skipping startup of oacore_server1 since the AdminServer is down.
ERROR: Skipping startup of forms_server1 since the AdminServer is down.
...
adstrtal.sh: Exiting with status 1
```

**Cause.** `adstrtal.sh` prompts for the WebLogic password interactively. Under
`podman exec` *without* `-i`, stdin is not connected, the password arrives
empty, and the AdminServer refuses to start. Every managed server is then
skipped, and the skip messages bury the one line that matters.

Look for this just before the cascade:

```
Enter the WebLogic Server password: stty: standard input: Inappropriate ioctl for device
```

**Fix.** `podman exec -i` and feed the password:

```bash
printf '%s\n' "$WLS_PASSWORD" | podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/EBSapps.env run
  $ADMIN_SCRIPTS_HOME/adstrtal.sh apps/apps'
```

**Decoy.** The same run usually shows `adnodemgrctl.sh: exiting with status 1`
and `AC-00002: Unable to create log file`. The NodeManager actually started —
check its log for `Plain socket listener started on port 5556`. That failure is
a cold-start race and resolves itself; the password is the real problem.

---

## The same cascade, but the WebLogic password is wrong

Identical to the previous entry in `adstrtal.sh` output, and a completely
different fix. What separates the two lives in the control-script logs under
`$INST_TOP/logs/appl/admin/log/`:

```
Connecting to Node Manager ...
ERROR: Invalid credentials passed.
ERROR: Unable to connect to the Node Manager. The Admin Server cannot be started up.
```

**Cause.** `Invalid credentials passed` comes from `nmConnect`: the NodeManager
rejected the password. The NodeManager itself **is up** — its log shows `Plain
socket listener started on port 5556` and the port answers — which is exactly
what sends you hunting the NodeManager for hours. With no AdminServer, every
managed server is skipped and the cascade blames the wrong component again.

`-WlsPassword` must be the password that **already exists** in the image's
domain: the deployment authenticates with it, it does not set it. The reference
package ships with `welcome1`.

**Ten-second confirmation.** If `AdminServer.out` still carries the image
capture date, it never even tried to start — the startup died earlier, at the
NodeManager:

```bash
podman exec ebs ls -la \
  /u01/install/APPS/fs1/FMW_Home/user_projects/domains/EBS_domain/servers/AdminServer/logs/AdminServer.out
```

**Fix.** Re-run the bring-up with the right password:

```powershell
podman machine ssh ebs 'WLS_PASSWORD=welcome1 bash /mnt/c/R12OnContainer/scripts/bringup.sh'
```

**The trap inside the trap.** Until this version `bringup.sh` and the deployment's
`services` step always exited 0: without `set -e`, a failing `adstrtal.sh`
stopped nothing and the final status came from the last `echo`. The panel
reported 100% and `services.log.rc` held 0 with WebLogic down — the bring-up
lied. Both now exit non-zero when the application tier does not come up.

---

## Listener binds to the short hostname

Compare the origin and the new host in
`$INST_TOP/logs/ora/10.1.2/network/apps_ebsdb.log`:

```
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=apps.example.com)(PORT=1626)))   <- origin
Listening on: (DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=apps)(PORT=1626)))               <- here
```

**Cause.** Podman already writes `<IP> apps ebs` into the container's
`/etc/hosts` because of `--hostname apps`. Appending a second line that repeats
the `apps` alias changes which name is *canonical* for that address, and Oracle
resolves the short one.

**Fix.** Exactly one line, fully-qualified name first:

```
10.88.0.2	apps.example.com apps ebs
```

**And `sed -i` will not do it.** `/etc/hosts` is a bind mount; renaming over it
fails with `Device or resource busy`. Write in place:

```bash
grep -v -e 'apps.example.com' -e 'apps ebs$' /etc/hosts > /tmp/h
printf '%s\tapps.example.com apps ebs\n' "$IP" >> /tmp/h
cat /tmp/h > /etc/hosts
```

---

## Everything breaks after restarting the container

Symptom after a reboot or `podman start`: `ORA-12560: TNS:protocol adapter
error` on any `@EBSDB` connection, and `adstrtal.sh` reporting
*"Database connection could not be established. Either the database is down or
the APPS credentials supplied are wrong"* — with a database that is demonstrably
open and credentials that are demonstrably correct.

**Cause.** Podman **regenerates `/etc/hosts` on every container start.** The
line carrying the fully-qualified canonical name is gone; only Podman's own
`<IP> apps ebs` survives. `tnsnames.ora` points at the fully-qualified name, so
resolution fails and every TNS connection dies.

This is not the same as the canonical-name ordering problem below — that one is
about *which* name wins. This one is the line vanishing entirely, and it comes
back every single time the container starts.

**Fix.** Re-apply it on every start, before starting anything else. This is what
`scripts/bringup.sh` does:

```bash
IP=$(podman inspect ebs --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
podman exec -i ebs bash -s <<EOF
grep -v -e 'apps.example.com' -e 'apps ebs\$' /etc/hosts > /tmp/h
printf '%s\tapps.example.com apps ebs\n' '$IP' >> /tmp/h
cat /tmp/h > /etc/hosts
EOF
```

If the listener was already started before the fix, restart it so it binds to
the right name — `lsnrctl stop && lsnrctl start` from the 19.0.0 home, never
`pkill -f tnslsnr`.

---

## adstrtal.sh blames the APPS credentials right after a startup

Same misleading message as above, but the database *is* reachable by the time
you check by hand.

**Cause.** A race. `startup` returns as soon as the database is open, but the
service is only registered with the listener when PMON gets around to it —
up to 60 seconds later. `adstrtal.sh` running in that gap cannot connect, and
reports it as a credentials problem.

**Fix.** Force registration and wait for a real connection before starting the
application tier:

```bash
sqlplus -s / as sysdba <<< "alter system register;"
```

then poll until this actually returns a row:

```bash
sqlplus -s -L apps/apps@EBSDB <<'SQL'
set heading off feedback off pagesize 0
select 'PRONTO' from dual;
exit
SQL
```

---

## "Database connection could not be established" after a restart

```
adstrtal.sh: Database connection could not be established.
Either the database is down or the APPS credentials supplied are wrong.
```

**Cause, most likely.** Someone ran `pkill -f tnslsnr`. There are *two*
listeners and both match: the database's on 1521 (19.0.0 home) and the apps
tier's on 1626 (10.1.2 home). The message blames credentials; the credentials
are fine.

**Fix.**

```bash
podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl start'
```

Then confirm the database is actually open before retrying `adstrtal.sh`.

---

## Concurrent manager will not start

```
Routine &ROUTINE has attempted to start the internal concurrent manager. The ICM is already running.
afpdlrq received an unsuccessful result from PL/SQL procedure or function FND_DCP.Request_Session_Lock.
Routine FND_DCP.REQUEST_SESSION_LOCK received a result code of 1 from the call to DBMS_LOCK.Request.
Call to establish_icm failed
```

**Cause.** The previous ICM's database session had not yet released its
`DBMS_LOCK` when the new one tried to claim it. A race in a stop/start cycle,
not corruption.

**Fix.** Wait for the lock to drop and start it again. `cmclean.sql` is not
needed for this.

```bash
podman exec -i -u oracle ebs bash -lc '
  source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
  $ADMIN_SCRIPTS_HOME/adcmctl.sh start apps/apps'
```

Confirm it took, rather than trusting the exit code:

```sql
select running_processes from fnd_concurrent_queues where concurrent_queue_name='FNDICM';
-- 1 = up
```

`adcmctl.sh` exits 0 even when the ICM later dies, so the exit code alone proves
nothing.

---

## Database will not open: ORA-27104 at startup

```
[*] banco + listener
ORA-32004: obsolete or deprecated parameter(s) specified for RDBMS instance
ORA-27104: system-defined limits for shared memory was misconfigured
[*] aguardando o servico EBSDB registrar no listener
    AVISO: servico nao respondeu em 150s -- seguindo assim mesmo
adstrtal.sh: exiting with status 1
```

**Cause.** A chicken-and-egg around the SGA reduction (`-SgaGb`, automatic on
16 GB hosts). The Machine phase used to lower the VM's `kernel.shmmax` to
"reduced SGA × 1.6" — smaller than the 20G SGA of the package's **original**
spfile. The reduction step ran `startup nomount` in order to alter the spfile;
nomount loads the original spfile, which no longer fit the freshly lowered
limit, and died with ORA-27104 **before** any `alter system` could land. Net
result: the spfile kept asking for 20G, the limit stayed at ~6G, and no later
startup could ever work — not in the deploy, not in `ebs-iniciar.bat`.

**Fix.** Two-pronged, both already in the repository: the SGA reduction now
runs against a **closed** database (`create pfile from spfile` → edit →
`create spfile from pfile`; both CREATE statements work with the instance
down, no nomount involved), and `shmmax`/`shmall` became fixed roomy ceilings
— a ceiling reserves no memory, there was nothing to "save". On a machine
already bitten, just resume from the services:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AleCyriaco/r12-on-container/main/bootstrap.ps1))) -BaseUrl '<your package base URL>' -From Services
```

**Variant: ORA-00821 after the reduction.**

```
ORA-00821: Specified value of sga_target 4096M is too small, needs to be at least 4240M
ORA-01078: failure in processing system parameters
```

Same spirit, different parameter: the original spfile also **pins the pools**
(`shared_pool_size`, `db_cache_size`, `java_pool_size`…) at 20G-world sizes.
The sum of the pinned pools becomes a floor, and the reduced `sga_target`
lands below it. The reduction now drops those parameters from the pfile: with
no pinned value, ASMM sizes them automatically within `sga_target`.

**Decoys.** Three on the same screen: ORA-32004 is noise (obsolete parameters
in the package spfile, harmless); "waiting for the service to register with
the listener" suggests listener slowness when the database never started; and
`adstrtal.sh: exiting with status 1` reports wrong APPS credentials — the real
error is the first of the cascade. Since the fix, startup aborts immediately
with "o banco nao abriu" instead of letting the cascade unfold.

---

## Machine will not start: HCS_E_CONNECTION_TIMEOUT

```
Starting machine "ebs"
The operation timed out because a response was not received from the virtual machine or container.
Error code: Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT
Error: the WSL bootstrap script failed: ... exit status 0xffffffff
```

**Cause.** The Host Compute Service asked WSL2 to create the VM and got no
answer in time; podman just relays the error. Almost always one of: stale
state from a previous attempt (or from a Fast Startup "Shut down", which
hibernates the kernel and does not reset the virtualization service), not
enough free host RAM at boot, an outdated WSL, or third-party antivirus
sitting on `vmcompute`.

**Fix.** The deploy recovers on its own: it tears WSL down
(`podman machine stop` + `wsl --shutdown`), waits and retries, up to three
times. If all three are spent, in order of likelihood:

1. Close RAM-hungry apps and re-run the same command with `-From Machine` — a
   16 GB host is borderline for this VM.
2. `wsl --update`, then **restart** Windows. An actual restart: a Fast
   Startup "Shut down" does not clear the stuck service.
3. Try without third-party antivirus.
4. To take podman out of the picture: `wsl -d podman-ebs echo ok` — if it
   fails the same way, it is WSL, not this deploy.

**Decoy.** The trailing `exit status 0xffffffff` points at podman's bootstrap
script, but it never got to run: the VM did not come up. The real error is the
middle line, `Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT`.

---

## Cannot move the VM disk: ERROR_SHARING_VIOLATION

```
wsl --manage podman-ebs --move D:\path
The process cannot access the file because it is being used by another process.
```

**Cause.** The vhdx stays attached while the WSL utility VM is alive — and it
stays alive as long as *any* distribution is running, not just this one.

**Fix.** Stop everything first:

```powershell
podman machine stop <every machine>
wsl --shutdown
wsl --manage podman-ebs --move D:\path
```

---

## The download returns HTML instead of the file

The download finishes suspiciously fast and the file starts with `<html`.

**Cause.** The bucket answered with an error page carrying HTTP 200: public
read not enabled, a wrong path under `-BaseUrl`, or a CDN error page.

**Detection.** A `.tar.zst` starts with the magic bytes `28 b5 2f fd`:

```bash
head -c 4 file.tar.zst | od -An -tx1
```

The deployment checks this, and checks SHA-256 against `manifest.txt` when
present. Without that check the failure surfaces half an hour later as an
incomprehensible `tar` error. On a size mismatch it also prints the first 200
bytes of what actually arrived, which usually names the real problem.

**Fix.** Confirm the objects are publicly readable and that
`<BaseUrl>/manifest.txt` opens in a browser, then re-run with
`-From Download` — parts already verified are skipped in seconds.

---

## The VM has more or less RAM than requested

`podman machine init --memory` is partly advisory on WSL: the global
`%USERPROFILE%\.wslconfig` wins, and its default is half the host's RAM.

Check what you actually got:

```powershell
podman machine ssh ebs "free -g; nproc"
```

To pin it, create `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=40GB
processors=8
```

---

## Freeing space inside the VM does not free space on Windows

The `ext4.vhdx` only grows. Deleting 37 GB inside the VM returns exactly zero
bytes to the host — the space is reused internally but never handed back.

To reclaim it, stop the machine and compact the disk. That means downtime, so
it is a deliberate step, not something the deployment does behind your back.

---

## Verifying an instance is genuinely healthy

Exit codes lie here. Check the observable state instead:

```bash
# HTTP: 302 and 200 are the expected answers
curl -s -o /dev/null -w '%{http_code}\n' http://apps.example.com:8000/OA_HTML/AppsLogin
curl -s -o /dev/null -w '%{http_code}\n' 'http://apps.example.com:8000/forms/frmservlet?config=EBSDB'

# WebLogic: AdminServer plus the enabled managed servers
podman exec ebs bash -lc 'ps -eo args | grep -o "weblogic.Name=[A-Za-z0-9_-]\+" | sort -u'

# Concurrent manager
podman exec ebs bash -lc 'pgrep -c FNDLIBR'
```

`forms-c4ws_server1` and `oaea_server1` are frequently `disabled` in the context
file. Their absence is configuration, not failure — confirm before chasing it:

```bash
grep -oE '<oa_service_status oa_var="s_[a-z0-9-]+status">[a-z]+' \
  $INST_TOP/appl/admin/*.xml
```
