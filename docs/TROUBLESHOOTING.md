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

## Google Drive returns HTML instead of the file

The download finishes suspiciously fast and the file starts with `<html`.

**Cause.** Quota exceeded on the public file, or the folder is not actually
shared publicly. Google serves an error page with HTTP 200.

**Detection.** A `.tar.zst` starts with the magic bytes `28 b5 2f fd`:

```bash
head -c 4 file.tar.zst | od -An -tx1
```

The deployment checks this, and checks SHA-256 against `manifest.txt` when
present. Without that check the failure surfaces half an hour later as an
incomprehensible `tar` error.

**Fix.** Wait for the quota to reset, or split into more parts — quota is
tracked per file.

---

## Folder listing finds nothing

```
nao achei a listagem na pagina da pasta
```

**Cause.** There is no key-free API to list a public Drive folder. This parses
the `_DRIVE_ivd` blob from the page HTML, the same approach `gdown` uses, and
Google changes that markup without notice.

Two details that are easy to get wrong when repairing it:

- the assignment is `window['_DRIVE_ivd'] = '...'` — the `']` sits between the
  name and the `=`
- once the `\xNN` escapes are decoded, each entry reads
  `"<id>",["<parentId>"],"<name>"` — the parent is a **nested array**, not a
  bare string

**Fix.** Bypass it with explicit IDs:

```powershell
.\Deploy-R12.ps1 -VolumeFileId '1abc...' -ImageFileId '1xyz...'
```

Note that this path has no manifest, so verification drops to the magic number.

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
