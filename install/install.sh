#!/usr/bin/env bash
# install.sh — aplica a hardening anti-OOM do neural-node (idempotente)
# Rode como root/sudo:  sudo ./install/install.sh
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1) OOMScoreAdjust em serviços vitais do host
for unit in sshd tailscaled containerd docker; do
  d="/etc/systemd/system/${unit}.service.d"
  mkdir -p "$d"
  cp "$HERE/units/${unit}.oom-protect.conf" "$d/oom-protect.conf"
  chmod 644 "$d/oom-protect.conf"
  echo "unit drop-in: $d/oom-protect.conf"
done

# 2) sysctl de memória (swap zram antes do OOM)
cp "$HERE/sysctl/90-neural-node-memory.conf" /etc/sysctl.d/90-neural-node-memory.conf
echo "sysctl: /etc/sysctl.d/90-neural-node-memory.conf"

# 3) healer (detecção + alerta loud de OOM)
cp "$HERE/healer/nexus-healer.sh" /usr/local/sbin/nexus-healer.sh
chmod 755 /usr/local/sbin/nexus-healer.sh
echo "healer: /usr/local/sbin/nexus-healer.sh"

# 4) aplica tudo
systemctl daemon-reload
sysctl --system >/dev/null

# 5) verifica
echo "--- verificacao ---"
for unit in sshd tailscaled containerd docker; do
  echo "$unit: $(systemctl show -p OOMScoreAdjust "$unit" 2>/dev/null || echo 'n/a')"
done
echo "swappiness: $(cat /proc/sys/vm/swappiness)  page-cluster: $(cat /proc/sys/vm/page-cluster)"
echo "OK hardening aplicado."