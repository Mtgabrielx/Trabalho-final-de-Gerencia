#!/usr/bin/env bash
# cacti_bulk_add_cli.sh
# Uso: ./cacti_bulk_add_cli.sh hosts.txt
# hosts.txt format (CSV): ip,hostname,description,community,snmp_version,host_template_name,host_group_name
# Exemplo linha:
# 192.168.1.10,SR-SW01,"Switch core","public",2,"Generic SNMP Device","Network Devices"

set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Execute como root" && exit 1

HOSTS_FILE="${1:-hosts.txt}"
CACTI_CLI_CANDIDATES=(
  "/opt/cacti/cli/add_device.php"
  "/usr/share/cacti/cli/add_device.php"
)

# Detecta add_device.php
CACTI_ADD_DEVICE=""
for p in "${CACTI_CLI_CANDIDATES[@]}"; do
  if [[ -x "$p" || -f "$p" ]]; then
    CACTI_ADD_DEVICE="$p"
    break
  fi
done

if [[ -z "$CACTI_ADD_DEVICE" ]]; then
  echo "Não foi encontrado add_device.php em locais padrões. Verifique a instalação do Cacti em /opt/cacti/cli."
  echo "O script vai gerar um arquivo SQL (import_cacti_devices.sql) como fallback."
  USE_CLI=0
else
  echo "Usando CLI: $CACTI_ADD_DEVICE"
  USE_CLI=1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Arquivo de hosts não encontrado: $HOSTS_FILE"
  exit 2
fi

# cria arquivos de log
LOG="./cacti_bulk_add.log"
SQL_OUT="./import_cacti_devices.sql"
: > "$LOG"
: > "$SQL_OUT"

while IFS= read -r line || [[ -n "$line" ]]; do
  # pula comentários e linhas vazias
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  # parse CSV simples (não suporta vírgulas dentro de campos)
  IFS=',' read -r IP HOSTNAME DESC COMMUNITY SNMP_VER TEMPLATE GROUPNAME <<< "$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"

  # default values
  COMMUNITY="${COMMUNITY:-public}"
  SNMP_VER="${SNMP_VER:-2}"
  TEMPLATE="${TEMPLATE:-\"Generic SNMP Device\"}"
  GROUPNAME="${GROUPNAME:-\"Network\"}"
  DESC="${DESC:-$HOSTNAME}"

  echo "Processando $IP ($HOSTNAME) ..." | tee -a "$LOG"

  if [[ "$USE_CLI" -eq 1 ]]; then
    # Exemplo de chamada — **verifique** flags com --help e ajuste se necessário.
    # Muitas instalações usam: php add_device.php --host="$IP" --description="$DESC" --snmp_community="$COMMUNITY" --snmp_version="$SNMP_VER" --host_template="$TEMPLATE" --host_group="$GROUPNAME"
    # Como cada versão pode ter flags diferentes, primeiro mostramos help (apenas na primeira iteração).
    if [[ ! -f ".cli_help_shown" ]]; then
      echo "Mostrando ajuda do add_device.php para você confirmar flags..." | tee -a "$LOG"
      php "$CACTI_ADD_DEVICE" --help 2>&1 | tee -a "$LOG"
      touch .cli_help_shown
      echo "Se as flags exibidas forem diferentes das usadas abaixo, ajuste o script." | tee -a "$LOG"
    fi

    # chamada tentativa — ajuste as flags conforme sua versão do add_device.php
    php "$CACTI_ADD_DEVICE" \
      --host="$IP" \
      --description="$DESC" \
      --hostname="$HOSTNAME" \
      --snmp_community="$COMMUNITY" \
      --snmp_version="$SNMP_VER" \
      --host_template="$TEMPLATE" \
      --host_group="$GROUPNAME" \
      >> "$LOG" 2>&1 || echo "Falha ao adicionar $IP — verifique $LOG"

  else
    # Fallback: gera statements SQL básicos (ATENÇÃO: revise antes de importar)
    # Observação: schema pode variar. Ajuste os nomes de colunas conforme sua versão do Cacti.
    cat >> "$SQL_OUT" <<SQL
-- INSERT device for $IP ($HOSTNAME)
INSERT INTO host (description, hostname, ip, snmp_version, snmp_community, snmp_port) VALUES ('$DESC', '$HOSTNAME', '$IP', '$SNMP_VER', '$COMMUNITY', 161);
-- (Atenção: ajuste para o schema real do seu Cacti antes de importar)
SQL
  fi

done < "$HOSTS_FILE"

echo "Concluído. Logs: $LOG"
if [[ -f "$SQL_OUT" && -s "$SQL_OUT" ]]; then
  echo "SQL gerado em: $SQL_OUT (revisar antes de importar)"
fi
