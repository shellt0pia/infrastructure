#!/bin/sh
# Called by gluetun when the forwarded port is released.
wget -q -O /dev/null -T 5 \
  --post-data 'json={"listen_port":0,"current_network_interface":"lo"}' \
  http://localhost:8080/api/v2/app/setPreferences || true
