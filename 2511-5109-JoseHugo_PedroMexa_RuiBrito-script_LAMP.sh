#!/bin/bash

set -euo pipefail

# ===========================================================
# SIMPLE LAMP INSTALLER - FINAL v13 (UNIFIED WIZARD)
# Baseado no arquivo zproject_lamp_dario-v3.sh
# Funcoes/variaveis em ingles
# Comentarios em portugues sem acentos
# Unificacao da logica de configuracao de banco de dados
# ===========================================================

# ======================
# GLOBAL VARIABLES
# ======================
WEB_ROOT="/var/www/html"
BACKUP_DIR="/backups"
DUCKDNS_SCRIPT="/usr/local/bin/duckdns_update.sh"
ROUTER_REMINDER_NEEDED="no"
STATIC_IFACE=""
STATIC_IP=""
STATIC_GW=""
STATIC_DNS=""
STATIC_MAC=""
SSH_PORT="22"
LAST_DOMAIN=""
PUBLIC_IP=""

# Full install pre-collected values
FI_STATIC_IFACE=""
FI_STATIC_IP=""
FI_STATIC_GW=""
FI_STATIC_DNS=""
FI_SSH_PORT=""
FI_SSH_DISABLE_ROOT=""
FI_SSH_DISABLE_PASSWORD=""
FI_SSH_ALLOWED_USERS=""
FI_DOMAIN=""
FI_CERTBOT_EMAIL=""
FI_DUCKDNS_SUBDOMAIN=""
FI_DUCKDNS_TOKEN=""
FI_GIT_REPO=""
# Novas variaveis para Smart Deploy
FI_APP_DB_CREATE=""
FI_APP_DB_NAME=""
FI_APP_DB_USER=""
FI_APP_DB_PASS=""
FI_APP_CONFIG_PATH=""

# ======================
# BASIC CHECKS
# ======================
check_root() {
if [ "$EUID" -ne 0 ]; then
echo "This script must be run as root"
exit 1
fi
}

is_installed() {
local pkg="${1:-}"
rpm -q "$pkg" >/dev/null 2>&1
}

service_enable_start() {
local svc="${1:-}"
systemctl enable --now "$svc" || true
}

# ======================
# DOMAIN HELPERS
# ======================
# Remove www prefix from domain
strip_www() {
local domain="$1"
echo "$domain" | sed 's/^www\.//'
}

# Get www version of domain
add_www() {
local domain="$1"
if [[ "$domain" != www.* ]]; then
echo "www.$domain"
else
echo "$domain"
fi
}

# ===========================================================
# STATIC IP CONFIGURATION
# ===========================================================
configure_static_ip() {
local iface="${1:-}"
local ip="${2:-}"
local gw="${3:-}"
local dns="${4:-}"
local skip_confirm="${5:-no}"

# If parameters not provided, prompt user
if [ -z "$iface" ]; then
echo "Available network interfaces:"
ip a
echo ""
read -p "Interface name (eg ens33): " iface
fi

if [ -z "$ip" ]; then
read -p "Static IP with mask (eg 192.168.1.100/24): " ip
fi

if [ -z "$gw" ]; then
read -p "Gateway (eg 192.168.1.1): " gw
fi

if [ -z "$dns" ]; then
read -p "DNS server (eg 1.1.1.1): " dns
fi

STATIC_IFACE="$iface"
STATIC_IP="$ip"
STATIC_GW="$gw"
STATIC_DNS="$dns"

# Get MAC address
STATIC_MAC=$(ip link show "$STATIC_IFACE" 2>/dev/null | grep "link/ether" | awk '{print $2}')

if [ "$skip_confirm" != "yes" ]; then
echo ""
echo "WARNING: This may disconnect your SSH session!"
read -p "Continue? (yes/y): " CONFIRM
if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
echo "Static IP configuration cancelled."
return
fi
fi

nmcli connection show "$STATIC_IFACE" > "/root/${STATIC_IFACE}_nmcli_before.bak" 2>/dev/null || true
nmcli connection modify "$STATIC_IFACE" ipv4.addresses "$STATIC_IP"
nmcli connection modify "$STATIC_IFACE" ipv4.gateway "$STATIC_GW"
nmcli connection modify "$STATIC_IFACE" ipv4.dns "$STATIC_DNS"
nmcli connection modify "$STATIC_IFACE" ipv4.method manual
nmcli connection down "$STATIC_IFACE" || true
nmcli connection up "$STATIC_IFACE" || true

echo ""
echo "Static IP applied:"
echo "Interface: $STATIC_IFACE"
echo "IP: $STATIC_IP"
echo "Gateway: $STATIC_GW"
echo "DNS: $STATIC_DNS"
echo "MAC Address: $STATIC_MAC"
echo ""

ROUTER_REMINDER_NEEDED="yes"
}

# ===========================================================
# INSTALL FUNCTIONS
# ===========================================================
install_base() {
echo "Installing base packages..."
dnf update -y
# Adicionado tree para o scanner de arquivos
dnf install -y epel-release dnf-utils git wget curl tree

# enable CRB if exists
if command -v crb >/dev/null 2>&1; then
crb enable || true
else
dnf config-manager --set-enabled crb || true
fi
}

install_apache() {
echo "Installing Apache..."
dnf install -y httpd mod_ssl
service_enable_start httpd
ROUTER_REMINDER_NEEDED="yes"
}

install_php() {
echo "Installing PHP..."
# Adicionadas extensoes essenciais (pdo, gd, xml, mbstring) para compatibilidade
dnf install -y php php-fpm php-mysqlnd php-pdo php-gd php-mbstring php-xml
service_enable_start php-fpm
systemctl restart httpd || true
}

install_mariadb() {
echo "Installing MariaDB..."
dnf install -y mariadb-server
service_enable_start mariadb
}

install_certbot() {
echo "Installing Certbot..."
dnf install -y certbot python3-certbot-apache
if systemctl list-unit-files | grep -q certbot-renew.timer; then
systemctl enable --now certbot-renew.timer || true
fi
}

install_fail2ban() {
echo "Installing fail2ban..."
dnf install -y fail2ban
service_enable_start fail2ban
}

install_chrony() {
echo "Installing chrony..."
dnf install -y chrony
service_enable_start chronyd || service_enable_start chrony
}

install_dnf_automatic() {
echo "Installing dnf-automatic..."
dnf install -y dnf-automatic
systemctl enable --now dnf-automatic.timer || true
}

install_modsecurity() {
echo "Installing ModSecurity..."
dnf install -y mod_security || true

if [ ! -d /etc/httpd/modsecurity-crs ]; then
git clone https://github.com/coreruleset/coreruleset.git /etc/httpd/modsecurity-crs || true
cp /etc/httpd/modsecurity-crs/crs-setup.conf.example /etc/httpd/modsecurity-crs/crs-setup.conf || true
fi

if [ -f /etc/httpd/conf.d/modsecurity_crs.conf ]; then
cp /etc/httpd/conf.d/modsecurity_crs.conf /etc/httpd/conf.d/modsecurity_crs.conf.bak || true
fi

cat > /etc/httpd/conf.d/modsecurity_crs.conf <<'EOF'
IncludeOptional /etc/httpd/modsecurity-crs/crs-setup.conf
IncludeOptional /etc/httpd/modsecurity-crs/rules/*.conf
EOF

# Start in detection mode only - avoid blocking legitimate traffic
sed -i 's/SecRuleEngine On/SecRuleEngine DetectionOnly/' /etc/httpd/conf.d/mod_security.conf 2>/dev/null || true
echo "ModSecurity installed in DETECTION mode. Check logs before enabling blocking."

systemctl restart httpd || true
}

# ===========================================================
# CONFIG FUNCTIONS
# ===========================================================
configure_firewall() {
local sshp="${1:-22}"
dnf install -y firewalld || true
service_enable_start firewalld

firewall-cmd --permanent --add-service=http 2>&1 | grep -v "ALREADY_ENABLED" || true
firewall-cmd --permanent --add-service=https 2>&1 | grep -v "ALREADY_ENABLED" || true
firewall-cmd --permanent --add-port="${sshp}/tcp" 2>&1 | grep -v "ALREADY_ENABLED" || true
firewall-cmd --reload || true

ROUTER_REMINDER_NEEDED="yes"
}

configure_selinux() {
echo "Configuring SELinux..."
setsebool -P httpd_can_network_connect_db 1 || true
setsebool -P httpd_can_network_connect 1 || true
setsebool -P httpd_read_user_content 1 || true
restorecon -Rv "${WEB_ROOT}" || true
}

# ===========================================================
# SSH HARDENING
# ===========================================================
harden_ssh() {
local port="${1:-}"
local disable_root="${2:-}"
local disable_password="${3:-}"
local allowed_users="${4:-}"
local skip_prompts="${5:-no}"

# If parameters not provided, prompt user
if [ "$skip_prompts" != "yes" ]; then
echo "SSH hardening:"
read -p "New SSH port (default 22): " port
read -p "Disable root login? (yes/no) [yes]: " disable_root
read -p "Disable password auth? (yes/no) [yes]: " disable_password
read -p "Allow users (space separated): " allowed_users
fi

disable_root="${disable_root:-yes}"
disable_password="${disable_password:-yes}"
SSH_PORT="${port:-22}"

# Check for SSH keys before disabling password auth
if [ "$disable_password" = "yes" ]; then
if [ ! -f ~/.ssh/authorized_keys ] || [ ! -s ~/.ssh/authorized_keys ]; then
echo ""
echo "WARNING: No SSH keys found in ~/.ssh/authorized_keys"
echo "Disabling password auth may lock you out!"
read -p "Disable password auth anyway? (yes/y): " FORCE
if [ "$FORCE" != "yes" ] && [ "$FORCE" != "y" ]; then
disable_password="no"
echo "Password authentication will remain enabled."
fi
fi
fi

# Backup
if [ -f /etc/ssh/sshd_config ]; then
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak || true
fi

# Remove previous Port line
sed -i '/^Port /d' /etc/ssh/sshd_config || true
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

# === SELinux FIX PARA PORTA NOVA ===
if command -v semanage >/dev/null 2>&1; then
if semanage port -l | grep -q "tcp.*${SSH_PORT}"; then
semanage port -m -t ssh_port_t -p tcp "${SSH_PORT}" || true
else
semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" || true
fi
else
dnf install -y policycoreutils-python-utils || true
semanage port -a -t ssh_port_t -p tcp "${SSH_PORT}" || true
fi

# Root login
if [ "$disable_root" = "yes" ]; then
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true
fi

# Password auth
if [ "$disable_password" = "yes" ]; then
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
fi
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true

if [ -n "$allowed_users" ]; then
sed -i '/^AllowUsers /d' /etc/ssh/sshd_config || true
echo "AllowUsers $allowed_users" >> /etc/ssh/sshd_config
fi

configure_firewall "$SSH_PORT"
systemctl restart sshd || true

ROUTER_REMINDER_NEEDED="yes"
}

# ===========================================================
# VIRTUALHOST
# ===========================================================
configure_virtualhost() {
local dom="${1:-}"
if [ -z "$dom" ]; then
read -p "Domain (eg my.duckdns.org): " dom
fi

# Strip www if present for base domain
local base_domain=$(strip_www "$dom")
local www_domain=$(add_www "$base_domain")

LAST_DOMAIN="$base_domain"

mkdir -p "$WEB_ROOT"

if [ -f "/etc/httpd/conf.d/${base_domain}.conf" ]; then
cp "/etc/httpd/conf.d/${base_domain}.conf" "/etc/httpd/conf.d/${base_domain}.conf.bak" || true
fi

cat > "/etc/httpd/conf.d/${base_domain}.conf" <<EOF
<VirtualHost *:80>
ServerName ${base_domain}
ServerAlias ${www_domain}
DocumentRoot ${WEB_ROOT}
DirectoryIndex index.php index.html
<Directory ${WEB_ROOT}>
AllowOverride All
Require all granted
</Directory>
</VirtualHost>
EOF

echo "VirtualHost configured for:"
echo "  - ${base_domain}"
echo "  - ${www_domain}"

systemctl restart httpd || true

ROUTER_REMINDER_NEEDED="yes"
}

# ===========================================================
# CERTBOT + SSL
# ===========================================================
configure_ssl_certbot() {
local dom="${1:-}"
local mail="${2:-}"
local skip_prompts="${3:-no}"

# If called without parameters and not skipping prompts, ask user
if [ "$skip_prompts" != "yes" ]; then
if [ -z "$dom" ]; then
read -p "Domain for certificate: " dom
fi
if [ -z "$mail" ]; then
read -p "Email for certbot: " mail
fi
fi

# Strip www for certbot domain (DuckDNS free does not support www)
local base_domain=$(strip_www "$dom")
local www_domain=$(add_www "$base_domain")

LAST_DOMAIN="$base_domain"

# Backup
if [ -d /etc/letsencrypt ]; then
cp -a /etc/letsencrypt /etc/letsencrypt.bak || true
fi

echo ""
echo "Requesting SSL certificate from Let's Encrypt..."
echo "Domain: $base_domain"
echo "Alias: $www_domain"
echo ""
echo "NOTE: For DuckDNS free tier, certificate will be issued ONLY for:"
echo "  $base_domain (without www)"
echo "Apache will redirect www.$base_domain -> $base_domain automatically"
echo ""
echo "DNS must be configured and ports 80/443 open on router."
echo ""

# Request certificate ONLY for base domain (no www for DuckDNS free)
certbot --apache -d "$base_domain" --email "$mail" --agree-tos --no-eff-email --redirect || {
echo ""
echo "WARNING: Certbot failed. Common causes:"
echo "  1) Domain DNS not pointing to your public IP"
echo "  2) Router ports 80/443 not forwarded to $STATIC_IP"
echo "  3) Firewall blocking external access"
echo "  4) DuckDNS domain not configured correctly"
echo ""
echo "After fixing the issue, run menu option 21 to retry SSL certificate."
echo ""
return 1
}

systemctl enable --now certbot-renew.timer || true

echo ""
echo "SSL certificate installed successfully for: $base_domain"
echo "Apache will handle www redirect automatically."
echo ""

ROUTER_REMINDER_NEEDED="yes"
}

# ===========================================================
# DATABASE (MARIADB)
# ===========================================================
configure_mariadb() {
echo "Configuring MariaDB..."
systemctl enable --now mariadb || true
echo ""
echo "Run 'mysql_secure_installation' manually to set root password."
echo ""
}

# ===========================================================
# DUCKDNS
# ===========================================================
install_duckdns() {
local subdomain="${1:-}"
local token="${2:-}"

# If called without parameters, prompt user
if [ -z "$subdomain" ]; then
read -p "DuckDNS subdomain (without .duckdns.org): " subdomain
fi
if [ -z "$token" ]; then
read -p "DuckDNS token: " token
fi

# Strip www if user included it
subdomain=$(strip_www "$subdomain")
subdomain=$(echo "$subdomain" | sed 's/\.duckdns\.org$//')

# Test token before creating cron
echo "Testing DuckDNS credentials..."
TEST=$(curl -sk "https://www.duckdns.org/update?domains=$subdomain&token=$token")
if [[ "$TEST" != *"OK"* ]]; then
echo "ERROR: Invalid token or subdomain!"
echo "Response: $TEST"
return 1
fi
echo "DuckDNS credentials validated successfully."

LAST_DOMAIN="${subdomain}.duckdns.org"

mkdir -p /opt/duckdns
cat > /opt/duckdns/duck.sh <<EOF
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${subdomain}&token=${token}&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF

chmod +x /opt/duckdns/duck.sh

cat > /etc/cron.d/duckdns <<EOF
*/5 * * * * root /opt/duckdns/duck.sh >/dev/null 2>&1
EOF

systemctl restart crond || true
echo "DuckDNS configured for: ${subdomain}.duckdns.org"
}

# ===========================================================
# AUTOMATIC UPDATES
# ===========================================================
install_dnf_automatic() {
dnf install -y dnf-automatic || true
if [ -f /etc/dnf/automatic.conf ]; then
cp /etc/dnf/automatic.conf /etc/dnf/automatic.conf.bak
fi

sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf || true
systemctl enable --now dnf-automatic.timer || true
}

# ===========================================================
# DAILY BACKUP
# ===========================================================
configure_daily_backup() {
mkdir -p /opt/backup

cat > /opt/backup/backup.sh <<'EOF'
#!/bin/bash

# Check available space (less than 1GB = abort)
SPACE=$(df /opt/backup | tail -1 | awk '{print $4}')
if [ "$SPACE" -lt 1048576 ]; then
echo "Insufficient disk space for backup"
exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="/opt/backup/www_${TIMESTAMP}.tar.gz"
tar -czf "$BACKUP_FILE" /var/www/html 2>/dev/null || true

# Keep only last 7 backups
cd /opt/backup
ls -t www_*.tar.gz | tail -n +8 | xargs rm -f -- 2>/dev/null || true
EOF

chmod +x /opt/backup/backup.sh

cat > /etc/cron.d/backup_www <<EOF
0 2 * * * root /opt/backup/backup.sh >/dev/null 2>&1
EOF
}


# ===========================================================
# GENERIC APP DATABASE SETUP (CORE FUNCTION)
# ===========================================================

setup_app_database() {
    local db_name="${1:-}"
    local db_user="${2:-}"
    local db_pass="${3:-}"
    local config_path="${4:-}"
    
    # 5 argumento removido pois auto_import e o padrao

    echo "--- Setting up Database: $db_name ---"

    # 1. Database Creation
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS ${db_name};"
    mysql -u root -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -u root -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
    mysql -u root -e "FLUSH PRIVILEGES;"

    # 2. AUTOMATIC SQL IMPORT (Always Runs)
    echo "Auto-scanning for .sql files in $WEB_ROOT..."
    
    # Procura arquivos .sql na raiz e subpastas (profundidade 3)
    mapfile -t sql_files < <(find "$WEB_ROOT" -maxdepth 3 -name "*.sql")
    
    if [ ${#sql_files[@]} -gt 0 ]; then
        for sql_file in "${sql_files[@]}"; do
            echo ">> Importing found file: $sql_file..."
            # Importa direto, sem perguntas
            mysql -u root "${db_name}" < "$sql_file" || echo "WARNING: Error importing $sql_file"
        done
        echo "SQL Import process completed."
    else
        echo "No .sql files found to import."
    fi

    # 3. SMART CONFIG DETECTION
    echo "Configuring application connection file..."
    
    # Tenta encontrar arquivos que tenham codigo de conexao
    DETECTED_FILE=$(grep -rPl "mysqli_connect|new mysqli" "$WEB_ROOT" | grep -v "index.php" | head -n 1)

    if [ -n "$DETECTED_FILE" ]; then
        echo "Detected config file: $DETECTED_FILE"
        # Backup do original
        mv "$DETECTED_FILE" "${DETECTED_FILE}.original_github"
        FULL_CONFIG_PATH="$DETECTED_FILE"
    else
        # Fallback: Usa o caminho informado ou padrao
        if [ -n "$config_path" ]; then
            FULL_CONFIG_PATH="${WEB_ROOT}/${config_path}"
        else
            FULL_CONFIG_PATH="${WEB_ROOT}/config/db_connect.php"
        fi
    fi

    # Garante que o diretorio existe
    CONFIG_DIR=$(dirname "$FULL_CONFIG_PATH")
    mkdir -p "$CONFIG_DIR"

    # 4. Create the Config File
    cat > "$FULL_CONFIG_PATH" <<EOF
<?php
// Arquivo gerado automaticamente pelo Instalador LAMP
// Substitui o arquivo original do repositorio

\$servername = "localhost";
\$username = "${db_user}";
\$password = "${db_pass}";
\$dbname = "${db_name}";

// Tenta conectar
\$conn = mysqli_connect(\$servername, \$username, \$password, \$dbname);

// Verifica erro
if (!\$conn) {
    die("Connection failed: " . mysqli_connect_error());
}
?>
EOF

    # Ajusta permissoes
    chown apache:apache "$FULL_CONFIG_PATH"
    chmod 640 "$FULL_CONFIG_PATH"
    restorecon -v "$FULL_CONFIG_PATH" || true
    
    echo "Database configured and config file created at: $FULL_CONFIG_PATH"
}

# ===========================================================
# HELPER: SCAN DIRECTORY FOR CONFIGS
# ===========================================================
scan_and_suggest_config() {
echo ""
echo "======= DIRECTORY STRUCTURE SCAN (HELPER) ======="
echo "This helps you decide where to put the database config file."
echo "Current files in your website:"
echo ""
# Mostra arvore de diretorios (limite de 3 niveis)
tree -L 3 "$WEB_ROOT" | head -n 30
echo ""
echo "SUGGESTIONS:"
echo "Look for folders like 'config', 'inc', 'includes'."
echo "Look for files named 'db.php', 'config.php', 'connect.php'."

# Tenta encontrar candidatos
local candidates=$(find "$WEB_ROOT" -maxdepth 3 -type f \( -name "*config*" -o -name "*db*" -o -name "*connect*" \) | grep ".php")

if [ -n "$candidates" ]; then
echo ""
echo "Possible config files found:"
echo "$candidates" | sed "s|$WEB_ROOT/||g"
fi
echo "================================================="
echo ""
}

# ===========================================================
# INTERACTIVE WIZARD: DATABASE SETUP (NEW COMMON FUNCTION)
# ===========================================================
wizard_database_setup() {
    echo ""
    echo "------- APP DATABASE CONFIGURATION -------"
    echo "Does your website require a database?"
    echo "   [yes] For dynamic sites (PHP, WordPress, Laravel) that store data."
    echo "   [no]  For static sites (HTML, CSS, JS) only."
    echo ""
    read -p "Setup App Database? (yes/no): " CONFIRM_DB

    if [ "$CONFIRM_DB" = "yes" ] || [ "$CONFIRM_DB" = "y" ]; then
        # Chama o visualizador de arquivos para ajudar
        scan_and_suggest_config

        echo "Enter database details to be created:"
        read -p "DB Name (eg myapp_db): " W_DB_NAME
        read -p "DB User (eg myapp_user): " W_DB_USER
        read -p "DB Password: " W_DB_PASS

        echo ""
        echo "Where should the config file be created?"
        echo "Enter path relative to web root (eg: config/db.php)"
        read -p "Config File Path (Optional - will try to auto-detect): " W_CONFIG_PATH

        # Chama a funcao que faz o trabalho pesado
        setup_app_database "$W_DB_NAME" "$W_DB_USER" "$W_DB_PASS" "$W_CONFIG_PATH"
    else
        echo "Skipping database setup."
    fi
}

# ===========================================================
# GITHUB DEPLOYMENT
# ===========================================================
deploy_from_github() {
local repo_url="${1:-}"

if [ -z "$repo_url" ]; then
read -p "GitHub Repository URL (https://github.com/user/repo.git): " repo_url
fi

if [ -z "$repo_url" ]; then
echo "No repository URL provided. Skipping deployment."
return
fi

echo "Preparing to deploy from: $repo_url"

# Install git if missing
if ! command -v git >/dev/null 2>&1; then
echo "Installing git..."
dnf install -y git
fi

# Verifica se diretorio esta vazio e faz backup se necessario
if [ "$(ls -A $WEB_ROOT 2>/dev/null)" ]; then
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/var/www/html_backup_${TIMESTAMP}"
echo "WARNING: Web root not empty. Backing up to $BACKUP_PATH"
mv "$WEB_ROOT" "$BACKUP_PATH"
mkdir -p "$WEB_ROOT"
fi

echo "Cloning repository..."
git clone "$repo_url" "$WEB_ROOT"

if [ $? -eq 0 ]; then
echo "Repository cloned successfully."

# Ajusta permissoes
echo "Setting permissions..."
chown -R apache:apache "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"

# Restaura contexto do SELinux
echo "Restoring SELinux context..."
restorecon -Rv "$WEB_ROOT" || true

echo "Deployment complete!"
else
echo "ERROR: Git clone failed. Check the URL and try again."
return 1
fi
}

# ===========================================================
# WEBAPP INSTALLATION (DEFAULT TEST PAGE)
# ===========================================================
install_webapp() {
local domain="${1:-}"

if [ -z "$domain" ]; then
read -p "Domain for webapp: " domain
fi

# Strip www
local base_domain=$(strip_www "$domain")

mkdir -p ${WEB_ROOT}

# Create phpinfo test page
cat > ${WEB_ROOT}/index.php <<'EOF'
<?php
phpinfo();
?>
EOF

if [ -f "/etc/httpd/conf.d/${base_domain}.conf" ]; then
cp "/etc/httpd/conf.d/${base_domain}.conf" "/etc/httpd/conf.d/${base_domain}.conf.bak"
fi

local www_domain=$(add_www "$base_domain")

cat > /etc/httpd/conf.d/${base_domain}.conf <<EOF
<VirtualHost *:80>
ServerName ${base_domain}
ServerAlias ${www_domain}
DocumentRoot ${WEB_ROOT}
DirectoryIndex index.php index.html
<Directory ${WEB_ROOT}>
AllowOverride All
Require all granted
</Directory>
</VirtualHost>
EOF

systemctl restart httpd || true
}

# ===========================================================
# ROUTER REMINDER (SHOWS CONFIGURED VALUES)
# ===========================================================
router_reminder() {
echo ""
echo "======================================================="
echo "ROUTER PORT-FORWARD CONFIGURATION GUIDE"
echo "======================================================="

if [ -n "$STATIC_IFACE" ]; then
echo "Network Interface: $STATIC_IFACE"
fi

if [ -n "$STATIC_IP" ]; then
echo "Private IP configured: $STATIC_IP"
fi

if [ -n "$STATIC_MAC" ]; then
echo "MAC Address: $STATIC_MAC"
echo "(Use this MAC to reserve IP on your router)"
fi

if [ -n "$SSH_PORT" ]; then
echo "SSH port configured: $SSH_PORT"
fi

if [ -n "$LAST_DOMAIN" ]; then
echo "FQDN configured: $LAST_DOMAIN"
echo "Also accessible via: www.$LAST_DOMAIN"
fi

# get public IP if not already stored
if [ -z "$PUBLIC_IP" ]; then
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "UNKNOWN")
fi

echo "Detected public IP: $PUBLIC_IP"
echo ""

echo "======================================================="
echo "ACTION REQUIRED: Configure port forwarding on router"
echo "======================================================="
echo ""
echo "Forward these ports on your router to: $STATIC_IP"
echo ""
echo "  Service | External Port | Protocol | Internal IP    | Internal Port"
echo "  --------|---------------|----------|----------------|---------------"
echo "  SSH     | ${SSH_PORT}   | TCP      | $STATIC_IP     | ${SSH_PORT}"
echo "  HTTP    | 80            | TCP      | $STATIC_IP     | 80"
echo "  HTTPS   | 443           | TCP      | $STATIC_IP     | 443"
echo ""
echo "After configuring port forwarding:"
echo "  1) Test if ports are open: https://www.yougetsignal.com/tools/open-ports/"
echo "  2) Run menu option 21 to install SSL certificate"
echo "  3) Run 'mysql_secure_installation' if you haven't yet."
echo ""
echo "======================================================="
echo ""
}

# ===========================================================
# FULL INSTALL WITH GROUPED QUESTIONS AT START
# ===========================================================
full_install() {
echo ""
echo "======================================================="
echo "  FULL LAMP INSTALLATION - CONFIGURATION INPUT"
echo "======================================================="
echo ""
echo "Please provide all required information upfront."
echo "Installation will proceed automatically after."
echo ""

# ===========================
# SECTION 1: NETWORK CONFIG
# ===========================
echo "------- NETWORK CONFIGURATION -------"
echo "Available interfaces:"
ip a
echo ""
read -p "Network interface (eg ens33): " FI_STATIC_IFACE
read -p "Static IP with CIDR (eg 192.168.1.100/24): " FI_STATIC_IP
read -p "Gateway IP (eg 192.168.1.1): " FI_STATIC_GW
read -p "DNS server (eg 1.1.1.1 or 8.8.8.8): " FI_STATIC_DNS
echo ""

# ===========================
# SECTION 2: SSH SECURITY
# ===========================
echo "------- SSH SECURITY CONFIGURATION -------"
read -p "SSH port (default 22): " FI_SSH_PORT
FI_SSH_PORT="${FI_SSH_PORT:-22}"
read -p "Disable root login via SSH? (yes/no) [yes]: " FI_SSH_DISABLE_ROOT
FI_SSH_DISABLE_ROOT="${FI_SSH_DISABLE_ROOT:-yes}"
read -p "Disable password authentication? (yes/no) [yes]: " FI_SSH_DISABLE_PASSWORD
FI_SSH_DISABLE_PASSWORD="${FI_SSH_DISABLE_PASSWORD:-yes}"
read -p "Allowed SSH users (space separated, eg: user1 user2): " FI_SSH_ALLOWED_USERS
echo ""

# ===========================
# SECTION 3: DOMAIN & SSL
# ===========================
echo "------- DOMAIN & SSL CONFIGURATION -------"
echo "IMPORTANT:"
echo "  - You can enter domain WITH or WITHOUT www"
echo "  - Apache will accept BOTH versions (eg: example.com and www.example.com)"
echo "  - SSL certificate will be issued for the base domain (without www)"
echo "  - www version will redirect automatically to non-www"
echo ""
read -p "Domain name (eg myserver.duckdns.org or www.myserver.duckdns.org): " FI_DOMAIN
read -p "Email for SSL certificate notifications (Let's Encrypt): " FI_CERTBOT_EMAIL
echo ""

# ===========================
# SECTION 4: DUCKDNS (OPTIONAL)
# ===========================
echo "------- DUCKDNS CONFIGURATION (optional) -------"
echo "If using DuckDNS for dynamic DNS, provide credentials below."
echo "NOTE: Enter subdomain WITHOUT www (DuckDNS free tier limitation)"
echo "Otherwise, leave blank and press Enter to skip."
echo ""
read -p "DuckDNS subdomain (eg: myserver - without .duckdns.org): " FI_DUCKDNS_SUBDOMAIN
if [ -n "$FI_DUCKDNS_SUBDOMAIN" ]; then
read -p "DuckDNS token (from duckdns.org account): " FI_DUCKDNS_TOKEN
fi
echo ""

# ===========================
# SECTION 5: WEBSITE CONTENT
# ===========================
echo "------- WEBSITE CONTENT (GitHub) -------"
echo "You can automatically deploy a website from a public GitHub repository."
echo "Leave blank to skip and install the default test page."
echo ""
read -p "GitHub Repository URL (eg https://github.com/user/my-site.git): " FI_GIT_REPO
echo ""

# Strip www from user inputs
FI_DOMAIN=$(strip_www "$FI_DOMAIN")
if [ -n "$FI_DUCKDNS_SUBDOMAIN" ]; then
FI_DUCKDNS_SUBDOMAIN=$(strip_www "$FI_DUCKDNS_SUBDOMAIN" | sed 's/\.duckdns\.org$//')
fi

# ===========================
# SECTION 6: CONFIRMATION
# ===========================
echo "======================================================="
echo "  CONFIGURATION SUMMARY"
echo "======================================================="
echo "Network: $FI_STATIC_IP / $FI_STATIC_GW"
echo "Domain:  $FI_DOMAIN"
if [ -n "$FI_GIT_REPO" ]; then
echo "Content: GitHub Deploy ($FI_GIT_REPO)"
else
echo "Content: Default Test Page"
fi
echo "======================================================="
echo ""
read -p "Proceed with installation? (yes/y): " CONFIRM
if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
echo "Installation cancelled."
return
fi

# ===========================
# START INSTALLATION
# ===========================
echo ""
echo "======================================================="
echo "  STARTING INSTALLATION..."
echo "======================================================="
echo ""

# Configure static IP
configure_static_ip "$FI_STATIC_IFACE" "$FI_STATIC_IP" "$FI_STATIC_GW" "$FI_STATIC_DNS" "yes"

# Install packages
install_base
install_apache
install_php
install_mariadb
configure_mariadb
install_certbot
install_fail2ban
install_chrony
install_dnf_automatic
install_modsecurity

# Configure services
configure_firewall "$FI_SSH_PORT"
configure_selinux
harden_ssh "$FI_SSH_PORT" "$FI_SSH_DISABLE_ROOT" "$FI_SSH_DISABLE_PASSWORD" "$FI_SSH_ALLOWED_USERS" "yes"

# Configure backup
configure_daily_backup

# Configure DuckDNS if provided
if [ -n "$FI_DUCKDNS_SUBDOMAIN" ] && [ -n "$FI_DUCKDNS_TOKEN" ]; then
install_duckdns "$FI_DUCKDNS_SUBDOMAIN" "$FI_DUCKDNS_TOKEN"
fi

# ===========================
# WEB CONTENT & DATABASE
# ===========================
if [ -n "$FI_GIT_REPO" ]; then
# 1. Deploy content
deploy_from_github "$FI_GIT_REPO"
# Garante que o VirtualHost seja criado
if [ ! -f "/etc/httpd/conf.d/${FI_DOMAIN}.conf" ]; then
configure_virtualhost "$FI_DOMAIN"
fi

# 2. Database Wizard (Interactive)
# CHAMADA DA NOVA FUNCAO COMUM (Simplifica o codigo e garante consistencia)
wizard_database_setup

else
# Instala pagina padrao de teste
install_webapp "$FI_DOMAIN"
fi

# SSL certificate
echo ""
echo "======================================================="
echo "  SSL CERTIFICATE CONFIGURATION"
echo "======================================================="
echo ""
echo "IMPORTANT: SSL certificate requires ports 80/443 forwarded on router."
read -p "Have you already configured port forwarding on your router? (yes/no): " PORT_FORWARD_READY

if [ "$PORT_FORWARD_READY" = "yes" ] || [ "$PORT_FORWARD_READY" = "y" ]; then
configure_ssl_certbot "$FI_DOMAIN" "$FI_CERTBOT_EMAIL" "yes"
else
echo "Skipping SSL certificate for now."
fi

echo ""
echo "======================================================="
echo "  INSTALLATION COMPLETED SUCCESSFULLY"
echo "======================================================="
echo ""

# Show important info at the end
router_reminder
}

# ===========================================================
# MENU (REORGANIZED BY CATEGORY)
# ===========================================================
show_menu() {
clear
echo "======================================================="
echo "          SIMPLE LAMP SERVER - MAIN MENU v13"
echo "======================================================="
echo ""
echo "[QUICK START]"
echo "   1) Full installation (automated setup)"
echo "   2) Show configuration & router reminder"
echo ""
echo "[NETWORK]"
echo "   3) Configure static IP address"
echo "   4) Configure firewall (ports & services)"
echo ""
echo "[WEB SERVER & DEPLOY]"
echo "   5) Install Apache HTTP Server"
echo "   6) Configure VirtualHost (domain)"
echo "   7) Configure SELinux for Apache"
echo "   8) Install ModSecurity WAF"
echo "   9) Deploy site from GitHub"
echo "  10) Setup App Database (Interactive)"
echo ""
echo "[APPLICATION LAYER]"
echo "  11) Install PHP"
echo "  12) Install MariaDB database"
echo "  13) Setup database + test webapp (Default)"
echo ""
echo "[SSL & CERTIFICATES]"
echo "  14) Install Certbot (Let's Encrypt client)"
echo "  15) Configure SSL certificate"
echo ""
echo "[SECURITY & HARDENING]"
echo "  16) Harden SSH (port/auth/users)"
echo "  17) Install & configure Fail2ban"
echo ""
echo "[SYSTEM SERVICES]"
echo "  18) Install base packages & updates"
echo "  19) Install Chrony (NTP time sync)"
echo "  20) Install dnf-automatic (auto updates)"
echo "  21) Configure daily backup system"
echo ""
echo "[DYNAMIC DNS]"
echo "  22) Configure DuckDNS"
echo ""
echo "[POST-INSTALL]"
echo "  23) Retry SSL certificate (after port forwarding)"
echo ""
echo "[EXIT]"
echo "   0) Exit script"
echo ""
echo "======================================================="
}

# ===========================================================
# MAIN LOOP
# ===========================================================
check_root

while true; do
show_menu
read -p "Choose an option: " OP
case "$OP" in
1) full_install ;;
2) router_reminder ;;
3) configure_static_ip ;;
4) configure_firewall "$SSH_PORT" ;;
5) install_apache ;;
6) configure_virtualhost ;;
7) configure_selinux ;;
8) install_modsecurity ;;
9) deploy_from_github ;;
10) 
wizard_database_setup
;;
11) install_php ;;
12) install_mariadb ;;
13) install_webapp ;;
14) install_certbot ;;
15) configure_ssl_certbot ;;
16) harden_ssh ;;
17) install_fail2ban ;;
18) install_base ;;
19) install_chrony ;;
20) install_dnf_automatic ;;
21) configure_daily_backup ;;
22) install_duckdns ;;
23) configure_ssl_certbot ;;
0) exit 0 ;;
*) echo "Invalid option" ;;
esac
echo ""
read -p "Press Enter to continue..."
done