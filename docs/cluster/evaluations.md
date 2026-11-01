# Cluster: evaluations and open points

The choices considered and set aside, and what is still to check or watch. The resulting architecture is in [README.md](README.md).

## Rejected options

| Option | Why not |
| --- | --- |
| Talhelper, Omni, Cluster API, a Terraform provider for Talos | See [nodes](../nodes/evaluations.md#rejected-options). |
| Cilium Gateway API | Envoy Gateway is used instead ([ingress](../ingress/evaluations.md#rejected-options)). |
| Cilium `bpf.masquerade` | Its IPv6 support is beta and always uses the GUA as source ([network](../network/evaluations.md#rejected-options)). |
| A registry cache | Docker Hub credentials in containerd avoid the rate limit. Spegel, which only shares between the nodes the images they already have, is used ([README](README.md#spegel)). |
| Intel DRA driver | See [below](#intel-dra-driver). |
| Reloader watching every workload (`autoReloadAll: true`) | Each certificate renewed by cert-manager would restart the pods that mount it, including those that reload it themselves, and the storage and network components would restart without anyone asking for it. Opt-in per workload instead ([README](README.md#reloader)). |
| Reloader `env-vars` strategy (its default) | Injects an env var in the containers of the workload: `annotations` leaves the containers as Flux and Helm applied them. |
| Kubernetes `NetworkPolicy` | No host firewall (the ports of the nodes stay open to the pods) and no entities (`world`, `remote-node`, `kube-apiserver`). The Cilium policies are used everywhere instead ([README](README.md#network-policies)). |
| Network policies only for the applications that ask for them (fail-open) | A new application, or a chart that adds a component, would be open by default. The clusterwide baseline puts every pod in default deny instead. |
| Exemption of `kube-system`, `piraeus-datastore` and `flux-system` | Their pods are the most privileged of the cluster (`kube-system` and `piraeus-datastore` are not even restricted by the Pod Security profile). The few flows they need from outside of their namespace are listed instead. |
| Rules by port for the pods | Every chart upgrade that changes a port would break a flow. The pod rules select the peers, a pod only exposes what it listens on. Only the host firewall uses ports, fixed by Talos and Kubernetes. |
| No egress filtering, or an allow-list of destinations per application | Without filtering, any pod reaches the NAS and the LAN. An allow-list per application (FQDN policies, DNS proxy of Cilium) is much more work to maintain: the baseline denies the private networks and allows the internet. |

## Intel DRA driver

The Intel device plugin is used through the operator, with `sharedDevNum: 3` (Plex, Immich). DRA is rejected for now: the Intel DRA driver (0.12.x) only allocates whole GPUs and is beta. Switch from the device plugin once it supports shared GPUs (DRAConsumableCapacity).

## Open points

| Topic | Notes |
| --- | --- |
| Intel DRA driver | Switch from the device plugin once it supports shared GPUs (DRAConsumableCapacity), [details](#intel-dra-driver). |
| Spegel and the Talos config | Talos generates `/etc/cri/conf.d/hosts` itself: check that a machine config change (`just talos apply`) or a Talos upgrade does not drop the mirror configuration written by Spegel. If it does, restart the DaemonSet after each change ([checks](bootstrap.md#spegel)). |
| Spegel and the image verification | Talos verifies the signatures of `registry.k8s.io` and `ghcr.io/siderolabs` images (`talos/patches/security.yaml`). The content is addressed by digest, so a mirror should change nothing: check that these images still pull with Spegel ([checks](bootstrap.md#spegel)). |
| Spegel `PreferSameNode` | The registry Service sends containerd to the Spegel of its own node with `trafficDistribution: PreferSameNode`. If Cilium ignores it, the request may go to the Spegel of another node, which still works. |
| Cilium `bpf.masquerade` | Reconsider once its IPv6 support is stable and picks the source address per destination (it would bring eBPF host routing, [network](../network/evaluations.md#open-points)). |

| Network policies: Talos host DNS | CoreDNS forwards to `169.254.116.108`, which Cilium may see as `host` or `world`: both are allowed (host firewall port 53, and the internet in the baseline). Check in the audited flows that nothing about it is denied. |
| Talos/Kubernetes version source | `talos/vars.yaml` (+ mise) or tuppr resources. Renovate should bump both in the same PR, or one should reference the other ([roadmap](../roadmap.md#open-decisions)). |
| Renovate in the cluster | Renovate operator or plain CronJob, with a GitHub App or a fine-grained token ([roadmap](../roadmap.md#open-decisions)). |
