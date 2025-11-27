#!/bin/bash

set -euo pipefail

# ===========================================================
# SIMPLE LAMP WIZARD - CLEAN & MODULAR
# script simplificado para automacao de servidor web
# ===========================================================

# globais
WEB_ROOT="/var/www/html"
BACKUP_DIR="/opt/backup"
PHP_VER="php" 

# ======================
# HELPER FUNCTIONS
# ======================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "erro: rode como root (sudo -i)"
        exit 1
    fi
}

msg() {
    echo ""
    echo ">>> $1"
    echo "--------------------------------------------------"
}

# input helper - le variavel se nao estiver setada
get_input() {
    local prompt="$1"
    local var_ref="$2" # nome da variavel para salvar
    local default="${3:-}"

    # se a variavel ja tem valor, nao pergunta (util para automacao)
    if [ -z "${!var_ref:-}" ]; then
        if [ -n "$default" ]; then
            read -p "$prompt [$default]: " temp_val
            printf -v "$var_ref" "%s" "${temp_val:-$default}"
        else
            read -p "$prompt: " temp_val
            printf -v "$var_ref" "%s" "$temp_val"
        fi
    fi
}

# ======================
# 1. SYSTEM BASE
# ======================
step_base_updates() {
    msg "atualizando sistema e instalando base"
    dnf update -y
    dnf install -y epel-release dnf-utils git wget curl tree chrony dnf-automatic firewalld policycoreutils-python-utils

    # ativa repositorio crb se existir (rocky/alma)
    dnf config-manager --set-enabled crb || true

    # inicia servicos de utilidade
    systemctl enable --now chronyd
    
    # configura updates automaticos de seguranca
    sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf || true
    systemctl enable --now dnf-automatic.timer
}

# ======================
# 2. NETWORK (OPTIONAL)
# ======================
step_static_ip() {
    msg "configuracao de ip estatico"
    echo "interfaces disponiveis:"
    ip a
    
    get_input "interface (ex: ens33)" NET_IFACE
    get_input "ip/cidr (ex: 192.168.1.100/24)" NET_IP
    get_input "gateway (ex: 192.168.1.1)" NET_GW
    get_input "dns (ex: 1.1.1.1)" NET_DNS

    read -p "aplicar config? isso pode derrubar o ssh! (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        nmcli con mod "$NET_IFACE" ipv4.addresses "$NET_IP" ipv4.gateway "$NET_GW" ipv4.dns "$NET_DNS" ipv4.method manual
        nmcli con down "$NET_IFACE" && nmcli con up "$NET_IFACE"
        echo "ip aplicado."
    fi
}

# ======================
# 3. LAMP STACK
# ======================
step_install_lamp() {
    msg "instalando apache, mariadb e php"
    
    # apache
    dnf install -y httpd mod_ssl mod_security
    systemctl enable --now httpd

    # modsecurity (deteccao apenas para evitar erros)
    sed -i 's/SecRuleEngine On/SecRuleEngine DetectionOnly/' /etc/httpd/conf.d/mod_security.conf 2>/dev/null || true

    # mariadb
    dnf install -y mariadb-server
    systemctl enable --now mariadb
    
    # php e extensoes comuns
    dnf install -y php php-fpm php-mysqlnd php-pdo php-gd php-mbstring php-xml php-zip php-intl
    systemctl enable --now php-fpm
    systemctl restart httpd
}

# ======================
# 4. SECURITY & FIREWALL
# ======================
step_security_basic() {
    msg "aplicando seguranca basica (firewall + fail2ban)"
    
    systemctl enable --now firewalld
    
    # abre portas web padrao
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=22/tcp # garante ssh padrao
    firewall-cmd --reload

    # fail2ban
    dnf install -y fail2ban
    systemctl enable --now fail2ban

    # selinux helpers para web
    setsebool -P httpd_can_network_connect 1 || true
    setsebool -P httpd_can_network_connect_db 1 || true
    setsebool -P httpd_read_user_content 1 || true
}

step_harden_ssh() {
    msg "hardening ssh (avancado)"
    echo "aviso: risco de bloqueio se configurar errado."
    
    get_input "nova porta ssh" SSH_NEW_PORT "2222"
    get_input "desativar login root? (yes/no)" SSH_NO_ROOT "yes"
    
    # selinux porta
    semanage port -a -t ssh_port_t -p tcp "$SSH_NEW_PORT" 2>/dev/null || true
    
    # config sshd
    sed -i '/^Port /d' /etc/ssh/sshd_config
    echo "Port $SSH_NEW_PORT" >> /etc/ssh/sshd_config
    
    if [ "$SSH_NO_ROOT" == "yes" ]; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    fi
    
    # firewall porta nova
    firewall-cmd --permanent --add-port="${SSH_NEW_PORT}/tcp"
    firewall-cmd --permanent --remove-port=22/tcp
    firewall-cmd --reload
    
    systemctl restart sshd
    echo "ssh reconfigurado na porta $SSH_NEW_PORT"
}

# ======================
# 5. SITE DEPLOYMENT
# ======================
step_deploy_site() {
    msg "configuracao do site e dominio"
    
    get_input "dominio principal (sem www)" SITE_DOMAIN
    get_input "url repo github (deixe vazio para pagina teste)" GIT_REPO

    # limpa e recria webroot
    mkdir -p "$WEB_ROOT"
    
    if [ -n "$GIT_REPO" ]; then
        echo "clonando repositorio..."
        # backup se existir algo
        if [ "$(ls -A $WEB_ROOT)" ]; then mv "$WEB_ROOT" "${WEB_ROOT}_bkp_$(date +%s)"; fi
        
        dnf install -y git
        git clone "$GIT_REPO" "$WEB_ROOT"
        chown -R apache:apache "$WEB_ROOT"
        restorecon -R "$WEB_ROOT"
    else
        echo "<?php phpinfo(); ?>" > "$WEB_ROOT/index.php"
        echo "criada pagina de teste padrao"
    fi

    # virtualhost apache
    cat > "/etc/httpd/conf.d/${SITE_DOMAIN}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${SITE_DOMAIN}
    ServerAlias www.${SITE_DOMAIN}
    DocumentRoot ${WEB_ROOT}
    <Directory ${WEB_ROOT}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

    systemctl restart httpd
    echo "vhost criado para $SITE_DOMAIN"
}

# ======================
# 6. DATABASE SETUP 
# ======================
step_setup_db() {
    msg "configuracao de banco de dados da aplicacao"
    
    read -p "criar banco de dados para o site? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    get_input "nome do banco" DB_NAME
    get_input "usuario do banco" DB_USER
    get_input "senha do banco" DB_PASS

    # cria banco e usuario no mysql
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
    mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -u root -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql -u root -e "FLUSH PRIVILEGES;"

    # 1. importa .sql automaticamente se encontrar
    local sql_file=$(find "$WEB_ROOT" -maxdepth 3 -name "*.sql" | head -n 1)
    if [ -n "$sql_file" ]; then
        echo "importando estrutura: $sql_file..."
        mysql -u root "$DB_NAME" < "$sql_file"
    fi

    # 2. DETECCAO INTELIGENTE DE CONFIGURACAO
    # procura por arquivos comuns de config (db.php, connect.php, config.php, etc)
    echo "procurando arquivo de configuracao do site..."
    TARGET_CONFIG=$(find "$WEB_ROOT" -maxdepth 3 -type f \( -name "*config*" -o -name "*db*" -o -name "*connect*" \) | grep ".php" | head -n 1)

    if [ -n "$TARGET_CONFIG" ]; then
        echo "arquivo encontrado: $TARGET_CONFIG"
        echo "fazendo backup e sobrescrevendo com as novas credenciais..."
        mv "$TARGET_CONFIG" "${TARGET_CONFIG}.bak"
        
        # cria o novo arquivo exatamente onde o site espera
        cat > "$TARGET_CONFIG" <<EOF
<?php
// config gerada automaticamente pelo script
\$servername = "localhost";
\$username = "${DB_USER}";
\$password = "${DB_PASS}";
\$dbname = "${DB_NAME}";

// conexao padrao mysqli
\$conn = mysqli_connect(\$servername, \$username, \$password, \$dbname);

if (!\$conn) {
    die("Connection failed: " . mysqli_connect_error());
}
?>
EOF
        chown apache:apache "$TARGET_CONFIG"
        echo "configuracao atualizada com sucesso!"
    else
        echo "aviso: nao encontrei o arquivo de config automaticamente."
        echo "voce tera que editar manualmente o arquivo php de conexao."
    fi
}

# ======================
# 7. SSL / CERTBOT
# ======================
step_ssl() {
    msg "configuracao ssl (https)"
    
    # checa se o usuario quer ssl agora
    if [ -z "${SITE_DOMAIN:-}" ]; then
        get_input "qual dominio?" SITE_DOMAIN
    fi

    echo "certifique-se que as portas 80/443 estao abertas no roteador!"
    read -p "rodar certbot agora? (y/n): " confirm
    
    if [[ "$confirm" == "y" ]]; then
        dnf install -y certbot python3-certbot-apache
        get_input "email para notificacoes" CERT_EMAIL
        
        certbot --apache -d "$SITE_DOMAIN" --email "$CERT_EMAIL" --agree-tos --no-eff-email --redirect
        systemctl enable --now certbot-renew.timer
    fi
}

# ======================
# 8. BACKUPS & TOOLS
# ======================
step_backup() {
    msg "configurando backup diario"
    mkdir -p "$BACKUP_DIR"
    
    # script simples de backup
    cat > /usr/local/bin/simple_backup.sh <<'EOF'
#!/bin/bash
tar -czf /opt/backup/site_$(date +%F).tar.gz /var/www/html 2>/dev/null
find /opt/backup -name "*.tar.gz" -mtime +7 -delete
EOF
    chmod +x /usr/local/bin/simple_backup.sh
    
    # cronjob 2am
    echo "0 2 * * * root /usr/local/bin/simple_backup.sh" > /etc/cron.d/simple_backup
    echo "backup diario agendado as 02:00 em $BACKUP_DIR"
}

step_duckdns() {
    msg "configuracao duckdns"
    get_input "subdominio (sem .duckdns.org)" DUCK_SUB
    get_input "token duckdns" DUCK_TOKEN
    
    mkdir -p /opt/duckdns
    echo "echo url=\"https://www.duckdns.org/update?domains=${DUCK_SUB}&token=${DUCK_TOKEN}&ip=\" | curl -k -K -" > /opt/duckdns/duck.sh
    chmod +x /opt/duckdns/duck.sh
    
    echo "*/5 * * * * root /opt/duckdns/duck.sh >/dev/null 2>&1" > /etc/cron.d/duckdns
    echo "duckdns configurado."
}

# ======================
# FULL INSTALLER LOGIC
# ======================
full_install() {
    echo ""
    echo "=================================="
    echo " INSTALACAO COMPLETA (SIMPLIFICADA)"
    echo "=================================="
    echo "este modo vai configurar:"
    echo "1. sistema base e updates"
    echo "2. lamp stack (webserver)"
    echo "3. firewall basico e fail2ban"
    echo "4. deploy do site (git ou teste)"
    echo "5. banco de dados"
    echo "6. ssl (lets encrypt)"
    echo "7. backups automáticos"
    echo ""
    read -p "pressione ENTER para comecar..."

    # sequencia de execucao usando as mesmas funcoes do menu
    step_base_updates
    step_install_lamp
    step_security_basic
    step_deploy_site
    step_setup_db
    step_backup
    step_ssl

    echo ""
    echo ">>> INSTALACAO FINALIZADA!"
    echo "lembrete: configure o port-forwarding (80/443) no seu roteador."
    echo "se precisar de ip estatico ou mudar porta ssh, use o menu principal."
}

# ======================
# MENU & MAIN
# ======================
show_menu() {
    clear
    echo "=== SERVER MANAGER v14 (SIMPLE) ==="
    echo "1.  FULL INSTALL (Recomendado)"
    echo "---"
    echo "2.  Configurar IP Estatico"
    echo "3.  Instalar LAMP Stack"
    echo "4.  Deploy Site (Git)"
    echo "5.  Setup Banco de Dados"
    echo "6.  Configurar SSL (HTTPS)"
    echo "7.  Seguranca Basica (Firewall/Fail2ban)"
    echo "8.  Harden SSH (Mudar Porta - Cuidado!)"
    echo "9.  Configurar DuckDNS"
    echo "10. Configurar Backup Diario"
    echo "0.  Sair"
    echo "==================================="
}

check_root

while true; do
    show_menu
    read -p "Opcao: " op
    case $op in
        1) full_install ;;
        2) step_static_ip ;;
        3) step_base_updates; step_install_lamp ;;
        4) step_deploy_site ;;
        5) step_setup_db ;;
        6) step_ssl ;;
        7) step_security_basic ;;
        8) step_harden_ssh ;;
        9) step_duckdns ;;
        10) step_backup ;;
        0) exit 0 ;;
        *) echo "opcao invalida" ;;
    esac
    read -p "pressione enter..."
done