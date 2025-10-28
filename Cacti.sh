#!/usr/bin/env bash
# Instalação completa do Cacti + dependências + Apache + MariaDB + PHP + SNMP + Configuração inicial
# Testado em Debian 12/13 e Ubuntu 22.04+. Executar como root.
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Execute como root: sudo $0"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

log(){ echo -e "\e[1;32m==>\e[0m $*"; }
warn(){ echo -e "\e[1;33m[AVISO]\e[0m $*"; }
die(){ echo -e "\e[1;31m[ERRO]\e[0m $*"; exit 1; }

# ------------------ 1. Instalação de pacotes ------------------
log "Atualizando pacotes..."
apt update

log "Instalando Apache, PHP e extensões..."
apt install -y apache2 php php-mysql libapache2-mod-php php-xml php-ldap php-mbstring php-gd php-gmp php-intl php-snmp

log "Instalando MariaDB (server e client)..."
apt install -y mariadb-server mariadb-client

log "Instalando SNMP e RRDTool..."
apt install -y snmp rrdtool librrds-perl

# ------------------ 2. Ajuste do MariaDB ------------------
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
BACKUP="$MARIADB_CNF.$(date +%Y%m%d-%H%M%S).bak"

[[ -f "$MARIADB_CNF" ]] || die "Arquivo $MARIADB_CNF não encontrado."
log "Backup do arquivo de configuração: $BACKUP"
cp -a "$MARIADB_CNF" "$BACKUP"

cat <<'EOF' >> "$MARIADB_CNF"

############################################
# Cacti / Performance tuning
[mysqld]
collation-server = utf8mb4_unicode_ci
max_heap_table_size = 128M
tmp_table_size = 64M
join_buffer_size = 64M
innodb_file_format = Barracuda
innodb_large_prefix = 1
innodb_buffer_pool_size = 512M
innodb_flush_log_at_timeout = 3
innodb_read_io_threads = 32
innodb_write_io_threads = 16
innodb_doublewrite = 0
sort_buffer_size = 60M
############################################
EOF

log "Reiniciando MariaDB..."
systemctl restart mariadb

# ------------------ 3. Configuração do PHP ------------------
PHP_V="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo 7.4)"
PHP_INI_APACHE="/etc/php/${PHP_V}/apache2/php.ini"
PHP_INI_CLI="/etc/php/${PHP_V}/cli/php.ini"

adjust_php_ini(){
  local file="$1"
  [[ -f "$file" ]] || { warn "php.ini não encontrado: $file"; return; }
  log "Ajustando parâmetros em $file"
  sed -i -E 's~^\s*;?\s*date\.timezone\s*=.*~date.timezone = US/Central~' "$file" || true
  sed -i -E 's~^\s*;?\s*memory_limit\s*=.*~memory_limit = 512M~' "$file" || true
  sed -i -E 's~^\s*;?\s*max_execution_time\s*=.*~max_execution_time = 60~' "$file" || true
  grep -q 'date.timezone' "$file" || echo "date.timezone = America/Fortaleza" >> "$file"
}
adjust_php_ini "$PHP_INI_APACHE"
adjust_php_ini "$PHP_INI_CLI"

log "Reiniciando Apache..."
systemctl restart apache2

# ------------------ 4. Banco de dados Cacti ------------------
log "Criando banco de dados Cacti..."
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS cacti;"
mysql -uroot -e "GRANT ALL ON cacti.* TO 'cacti'@'localhost' IDENTIFIED BY 'cacti';"
mysql -uroot -e "FLUSH PRIVILEGES;"

TZ_SQL="/usr/share/mysql/mysql_test_data_timezone.sql"
if [[ -f "$TZ_SQL" ]]; then
  log "Importando time zones MySQL..."
  mysql -uroot mysql < "$TZ_SQL"
else
  warn "Arquivo $TZ_SQL não encontrado. Pulando import."
fi

log "Atribuindo permissões SELECT para time zones..."
mysql -uroot -e "GRANT SELECT ON mysql.time_zone_name TO 'cacti'@'localhost';"
mysql -uroot -e "FLUSH PRIVILEGES;"

# ------------------ 5. Download e instalação do Cacti ------------------
log "Baixando Cacti..."
cd /tmp
wget -q https://www.cacti.net/downloads/cacti-latest.tar.gz -O cacti-latest.tar.gz
tar -zxf cacti-latest.tar.gz
CACTI_DIR=$(find . -maxdepth 1 -type d -name 'cacti-*' | head -n1)
[[ -n "$CACTI_DIR" ]] || die "Não foi possível extrair o pacote Cacti."
mv "$CACTI_DIR" /opt/cacti

log "Importando estrutura SQL do Cacti..."
mysql -uroot cacti < /opt/cacti/cacti.sql

# ------------------ 6. Configuração do config.php ------------------
log "Criando /opt/cacti/include/config.php..."
cat <<'EOF' > /opt/cacti/include/config.php
<?php
/* make sure these values reflect your actual database/host/user/password */
$database_type = "mysql";
$database_default = "cacti";
$database_hostname = "localhost";
$database_username = "cacti";
$database_password = "cacti";
$database_port = "3306";
$database_ssl = false;
?>
EOF

# ------------------ 7. Configuração do cron do Cacti ------------------
log "Criando tarefa CRON para o poller do Cacti..."
echo "*/5 * * * * www-data php /opt/cacti/poller.php > /dev/null 2>&1" > /etc/cron.d/cacti

# ------------------ 8. Configuração do site Apache ------------------
log "Criando VirtualHost do Cacti..."
cat <<'EOF' > /etc/apache2/sites-available/cacti.conf
Alias /cacti /opt/cacti

<Directory /opt/cacti>
    Options +FollowSymLinks
    AllowOverride None
    <IfVersion >= 2.3>
        Require all granted
    </IfVersion>
    <IfVersion < 2.3>
        Order Allow,Deny
        Allow from all
    </IfVersion>
</Directory>

AddType application/x-httpd-php .php

<IfModule mod_php.c>
    php_flag magic_quotes_gpc Off
    php_flag short_open_tag On
    php_flag register_globals Off
    php_flag register_argc_argv On
    php_flag track_vars On
    # this setting is necessary for some locales
    php_value mbstring.func_overload 0
    php_value include_path .
</IfModule>

DirectoryIndex index.php
EOF

log "Habilitando site do Cacti..."
echo "ServerName localhost" >> /etc/apache2/apache2.conf 
a2ensite cacti > /dev/null
systemctl reload apache2

# ------------------ 9. Permissões e log ------------------
log "Ajustando permissões e criando log do Cacti..."
touch /opt/cacti/log/cacti.log
chown -R www-data:www-data /opt/cacti/

# ------------------ 10. Finalização ------------------
log "Instalação concluída!"
echo
echo "Acesse via navegador:  http://$(hostname -I | awk '{print $1}')/cacti"
echo "Usuário padrão: admin / Senha: admin"
echo
echo "Backup do arquivo MariaDB: $BACKUP"
