#!/usr/bin/env sh
# Copyright (c) 2023, Victor Bouvier-Deleau. All rights reserved.
#
# This program is free software, you can redistribute it and/or modify it under
# the terms of the 3-Clause BSD License written below.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
# 3. Neither the name of the copyright holder nor the names of its contributors
#    may be used to endorse or promote products derived from this software
#    without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

sync_errors=0

echo "Pinging Healthchecks: start"
wget -T 10 -O- -q "https://${HEALTHCHECKS_URL}/${HEALTHCHECKS_UUID}/start"
echo "Begining servers backup..."
for host in ${CONTAINERS_HOSTS}; do
  echo "Rsyncing container host ${host}..."
  mkdir -p "${CONTAINERS_HOSTS_LOCAL_PATH}/${host}/${CONTAINERS_HOSTS_REMOTE_PATH}"
  if rsync -e "ssh -i /root/id_ed25519 -p 2222" -a --delete root@"${host}":"${CONTAINERS_HOSTS_REMOTE_PATH}/" "${CONTAINERS_HOSTS_LOCAL_PATH}/${host}/${CONTAINERS_HOSTS_REMOTE_PATH}/"; then
    echo "Successfuly synced ${host}!"
  else
    echo "Error while syncing ${host}!"
    sync_errors=$((sync_errors + 1))
  fi
done
echo "Rsyncing documents host ${DOCUMENTS_HOST}..."
if rsync -e "ssh -i /root/id_ed25519 -p 2222" -a --delete root@"${DOCUMENTS_HOST}":"${DOCUMENTS_HOST_REMOTE_PATH}/" "${DOCUMENTS_HOST_LOCAL_PATH}/"; then
  echo "Successfuly synced ${DOCUMENTS_HOST}!"
else
  echo "Error while syncing ${DOCUMENTS_HOST}!"
  sync_errors=$((sync_errors + 1))
fi
if [ ${sync_errors} -eq 0 ]; then
  echo "Rsyncing completed successfully!"
  echo "Pinging Healthchecks: success"
  wget -T 10 -O- -q "https://${HEALTHCHECKS_URL}/${HEALTHCHECKS_UUID}"
else
  echo "Error while rsyncing server(s)!"
  echo "Pinging Healthchecks: fail"
  wget -T 10 -O- -q "https://${HEALTHCHECKS_URL}/${HEALTHCHECKS_UUID}/fail"
  exit 1
fi
