#!/bin/bash
set -euo pipefail

PORT="22"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

if [ "$PORT" == "22" ]; then
    echo "SSH port is default (22). Skipping change."
    exit 0
fi

echo ">> Changing SSH port to $PORT..."

# alterando config do ssh
sed -i '/^Port /d' /etc/ssh/sshd_config
echo "Port $PORT" >> /etc/ssh/sshd_config

# ajustando selinux
if command -v semanage >/dev/null; then
    semanage port -a -t ssh_port_t -p tcp "$PORT" 2>/dev/null || \
    semanage port -m -t ssh_port_t -p tcp "$PORT" 2>/dev/null || true
fi

# ajustando firewall
firewall-cmd --permanent --add-port="${PORT}/tcp"
firewall-cmd --reload

systemctl restart sshd
echo "SSH config updated."