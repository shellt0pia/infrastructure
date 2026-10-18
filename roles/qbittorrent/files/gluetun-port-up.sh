#!/bin/sh
# Called by gluetun when a port has been forwarded: gluetun-port-up.sh <ports> <vpn interface>
# Requires qBittorrent's "Bypass authentication for clients on localhost" option.
port="${1%%,*}"
interface="${2:-tun0}"
attempt=0
while [ "${attempt}" -lt 30 ]; do
  if wget -q -O /dev/null -T 10 \
    --post-data "json={\"listen_port\":${port},\"current_network_interface\":\"${interface}\",\"random_port\":false,\"upnp\":false}" \
    http://localhost:8080/api/v2/app/setPreferences; then
    echo "qBittorrent listening port set to ${port} on ${interface}"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 10
done
echo "Failed to set qBittorrent listening port to ${port}" >&2
exit 1
