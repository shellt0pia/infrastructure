# Cluster rename: `kube-cluster01` to `kubecluster-01`

Temporary document: it tracks the rename and is deleted at the end of it (last step). *Not tested yet*: adjust the commands and the checks while running them.

What changes:

| Before | After |
| --- | --- |
| Talos `cluster.name: main` (kubeconfig and talosconfig contexts, `--cluster-name` of the controller manager) | `kubecluster-01` |
| Cluster endpoint `kube-cluster01.shelltopia.net` | `kubecluster-01.shelltopia.net` |
| Issuer and audience of the service account tokens, `https://kube-cluster01.shelltopia.net:6443` (Talos derives both from the endpoint) | `https://kubecluster-01.shelltopia.net:6443` |
| `gateway-external.kube-cluster01.shelltopia.net`, `syslog.kube-cluster01.shelltopia.net` | `gateway-external.kubecluster-01.shelltopia.net`, `syslog.kubecluster-01.shelltopia.net` |
| external-dns owner, record comments, `cluster` label of the metrics | `kubecluster-01` |
| 1Password item `docker-hub-kube-cluster01`, `healthchecks` fields `kube-cluster01-volsync` and `kube-cluster01-alertmanager` | `docker-hub-kubecluster-01`, `kubecluster-01-volsync`, `kubecluster-01-alertmanager` |
| B2 bucket `kube-cluster01-volsync-gz8j9y` | `kubecluster-01-volsync-gz8j9y`, new and empty: the backup history is dropped |
| FRR prefix lists and peer groups `kube-cluster01-*` (OPNsense) | `kubecluster-01-*` (optional) |

Unchanged: the secrets bundle and the PKI, etcd, the subnets, the node names. No node reset, no reboot expected (checked by the dry runs).

Rules:

- Add the new names next to the old ones, switch, then remove the old ones (last step).
- One `wip` commit, amended and force-pushed when Flux must apply a step, squashed into a single commit at the end (without this document).
- external-dns: never push the entry name and the owner together (steps 4 and 5): push step 4, check it, then step 5.
- Each step updates its documents ([AGENTS.md](../AGENTS.md#do-not)): the **Docs** line of each step.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 2 | Host overrides **with the same name** `kubecluster-01.shelltopia.net`, one AAAA per node (the ULA address, same as the old name). | Unbound ([network](network/README.md#names)) | Done |
| 6 | Host overrides `syslog.kubecluster-01.shelltopia.net`, `A` `192.168.19.2` and `AAAA` `fd38:4c4d:8f66:13::2`. | Unbound ([dns](dns/runbook.md#where-to-create-a-record)) | Done |
| 7 | Fields `kubecluster-01-volsync` and `kubecluster-01-alertmanager` in the `healthchecks` item, same ping URLs as the old fields. Checks renamed in healthchecks.io (the ping URL does not change). | 1Password, healthchecks.io | Done |
| 8 | The B2 master key, to delete the old bucket. | B2 web interface | To do |

## 1. Talos: every API server accepts the new name

The kubelets and the control plane components go through KubePrism (`127.0.0.1:7445`), not through the endpoint name: the SAN is for the clients outside the cluster. The issuer and the audience matter more: a node switched at step 2 signs the tokens with the new issuer, the other API server must accept them.

- [x] **Patch.** Temporary `talos/patches/cluster-rename.yaml`, endpoint still the old name: `certExtraSANs` (`KubeAPIServerConfig`) with the new name, `accepted.issuers` (`KubeServiceAccountConfig`) with the new issuer URL, `accepted.audiences` with the old URL first, then the new one. Rendered locally with throwaway secrets: valid, the diff only adds these fields.
- [x] **Diff and apply**, one node at a time:

  ```sh
  just talos diff
  just talos apply-node kube-01
  just talos apply-node kube-03
  ```

  Expected: the diff only adds the fields of the patch, `Applied configuration without a reboot`.

- [x] **Check** on each node:

  ```sh
  openssl s_client -connect kube-01.shelltopia.net:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
  kubectl -n kube-system get pods -l k8s-app=kube-apiserver -o yaml | grep -E 'service-account-issuer|api-audiences'
  ```

  Expected: both names in the certificate. On each API server, `--service-account-issuer` with the old URL first, then the new one, and `--api-audiences` with both.

  Done on 2026-11-13: as expected on both nodes. `linstorControllerOffline` fired right after the apply: the LINSTOR controller could not reach the `kubernetes` Service for 10 seconds (`no route to host`: no API server left behind it, both restarted 19 seconds apart), lost its leader lease and restarted. Satellites `Online`, no error report. Hence the wait between the nodes at steps 2 and 9. The restarts of the controller are an [open point](storage/evaluations.md#open-points).

## 2. Talos: new name and endpoint

- [x] **Item.** Rename `infrastructure/docker-hub-kube-cluster01` to `docker-hub-kubecluster-01` in 1Password. It is only read when a config is rendered.
- [x] **Files.** `talos/vars.yaml`: `cluster.name: kubecluster-01`, `endpoint: https://kubecluster-01.shelltopia.net:6443`. `talos/patches/containerd.yaml.j2`: the new item. `talos/patches/cluster-rename.yaml` now keeps the **old** name: `certExtraSANs` and `accepted.issuers` with the old name, `accepted.audiences` with the new URL first, then the old one. Rendered locally with throwaway secrets: valid, and compared with the config of step 1 only `clusterName`, `endpoint`, `issuerURL`, the patch fields and the `RegistryAuthConfig` change.
- [x] **Diff and apply**, one node at a time. Before the second node, wait until the API server of the first one is back behind the `kubernetes` Service, otherwise the LINSTOR controller loses its lease (step 1):

  ```sh
  just talos diff
  just talos apply-node kube-01
  kubectl get nodes
  kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes
  just talos apply-node kube-03
  ```

  Expected: the diff changes `clusterName`, `endpoint`, `issuerURL` and the patch fields (not the `RegistryAuthConfig`: the diff shows the resolved values, the same in the renamed item); `Applied configuration without a reboot`, else stop. Both node addresses in the EndpointSlice before the second apply. The nodes stay `Ready`, no `401` in the logs of the pods (Cilium, Flux, cert-manager), no restart of the LINSTOR controller.

  Done on 2026-11-13: diff and applies as expected, each node out of the EndpointSlice for a few seconds, then back.

- [x] **Check:**

  ```sh
  kubectl -n kube-system get pods -l k8s-app=kube-apiserver -o yaml | grep -E 'service-account-issuer|api-audiences'
  openssl s_client -connect kube-01.shelltopia.net:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
  kubectl -n kube-system logs kube-apiserver-kube-01 --since=30m | grep -ci 'unable to authenticate'
  kubectl -n kube-system logs kube-apiserver-kube-03 --since=30m | grep -ci 'unable to authenticate'
  kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-controller
  kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded
  ```

  Expected: `--service-account-issuer` with the new URL first, then the old one, `--api-audiences` with both, the new one first. Both names in the certificate. `0` authentication errors. The LINSTOR controller still at 8 restarts. No pod in error.

- [x] **Docs:** `talos/vars.yaml` comments (nothing to change), [network](network/README.md) (principles, names), [network bootstrap](network/bootstrap.md#2-dns-unbound-internal-only), [network evaluations](network/evaluations.md), [reference](reference.md) (names, 1Password items), [secrets](secrets/README.md), [secrets bootstrap](secrets/bootstrap.md), [secrets runbook](secrets/runbook.md).

## 3. Clients

- [x] **Regenerate** the talosconfig and the kubeconfig (contexts named after `cluster.name`, server on the new endpoint):

  ```sh
  just talos talosconfig
  just bootstrap kubeconfig
  kubectl get nodes
  flux get kustomizations -A
  ```

  Expected: the contexts are named `kubecluster-01`, the server is `https://kubecluster-01.shelltopia.net:6443`, everything is ready.

  Done on 2026-11-13: as expected, `talosctl get members` answers with the new talosconfig.

## 4. Public names: the entry name

Owner unchanged: external-dns updates its own CNAMEs and deletes its old AAAA.

- [x] **Files.** The new entry name in `network/gateways/app/gateway-external.yaml` (target), `network/gateways/app/envoyproxy-external.yaml` (hostname), `network/cloudflare-ddns/app/deployment.yaml` (name and comment), and the comments of `network/external-dns/app/helmrelease.yaml`. `regex-domain-filter` accepts **both** names, otherwise the old AAAA is never deleted:

  ```yaml
  regex-domain-filter: '^(.+\.)?shelltopia\.org$|^(gateway-external\.(kube-cluster01|kubecluster-01)\.)?shelltopia\.net$'
  ```

  Rendered locally (`flux build`): only these values change, owner and record comment of external-dns unchanged.

- [x] **Push** the `wip` commit (amend, force push).
- [x] **Check** once Flux applied it, and after a cycle of external-dns:

  ```sh
  kubectl -n network logs deploy/external-dns
  kubectl -n network logs deploy/cloudflare-ddns
  dig +short CNAME <app>.shelltopia.org @1.1.1.1
  dig +short A gateway-external.kubecluster-01.shelltopia.net @1.1.1.1
  dig +short AAAA gateway-external.kubecluster-01.shelltopia.net @1.1.1.1
  dig +short AAAA gateway-external.kube-cluster01.shelltopia.net @1.1.1.1
  ```

  Expected: external-dns updates the CNAMEs, creates the AAAA of the new name and deletes the old one (with their `aaaa-` TXT records); cloudflare-ddns creates the `A` of the new name. The CNAMEs point to the new name, it has its `A` and `AAAA`, the old AAAA is gone. A public application answers from outside.

- [x] **Old `A` record.** cloudflare-ddns never deletes it: delete `A gateway-external.kube-cluster01.shelltopia.net` by hand in Cloudflare.
- [x] **Docs:** [dns](dns/README.md), [dns bootstrap](dns/bootstrap.md), [dns runbook](dns/runbook.md), [dns evaluations](dns/evaluations.md), [network runbook](network/runbook.md), [milkywan](network/milkywan.md), [network evaluations](network/evaluations.md), [reference](reference.md).

## 5. external-dns: the owner

- [x] **Flag.** Chart `1.23.0` runs external-dns `v0.23.0`, which has `--migrate-from-txt-owner` (`pkg/apis/externaldns/types.go`). Read in its code: the registry reads the records of the old owner as owned by the new one, and the planner updates every record whose owner differs from the old one, at **every cycle** while the flag is set: the TXT records are rewritten with the new owner. The comment of the records is compared too: a new `cloudflare-record-comment` updates them.
- [x] **Files.** `network/external-dns/app/helmrelease.yaml`: `txtOwnerId: kubecluster-01`, `migrate-from-txt-owner: kube-cluster01` in `extraArgs`, `cloudflare-record-comment: managed by external-dns (kubecluster-01)`, `regex-domain-filter` with the new name only, the comment of `txtOwnerId` updated. Rendered locally (`helm template`): the arguments `--txt-owner-id=kubecluster-01` and `--migrate-from-txt-owner=kube-cluster01`.
- [x] **Push** the `wip` commit (amend, force push).
- [x] **Check** after a cycle of external-dns:

  ```sh
  kubectl -n network logs deploy/external-dns --since=5m
  dig +short TXT cname-<app>.shelltopia.org @1.1.1.1
  dig +short TXT aaaa-gateway-external.kubecluster-01.shelltopia.net @1.1.1.1
  ```

  Expected: `UPDATE` of the CNAMEs, the AAAA and their TXT records, then `external-dns/owner=kubecluster-01` everywhere. No `owner id does not match` in the logs. In Cloudflare, the comment `managed by external-dns (kubecluster-01)`.

- [x] **Remove** `migrate-from-txt-owner` and its comment right after the check, and push: until then, every record is updated every minute. Expected in the logs: `All records are already up to date`. Files ready: the flag removed, the comment of `txtOwnerId` says how to change it.
- [x] **Docs:** [dns](dns/README.md#overview) (owner, comments).

## 6. Syslog

- [x] **Devices.** Point each device to `syslog.kubecluster-01.shelltopia.net:514`, same transport as before ([external devices](observability/README.md#external-devices)): `fw-01` (OPNsense, *System → Settings → Logging → Remote*), `sw-01` (RouterOS, `/system logging action set [find name=vector] remote=syslog.kubecluster-01.shelltopia.net`), `nas-01` (TrueNAS, *System → Advanced Settings → Syslog*), `ap-01`. Independent of the push: the host overrides of the new name already exist.
- [x] **Check** in VictoriaLogs, 15 minutes after the last device:

  ```logsql
  log_source:syslog _time:15m | stats by (host) count()
  ```

  Expected: the four hosts. `SyslogHostSilent` does not fire.

- [x] **Files:** the comment of `observability/vector-aggregator/app/helmrelease.yaml`.
- [x] **Docs:** [observability](observability/README.md), [observability bootstrap](observability/bootstrap.md), [observability evaluations](observability/evaluations.md), [dns runbook](dns/runbook.md), [dns evaluations](dns/evaluations.md), [conventions](conventions.md#loadbalancer-addresses), [reference](reference.md). The host override `graphite.kube-cluster01.shelltopia.net` of the observability bootstrap keeps its name: it was deleted under it.

## 7. Metrics label and healthchecks fields

- [x] **Files.** `observability/victoria-metrics-k8s-stack/app/helmrelease.yaml`: `cluster: kubecluster-01` in `externalLabels`. The keys `healthchecks/kubecluster-01-alertmanager` (same folder, `externalsecret.yaml`) and `healthchecks/kubecluster-01-volsync` (`backups/volsync-monitor/app/externalsecret.yaml`). Nothing else uses the value of the label: the dashboards read it through their `cluster` variable. Rendered locally (`flux build`).
- [x] **Push** the `wip` commit (amend, force push), with step 6.
- [x] **Check:**

  ```sh
  kubectl get externalsecret -A
  kubectl -n observability get vmagent -o yaml | grep -A1 externalLabels
  ```

  Expected: every ExternalSecret `SecretSynced`. The new series carry `cluster="kubecluster-01"`, the history keeps the old label until the end of the retention (90 days): pick the new value in the `cluster` variable of the dashboards. The alerts firing at the push resolve and fire again with the new label: one more notification each. The pending ones start their `for:` again. The Watchdog keeps pinging its check, the next `volsync-monitor` job (09:00) pings `kubecluster-01-volsync`.

- [x] **Docs:** [observability](observability/README.md) (label, dead man's switch), [observability bootstrap](observability/bootstrap.md), [backups](backups/README.md#monitoring), [backups bootstrap](backups/bootstrap.md), [reference](reference.md#1password-items).

## 8. B2 bucket

The new bucket starts empty: no backup between the apply and the first backup of each application. Do not delete a PVC with its ReplicationDestination in between, the restore would be empty.

- [x] **Forget the old bucket.** `prevent_destroy` blocks the plan otherwise. The old key stays in the state: the apply deletes it.

  ```sh
  just tofu run backblaze state rm "'b2_bucket.restic[\"kube-cluster01-volsync\"]'"
  ```

  Expected: `Removed b2_bucket.restic["kube-cluster01-volsync"]`. The extra single quotes survive the interpolation of the recipe: same form as [tofu/README.md](../tofu/README.md#bucket-rebuilt-by-hand), not tested.

- [x] **Files.** `tofu/backblaze/main.tf`: the key `kubecluster-01-volsync` in `restic_repositories` (same vault and item). OpenTofu runs from the working tree: no push needed before the plan. `fmt` checked.
- [x] **Plan and apply:**

  ```sh
  just tofu plan backblaze
  just tofu apply backblaze
  ```

  Expected: the plan creates `b2_bucket.restic["kubecluster-01-volsync"]` and `b2_application_key.restic["kubecluster-01-volsync"]`, destroys `b2_application_key.restic["kube-cluster01-volsync"]`, nothing else (and the sensitive output `onepassword_items` changes). `sync-1password` updates `repository` (`s3:https://s3.eu-central-003.backblazeb2.com/kubecluster-01-volsync-gz8j9y`), `access-key-id` and `secret-access-key` of `restic-volsync`, the restic `password` is kept. A second `just tofu plan backblaze` shows no change.

- [x] **Refresh** the Secrets of VolSync now rather than in 12 hours:

  ```sh
  kubectl get externalsecret -A -o json \
    | jq -r '.items[] | select(.metadata.name | endswith("-volsync")) | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do kubectl -n "$ns" annotate externalsecret "$name" force-sync="$(date +%s)" --overwrite; done
  ```

- [ ] **Check** after the next backups:

  ```sh
  kubectl get replicationsource -A
  ```

  Expected: a recent `LAST SYNC` everywhere. The mover initializes each repository: one `<app>/` folder per application in the new bucket. The `volsync-monitor` check stays green.

- [x] **Old bucket and key**, with the master key:

  ```sh
  b2 rm --versions --recursive b2://kube-cluster01-volsync-gz8j9y
  b2 bucket delete kube-cluster01-volsync-gz8j9y
  b2 key list --long
  b2 account clear
  ```

  Expected: the bucket is gone, `kube-cluster01-volsync` is no longer in the keys (deleted by the apply).

- [x] **Docs:** [backups](backups/README.md#destination-backblaze-b2), [backups bootstrap](backups/bootstrap.md), [backups runbook](backups/runbook.md) (the bucket names of the recovery).

## 9. Cleanup

Unbound, 1Password and BGP can be done now: steps 6 and 7 are checked. The Talos patch waits 24 hours after step 2, the final grep waits for it.

- [x] **Unbound.** Delete the host overrides `kube-cluster01.shelltopia.net` and `syslog.kube-cluster01.shelltopia.net`. Nothing in the repository uses them any more; a kubeconfig or a talosconfig on another machine would: regenerate it first (step 3).

  ```sh
  dig +short AAAA kube-cluster01.shelltopia.net
  dig +short A syslog.kube-cluster01.shelltopia.net
  ```

  Expected: no answer. `SyslogHostSilent` does not fire.

- [x] **1Password.** Delete the fields `kube-cluster01-volsync` and `kube-cluster01-alertmanager` of `healthchecks`. The ExternalSecrets read the new fields since step 7. Expected: `kubectl get externalsecret -A` still all `SecretSynced` after a refresh.
- [x] **BGP (optional).** Rename the prefix lists and peer groups `kube-cluster01-*` in OPNsense. The BGP sessions probably restart: the LoadBalancer addresses are withdrawn for a few seconds. Docs: [network bootstrap](network/bootstrap.md#4-bgp-frr), [milkywan](network/milkywan.md).

  Done on 2026-11-13: renamed `kubecluster-01-lb-v4`, `kubecluster-01-lb-v6`, `kubecluster-01-v4` and `kubecluster-01-v6`, docs updated.
- [ ] **Talos**, not before 2026-11-14 04:10 (24 hours after step 2): the kubelets have replaced the tokens of the old issuer by then. A client that keeps an old token without reading it again would be rejected. Before, in VictoriaMetrics:

  ```promql
  sum by (instance) (increase(serviceaccount_stale_tokens_total[24h]))
  ```

  Expected: `0`, else find the client first. The scrape of the API servers is the default of the chart: if the series is missing, `kubectl get --raw /metrics | grep serviceaccount_stale_tokens_total` (one API server per call). Then delete `talos/patches/cluster-rename.yaml` (the recipes read every file of `patches/`), and apply one node at a time, with the same wait as at step 2:

  ```sh
  just talos diff
  just talos apply-node kube-01
  kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes
  just talos apply-node kube-03
  ```

  Expected: the diff only removes `certExtraSANs` and the `accepted` issuers and audiences, `Applied configuration without a reboot`. Then the checks of step 2: only the new name in the certificate, the new issuer and audience alone, `0` authentication errors, no pod in error, no restart of the LINSTOR controller.

- [x] **Leftovers.** The sentence "The statuses and checkboxes track `kubecluster-01`" of every `bootstrap.md`.
- [ ] **Final grep**, after the Talos patch:

  ```sh
  grep -rn --exclude-dir=.git --exclude-dir=.scratch --exclude=kubeconfig --exclude=talosconfig 'kube-cluster01' .
  ```

  Expected: nothing outside this document, except `graphite.kube-cluster01.shelltopia.net` in the observability bootstrap (deleted under this name).

- [ ] **Delete this document**, then squash the `wip` commit.
