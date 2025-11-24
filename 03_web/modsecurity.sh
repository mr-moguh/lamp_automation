#!/bin/bash
set -euo pipefail

echo ">> Installing ModSecurity (WAF)..."
dnf install -y mod_security

# baixando regras owasp
if [ ! -d /etc/httpd/modsecurity-crs ]; then
    dnf install -y git
    git clone https://github.com/coreruleset/coreruleset.git /etc/httpd/modsecurity-crs
    cp /etc/httpd/modsecurity-crs/crs-setup.conf.example /etc/httpd/modsecurity-crs/crs-setup.conf
fi

# criando config do apache para ler regras
cat > /etc/httpd/conf.d/modsecurity_crs.conf <<'EOF'
IncludeOptional /etc/httpd/modsecurity-crs/crs-setup.conf
IncludeOptional /etc/httpd/modsecurity-crs/rules/*.conf
EOF

# definindo modo apenas de deteccao para nao bloquear usuarios legitimos
sed -i 's/SecRuleEngine On/SecRuleEngine DetectionOnly/' /etc/httpd/conf.d/mod_security.conf 2>/dev/null || true

systemctl restart httpd
echo "ModSecurity installed (DetectionOnly mode)."