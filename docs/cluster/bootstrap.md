# Cluster: first deployment

The Git repository, the checks before the bootstrap, `just bootstrap cluster` and the checks of the cluster and of the network policies. Architecture: [README.md](README.md). The order of the whole bootstrap is in [first-bootstrap.md](../first-bootstrap.md).

Create every prerequisite of a step before starting it, then follow the steps in order. The statuses and checkboxes track `kube-cluster01`.

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

- [x] **Render node.** A non-root pod requesting the GPU sees the render node, owned by its user (`device_ownership_from_security_context` in `talos/patches/containerd.yaml.j2`):

  ```sh
  kubectl apply -f - <<'EOF'
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
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gputest
  kubectl get pod gputest -o wide    # scheduled on kube-01
  kubectl logs gputest               # renderD128 (and card0) owned by 1000:1000
  kubectl delete pod gputest
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
  kubectl create configmap reloader-test --from-literal=VALUE=1
  kubectl apply -f - <<'EOF'
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
  kubectl rollout status deploy/reloader-test
  kubectl create configmap reloader-test --from-literal=VALUE=2 --dry-run=client -o yaml | kubectl apply -f -
  sleep 10
  kubectl rollout status deploy/reloader-test
  kubectl logs deploy/reloader-test
  kubectl get deploy reloader-test -o jsonpath='{.spec.template.metadata.annotations}'
  kubectl -n kube-system logs deploy/reloader | grep reloader-test
  kubectl delete deploy/reloader-test configmap/reloader-test
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
    kubectl run spegel-test-$node --image=docker.io/library/alpine:3.22 --restart=Never \
      --overrides='{"spec":{"nodeName":"'$node'"}}' --command -- true
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/spegel-test-$node
  done
  kubectl get events --field-selector involvedObject.name=spegel-test-kube-03 | grep Pulled
  kubectl -n kube-system port-forward "$(kubectl -n kube-system get pods -l app.kubernetes.io/name=spegel --field-selector spec.nodeName=kube-03 -o name)" 9090
  ```

  Then open `http://localhost:9090/debug/web`, and delete the pods:

  ```sh
  kubectl delete pod spegel-test-kube-01 spegel-test-kube-03
  ```

  Expected: on the debug page of the Spegel of kube-03, `Last Mirror Success` shows a duration (not `Pending`). The pull on kube-03 is much shorter than the one on kube-01 in the `Pulled` events.

- [x] **Verified images.** An image checked by the `ImageVerificationConfig` of Talos (`talos/patches/security.yaml`) still pulls through Spegel. kube-proxy is disabled, its image (at the Kubernetes version of `talos/vars.yaml`) is on no node:

  ```sh
  for node in kube-01 kube-03; do
    kubectl run spegel-verify-$node --image=registry.k8s.io/kube-proxy:v1.37.1 --restart=Never \
      --overrides='{"spec":{"nodeName":"'$node'"}}' --command -- kube-proxy --version
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/spegel-verify-$node
  done
  kubectl logs spegel-verify-kube-03
  kubectl delete pod spegel-verify-kube-01 spegel-verify-kube-03
  ```

  Expected: both pods succeed and print the version, `Last Mirror Success` of kube-03 is updated. A verification failure shows up as `ErrImagePull` in the events of the pod.

- [ ] **Mirror kept after a Talos change.** After the next `just talos apply-node` that changes the machine config of a node, and after the next Talos upgrade, read `_default/hosts.toml` again as above ([open point](evaluations.md#open-points)).

  Expected: the `http://<IPv4 of the node>:30020` host is still there. If not, restart the DaemonSet (`kubectl -n kube-system rollout restart ds/spegel`) and record it in the [runbook](runbook.md).

### Network policies

Not tested yet. The policies are first deployed in audit mode (`policyAuditMode: true` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`): the denied flows are reported, nothing is dropped. Enforce them once the flows are understood ([README](README.md#network-policies)).

- [ ] **Deployment:**

  ```sh
  flux -n kube-system get ks cilium-policies
  kubectl get ciliumclusterwidenetworkpolicies
  kubectl get ciliumnetworkpolicies -A
  kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-host-firewall} {.data.policy-audit-mode}{"\n"}'
  kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i firewall
  kubectl -n flux-system get networkpolicies
  ```

  Expected: the Kustomization is `Ready`. The clusterwide policies `host`, `baseline` and `coredns`; `same-namespace` in each namespace of `kubernetes/apps`, plus `envoy-proxies`, `k8s-gateway`, `spegel` and `linstor-controller`. `true true`, and the host firewall `Enabled` on the devices of the node. No NetworkPolicy left in `flux-system`.

- [ ] **Hubble Relay:**

  ```sh
  kubectl -n kube-system get pods -l k8s-app=hubble-relay
  kubectl -n kube-system get cronjob hubble-generate-certs
  hubble status -P
  ```

  Expected: the Relay pod is `Running`, the CronJob exists. `hubble status` reports every node as connected (`-P` forwards the port of the Relay through the Kubernetes API).

- [ ] **Audited flows.** Over a few days, so that the nightly backups, a Flux reconciliation of each Kustomization and a certificate renewal check run at least once:

  ```sh
  hubble observe -P --verdict AUDIT --last 1000
  hubble observe -P --verdict AUDIT -f
  ```

  Expected: none, except the tests below. Each other flow is either needed (add an exception, [runbook](runbook.md#network-policies)) or must be denied (note why).

- [ ] **Denied flows.** From a test pod on kube-01, towards the ports of another node (kubelet over IPv4, Talos API over ULA), the GUA of another node, and a private address outside of the cluster (the NAS):

  ```sh
  kubectl run np-test --image=docker.io/library/busybox --restart=Never \
    --overrides='{"spec":{"nodeName":"kube-01"}}' --command -- sleep 600
  kubectl wait --for=condition=Ready pod/np-test
  kubectl exec np-test -- nc -zv -w 3 192.168.15.13 10250
  kubectl exec np-test -- nc -zv -w 3 <ULA of kube-03> 50000
  kubectl exec np-test -- nc -zv -w 3 <GUA of kube-03> 50000
  kubectl exec np-test -- nc -zv -w 3 <IPv4 of the NAS> 443
  kubectl exec np-test -- nslookup github.com
  kubectl exec np-test -- wget -q --spider https://github.com
  hubble observe -P --verdict AUDIT --pod default/np-test
  kubectl delete pod np-test
  ```

  Expected: the connections still succeed (audit mode), and each of the four first ones shows up as `AUDIT`, with `default/np-test` as source. For the two node addresses, this confirms that the masquerading keeps the pod address towards the nodes (inferred, not verified: Cilium excludes the node addresses from it), otherwise the source would be `remote-node` and the host firewall would allow it. DNS and HTTPS are not audited.

- [ ] **Enforce.** Set `policyAuditMode: false` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`, commit and push. Once the Cilium pods are restarted:

  ```sh
  kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}{"\n"}'
  hubble observe -P --verdict DROPPED -f
  flux get ks -A
  ```

  Then run the test pod above again, and check the Gateways from the LAN, the internal DNS ([dns/bootstrap.md](../dns/bootstrap.md#1-deploy-and-check)) and a volume attached on another node than its LINSTOR controller.

  Expected: `false`. The four connections of the test pod time out, DNS and HTTPS work. No other `DROPPED` flow with `Policy denied`, and every Kustomization stays `Ready`. Then update the status in the [README](README.md#status) and the [roadmap](../roadmap.md#security).
