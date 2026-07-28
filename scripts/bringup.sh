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
APPSHOST="${APPS_HOST:-apps.example.com}"

if [ -z "$WLSPWD" ]; then
  echo "ERRO: informe a senha do WebLogic / provide the WebLogic password." >&2
  echo "      WLS_PASSWORD=xxx bash bringup.sh   |   bash bringup.sh xxx" >&2
  exit 1
fi

podman start "$CTR" >/dev/null 2>&1 || true
sleep 3

# O podman REGENERA o /etc/hosts a cada start do container -- a linha com o
# nome canonico se perde. O tnsnames aponta para esse nome, entao sem
# reaplicar o banco fica inacessivel com ORA-12560 e o adstrtal reporta
# "credenciais erradas". Tem que ser antes de subir qualquer coisa, e com
# "cat >" porque /etc/hosts e bind mount (sed -i falha com "resource busy").
# podman REGENERATES /etc/hosts on every container start, dropping the
# canonical-name line. tnsnames points at that name, so without re-applying it
# the database is unreachable (ORA-12560) and adstrtal blames the credentials.
echo "[*] reaplicando o nome canonico no /etc/hosts do container"
IP=$(podman inspect "$CTR" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
if [ -n "$IP" ]; then
  podman exec -i "$CTR" bash -s <<EOF
grep -v -e '$APPSHOST' -e 'apps ebs\$' /etc/hosts > /tmp/h
printf '%s\t%s apps ebs\n' '$IP' '$APPSHOST' >> /tmp/h
cat /tmp/h > /etc/hosts
EOF
  echo "    $IP $APPSHOST apps ebs"
else
  echo "    AVISO: nao consegui obter o IP do container"
fi

echo "[*] banco + listener"
# stop+start (nao so start): se o listener ja tinha subido antes da correcao do
# /etc/hosts, ele esta com o binding errado. E "lsnrctl stop" no ORACLE_HOME
# certo, nunca "pkill -f tnslsnr" -- esse padrao casa tambem com o listener do
# apps tier na 1626 e derruba os dois.
podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl stop  >/dev/null 2>&1
  lsnrctl start >/dev/null 2>&1
  sqlplus -s / as sysdba <<< "startup;"
  # o listener sobe antes do banco e fica sem servicos; forcar o registro
  # encurta a espera do PMON, que so registraria sozinho em ~60s
  sqlplus -s / as sysdba <<< "alter system register;" >/dev/null 2>&1' 2>&1 |
  grep -viE "^$|already" | tail -5

# Esperar o servico EBSDB aceitar conexao ANTES do adstrtal. Sem isso ele roda
# na janela entre "banco aberto" e "servico registrado no listener", falha ao
# conectar e reporta "Database connection could not be established. Either the
# database is down or the APPS credentials supplied are wrong" -- mensagem que
# acusa credenciais quando o problema e temporizacao.
# Wait for the EBSDB service to accept connections BEFORE adstrtal, otherwise
# it runs in the gap between "database open" and "service registered" and
# blames the APPS credentials for what is a timing problem.
echo "[*] aguardando o servico EBSDB registrar no listener"
db_pronto() {
  podman exec -i -u oracle "$CTR" bash -lc "
    source /u01/install/APPS/EBSapps.env run >/dev/null 2>&1
    sqlplus -s -L apps/$APPSPWD@EBSDB" <<'SQL' 2>/dev/null | grep -q PRONTO
set heading off feedback off pagesize 0
select 'PRONTO' from dual;
exit
SQL
}
for i in $(seq 1 30); do
  if db_pronto; then
    echo "    servico disponivel apos $((i*5))s"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "    AVISO: servico nao respondeu em 150s -- seguindo assim mesmo"
  fi
  sleep 5
done

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
