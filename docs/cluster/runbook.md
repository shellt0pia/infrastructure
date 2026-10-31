# Cluster: runbook

Day-to-day operations on the cluster. Architecture: [README.md](README.md).

## The `just kube` recipes

`kubernetes/mod.just` holds the recipes run from the workstation. For now, the restore recipes of the backups (`volsync-snapshots`, `volsync-restic`, `volsync-backup`, `volsync-restore`, [backups](../backups/runbook.md)).

Recipes planned, with ideas taken from [onedr0p/home-ops](https://github.com/onedr0p/home-ops/blob/main/kubernetes/mod.just):

- `sync <hr|ks|gitrepo|ocirepo|es>`: force the reconciliation of every resource of a kind (`reconcile.fluxcd.io/requestedAt` annotation).
- `debug-node <node>`: `kubectl debug node --profile=sysadmin`, removing the debug pod on exit. The only way to get a shell on a Talos node.
- `prune-pods`: delete the Failed, Succeeded and Pending pods.
- `browse-pvc` and `view-secret`: need the `browse-pvc` and `view-secret` kubectl plugins.
- `apply-ks` / `delete-ks`: apply a Flux Kustomization from the working copy, with `flate` or `flux build ks`.

## Upgrades

Not automated yet: Talos and Kubernetes are upgraded by hand with `just talos upgrade-node` and `just talos upgrade-k8s`. The plan is tuppr for both, in `system-upgrade` (Talos API access already allowed for this namespace, role `os:admin`), and Renovate in the cluster for the charts and the images ([roadmap](../roadmap.md#7-upgrades)). Until tuppr is deployed, keep a console at hand during the Talos upgrades ([TPM unlock failure](../nodes/evaluations.md#open-points)).

Once tuppr is in place, each Talos upgrade makes the API unavailable during the reboot of the node while the cluster only has [two nodes](../nodes/README.md#test-phase-2-nodes).

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
