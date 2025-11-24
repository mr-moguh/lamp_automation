#!/bin/bash
set -euo pipefail

# atualizando o sistema operacional
echo ">> Updating system packages..."
dnf update -y