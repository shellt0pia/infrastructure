# Cluster: first deployment

The Git repository, the checks before the bootstrap, `just bootstrap cluster` and the checks of the cluster, of the network policies and of Pod Security. Architecture: [README.md](README.md). The order of the whole bootstrap is in [first-bootstrap.md](../first-bootstrap.md).

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kubecluster-01`.

## Prerequisites

| Step | Prerequisite | How | Status |
| --- | --- | --- | --- |
| 1 | Workstation tools installed. | [first-bootstrap.md](../first-bootstrap.md#phase-0--workstation) | Done |
| 1 | OPNsense configured: the BGP sessions and the LoadBalancer pools of the cluster must match it (ASNs, pools, ULA address of OPNsense). | [network/bootstrap.md](../network/bootstrap.md#4-bgp-frr) | Done |
| 2, 3 | The service accounts, the Talos secrets and the Docker Hub and NUT credentials. | [secrets/bootstrap.md](../secrets/bootstrap.md) | Done |
| 3 | The nodes booted in maintenance mode, each reachable by its name. | [nodes/bootstrap.md](../nodes/bootstrap.md#3-first-boot-in-maintenance-mode) | Done for kube-01 and kube-03 |
| 3 | Item `cloudflare-cert-manager` in the `kubernetes` vault (field `credential`, a Cloudflare token with *Zone → DNS → Edit* and *Zone → Zone → Read*), for the Let's Encrypt issuers. | [ingress/bootstrap.md](../ingress/bootstrap.md#prerequisites) | Done |

## 1. Git repository

- [x] **Cluster ranges.** In `talos/vars.yaml`, check the [cluster ranges](README.md#cluster-ranges), they **cannot be changed** once the cluster is created.
- [x] **CNI and CoreDNS.** Cilium and CoreDNS are the first releases of `bootstrap/helmfile/apps.yaml.gotmpl`. Flannel, kube-proxy and the CoreDNS managed by Talos are disabled in the Talos configuration: until Cilium runs, the nodes stay `NotReady`. Their values live in `kubernetes/apps/kube-system/{cilium,coredns}/app/helmrelease.yaml` and repeat the cluster ranges of `talos/vars.yaml`: keep them in sync if the ranges are changed before the bootstrap. The CoreDNS service is dual-stack with the cluster DNS addresses given to the kubelet (the 10th address of each service subnet): `10.96.0.10` then `fd1b:654d:9afe:200::a`.
- [x] **BGP and pools.** The BGP sessions and the LoadBalancer pools in `kubernetes/apps/kube-system/cilium/networking` match the [OPNsense configuration](../network/bootstrap.md#4-bgp-frr) (ASNs, pools, ULA address of OPNsense). helmfile applies them right after Cilium.
- [x] **Flux source.** In `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`:
  - `url`: the real URL of the GitHub repository;
  - `ref`: the branch Flux must follow.
- [x] **Commit and push.** Meanwhile, check that the working copy holds neither `talosconfig`, `kubeconfig` nor `*.iso`:

  ```sh
  git status
  ```

  Expected: none of the three files listed.

The branch matters: helmfile installs the bootstrap apps from the local working copy, but Flux then applies what is **on GitHub**, on the configured branch. So either merge into `main` before the bootstrap, or temporarily set `refs/heads/migrate-to-k8s` and switch back to `main` after the merge. Either way, **commit and push** the `sync.ref` value of `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` before the bootstrap: Flux reapplies this HelmRelease from the pushed commit, and an older value would switch the `GitRepository` to another branch (every Kustomization then fails with `kustomization path not found`). To recover, patch `spec.values.instance.sync.ref` of the `flux-instance` HelmRelease in the cluster, then:

```sh
flux -n flux-system reconcile hr flux-instance --force
```

## 2. Dry checks

These checks have no impact on the nodes.

- [x] **Rendered configs.** For each node, the rendered config must be valid:

  ```sh
  talosctl validate --mode metal --strict --config <(just talos render-config kube-01)
  ```

  Expected: the config is reported as valid for `metal` mode, for each node.

- [x] **helmfile.** It must list the releases with the expected versions:

  ```sh
  cd bootstrap/helmfile && helmfile -f apps.yaml.gotmpl list
  ```

- [x] **Manifests.** They must build:

  ```sh
  kubectl kustomize kubernetes/apps/flux-system
  kubectl kustomize kubernetes/apps/external-secrets
  kubectl kustomize kubernetes/apps/cert-manager
  kubectl kustomize kubernetes/apps/cert-manager/cert-manager/issuers
  kubectl kustomize kubernetes/apps/kube-system
  kubectl kustomize kubernetes/apps/kube-system/cilium/networking
  kubectl kustomize kubernetes/apps/kube-system/cilium/policies
  kubectl kustomize kubernetes/apps/kube-system/intel-device-plugin/gpu
  kubectl kustomize kubernetes/apps/envoy-gateway-system
  kubectl kustomize kubernetes/apps/network
  kubectl kustomize kubernetes/apps/network/gateways/app
  ```

  Expected: every command prints its manifests, without error.

## 3. Bootstrap

- [x] **Nodes.** The nodes are booted from the ISO in maintenance mode, each reachable by its name, and the USB drive is removed.
- [x] **Bootstrap.** Run the recipe and confirm:

  ```sh
  just bootstrap cluster
  ```

  Each stage logs its progress (`gum log`). The recipe can safely be run again after a failure: the nodes already configured are skipped and an already bootstrapped etcd is left as is. A single stage can also be run alone:

  ```sh
  just bootstrap apps
  ```

- [x] **Checks of each node:** [nodes/bootstrap.md](../nodes/bootstrap.md#4-checks-after-the-bootstrap).

Checks on the cluster:

- [x] **Nodes:**

  ```sh
  kubectl get nodes -o wide
  kubectl get node kube-01 -o jsonpath='{.status.addresses}'
  ```

  Expected: the nodes are `Ready`, without taints, with the IPv4 address as `INTERNAL-IP`. The second command lists the ULA address too.

- [x] **Pod CIDRs:**

  ```sh
  kubectl get node kube-01 -o jsonpath='{.spec.podCIDRs}'
  ```

  Expected: one IPv4 /24 from `10.244.0.0/16` and one IPv6 /64 from `fd1b:654d:9afe:100::/56`.

- [x] **Cilium:**

  ```sh
  kubectl -n kube-system exec ds/cilium -- cilium-dbg status
  kubectl -n kube-system exec ds/cilium -- cilium-health status
  ```

  Expected: `KubeProxyReplacement: True`, `Routing: Network: Native`, `Masquerading: IPTables [IPv4: Enabled, IPv6: Enabled]`, and every controller healthy. Every node is reachable.

- [x] **API server to kubelet** (port 10250), on a pod of each node:

  ```sh
  kubectl -n <namespace> logs <pod>
  kubectl -n <namespace> exec <pod> -- <command>
  ```

  Expected: both work.

- [x] **Cluster DNS:**

  ```sh
  kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIPs}'
  ```

  Expected: the two cluster IPs `10.96.0.10` and `fd1b:654d:9afe:200::a`. The `CLUSTER-IP` column of `kubectl get svc` only shows the primary one.

- [x] **Network:** DNS and egress from a pod, the BGP sessions and a LoadBalancer Service: [network tests](../network/bootstrap.md#network-tests-after-the-bootstrap).
- [x] **Flux:**

  ```sh
  kubectl -n flux-system get fluxinstance
  flux get ks -A
  flux get hr -A
  ```

  Expected: everything is `Ready`. cert-manager and the Intel GPU device plugin are only deployed by Flux, after the bootstrap: `intel-device-plugin-operator` waits for `cert-manager`, then `intel-device-plugin-gpu` waits for the operator.

- [x] **cert-manager:**

  ```sh
  kubectl -n cert-manager get pods
  kubectl get clusterissuers
  kubectl -n cert-manager get externalsecret cloudflare-api-token
  ```

  Expected: the controller, the webhook and the cainjector are running. `letsencrypt-staging` and `letsencrypt-production` are `Ready`: this needs the `cloudflare-cert-manager` item (see the prerequisites), synced by the ExternalSecret.

- [x] **Envoy Gateway and the Gateways:** see the checks of [ingress/bootstrap.md](../ingress/bootstrap.md#1-deploy-and-check). The wildcard certificate is issued by `letsencrypt-production`.
- [x] **Application DNS** (k8s-gateway, external-dns, cloudflare-ddns): see the checks of [dns/bootstrap.md](../dns/bootstrap.md#1-deploy-and-check). external-dns and cloudflare-ddns need the `cloudflare-external-dns` and `cloudflare-ddns` items in the `kubernetes` vault ([dns/bootstrap.md](../dns/bootstrap.md#prerequisites)); Unbound must forward `shelltopia.org` to k8s-gateway ([dns/bootstrap.md](../dns/bootstrap.md#2-opnsense-unbound)).
- [x] **Storage:** [storage/bootstrap.md](../storage/bootstrap.md).
- [x] **External Secrets:**

  ```sh
  kubectl get clustersecretstore onepassword
  ```

  Expected: the `READY` column is `True`.

- [x] **Test ExternalSecret.** Create one targeting the [test item](../secrets/bootstrap.md#5-service-account-for-external-secrets).

### Intel GPU device plugin

- [x] **Plugin:**

  ```sh
  kubectl get gpudeviceplugins
  kubectl -n kube-system get pods -o wide | grep intel-gpu-plugin
  ```

  Expected: `intel-gpu`, with as many ready nodes as desired. One pod on kube-01 only (kube-02 later), none on kube-03.

- [x] **Resources of the node:**

  ```sh
  kubectl get node kube-01 -o jsonpath='{.status.allocatable}'
  ```

  Expected: `gpu.intel.com/i915` is `3`. kube-03 has no `gpu.intel.com/*` resource.

- [x] **Render node.** A non-root pod requesting the GPU sees the render node, owned by its user (`device_ownership_from_security_context` in `talos/patches/containerd.yaml.j2`). The test pods of this page run in the privileged [`debug` namespace](README.md#pod-security):

  ```sh
  kubectl -n debug apply -f - <<'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: gputest
  spec:
    restartPolicy: Never
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
    containers:
      - name: gputest
        image: docker.io/library/busybox
        command: [ls, -ln, /dev/dri]
        resources:
          limits:
            gpu.intel.com/i915: 1
  EOF
  kubectl -n debug wait --for=jsonpath='{.status.phase}'=Succeeded pod/gputest
  kubectl -n debug get pod gputest -o wide    # scheduled on kube-01
  kubectl -n debug logs gputest               # renderD128 (and card0) owned by 1000:1000
  kubectl -n debug delete pod gputest
  ```

### Reloader

- [x] **Deployment:**

  ```sh
  flux -n kube-system get hr reloader
  kubectl -n kube-system get pods -l app=reloader
  ```

  Expected: the HelmRelease is `Ready`, one pod `Running`.

- [x] **Reload on change.** A test Deployment that reads a ConfigMap as an env var is restarted when the ConfigMap changes:

  ```sh
  kubectl -n debug create configmap reloader-test --from-literal=VALUE=1
  kubectl -n debug apply -f - <<'EOF'
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: reloader-test
    annotations:
      reloader.stakater.com/auto: "true"
  spec:
    selector:
      matchLabels:
        app: reloader-test
    template:
      metadata:
        labels:
          app: reloader-test
      spec:
        containers:
          - name: test
            image: docker.io/library/busybox
            command: [sh, -c, 'echo "VALUE=$VALUE"; sleep 3600']
            envFrom:
              - configMapRef:
                  name: reloader-test
  EOF
  kubectl -n debug rollout status deploy/reloader-test
  kubectl -n debug create configmap reloader-test --from-literal=VALUE=2 --dry-run=client -o yaml | kubectl -n debug apply -f -
  sleep 10
  kubectl -n debug rollout status deploy/reloader-test
  kubectl -n debug logs deploy/reloader-test
  kubectl -n debug get deploy reloader-test -o jsonpath='{.spec.template.metadata.annotations}'
  kubectl -n kube-system logs deploy/reloader | grep reloader-test
  kubectl -n debug delete deploy/reloader-test configmap/reloader-test
  ```

  Expected: a new pod, whose log shows `VALUE=2`. The pod template carries `reloader.stakater.com/last-reloaded-from` and the log of Reloader reports the change of the ConfigMap. The containers have no `STAKATER_*` env var (`annotations` strategy).

- [x] **Opted-in workloads.** external-dns and cloudflare-ddns carry the annotation:

  ```sh
  kubectl -n network get deploy external-dns cloudflare-ddns -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.reloader\.stakater\.com/auto}{"\n"}{end}'
  ```

  Expected: `true` for both. The restart itself is checked at the next token rotation ([secrets runbook](../secrets/runbook.md#replacing-a-token-synced-to-the-cluster)).

### Spegel

Spegel is installed by `just bootstrap apps` (after CoreDNS) and by Flux ([README](README.md#spegel)). On a running cluster, Flux deploys it alone.

- [x] **Deployment:**

  ```sh
  flux -n kube-system get hr spegel
  kubectl -n kube-system get pods -l app.kubernetes.io/name=spegel -o wide
  kubectl -n kube-system logs ds/spegel -c registry | grep -i error
  ```

  Expected: the HelmRelease is `Ready`, one pod `Running` and ready per node, no error in the log. A pod that exits at startup reports the containerd setting it refuses (registry config path, `discard_unpacked_layers`).

- [x] **Mirror configuration on the nodes:**

  ```sh
  talosctl -n kube-01.shelltopia.net ls /etc/cri/conf.d/hosts
  talosctl -n kube-01.shelltopia.net read /etc/cri/conf.d/hosts/_default/hosts.toml
  ```

  Expected: `_default` and `_backup` (what was there before Spegel). `hosts.toml` has no `server` line (the upstream registry is implicit) and a single host `http://<IPv4 of the node>:30020` with the `pull` and `resolve` capabilities.

- [x] **Pull through a peer.** Pull an image absent from the cluster on kube-01, then on kube-03:

  ```sh
  for node in kube-01 kube-03; do
    kubectl -n debug run spegel-test-$node --image=docker.io/library/alpine:3.22 --restart=Never \
      --overrides='{"spec":{"nodeName":"'$node'"}}' --command -- true
    kubectl -n debug wait --for=jsonpath='{.status.phase}'=Succeeded pod/spegel-test-$node
  done
  kubectl -n debug get events --field-selector involvedObject.name=spegel-test-kube-03 | grep Pulled
  kubectl -n kube-system port-forward "$(kubectl -n kube-system get pods -l app.kubernetes.io/name=spegel --field-selector spec.nodeName=kube-03 -o name)" 9090
  ```

  Then open `http://localhost:9090/debug/web`, and delete the pods:

  ```sh
  kubectl -n debug delete pod spegel-test-kube-01 spegel-test-kube-03
  ```

  Expected: on the debug page of the Spegel of kube-03, `Last Mirror Success` shows a duration (not `Pending`). The pull on kube-03 is much shorter than the one on kube-01 in the `Pulled` events.

- [x] **Verified images.** An image checked by the `ImageVerificationConfig` of Talos (`talos/patches/security.yaml`) still pulls through Spegel. kube-proxy is disabled, its image (at the Kubernetes version of `talos/vars.yaml`) is on no node:

  ```sh
  for node in kube-01 kube-03; do
    kubectl -n debug run spegel-verify-$node --image=registry.k8s.io/kube-proxy:v1.37.1 --restart=Never \
      --overrides='{"spec":{"nodeName":"'$node'"}}' --command -- kube-proxy --version
    kubectl -n debug wait --for=jsonpath='{.status.phase}'=Succeeded pod/spegel-verify-$node
  done
  kubectl -n debug logs spegel-verify-kube-03
  kubectl -n debug delete pod spegel-verify-kube-01 spegel-verify-kube-03
  ```

  Expected: both pods succeed and print the version, `Last Mirror Success` of kube-03 is updated. A verification failure shows up as `ErrImagePull` in the events of the pod.

- [ ] **Mirror kept after a Talos change.** After the next `just talos apply-node` that changes the machine config of a node, and after the next Talos upgrade, read `_default/hosts.toml` again as above ([open point](evaluations.md#open-points)).

  Expected: the `http://<IPv4 of the node>:30020` host is still there. If not, restart the DaemonSet (`kubectl -n kube-system rollout restart ds/spegel`) and record it in the [runbook](runbook.md).

### Network policies

The policies were first deployed in audit mode (`policyAuditMode: true` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`): the denied flows are reported, nothing is dropped. They are enforced once the flows are understood and the observability stack shows the drops ([README](README.md#network-policies)). A new cluster gets them enforced: if they changed since, return to audit mode first ([runbook](runbook.md#network-policies)).

- [x] **Deployment:**

  ```sh
  flux -n kube-system get ks cilium-policies
  kubectl get ciliumclusterwidenetworkpolicies
  kubectl get ciliumnetworkpolicies -A
  kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-host-firewall} {.data.policy-audit-mode}{"\n"}'
  kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i firewall
  kubectl get networkpolicies -A
  ```

  Expected: the Kustomization is `Ready`. The clusterwide policies `host`, `baseline` and `coredns`; `same-namespace` in each namespace of `kubernetes/apps`, plus `envoy-proxies`, `k8s-gateway`, `spegel` and `linstor-controller`. `true true`, and the host firewall `Enabled` on the devices of the node. No Kubernetes NetworkPolicy in the cluster (a chart that creates one opens its pods over the baseline: disable it in its values).

- [x] **Hubble Relay:**

  ```sh
  kubectl -n kube-system get pods -l k8s-app=hubble-relay
  kubectl -n kube-system get cronjob hubble-generate-certs
  hubble status -P
  ```

  Expected: the Relay pod is `Running`, the CronJob exists. `hubble status` reports every node as connected (`-P` forwards the port of the Relay through the Kubernetes API).

- [x] **Hubble UI**, once the client is in the Pocket ID and its item in 1Password ([prerequisites](../ingress/runbook.md#a-ui-without-a-login-of-its-own)):

  ```sh
  flux -n kube-system get ks cilium cilium-hubble-ui
  kubectl -n kube-system get pods -l k8s-app=hubble-ui
  kubectl -n kube-system get externalsecret,httproute,securitypolicy
  kubectl -n envoy-gateway-system logs deploy/envoy-gateway | grep -i -E 'error|oidc'
  curl -sI https://hubble.shelltopia.org
  ```

  Expected: both Kustomizations `Ready`, the pod `Running` with its two containers, `SecretSynced`, the route and the policy `Accepted`, no error about the OIDC provider. `302` to `https://id.shelltopia.org/authorize`. In a browser, a member of `kubernetes_admins` sees the flows of a namespace, another user is refused by the Pocket ID ([README](README.md#network-policies)). Done on 2026-11-13: as expected, with PKCE (Envoy sends a `code_challenge`).

- [x] **Audited flows.** Over a few weeks, so that the nightly backups, a Flux reconciliation of each Kustomization and a certificate renewal run at least once. Hubble only keeps the last flows of each node in memory: read the [export](README.md#network-policies) of each node, then, once the observability stack runs, query the logs instead:

  ```sh
  for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    kubectl -n kube-system exec "$pod" -c cilium-agent -- sh -c 'cat /var/run/cilium/hubble/events*.log'
  done | hubble observe --input-file - --verdict AUDIT
  ```

  Expected: none, except the tests below. Each other flow is either needed (add an exception, [runbook](runbook.md#network-policies)) or must be denied (note why). Done: the `AUDIT` flows only come with a new tool or manifest, until its exceptions are written, or go to the address of a pod just deleted (`world`: a stale scrape target, the old address of an Alertmanager peer; [observability](../observability/evaluations.md#open-points)). The drops `INVALID_SOURCE_IP` (the Router Solicitations of the pods, harmless: [README](README.md#network-policies)), `UNKNOWN_L3_TARGET_ADDRESS` and `FORBIDDEN_ICMPV6_MESSAGE` have no verdict of the policies: [open points](evaluations.md#open-points), they do not wait for the enforcement.

- [x] **Denied flows.** From a test pod on kube-01, towards the ports of another node (kubelet over IPv4, Talos API over ULA and GUA), and a private address outside of the cluster (the NAS, over ULA):

  ```sh
  kubectl -n debug run np-test --image=docker.io/library/busybox --restart=Never \
    --overrides='{"spec":{"nodeName":"kube-01"}}' --command -- sleep 600
  kubectl -n debug wait --for=condition=Ready pod/np-test
  kubectl -n debug exec np-test -- nc -zv -w 3 192.168.15.13 10250
  kubectl -n debug exec np-test -- nc -zv -w 3 <ULA of kube-03> 50000
  kubectl -n debug exec np-test -- nc -zv -w 3 <GUA of kube-03> 50000
  kubectl -n debug exec np-test -- nc -zv -w 3 nas-01-dmz.shelltopia.net 443
  kubectl -n debug exec np-test -- nslookup github.com
  kubectl -n debug exec np-test -- wget -q --no-check-certificate --spider https://github.com
  hubble observe -P --verdict AUDIT --pod debug/np-test
  kubectl -n debug delete pod np-test
  ```

  `--no-check-certificate`: the busybox image has no CA certificates, only the egress is tested.

  Expected: the connections still succeed (audit mode), and each of the four first ones shows up as `AUDITED`, with `debug/np-test` and its identity as source. The two node ports are audited on `INGRESS` by the host firewall: the masquerading keeps the pod address towards the nodes (otherwise the source would be `remote-node`, allowed). The NAS and the GUA are audited on `EGRESS` by the baseline. DNS and HTTPS are not audited. Done: as expected.

- [x] **Enforce**, once the observability stack runs (the denied flows in the logs, the alert on the drops). Set `policyAuditMode: false` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`, commit and push. Once the Cilium pods are restarted:

  ```sh
  kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}{"\n"}'
  hubble observe -P --verdict DROPPED -f
  flux get ks -A
  ```

  Then run the test pod above again, with `--verdict DROPPED`, and check the Gateways from the LAN, the internal DNS ([dns/bootstrap.md](../dns/bootstrap.md#1-deploy-and-check)) and a volume attached on another node than its LINSTOR controller. Look in Hubble UI as well. Last, the alert of the drops ([observability](../observability/bootstrap.md#4-alert-rules-and-the-dead-mans-switch)): a flow no policy allows, repeated for 25 minutes, then the pod deleted:

  ```sh
  kubectl -n debug run np-alert-test --image=docker.io/library/busybox --restart=Never --command -- \
    sh -c 'while true; do nc -zv -w 3 vmsingle-victoria-metrics-k8s-stack.observability.svc 8428; sleep 30; done'
  hubble observe -P --verdict DROPPED --from-pod debug/np-alert-test -f
  kubectl -n debug delete pod np-alert-test
  ```

  Expected: `false`. The four connections of the test pod time out, DNS and HTTPS work. No other `DROPPED` flow with `Policy denied`, and every Kustomization stays `Ready`. `NetworkPolicyDroppedFlows` fires within 25 minutes (`for: 20m`), `direction="ingress"`, `namespace="observability"`, its summary from `debug/(a pod without workload)` to `observability/vmsingle-victoria-metrics-k8s-stack`, and notifies on the phone (`warning`); it resolves about 10 minutes after the pod is deleted (the `rate` window). No more `NetworkPolicyAuditedFlows`. Then update the status in the [README](README.md#status) and the [roadmap](../roadmap.md#current-state).

  Done on 2026-11-13: `false`; the only other drops are the Router Solicitations of the pods (`Invalid source ip`, harmless, [README](README.md#network-policies)). The four connections of the test pod time out, DNS and HTTPS work, the NAS flow is `Policy denied` on `EGRESS`. The Gateways, the internal DNS and the LINSTOR volumes work. The alert notifies; its summary then had no name for a pod without workload, since shown as `(a pod without workload)` with the namespaces.

### Pod Security

Not applied yet. The `restricted` profile is the default of the cluster (`talos/patches/security.yaml`) and only the exceptions carry labels ([README](README.md#pod-security)). Pod Security only checks the pods when they are created: the running pods are never evicted, a rejected one only shows up at its next restart.

- [x] **Dry run**, before pushing. The API server checks the running pods against `restricted`, without changing anything:

  ```sh
  kubectl label --dry-run=server --overwrite ns --all pod-security.kubernetes.io/enforce=restricted
  ```

  Expected: warnings only for `piraeus-datastore` (it stays `privileged`) and for the test pods left in `default` or `debug`, if any. Nothing for `kube-system` (exempt). Done: as expected, only `piraeus-datastore`; the audit log of the API server only showed the test pods of the docs, then in `default`.

- [x] **Namespace labels.** Push, then once Flux has reconciled:

  ```sh
  flux get ks -A
  kubectl get ns -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/audit,pod-security.kubernetes.io/warn
  ```

  Expected: every Kustomization is `Ready`. `privileged` on the three modes of `piraeus-datastore` and `debug`. No label on the other namespaces, except `warn: restricted` on `flux-system` (set by flux-operator).

- [x] **Cluster default.** Check the diff, then apply node by node, waiting for the node to be back before the next one:

  ```sh
  just talos diff
  just talos apply-node kube-0X
  talosctl -n kube-0X.shelltopia.net get admissioncontrolconfigs.kubernetes.talos.dev admission-control -o yaml
  ```

  Expected: the diff only changes the `PodSecurity` admission plugin: its `apiVersion` (`v1alpha1` to `v1`) and `enforce` (`baseline` to `restricted`; `audit` and `warn` were already `restricted`, every version stays `latest`). The configuration is applied without a reboot, the API server of the node restarts. The resource lists the `PodSecurity` plugin with these defaults and `kube-system` as the only exempted namespace.

- [x] **Rejection and exception.** A busybox pod runs as root, without a security context:

  ```sh
  kubectl run psa-test --image=docker.io/library/busybox --restart=Never --command -- true
  kubectl -n debug run psa-test --image=docker.io/library/busybox --restart=Never --command -- true
  kubectl -n debug delete pod psa-test
  ```

  Expected: the first one is refused, `violates PodSecurity "restricted:latest"` with the list of the missing settings. The second one is created.

- [x] **No rejected workload**, after the next restarts (node reboots, rollouts, Flux upgrades):

  ```sh
  kubectl get events -A --field-selector reason=FailedCreate
  flux get hr -A
  ```

  Expected: no `FailedCreate` event mentioning `PodSecurity`, every HelmRelease `Ready`. A rejected pod only shows up as such an event on its ReplicaSet, StatefulSet, DaemonSet or Job ([runbook](runbook.md#pod-security)).

- [ ] **Jobs and CronJobs**, after their next run: `volsync-monitor` in `backups`.

  ```sh
  kubectl -n backups get jobs
  ```

  Expected: the last Job `Complete`.

- [ ] **VolSync movers.** Not tested yet: they run in the namespace of the application, at its level. At the first application backed up (or with the [test application](../backups/bootstrap.md#test-application)), check that the backup and the restore movers start ([open point](evaluations.md#open-points)).

  Expected: `just kube volsync-backup <app>` succeeds, no `FailedCreate` event in the namespace. Then update the status in the [README](README.md#status) and the [roadmap](../roadmap.md#current-state).

### Resources and priorities

The class `infrastructure` and the alerts of the convention ([README](README.md#resources-and-priorities)). The sizing of the existing components follows its [plan](../cluster-tools.md#3-sizing).

- [x] **Classes.** Push, then once Flux has reconciled:

  ```sh
  flux -n kube-system get ks priority-classes
  kubectl get priorityclasses
  ```

  Expected: the Kustomization is `Ready`. `infrastructure` at `1000000`, `PreemptLowerPriority`, not the global default, next to `system-node-critical` and `system-cluster-critical`.

- [x] **Rules loaded**, through `vmalert` ([observability](../observability/bootstrap.md#4-alert-rules-and-the-dead-mans-switch)):

  ```sh
  kubectl -n observability get pods -l app.kubernetes.io/name=vmalert -o name
  kubectl -n observability port-forward <pod> 8080
  curl -s localhost:8080/api/v1/rules | jq -r '.data.groups[] | select(.name == "resources") | .rules[] | .name + " " + .labels.severity + " " + .health + " " + .lastError'
  ```

  Expected: `ContainerWithoutMemoryLimit info ok` and `ContainerOOMKilled warning ok`.

- [x] **Series of kube-state-metrics.** A rule on a series that does not exist never fires. Through `VMSingle`:

  ```sh
  kubectl -n observability port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=count by (__name__) ({__name__=~"kube_pod_(init_)?container_(info|resource_limits)|kube_pod_container_status_(last_)?terminated_reason|kube_pod_owner|kube_pod_status_phase"})' | jq -c '.data.result[] | [.metric.__name__, .value[1]]'
  curl -s localhost:8080/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "ContainerWithoutMemoryLimit") | .labels.namespace + "/" + .labels.pod + " " + .labels.container' | sort
  ```

  Expected: the eight series, `kube_pod_init_container_info` and `kube_pod_init_container_resource_limits` included. The two `terminated_reason` only exist for a container that terminated (a Job, a restart): the OOM test below checks them otherwise. The containers without a memory limit: those of the [inventory](../cluster-tools.md#plan), no static pod (`kube-apiserver-*`), no finished pod, nothing in `debug`. `info`: in Grafana only, no notification.

- [x] **OOM kill.** A test pod past its limit of 16 MiB (`tail` keeps reading `/dev/zero`, a file without a newline, in memory):

  ```sh
  kubectl -n debug run oom-test --image=docker.io/library/busybox --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"oom-test","image":"docker.io/library/busybox","command":["tail","/dev/zero"],"resources":{"limits":{"memory":"16Mi"}}}]}}'
  kubectl -n debug get pod oom-test -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{"\n"}'
  curl -s localhost:8080/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "ContainerOOMKilled") | .state + " " + .labels.namespace + "/" + .labels.pod'
  kubectl -n debug delete pod oom-test
  ```

  Expected: `OOMKilled`. The alert `firing` for `debug/oom-test` at the next evaluation (no `for`), notified on the phone (`warning`); it resolves once the pod is deleted.

  Done on 2026-11-13: the four checks as expected.

### Kubelet serving certificates

The approver, then `serverTLSBootstrap` ([README](README.md#kubelet-serving-certificates)).

- [x] **Approver.** Push, then once Flux has reconciled:

  ```sh
  kubectl get namespace cluster-tools --show-labels
  flux -n cluster-tools get hr kubelet-csr-approver
  kubectl -n cluster-tools get pods -l app.kubernetes.io/name=kubelet-csr-approver
  kubectl -n cluster-tools logs deploy/kubelet-csr-approver
  ```

  Expected: the namespace without Pod Security label. The HelmRelease is `Ready`, one pod `Running`, no error in its logs.

- [x] **No CSR denied:**

  ```sh
  kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
  ```

  Expected: none before `serverTLSBootstrap`, then one `Approved,Issued` per node and none `Denied`.

- [x] **Talos config**, with the approver running. The diff, then one node (kube-01, then kube-03 once the checks below pass on kube-01):

  ```sh
  just talos diff
  just talos apply-node kube-01
  ```

  Expected: the diff only adds `serverTLSBootstrap: true` to the `KubeletConfig` of each node. The kubelet restarts, the node does not reboot.

- [x] **Certificate of the node:**

  ```sh
  kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
  kubectl get csr <csr> -o jsonpath='{.status.certificate}' | base64 -d | openssl x509 -noout -issuer -ext subjectAltName -enddate
  kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -subject
  kubectl -n cluster-tools logs deploy/kubelet-csr-approver
  ```

  Expected: a CSR of `system:node:kube-01`, `Approved,Issued` within seconds. Its issuer is the subject of the cluster CA, its names `DNS:kube-01`, the IPv4 address and the ULA address of the node, its end date about a year later. The approver logs the approval.

- [x] **API server to kubelet**, on a pod of the node:

  ```sh
  kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=kube-01 -o name
  kubectl -n kube-system logs <pod> --tail=5
  kubectl -n kube-system exec <pod> -- cilium-dbg version
  ```

  Expected: both work. The API server does not verify the certificate yet ([plan](../cluster-tools.md#commits)).

- [x] **Scrapes and series of the alerts**, through `VMSingle`:

  ```sh
  kubectl -n observability port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=kubelet_certificate_manager_server_ttl_seconds' | jq -c '.data.result[] | [.metric.node, .value[1]]'
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=up{job="kubelet"}' | jq -c '.data.result[] | [.metric.node, .metric.metrics_path, .value[1]]'
  ```

  Expected: one series per node, about a year of seconds: the rule `KubeletServerCertificateExpiration` now has data. Every kubelet target at `1` (still `insecureSkipVerify` at this step, verified with [metrics-server](#metrics-server)).

- [x] **Talos config of the API server**, once both nodes have their certificate. The diff, then one node (kube-01, then kube-03 once the checks below pass on kube-01):

  ```sh
  just talos diff
  just talos apply-node kube-01
  kubectl -n kube-system get pod kube-apiserver-kube-01 -o yaml | grep kubelet-certificate-authority
  ```

  Expected: the diff only adds `kubelet-certificate-authority` to the `extraArgs` of the `KubeAPIServerConfig` of each node, next to its `certExtraSANs`. The API server restarts with the flag, the node does not reboot.

- [x] **API server to kubelet, verified**, through the API server of the node, on a pod of each node:

  ```sh
  kubectl get pods -A -o wide --field-selector spec.nodeName=kube-03
  kubectl --server https://kube-01.shelltopia.net:6443 --tls-server-name kubecluster-01.shelltopia.net -n <namespace> logs <pod> --tail=5
  kubectl --server https://kube-01.shelltopia.net:6443 --tls-server-name kubecluster-01.shelltopia.net -n <namespace> exec <pod> -- <command>
  ```

  Expected: both work, for a pod of kube-01 and a pod of kube-03. `x509: certificate signed by unknown authority` means a kubelet still serves its self-signed certificate (its CSR, above).

  Done on 2026-11-13: the checks as expected, on both nodes, through each API server.

### metrics-server

The release, and the kubelet scrapes of `VMAgent` verified ([README](README.md#metrics-server)). After the [kubelet serving certificates](#kubelet-serving-certificates).

- [x] **Release.** Push, then once Flux has reconciled:

  ```sh
  flux -n cluster-tools get ks metrics-server
  flux -n cluster-tools get hr metrics-server
  kubectl -n cluster-tools get certificate,pods
  kubectl -n cluster-tools logs deploy/metrics-server
  ```

  Expected: both `Ready`. The `Certificate` `metrics-server` `Ready`, one pod `Running`. No `x509` error in its logs: it would mean a kubelet it cannot verify.

- [x] **APIService**, verified by the API server:

  ```sh
  kubectl get apiservice v1beta1.metrics.k8s.io
  kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.spec.insecureSkipTLSVerify} {.spec.caBundle}' | cut -c1-40
  ```

  Expected: `Available` `True`. No `insecureSkipTLSVerify` (empty or `false`), a `caBundle` set by cainjector.

- [x] **`kubectl top`:**

  ```sh
  kubectl top nodes
  kubectl top pods -A --sort-by=memory
  ```

  Expected: both nodes, and the pods of both nodes.

- [x] **Kubelet scrapes verified**, through `VMSingle`, a few minutes after the reconciliation of the stack:

  ```sh
  kubectl -n observability port-forward svc/vmsingle-victoria-metrics-k8s-stack 8428
  curl -s localhost:8428/api/v1/query --data-urlencode 'query=up{job="kubelet"}' | jq -c '.data.result[] | [.metric.node, .metric.metrics_path, .value[1]]'
  ```

  Expected: every target at `1`, for both nodes and the three paths (`/metrics`, `/metrics/cadvisor`, `/metrics/probes`). A target at `0` means a kubelet `VMAgent` cannot verify: the error is on its *Targets* page.

  Done on 2026-11-13: the four checks as expected.

### VPA recommender

The recommender alone, without the updater nor the admission controller ([README](README.md#vpa-recommender)). After [metrics-server](#metrics-server).

- [x] **Release.** Push, then once Flux has reconciled:

  ```sh
  flux -n cluster-tools get ks vertical-pod-autoscaler
  flux -n cluster-tools get hr vertical-pod-autoscaler
  kubectl -n cluster-tools get pods -l app.kubernetes.io/name=vertical-pod-autoscaler
  kubectl get crd verticalpodautoscalers.autoscaling.k8s.io verticalpodautoscalercheckpoints.autoscaling.k8s.io
  kubectl get mutatingwebhookconfigurations
  kubectl -n cluster-tools logs deploy/vpa-recommender | grep -iE 'error|fail'
  ```

  Expected: both `Ready`, one pod `vpa-recommender` `Running`, the two CRDs. No VPA webhook, no updater. No error reading `metrics.k8s.io` in the logs.

- [x] **A recommendation**, for a test Deployment in `debug`:

  ```sh
  kubectl -n debug create deployment vpa-test --image=docker.io/library/busybox -- sleep infinity
  kubectl apply -f - <<'EOF'
  apiVersion: autoscaling.k8s.io/v1
  kind: VerticalPodAutoscaler
  metadata:
    name: vpa-test
    namespace: debug
  spec:
    targetRef:
      apiVersion: apps/v1
      kind: Deployment
      name: vpa-test
    updatePolicy:
      updateMode: "Off"
  EOF
  kubectl -n debug get vpa vpa-test
  kubectl -n debug get vpa vpa-test -o jsonpath='{.status.recommendation}' | jq
  kubectl -n debug get verticalpodautoscalercheckpoints
  ```

  Expected: within a few minutes, `PROVIDED` `True`, and a target at the floor: about `11m` of CPU (the first bucket of the CPU histogram, 10m, plus the margin of 15 %) and `16Mi` (the minimum). The upper bound is huge until about a day of history. Then a checkpoint `vpa-test-busybox`. The pod keeps its requests (none).

- [x] **Cleanup:**

  ```sh
  kubectl -n debug delete vpa vpa-test
  kubectl -n debug delete deployment vpa-test
  kubectl -n debug get verticalpodautoscalercheckpoints
  ```

  Expected: the checkpoint is gone a few minutes later (garbage collected by the recommender every 10 minutes).

  Done on 2026-11-13: the three checks as expected, a target of `11m` and `16Mi` for the test Deployment.

### Goldilocks

A VPA per workload and the dashboard behind the Pocket ID ([README](README.md#goldilocks)). After the [VPA recommender](#vpa-recommender), once the client is in the Pocket ID and its item in 1Password ([prerequisites](../ingress/runbook.md#a-ui-without-a-login-of-its-own)).

- [x] **Release.** Push, then once Flux has reconciled:

  ```sh
  flux -n cluster-tools get ks goldilocks
  flux -n cluster-tools get hr goldilocks
  kubectl -n cluster-tools get pods -l app.kubernetes.io/name=goldilocks
  kubectl -n cluster-tools get pods -l app.kubernetes.io/name=goldilocks -o custom-columns=NAME:.metadata.name,CLASS:.spec.priorityClassName
  ```

  Expected: both `Ready`, the pods `goldilocks-controller` and `goldilocks-dashboard` `Running`, both in the class `infrastructure` (the `postRenderers` patch).

- [x] **A VPA per workload:**

  ```sh
  kubectl get verticalpodautoscalers -A -l source=goldilocks
  kubectl -n cluster-tools logs deploy/goldilocks-controller | grep -iE 'error|fail' | sort | uniq -c
  ```

  Expected: a VPA `goldilocks-<workload>` per Deployment, StatefulSet, DaemonSet and CronJob of every namespace, and `goldilocks-victoria-metrics-k8s-stack` for the `VMAgent`; none for a Job. Mode `Off`, `PROVIDED` `True` within a few minutes, but for a CronJob (`NoPodsMatched` between two runs). A `ConfigUnsupported` means a target below the topmost owner with a `scale` subresource ([README](README.md#goldilocks)). In the logs, only the owners the controller cannot read (the resources of the operators): the workload below is the target.

- [x] **Dashboard:**

  ```sh
  kubectl -n cluster-tools get externalsecret,httproute,securitypolicy
  kubectl -n envoy-gateway-system logs deploy/envoy-gateway | grep -i -E 'error|oidc'
  curl -sI https://goldilocks.shelltopia.org
  ```

  Expected: `SecretSynced`, the route and the policy `Accepted`, no error about the OIDC provider. `302` to `https://id.shelltopia.org/authorize`. In a browser, a member of `kubernetes_admins` sees the namespaces and their recommendations, another user is refused by the Pocket ID.

  Done on 2026-11-13: the three checks as expected, after a second run with `ignore-controller-kind: Job` and the `VMAgent` readable. Only the CronJobs `volsync-monitor` and `hubble-generate-certs` without a recommendation between two runs. In the logs, the resources of VictoriaMetrics, LINSTOR and the Intel GPU plugin, at each event of a pod of their namespace.
