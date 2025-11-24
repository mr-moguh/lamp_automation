#!/bin/bash
set -euo pipefail

# leitura de argumentos
DB_NAME=""
DB_USER=""
DB_PASS=""
CONFIG_PATH=""
WEB_ROOT="/var/www/html"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --db) DB_NAME="$2"; shift ;;
        --user) DB_USER="$2"; shift ;;
        --pass) DB_PASS="$2"; shift ;;
        --config) CONFIG_PATH="$2"; shift ;;
    esac
    shift
done

# verificacao de dependencias
if ! command -v mysql >/dev/null; then
    echo "MariaDB not found. Installing..."
    dnf install -y mariadb-server
    systemctl enable --now mariadb
fi

echo ">> Creating Database $DB_NAME..."

# comandos sql para criar banco e usuario
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# importacao automatica de sql
echo ">> Scanning for .sql files in $WEB_ROOT..."
COUNT=$(find "$WEB_ROOT" -maxdepth 3 -name "*.sql" | wc -l)

if [ "$COUNT" -gt 0 ]; then
    find "$WEB_ROOT" -maxdepth 3 -name "*.sql" | while read F; do
        echo "Found: $F"
        # se rodado via main.sh assumimos yes, senao perguntamos
        # para simplicidade deste script modular, vamos importar direto
        mysql "$DB_NAME" < "$F"
        echo "Imported $F successfully."
    done
fi

# geracao do arquivo de conexao php
if [ -n "$CONFIG_PATH" ]; then
    FULL_PATH="${WEB_ROOT}/${CONFIG_PATH}"
    mkdir -p "$(dirname "$FULL_PATH")"
    
    cat > "$FULL_PATH" <<EOF
<?php
// Auto-generated config
\$servername = "localhost";
\$username = "${DB_USER}";
\$password = "${DB_PASS}";
\$dbname = "${DB_NAME}";

\$conn = mysqli_connect(\$servername, \$username, \$password, \$dbname);
if (!\$conn) { die("Connection failed: " . mysqli_connect_error()); }
?>
EOF
    # ajustando permissoes
    chown apache:apache "$FULL_PATH"
    chmod 640 "$FULL_PATH"
    # selinux fix
    restorecon -v "$FULL_PATH" || true
    echo "Config file created at $FULL_PATH"
fi