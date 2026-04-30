#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/avi-cac-demo"
APP_USER="aviapp"

sudo apt update
sudo apt install -y python3 python3-venv python3-pip nginx curl

if ! id "$APP_USER" >/dev/null 2>&1; then
  sudo useradd --system --shell /usr/sbin/nologin --home "$APP_DIR" "$APP_USER"
fi

sudo mkdir -p "$APP_DIR"
sudo cp -r app.py requirements.txt .env.cac.demo "$APP_DIR"/
sudo cp .env.cac.demo "$APP_DIR/.env"

sudo chown -R "$APP_USER:www-data" "$APP_DIR"

sudo -u "$APP_USER" python3 -m venv "$APP_DIR/venv"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install --upgrade pip
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

sudo cp systemd/avi-cac-demo.service /etc/systemd/system/avi-cac-demo.service
sudo systemctl daemon-reload
sudo systemctl enable --now avi-cac-demo

sudo cp nginx/avi-cac-demo.conf /etc/nginx/sites-available/avi-cac-demo
sudo ln -sf /etc/nginx/sites-available/avi-cac-demo /etc/nginx/sites-enabled/avi-cac-demo
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

echo "Install complete."
echo "Check app: curl http://127.0.0.1:8080/health"