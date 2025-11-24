#!/bin/bash
set -euo pipefail

# verificando se ja existe, senao instala
if ! command -v httpd >/dev/null; then
    echo ">> Installing Apache..."
    dnf install -y httpd mod_ssl
    systemctl enable --now httpd
else
    echo ">> Apache already installed."
fi

# ajustando permissoes de firewall
if command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload || true
fi