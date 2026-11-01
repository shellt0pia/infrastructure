# Cluster: runbook

Day-to-day operations on the cluster. Architecture: [README.md](README.md).

## The `just kube` recipes

`kubernetes/mod.just` holds the recipes run from the workstation. For now, the restore recipes of the backups (`volsync-snapshots`, `volsync-restic`, `volsync-backup`, `volsync-restore`, [backups](../backups/runbook.md)).

Recipes planned, with ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just):

- `sync <hr|ks|gitrepo|ocirepo|es>`: force the reconciliation of every resource of a kind (`reconcile.fluxcd.io/requestedAt` annotation).
- `debug-node <node>`: `kubectl -n debug debug node/<node> --profile=sysadmin`, removing the debug pod on exit. The only way to get a shell on a Talos node. In the `debug` namespace: the pod is privileged, [Pod Security](README.md#pod-security) refuses it anywhere else.
- `prune-pods`: delete the Failed, Succeeded and Pending pods.
- `browse-pvc` and `view-secret`: need the `browse-pvc` and `view-secret` kubectl plugins.
- `apply-ks` / `delete-ks`: apply a Flux Kustomization from the working copy, with `flate` or `flux build ks`.

## Upgrades

Not automated yet: Talos and Kubernetes are upgraded by hand with `just talos upgrade-node` and `just talos upgrade-k8s`. The plan is tuppr for both, in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`), and Renovate in the cluster for the charts and the images ([roadmap](../roadmap.md#upgrades)). Until tuppr is deployed, keep a console at hand during the Talos upgrades ([TPM unlock failure](../nodes/evaluations.md#open-points)).

Once tuppr is in place, each Talos upgrade makes the API unavailable during the reboot of the node while the cluster only has [two nodes](../nodes/README.md#test-phase-2-nodes).

### Upgrading Talos by hand

The version and the image come from the repository: `talos_version` in `talos/vars.yaml` and `talos/schematic.yaml` (the extensions). The `talosctl` of `mise.toml` follows the same version.

- [ ] **Versions.** Merge the Renovate PR (it updates `talos_version` in `talos/vars.yaml` and `talosctl` in `mise.toml` together), or change both by hand, then `mise install`. Check what differs from the running machine configs:

  ```sh
  just talos diff
  ```

- [ ] **Node by node**, waiting for the node to be back before the next one. The configuration is applied first only when it changed (`just talos diff`):

  ```sh
  just talos apply-node kube-0X
  just talos upgrade-node kube-0X
  talosctl health
  ```

  Expected: the node reboots on the new image and rejoins etcd, `talosctl health` passes. With two nodes, the API is unavailable while one of them reboots. With a Secure Boot or TPM failure at the reboot, see the [open points](../nodes/evaluations.md#open-points).

- [ ] **Storage.** Before the next node, the volumes must be back in sync, otherwise a second node going down would block them:

  ```sh
  kubectl linstor resource list
  ```

  Expected: every replica `UpToDate` ([checking the state](../storage/runbook.md#checking-the-state)).

### Upgrading Kubernetes by hand

- [ ] **Versions.** Merge the Renovate PR (it updates `kubernetes_version` in `talos/vars.yaml` and `kubectl` in `mise.toml` together), or change both by hand, then `mise install`.
- [ ] **Upgrade:**

  ```sh
  just talos upgrade-k8s --dry-run
  just talos upgrade-k8s
  kubectl get nodes
  ```

  Expected: the nodes `Ready` on the new version.

- [ ] **Pod Security**, after a minor upgrade only (1.37 to 1.38, for instance). The profiles follow the version of the API server ([README](README.md#pod-security)): before merging, read in the release notes what the new version changes in the [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/). After the upgrade, check the running pods against the new profiles:

  ```sh
  kubectl label --dry-run=server --overwrite ns --all pod-security.kubernetes.io/enforce=restricted
  ```

  Expected: warnings only for the namespaces below `restricted` (`piraeus-datastore`, `debug`, those of the applications at `baseline`). Run it again on each of these with its own level (`--overwrite ns <namespace> pod-security.kubernetes.io/enforce=baseline`): no warning. A pod listed otherwise would be refused at its next restart: [fix it](#pod-security) before.

## Diagnosing Flux

Start from what is not `Ready`:

- [ ] **List what fails:**

  ```sh
  flux get ks -A --status-selector ready=false
  flux get hr -A --status-selector ready=false
  flux get sources all -A --status-selector ready=false
  ```

  A Kustomization waiting for its `dependsOn` is not an error of its own: look for the first one that fails.

- [ ] **Read the reason:**

  ```sh
  kubectl -n <namespace> describe kustomization <name>
  kubectl -n <namespace> describe helmrelease <name>
  flux logs --level=error -A
  ```

- [ ] **Reconcile it**, after the cause is fixed and pushed:

  ```sh
  flux reconcile ks <name> --with-source
  flux reconcile hr <name> -n <namespace> --force
  ```

  Expected: `Ready`. A Kustomization or a HelmRelease that someone suspended stays so until `flux resume ks <name>` (or `hr`): `flux get ks -A` shows the `SUSPENDED` column.

If every Kustomization fails with `kustomization path not found`, Flux follows the wrong branch: [see below](#recovering-flux-on-the-wrong-branch).

## Network policies

How they work: [README](README.md#network-policies). A flow denied by a policy times out (the packets are dropped, never refused): a connection that hangs between two pods, or from a pod to a node, starts here.

- [ ] **Find the drop.** `-P` forwards the port of Hubble Relay; add `-f` to follow:

  ```sh
  hubble observe -P --verdict DROPPED --namespace <namespace> --last 100
  hubble observe -P --verdict DROPPED --pod <namespace>/<pod> --last 100
  ```

  A line gives the source and destination (pod, or identity such as `world`, `host`, `remote-node`), the port, and `Policy denied` with its direction (`INGRESS` on the side of the server, `EGRESS` on the side of the client). In audit mode, the same flows have the verdict `AUDIT`.

  Hubble only keeps the last 4095 flows of each node in memory. For an older drop, read the export of each node (the logs, once the observability stack runs):

  ```sh
  for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    kubectl -n kube-system exec "$pod" -c cilium-agent -- sh -c 'cat /var/run/cilium/hubble/events*.log'
  done | hubble observe --input-file - --namespace <namespace>
  ```

- [ ] **Allow it**, in Git, at the narrowest place:

  | Flow | Where |
  | --- | --- |
  | Between two pods of the same namespace | Already allowed: check that the namespace includes the `network-policies` component. |
  | To a pod, from another namespace, a node or outside of the cluster | `ciliumnetworkpolicy.yaml` next to the application that receives it, `ingress` ([conventions](../conventions.md#network-policies)). |
  | From a pod to a private address outside of the cluster (NAS, OPNsense, a LAN device) | `ciliumnetworkpolicy.yaml` next to the application that sends it, `egress` with `toCIDR` (the only case with addresses). |
  | From a pod to a port of the nodes (Talos API, kubelet, metrics) | A rule in `kubernetes/apps/kube-system/cilium/policies/host.yaml`, from the pods that need it (`fromEndpoints`) to that port only, and the port in [reference](../reference.md#ports). |
  | From a new Gateway, or to every pod (a scraper) | `kubernetes/apps/kube-system/cilium/policies/baseline.yaml`. |

  Then check with `hubble observe` that the flow is `FORWARDED`.

- [ ] **Return to audit mode**, to roll out a change of the policies or when many flows break at once: set `policyAuditMode: true` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`, commit and push. The Cilium pods restart (a few seconds without new connections on each node, one node at a time). Set it back to `false` once the `AUDIT` flows are understood.
- [ ] **Break-glass**, if the policies block Flux itself (it cannot apply a fix): suspend their Kustomization and delete the baseline, which opens every pod again (the host firewall stays):

  ```sh
  flux -n kube-system suspend ks cilium-policies
  kubectl delete ciliumclusterwidenetworkpolicy baseline
  ```

  Once the fix is pushed, `flux -n kube-system resume ks cilium-policies` recreates it.

## Pod Security

How it works: [README](README.md#pod-security). A refused pod never exists: `kubectl get pods` shows nothing, the workload stays without ready replica and its HelmRelease or Kustomization fails at the end of its timeout.

- [ ] **Find the refusal:**

  ```sh
  kubectl get events -A --field-selector reason=FailedCreate
  kubectl -n <namespace> describe rs <name>    # or sts, ds, job
  ```

  The message `violates PodSecurity "restricted:latest"` lists every missing setting (`allowPrivilegeEscalation != false`, `unrestricted capabilities`, `runAsNonRoot != true`, `seccompProfile`, `restricted volume types`...).

- [ ] **Check a manifest before pushing.** The `warn` mode also checks the pod templates of the workloads: a server dry run returns the same list, without creating anything:

  ```sh
  kubectl -n <namespace> apply --dry-run=server -f <manifest>
  helm template <release> <chart> -n <namespace> -f <values> | kubectl -n <namespace> apply --dry-run=server -f -
  ```

- [ ] **Fix it**, in this order:

  1. The security context, in the manifest or the values of the chart (most charts have `podSecurityContext` and `securityContext`): [conventions](../conventions.md#pod-security).
  2. Another image of the application, that runs as non-root.
  3. `hostUsers: false`, if the application only needs root inside its container, without NFS volume ([README](README.md#pod-security)).
  4. Otherwise, a namespace at a lower level, `baseline` before `privileged`: the `enforce`, `audit` and `warn` labels in its `namespace.yaml`, with a comment naming the pods and the reason ([conventions](../conventions.md#namespaces)). Applications at the same level can share it.

  The controller retries the creation of the pods by itself, with a growing delay; `kubectl -n <namespace> rollout restart` makes it immediate.

- [ ] **Debugging a pod.** The ephemeral containers of `kubectl debug` are checked like the others: in a `restricted` namespace, use `--profile=restricted`, with an image that runs as non-root (or a `runAsUser` given with `--custom`). The test pods (`kubectl run`) go in the `debug` namespace, and are deleted after use.

## Recovering Flux on the wrong branch

If the `sync.ref` of the `flux-instance` HelmRelease pushed to GitHub is not the branch Flux must follow, every Kustomization fails with `kustomization path not found` ([why](bootstrap.md#1-git-repository)).

1. **Patch the HelmRelease in the cluster.** Set `spec.values.instance.sync.ref` of the `flux-instance` HelmRelease to the right branch (`refs/heads/main`, for instance):

   ```sh
   kubectl -n flux-system patch hr flux-instance --type merge -p '{"spec":{"values":{"instance":{"sync":{"ref":"refs/heads/main"}}}}}'
   ```

2. **Reconcile it:**

   ```sh
   flux -n flux-system reconcile hr flux-instance --force
   ```

   Expected: the `GitRepository` follows the right branch and the Kustomizations become `Ready` again (`flux get ks -A`).

3. **Fix Git.** Commit and push the right `sync.ref` in `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`, otherwise Flux reapplies the wrong one.
