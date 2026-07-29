#!/bin/bash
# Para o EBS na ordem correta: aplicacao -> banco -> container.
# Stops EBS in the right order: application -> database -> container.
#
# A senha do WebLogic vem de WLS_PASSWORD ou do primeiro argumento. Sem
# credencial embutida: este arquivo vive num repositorio publico.
#
# NUNCA use "pkill -f tnslsnr" aqui: esse padrao casa com os DOIS listeners
# (banco na 1521, apps tier na 1626) e derruba os dois de uma vez. Use
# lsnrctl stop no ORACLE_HOME certo, ou pare o container ao final.
set -uo pipefail

CTR="${CTR:-ebs}"
WLSPWD="${1:-${WLS_PASSWORD:-}}"
APPSPWD="${APPS_PASSWORD:-apps}"

if [ -z "$WLSPWD" ]; then
  echo "ERRO: informe a senha do WebLogic / provide the WebLogic password." >&2
  echo "      WLS_PASSWORD=xxx bash parar-ebs.sh   |   bash parar-ebs.sh xxx" >&2
  exit 1
fi

echo "[*] parando a pilha de aplicacao (alguns minutos)"
printf '%s\n' "$WLSPWD" | podman exec -i -u oracle "$CTR" bash -lc "
  source /u01/install/APPS/EBSapps.env run
  \$ADMIN_SCRIPTS_HOME/adstpall.sh apps/$APPSPWD" 2>&1 |
  grep -E "Exiting with status|ERROR" | tail -3

echo "[*] parando o banco"
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  sqlplus -s / as sysdba <<< "shutdown immediate;"
  lsnrctl stop' 2>&1 | grep -viE "^$" | tail -4

echo "[*] parando o container"
podman stop -t 60 "$CTR" >/dev/null 2>&1
podman ps -a --format "    {{.Names}} {{.Status}}" | grep "$CTR"

echo "[*] EBS parado. Para desligar tambem a VM:  podman machine stop $CTR"
