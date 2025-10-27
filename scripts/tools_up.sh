#!/usr/bin/env bash
set -euo pipefail

# Optional supervision tools: Portainer + Dozzle

echo "[tools_up] Starting Portainer (9443) and Dozzle (9999)"
docker volume create portainer_data >/dev/null
docker run -d --name portainer --restart=always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest >/dev/null

docker run -d --name dozzle --restart=always \
  -p 9999:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  amir20/dozzle:latest >/dev/null

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$HOST_IP" ]; then
  echo "[tools_up] Portainer: https://$HOST_IP:9443  Dozzle: http://$HOST_IP:9999"
else
  echo "[tools_up] Portainer: https://<host>:9443  Dozzle: http://<host>:9999"
fi
