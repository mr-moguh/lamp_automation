#!/bin/bash
# coordena a execucao dos modulos

set -euo pipefail

# cores para facilitar a leitura
GREEN='\033[0;32m'
NC='\033[0m'

# garante que o script rode como root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root."
    exit 1
fi

echo -e "${GREEN}=== LAMP INSTALLER MODULAR v1.0 ===${NC}"

# menu principal
echo "Select an option:"
echo "1) Full Installation (Wizard)"
echo "2) Deploy Site only (Git + DB)"
echo "3) Configure SSL only"
echo "0) Exit"
read -p "Option: " OPT

if [ "$OPT" == "0" ]; then exit 0; fi

# coleta de dados inicial
if [ "$OPT" == "1" ]; then
    echo ""
    echo "--- CONFIGURATION ---"
    read -p "Domain (e.g. site.com): " FI_DOMAIN
    read -p "Email for SSL: " FI_EMAIL
    read -p "GitHub Repo URL (optional): " FI_REPO
    read -p "New SSH Port (default 22): " P_SSH
    FI_SSH_PORT="${P_SSH:-22}"

    # execucao sequencial dos modulos
    echo ""
    echo ">> Step 1: System Base"
    ./02_system/base_tools.sh
    ./02_system/updates.sh
    
    echo ">> Step 2: Web Stack"
    ./03_web/install_apache.sh
    ./03_web/install_php.sh
    
    echo ">> Step 3: Database Server"
    ./04_db/install_mariadb.sh
    
    # configura vhost
    # nota: o apache cria o vhost padrao, mas aqui garantimos o dominio
    # vamos usar uma funcao simples aqui ou chamar o modulo de apache passando dominio
    # para simplificar, o deploy do git cuidara do vhost se houver repo
    
    echo ">> Step 4: Security Base"
    ./06_security/firewall.sh
    ./06_security/ssh_harden.sh --port "$FI_SSH_PORT"
    ./06_security/fail2ban.sh

    # deploy da aplicacao
    if [ -n "$FI_REPO" ]; then
        echo ">> Step 5: Application Deploy"
        ./05_app/deploy_git.sh --repo "$FI_REPO" --domain "$FI_DOMAIN"
        
        echo ""
        echo "--- APP DATABASE ---"
        read -p "Create database for app? (yes/no): " CREATE_DB
        if [ "$CREATE_DB" == "yes" ]; then
            read -p "DB Name: " DB_N
            read -p "DB User: " DB_U
            read -p "DB Pass: " DB_P
            read -p "Config Path (e.g. config/db.php): " DB_C
            
            ./04_db/setup_app_db.sh --db "$DB_N" --user "$DB_U" --pass "$DB_P" --config "$DB_C"
        fi
    fi
    
    # ssl
    echo ""
    read -p "Configure SSL now? (yes/no): " DO_SSL
    if [ "$DO_SSL" == "yes" ]; then
        ./06_security/ssl_certbot.sh --domain "$FI_DOMAIN" --email "$FI_EMAIL"
    fi
    
    # opcionais
    echo ""
    read -p "Install ModSecurity (WAF)? (yes/no): " DO_WAF
    if [ "$DO_WAF" == "yes" ]; then
        ./03_web/modsecurity.sh
    fi
    
    echo ""
    echo "${GREEN}=== INSTALLATION COMPLETE ===${NC}"
fi

# modo deploy manual
if [ "$OPT" == "2" ]; then
    read -p "Repo URL: " R
    read -p "Domain: " D
    ./05_app/deploy_git.sh --repo "$R" --domain "$D"
    
    read -p "Setup DB? (y/n): " Q
    if [ "$Q" == "y" ]; then
        read -p "DB Name: " N; read -p "User: " U; read -p "Pass: " P; read -p "Config Path: " C
        ./04_db/setup_app_db.sh --db "$N" --user "$U" --pass "$P" --config "$C"
    fi
fi

# modo ssl manual
if [ "$OPT" == "3" ]; then
    read -p "Domain: " D
    read -p "Email: " E
    ./06_security/ssl_certbot.sh --domain "$D" --email "$E"
fi