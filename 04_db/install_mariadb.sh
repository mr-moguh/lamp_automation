#!/bin/bash
# 04_db/install_mariadb.sh
# instala E CONFIGURA o banco de dados mariadb
# realiza o 'mysql_secure_installation' automaticamente

set -euo pipefail

ROOT_PASS=""

# aceita senha via argumento --password
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --password) ROOT_PASS="$2"; shift ;;
    esac
    shift
done

# verifica root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

# 1. instalacao
if ! command -v mariadb >/dev/null; then
    echo ">> [DB] Installing MariaDB Server..."
    dnf install -y mariadb-server
else
    echo ">> [DB] MariaDB already installed."
fi

# 2. inicializacao do servico
echo ">> [DB] Starting service..."
systemctl enable --now mariadb

# 3. configuracao de seguranca (hardening)
echo ">> [DB] Securing installation..."

# se nao foi passada senha por argumento, pergunta interativamente
if [ -z "$ROOT_PASS" ]; then
    echo "--- DATABASE SETUP ---"
    echo "You need to set a root password for MariaDB."
    read -s -p "Enter new DB Root Password: " ROOT_PASS
    echo ""
fi

if [ -z "$ROOT_PASS" ]; then
    echo "Error: Password cannot be empty."
    exit 1
fi

# executa comandos sql para travar o banco (equivalente ao mysql_secure_installation)
# nota: o comando abaixo assume que o root atual esta sem senha (padrao pos instalacao)
# se ja tiver senha, o comando falhara (o que e bom, pois nao sobrescreve)

mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# tenta definir a senha. se falhar, assume que ja esta configurado
if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';" 2>/dev/null; then
    echo ">> [DB] Root password set successfully."
    
    echo ">> [DB] Removing anonymous users and test database..."
    mysql -u root -p"${ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='';"
    mysql -u root -p"${ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -u root -p"${ROOT_PASS}" -e "DROP DATABASE IF EXISTS test;"
    mysql -u root -p"${ROOT_PASS}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -u root -p"${ROOT_PASS}" -e "FLUSH PRIVILEGES;"
    
    echo ">> [DB] Security configuration complete."
else
    echo ">> [DB] Root password already set or connection failed. Skipping security steps."
fi

echo ">> [DB] Setup complete."