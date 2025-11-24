#!/bin/bash
set -euo pipefail

REPO=""
DOMAIN=""
WEB_ROOT="/var/www/html"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --repo) REPO="$2"; shift ;;
        --domain) DOMAIN="$2"; shift ;;
    esac
    shift
done

if [ -z "$REPO" ]; then
    echo "Error: Repo URL required."
    exit 1
fi

# instalando git se nao existir
if ! command -v git >/dev/null; then
    dnf install -y git
fi

echo ">> Deploying from $REPO..."

# backup se a pasta nao estiver vazia
if [ "$(ls -A $WEB_ROOT 2>/dev/null)" ]; then
    BKP="/var/www/html_bkp_$(date +%s)"
    echo "Backing up current files to $BKP"
    mv "$WEB_ROOT" "$BKP"
    mkdir -p "$WEB_ROOT"
fi

git clone "$REPO" "$WEB_ROOT"

# ajustando permissoes e selinux
echo ">> Fixing permissions..."
chown -R apache:apache "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
if command -v restorecon >/dev/null; then
    restorecon -Rv "$WEB_ROOT" || true
fi

# configurando virtualhost se dominio foi passado
if [ -n "$DOMAIN" ]; then
    echo ">> Updating VirtualHost..."
    # logica simplificada de vhost
    cat > "/etc/httpd/conf.d/${DOMAIN}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WEB_ROOT}
    <Directory ${WEB_ROOT}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    systemctl restart httpd
fi