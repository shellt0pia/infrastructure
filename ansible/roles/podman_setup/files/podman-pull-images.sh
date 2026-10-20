#!/usr/bin/env bash

if [[ ${EUID} -ne 0 ]]; then
  echo "Must be executed as root." 1>&2
  exit 1
fi

podman_pull_failed=0

echo "Pulling new images"

for image in $(grep -s -h -r "Image=" /etc/containers/systemd/ /etc/systemd/system/ | awk -F= '{print $2}' | uniq); do
  podman image pull "${image}" || podman_pull_failed=1
done

[[ ${podman_pull_failed} -ne 0 ]] && exit 1 || exit 0
