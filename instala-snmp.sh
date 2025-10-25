#!/usr/bin/env bash
# deploy_and_run_snmp.sh
# Descrição: copia e executa remotamente setup_snmp_environment.sh em múltiplos hosts via SSH (usuário/senha)
#            e reinicia o host no fim.
# Uso:
#   ./deploy_and_run_snmp.sh -u usuario -p senha -f hosts.txt
#   ou
#   ./deploy_and_run_snmp.sh -u usuario -p senha host1 host2 host3
#
# Requisitos no host local: ssh, scp, sshpass (o script instala sshpass se não existir).
#
set -euo pipefail

# --- Configurações padrão ---
SSH_USER=""
SSH_PASS=""
HOSTS_FILE=""
TIMEOUT_SSH=120
REMOTE_SCRIPT="setup_snmp_environment.sh"   # nome do script local que será copiado e executado remotamente
REMOTE_DEST="/tmp/${REMOTE_SCRIPT}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

log()   { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }

usage(){
  cat <<EOF
Uso:
  $0 -u <usuario> -p <senha> -f <hosts.txt>
  OU
  $0 -u <usuario> -p <senha> host1 host2 host3

Formato de hosts.txt: um host por linha (IP ou hostname). Comentários com '#'.
Exemplo de hosts.txt:
  192.168.1.10
  192.168.1.11

Observações de segurança:
 - Este script usa senha em linha de comando (sshpass); evite em redes inseguras.
 - Preferível usar chaves SSH em produção.
EOF
  exit 1
}

# --- Parsers de argumentos ---
if [[ $# -eq 0 ]]; then usage; fi

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user) SSH_USER="$2"; shift 2;;
    -p|--pass) SSH_PASS="$2"; shift 2;;
    -f|--file) HOSTS_FILE="$2"; shift 2;;
    -h|--help) usage;;
    --) shift; break;;
    -*)
      echo "Opção desconhecida: $1"; usage;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done
set -- "${POSITIONAL[@]}"

# Validações básicas
if [[ -z "$SSH_USER" || -z "$SSH_PASS" ]]; then
  error "Usuário e senha SSH são obrigatórios (-u e -p)."
  usage
fi

HOSTS=()
if [[ -n "$HOSTS_FILE" ]]; then
  if [[ ! -f "$HOSTS_FILE" ]]; then
    error "Arquivo de hosts não encontrado: $HOSTS_FILE"
    exit 2
  fi
  mapfile -t tmphosts < <(grep -Ev '^\s*(#|$)' "$HOSTS_FILE")
  HOSTS+=("${tmphosts[@]}")
fi

# Hosts passados como argumentos posicionais
if [[ $# -gt 0 ]]; then
  for h in "$@"; do
    HOSTS+=("$h")
  done
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  error "Nenhum host fornecido."
  usage
fi

# Verifica existência do script local que será enviado
if [[ ! -f "$REMOTE_SCRIPT" ]]; then
  error "Arquivo ${REMOTE_SCRIPT} não encontrado no diretório atual. Coloque o script a ser executado remotamente no mesmo diretório e rode novamente."
  exit 3
fi

# Instalar sshpass se não existir (tentativa automática)
if ! command -v sshpass >/dev/null 2>&1; then
  log "sshpass não encontrado. Instalando sshpass..."
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y sshpass
  else
    warn "Não foi possível instalar sshpass automaticamente (apt não disponível). Instale sshpass manualmente e rode novamente."
    exit 4
  fi
fi

# Função que executa deploy+run em um host
run_on_host(){
  local host="$1"
  log "=== Iniciando deploy em: $host ==="

  # 1) Copiar o script para o host remoto (em /tmp)
  log "Copiando ${REMOTE_SCRIPT} para ${host}:${REMOTE_DEST} ..."
  if ! sshpass -p "$SSH_PASS" scp $SSH_OPTS "$REMOTE_SCRIPT" "${SSH_USER}@${host}:${REMOTE_DEST}"; then
    warn "Falha no scp para $host. Pulando."
    return 1
  fi

  # 2) Tornar executável e executar via sudo (passando senha para sudo via stdin)
  #    Executa: printf 'SENHA\n' | sudo -S bash -c "/tmp/setup_snmp_environment.sh"
  log "Executando remotamente o script em $host (com sudo)..."
  # Usamos timeout para limitar tempo de execução remota
  SSH_CMD="printf '%s\n' '${SSH_PASS}' | sudo -S bash -c 'chmod +x \"${REMOTE_DEST}\" && \"${REMOTE_DEST}\"'"
  if ! sshpass -p "$SSH_PASS" ssh $SSH_OPTS "${SSH_USER}@${host}" "timeout ${TIMEOUT_SSH}s bash -lc \"$SSH_CMD\""; then
    warn "Execução remota falhou em $host. Verifique logs e conectividade."
    return 2
  fi

  # 3) Agendar reinício (reboot) imediato no final da execução
  #    Usamos 'printf senha | sudo -S reboot -f' para forçar reboot
  log "Reiniciando $host agora..."
  SSH_REBOOT_CMD="printf '%s\n' '${SSH_PASS}' | sudo -S bash -c 'sleep 2 && /sbin/reboot -f'"
  if ! sshpass -p "$SSH_PASS" ssh $SSH_OPTS "${SSH_USER}@${host}" "bash -lc \"$SSH_REBOOT_CMD\"" >/dev/null 2>&1; then
    warn "Comando de reboot pode ter falhado (ou host já reiniciando)."
  else
    log "Comando de reboot enviado para $host."
  fi

  log "=== Concluído para: $host ==="
  return 0
}

# Loop sobre hosts (sequencial)
SUCCESS=0
FAIL=0
for h in "${HOSTS[@]}"; do
  if run_on_host "$h"; then
    SUCCESS=$((SUCCESS+1))
  else
    FAIL=$((FAIL+1))
  fi
done

echo
log "Resumo: Sucesso = ${SUCCESS}, Falhas = ${FAIL}"
if [[ $FAIL -gt 0 ]]; then
  warn "Alguns hosts falharam. Verifique saída acima e ssh/scp/credenciais."
fi

exit 0
