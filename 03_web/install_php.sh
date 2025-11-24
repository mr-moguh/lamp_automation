#!/bin/bash
set -euo pipefail

# dependencia: apache deve existir
if ! command -v httpd >/dev/null; then
    echo ">> Apache not found. Installing dependency..."
    dnf install -y httpd
fi

echo ">> Installing PHP and extensions..."
# instalando extensoes comuns para compatibilidade
dnf install -y php php-fpm php-mysqlnd php-pdo php-gd php-mbstring php-xml php-opcache php-intl

systemctl enable --now php-fpm
systemctl restart httpd