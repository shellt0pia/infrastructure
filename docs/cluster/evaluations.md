# Cluster: evaluations and open points

The choices considered and set aside, and what is still to check or watch. The resulting architecture is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| Talhelper, Omni, Cluster API, a Terraform provider for Talos | See [nodes](../nodes/evaluations.md#rejected-options). |
| Cilium Gateway API | Envoy Gateway is used instead ([ingress](../ingress/evaluations.md#rejected-options)). |
| Cilium `bpf.masquerade` | Its IPv6 support is beta and always uses the GUA as source ([network](../network/evaluations.md#rejected-options)). |
| A registry cache | Docker Hub credentials in containerd avoid the rate limit. |
| Intel DRA driver | See [below](#intel-dra-driver). |
| Reloader watching every workload (`autoReloadAll: true`) | Each certificate renewed by cert-manager would restart the pods that mount it, including those that reload it themselves, and the storage and network components would restart without anyone asking for it. Opt-in per workload instead ([README](README.md#reloader)). |
| Reloader `env-vars` strategy (its default) | Injects an env var in the containers of the workload: `annotations` leaves the containers as Flux and Helm applied them. |

## Intel DRA driver

The Intel device plugin is used through the operator, with `sharedDevNum: 3` (Plex, Immich). DRA is rejected for now: the Intel DRA driver (0.12.x) only allocates whole GPUs and is beta. Switch from the device plugin once it supports shared GPUs (DRAConsumableCapacity).

## Open points

| Topic | Notes |
| --- | --- |
| Intel DRA driver | Switch from the device plugin once it supports shared GPUs (DRAConsumableCapacity), [details](#intel-dra-driver). |
| Cilium `bpf.masquerade` | Reconsider once its IPv6 support is stable and picks the source address per destination (it would bring eBPF host routing, [network](../network/evaluations.md#open-points)). |
| Talos/Kubernetes version source | `talos/vars.yaml` (+ mise) or tuppr resources. Renovate should bump both in the same PR, or one should reference the other ([roadmap](../roadmap.md#open-decisions)). |
| Renovate in the cluster | Renovate operator or plain CronJob, with a GitHub App or a fine-grained token ([roadmap](../roadmap.md#open-decisions)). |
