#!/bin/bash
set -euo pipefail

echo ">> Configuring basic firewall..."
dnf install -y firewalld
systemctl enable --now firewalld

# abrindo portas web padrao
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload