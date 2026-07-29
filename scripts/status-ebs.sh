#!/bin/bash
# Estado observavel do EBS. Codigo de saida de script mente aqui -- o que vale
# e o que responde: HTTP, processos e o que o banco diz de si mesmo.
set -uo pipefail
CTR="${CTR:-ebs}"
APPSPWD="${APPS_PASSWORD:-apps}"

echo "  container : $(podman ps -a --format '{{.Status}}' --filter name=^${CTR}$ 2>/dev/null || echo 'nao existe')"

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
  echo "  container parado -- nada mais a checar"
  exit 0
fi

echo "  banco     : $(podman exec "$CTR" bash -lc 'pgrep -c ora_pmon 2>/dev/null || echo 0') instancia(s) pmon"
podman exec -i -u oracle "$CTR" bash -lc "
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env 2>/dev/null
  sqlplus -s / as sysdba" <<'SQL' 2>/dev/null | sed 's/^/  /' | grep -v '^  *$'
set heading off feedback off pagesize 0
select 'CDB       : '||name||' '||open_mode from v$database;
select 'PDB       : '||name||' '||open_mode from v$pdbs where name='EBSDB';
select 'SGA       : '||round(value/1024/1024/1024,1)||' GB' from v$parameter where name='sga_target';
exit
SQL

echo "  WebLogic  : $(podman exec "$CTR" bash -lc 'ps -eo args | grep -o "weblogic.Name=[A-Za-z0-9_-]\+" | sort -u | sed "s/weblogic.Name=//" | tr "\n" " "' 2>/dev/null)"
echo "  FNDLIBR   : $(podman exec "$CTR" bash -lc 'pgrep -c FNDLIBR 2>/dev/null || echo 0') processos"

printf '  AppsLogin : '
podman exec "$CTR" bash -lc 'curl -s -o /dev/null -w "%{http_code}\n" http://apps.example.com:8000/OA_HTML/AppsLogin' 2>/dev/null || echo '---'
printf '  frmservlet: '
podman exec "$CTR" bash -lc 'curl -s -o /dev/null -w "%{http_code}\n" "http://apps.example.com:8000/forms/frmservlet?config=EBSDB"' 2>/dev/null || echo '---'
echo "  esperado  : 302 e 200"
