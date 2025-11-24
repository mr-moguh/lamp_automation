#!/bin/bash
set -euo pipefail

DOMAIN=""
EMAIL=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift ;;
        --email) EMAIL="$2"; shift ;;
    esac
    shift
done

# verificacao de dependencias
if ! command -v httpd >/dev/null; then
    echo "Apache required. Installing..."
    dnf install -y httpd
fi

echo ">> Installing Certbot..."
dnf install -y certbot python3-certbot-apache

echo ">> Requesting SSL for $DOMAIN..."
# remove www para evitar problemas no duckdns free
CLEAN_DOM=$(echo "$DOMAIN" | sed 's/^www\.//')

certbot --apache -d "$CLEAN_DOM" --email "$EMAIL" --agree-tos --no-eff-email --redirect