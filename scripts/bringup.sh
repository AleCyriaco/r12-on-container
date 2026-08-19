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
DB=$(podman exec -i -u oracle "$CTR" bash -lc '
  source /u01/install/APPS/19.0.0/EBSCDB_apps.env
  lsnrctl stop  >/dev/null 2>&1
  lsnrctl start >/dev/null 2>&1
  sqlplus -s / as sysdba <<< "startup;"
  # o listener sobe antes do banco e fica sem servicos; forcar o registro
  # encurta a espera do PMON, que so registraria sozinho em ~60s
  sqlplus -s / as sysdba <<< "alter system register;" >/dev/null 2>&1' 2>&1)
echo "$DB" | grep -viE "^$|already" | tail -5
# Sem banco aberto o resto e perda de tempo: a espera de 150s estoura e o
# adstrtal falha culpando as credenciais do APPS, com o erro real la em cima.
# ORA-01081 = "ja estava aberto", que aqui conta como sucesso.
# Without an open database the rest is wasted time: the 150s wait expires and
# adstrtal blames the APPS credentials for what actually failed right here.
if ! echo "$DB" | grep -qiE "Database opened|ORA-01081"; then
  echo ""
  echo "ERRO: o banco nao abriu -- parando aqui."
  echo "      ORA-27104/ORA-00845 = limites de memoria x SGA do spfile."
  echo "      Correcao e contexto: docs/TROUBLESHOOTING.pt-BR.md (ORA-27104)."
  echo "ERROR: database did not open; see docs/TROUBLESHOOTING.md (ORA-27104)."
  exit 1
fi

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
APPSOUT=$(printf '%s\n' "$WLSPWD" | podman exec -i -u oracle "$CTR" bash -lc "
  source /u01/install/APPS/EBSapps.env run
  \$ADMIN_SCRIPTS_HOME/adstrtal.sh apps/$APPSPWD" 2>&1)
echo "$APPSOUT" | grep -E "exiting with status|Exiting with status|ERROR"

# Senha errada e falha generica saem as duas como "AdminServer is down", entao
# separe as duas aqui: "Invalid credentials passed" vem do nmConnect e significa
# senha do WebLogic recusada. O NodeManager em si subiu -- o log dele mostra
# "Plain socket listener started on port 5556" -- e e justamente isso que faz
# perder tempo cacando o NodeManager. A senha de fabrica do pacote e 'welcome1'.
# Wrong password and generic failure both surface as "AdminServer is down";
# "Invalid credentials passed" comes from nmConnect and means the WebLogic
# password was rejected, even though the NodeManager itself started fine.
APPSFAIL=0
if echo "$APPSOUT" | grep -q "Invalid credentials passed"; then
  APPSFAIL=1
  echo ""
  echo "ERRO: o NodeManager recusou a senha do WebLogic."
  echo "      Confira WLS_PASSWORD: a senha de fabrica do pacote e 'welcome1'."
  echo "ERROR: NodeManager rejected the WebLogic password (factory: 'welcome1')."
elif echo "$APPSOUT" | grep -qE "ServiceControl is exiting with status [1-9]"; then
  APPSFAIL=1
  echo ""
  echo "ERRO: a pilha de aplicacao nao subiu por completo."
  echo "ERROR: the application tier did not come up completely."
fi

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
VER=$(podman exec "$CTR" bash -lc '
  printf "  AppsLogin  : "; curl -s -o /dev/null -w "%{http_code}\n" http://apps.example.com:8000/OA_HTML/AppsLogin
  printf "  frmservlet : "; curl -s -o /dev/null -w "%{http_code}\n" "http://apps.example.com:8000/forms/frmservlet?config=EBSDB"' 2>&1)
echo "$VER"
echo "  esperado / expected: 302 e 200"

# Este script terminava SEMPRE em 0: sem "set -e", o adstrtal saindo 1 nao
# interrompia nada e o status final era o do ultimo echo. O painel marcava 100%
# e o .rc ficava 0 com o WebLogic fora do ar -- o bring-up mentia. O status
# agora reflete o que de fato subiu.
# This script always exited 0: without "set -e" a failing adstrtal changed
# nothing and the final status came from the last echo, so the panel reported
# 100% with WebLogic down. The exit status now reflects what actually started.
if [ "$APPSFAIL" = "1" ] || ! echo "$VER" | grep -qE "AppsLogin *: (200|302)"; then
  echo ""
  echo "ERRO: bring-up incompleto -- o AppsLogin nao respondeu 200/302."
  echo "ERROR: incomplete bring-up -- AppsLogin did not answer 200/302."
  exit 1
fi

echo "[*] tudo no ar / all up"
exit 0
