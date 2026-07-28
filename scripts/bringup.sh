#!/bin/bash
# Sobe o EBS inteiro / Brings the whole EBS stack up.
#
# Rodar dentro da maquina podman / run inside the podman machine:
#   podman machine start ebs
#   podman machine ssh ebs 'WLS_PASSWORD=xxx bash /mnt/d/r12/scripts/bringup.sh'
#
# A senha do WebLogic vem de WLS_PASSWORD ou do primeiro argumento. Nao ha
# credencial embutida: este arquivo vive num repositorio publico.
# The WebLogic password comes from $WLS_PASSWORD or the first argument.
# No credentials are baked in: this file lives in a public repository.
#
# Ordem: banco -> listener -> pilha de aplicacao -> confere o CM.
# O container tem --restart unless-stopped, mas roda "sleep infinity":
# ele volta sozinho, os servicos do EBS nao.
set -uo pipefail

CTR="${CTR:-ebs}"
WLSPWD="${1:-${WLS_PASSWORD:-}}"
APPSPWD="${APPS_PASSWORD:-apps}"

if [ -z "$WLSPWD" ]; then
  echo "ERRO: informe a senha do WebLogic / provide the WebLogic password." >&2
  echo "      WLS_PASSWORD=xxx bash bringup.sh   |   bash bringup.sh xxx" >&2
  exit 1
fi

podman start "$CTR" >/dev/null 2>&1 || true
sleep 3

echo "[*] banco + listener"
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl start >/dev/null 2>&1
  sqlplus -s / as sysdba <<< "startup;"' 2>&1 | grep -viE "^$|already" | tail -5

echo "[*] pilha de aplicacao (varios minutos)"
# O adstrtal.sh pede a senha do WebLogic no stdin: sem "podman exec -i" ela
# chega vazia, o AdminServer falha e todos os managed servers sao pulados.
printf '%s\n' "$WLSPWD" | podman exec -i -u oracle "$CTR" bash -lc "
  source /u01/install/APPS/EBSapps.env run
  \$ADMIN_SCRIPTS_HOME/adstrtal.sh apps/$APPSPWD" 2>&1 |
  grep -E "exiting with status|Exiting with status|ERROR"

# O ICM as vezes perde a corrida com o lock da sessao anterior e morre com
# "FND_DCP.Request_Session_Lock ... result code of 1 / establish_icm failed".
# Basta subir de novo depois que o lock cai -- nao precisa de cmclean.
echo
echo "[*] conferindo o concurrent manager"
CM=$(podman exec -i -u oracle "$CTR" bash -lc "
  source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
  \$ADMIN_SCRIPTS_HOME/adcmctl.sh status apps/$APPSPWD" 2>&1 | grep -ioE "is Active|is Not Active")
echo "    $CM"
if ! echo "$CM" | grep -qi "is Active"; then
  echo "    ICM fora -- tentando subir de novo"
  sleep 20
  podman exec -i -u oracle "$CTR" bash -lc "
    source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
    \$ADMIN_SCRIPTS_HOME/adcmctl.sh start apps/$APPSPWD" 2>&1 | grep -iE "starting|exiting with status"
  sleep 60
  podman exec -i -u oracle "$CTR" bash -lc "
    source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
    \$ADMIN_SCRIPTS_HOME/adcmctl.sh status apps/$APPSPWD" 2>&1 | grep -iE "Concurrent Manager is"
fi

echo
echo "[*] verificacao"
podman exec "$CTR" bash -lc '
  printf "  AppsLogin  : "; curl -s -o /dev/null -w "%{http_code}\n" http://apps.example.com:8000/OA_HTML/AppsLogin
  printf "  frmservlet : "; curl -s -o /dev/null -w "%{http_code}\n" "http://apps.example.com:8000/forms/frmservlet?config=EBSDB"'
echo "  esperado / expected: 302 e 200"
