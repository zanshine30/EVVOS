#!/usr/bin/env bash
set -euo pipefail

# install_evvos.sh
# Usage:
#   sudo bash install_evvos.sh <RAW_PY_URL> <EDGE_URL> <EDGE_TOKEN>
# If arguments are not provided, defaults assume the Python file is in the same repo path.
RAW_PY_URL="${1:-https://raw.githubusercontent.com/shyroldan/EVVOS/refs/heads/main/evvos_ble_provision.py}"
EDGE_URL="${2:-https://zekbonbxwccgsfagrrph.functions.supabase.co/handle-device}"
EDGE_TOKEN="${3:-27250d319212d0d3f35ab39af8415345cca8d7d114fac1c5b3b30ae3c9e1be9d}"

echo "Installer starting..."
echo "Python daemon URL: $RAW_PY_URL"
echo "Edge function URL: $EDGE_URL"

# Prepare directories
mkdir -p /opt/evvos
mkdir -p /etc/evvos
chmod 700 /etc/evvos

# Download daemon
echo "Downloading daemon..."
curl -fsSL "$RAW_PY_URL" -o /opt/evvos/evvos_ble_provision.py
if [ ! -s /opt/evvos/evvos_ble_provision.py ]; then
  echo "Failed to download daemon or file empty: $RAW_PY_URL" >&2
  exit 2
fi
chmod +x /opt/evvos/evvos_ble_provision.py

# Write config
cat > /etc/evvos/config.json <<JSON
{
  "supabase_edge_url": "$EDGE_URL",
  "supabase_auth_token": "$EDGE_TOKEN"
}
JSON
chmod 600 /etc/evvos/config.json
echo "Wrote /etc/evvos/config.json"

# Create systemd service unit
cat > /etc/systemd/system/evvos-ble-provision.service <<'UNIT'
[Unit]
Description=EVVOS BLE GATT Provisioning Service
After=bluetooth.service network-online.target
Requires=bluetooth.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/evvos/evvos_ble_provision.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

echo "Created systemd unit"

# Install system packages
echo "Installing system packages (apt) — this may take a minute..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bluez python3-dbus python3-gi python3-pip libdbus-1-dev libdbus-glib-1-dev

# Install Python deps
echo "Installing Python packages (pip)..."
pip3 install --upgrade pip
pip3 install requests cryptography

# Enable & start services
systemctl daemon-reload
systemctl enable bluetooth.service
systemctl enable evvos-ble-provision.service
systemctl restart bluetooth.service || true
systemctl restart evvos-ble-provision.service

echo "Installation finished."
echo "Check logs: sudo journalctl -u evvos-ble-provision -f"
