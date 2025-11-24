#!/bin/bash
set -euo pipefail

# instalando ferramentas basicas
echo ">> Installing base tools (git, wget, curl, tree)..."
dnf install -y epel-release dnf-utils git wget curl tree policycoreutils-python-utils

# habilitando repositorio crb se necessario
if command -v crb >/dev/null 2>&1; then
    crb enable || true
fi