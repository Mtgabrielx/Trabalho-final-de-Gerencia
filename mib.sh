#!/usr/bin/env bash
# Configuração automatizada do ambiente SNMP (cliente e servidor)
# Testado em Debian 12/13 e Ubuntu 22.04+. Executar como root.

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Execute como root: sudo $0"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

log(){ echo -e "\e[1;32m==>\e[0m $*"; }
warn(){ echo -e "\e[1;33m[AVISO]\e[0m $*"; }
die(){ echo -e "\e[1;31m[ERRO]\e[0m $*"; exit 1; }

# ------------------ 1. Atualização e pacotes ------------------
log "Atualizando pacotes..."
apt update

log "Instalando dependências SNMP..."
apt install -y libsnmp-dev tkmib snmpd iperf3 speedtest-cli

# ------------------ 2. Ajustar /etc/snmp/snmp.conf ------------------
SNMP_CONF="/etc/snmp/snmp.conf"
if [[ -f "$SNMP_CONF" ]]; then
  log "Comentando linha 'mibs :' em $SNMP_CONF"
  sed -i 's/^\s*mibs\s*:/# mibs :/' "$SNMP_CONF"
else
  warn "$SNMP_CONF não encontrado, criando..."
  echo "# mibs :" > "$SNMP_CONF"
fi

# ------------------ 3. Tentar instalar snmp-mibs-downloader (opcional) ------------------
# Debian 13 removeu o pacote dos repositórios oficiais, então fazemos tentativa segura
log "Tentando instalar snmp-mibs-downloader (se disponível)..."
if apt-cache show snmp-mibs-downloader >/dev/null 2>&1; then
  apt install -y snmp-mibs-downloader
else
  warn "Pacote snmp-mibs-downloader não encontrado no repositório atual (Debian 13 removeu)."
  warn "Você pode baixar manualmente as MIBs de https://github.com/net-snmp/net-snmp/tree/master/mibs"
fi

# ------------------ 4. Ajuste do snmpd.conf ------------------
SNMPD_CONF="/etc/snmp/snmpd.conf"
BACKUP_SNMPD="$SNMPD_CONF.$(date +%Y%m%d-%H%M%S).bak"

if [[ -f "$SNMPD_CONF" ]]; then
  log "Backup do snmpd.conf: $BACKUP_SNMPD"
  cp -a "$SNMPD_CONF" "$BACKUP_SNMPD"

  log "Atualizando seções 'view systemonly'..."
  # Substitui as linhas de view systemonly existentes
  sed -i '/^view systemonly/d' "$SNMPD_CONF"
  cat <<'EOF' >> "$SNMPD_CONF"

# ---- Custom SNMP views (simplificadas) ----
view systemonly included .1.3.6.1.2.1.1
view systemonly included .1.3.6.1.2.1.2
EOF

  log "Ajustando agentAddress para permitir acesso remoto (udp:161,[::1])..."
  sed -i 's/^agentaddress .*/agentaddress udp:161,[::1]/' "$SNMPD_CONF"
else
  die "$SNMPD_CONF não encontrado. O pacote snmpd foi instalado corretamente?"
fi

# ------------------ 5. Reiniciar serviço SNMP ------------------
log "Reiniciando snmpd..."
systemctl restart snmpd
systemctl enable snmpd

# ------------------ 6. Teste rápido ------------------
log "Verificando status do snmpd..."
systemctl --no-pager status snmpd | grep Active

echo
echo "✅ Configuração SNMP concluída com sucesso!"
echo
echo "Verifique o serviço com:  snmpwalk -v2c -c public 127.0.0.1 system"
echo "Backup do snmpd.conf em:  $BACKUP_SNMPD"
