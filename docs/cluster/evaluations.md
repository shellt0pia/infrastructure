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
| Pod Security: `baseline` default, `restricted` labels per namespace (fail-open) | A new namespace, or one whose labels were forgotten, would only get `baseline`. The default is `restricted` instead, the lower levels are explicit exceptions ([README](README.md#pod-security)). |
| Pod Security version pinned (the minor of the cluster) | A bump by hand of the default and of the labels at each minor, while the upgrades are automated (tuppr, Renovate). The profiles follow the cluster (`latest`) instead: a minor that makes them stricter can refuse a pod at its next restart, seen in the `FailedCreate` events ([runbook](runbook.md#upgrading-kubernetes-by-hand)). |
| Pod Security labels on every namespace, `restricted` included | The level would read in each manifest, but it repeats the default everywhere. Only the exceptions carry labels: a namespace without them is `restricted` ([README](README.md#pod-security)). |
| Pod Security without the `kube-system` exemption | Cilium, Spegel and the GPU plugin need privileged pods, so `kube-system` would be `privileged` anyway; the namespace is created by Kubernetes, and labels set by Flux on it would not be there at bootstrap. The Talos exemption is kept. |
| Stop the Router Solicitations of the pods (`accept_ra=0` in their network namespace) | The CNI plugin `tuning` chained to Cilium replaces the CNI configuration of the chart (`cni.customConf`), and needs the plugin on Talos; the sysctls per pod are unsafe ones, to allow on the kubelets and set in every pod. Neither covers the health endpoint, created by Cilium. The drops are harmless: filtered out of the export instead ([README](README.md#network-policies)). |
| A fix of Cilium for the Router Solicitations | [cilium/cilium#47645](https://github.com/cilium/cilium/issues/47645) was closed by the stale bot without a fix. Not taken up: a patch of the datapath, not tested here. |
| CPU limits | CPU is compressible: a limit throttles a container even on an idle node, while the requests already share the CPU under contention ([README](README.md#resources-and-priorities)). |
| A `ValidatingAdmissionPolicy` that requires the resources, in `Warn` and `Audit` | Nobody would see its results: the warnings go to the client that creates the pod (a ReplicaSet, an operator) or the workload (Flux, which does not report them), and the audit events to the audit log of the API server, which nothing collects. An alert on kube-state-metrics instead, which also covers the pods already running ([README](README.md#resources-and-priorities)). In `Deny`, a forgotten limit would block a release. |
| A `LimitRange` per namespace, with default requests and limits | It invents values for what has none, and hides the forgotten ones. |
| A class below the applications (negative, `preemptionPolicy: Never`) | No workload to put there today: the backups and the exporters matter more than the applications. To add if one shows up. |
| A `globalDefault` class for the applications | The default of a pod without class is already 0, below `infrastructure`. |

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
| Drops `UNKNOWN_L3_TARGET_ADDRESS` | Seen at the deployment of new tools and manifests. Not caused by the network policies (no verdict, other reason): Cilium drops them in audit mode already. Probably packets sent to the address of a pod that was just replaced (a client or a backend not updated yet). The audited flows to `world` on addresses of the pod CIDR, from 2026-11-10 to 11-13, are such packets ([observability](../observability/evaluations.md#open-points)): likely the same ones, audited by the policy then dropped by the datapath. An inference to check: a drop and an audited flow at the same time, with the same ends. Otherwise, find what keeps the old address. In VictoriaLogs: `log_source:hubble flow.drop_reason_desc:UNKNOWN_L3_TARGET_ADDRESS`. |
| Drops `FORBIDDEN_ICMPV6_MESSAGE` | From `kube-apiserver`, the identity of the addresses of the control plane nodes: ICMPv6 sent by a node. Not caused by the network policies (no verdict, other reason). Probably the host firewall, which only lets some ICMPv6 types through (an inference to check in the code of Cilium). To understand: the type of the messages (`flow.l4.ICMPv6.type` in VictoriaLogs, `log_source:hubble flow.drop_reason_desc:FORBIDDEN_ICMPV6_MESSAGE`) and their destination, then whether one is needed (neighbor discovery, MLD) or can stay dropped. |
| Talos/Kubernetes version source | `talos/vars.yaml` (+ mise) or tuppr resources. Renovate should bump both in the same PR, or one should reference the other ([roadmap](../roadmap.md#open-decisions)). |
| Renovate in the cluster | Renovate operator or plain CronJob, with a GitHub App or a fine-grained token ([roadmap](../roadmap.md#open-decisions)). |
| Pod Security: VolSync movers | The movers run in the namespace of the application, so at `restricted`. With `moverSecurityContext` (component `kubernetes/components/volsync`) they should comply: check at the first application backed up ([checks](bootstrap.md#pod-security)). |
| User namespaces (`hostUsers: false`) | Root in the container mapped to an unprivileged UID of the node. Stable and enabled (Kubernetes 1.37, kernel 6.18, containerd 2, `user.max_user_namespaces` set in `talos/patches/sysctls.yaml`), and a server dry run shows that Pod Security skips the non-root checks. Not tested with a real pod: start with a LINSTOR volume. Not for NFS volumes (no idmapped mounts) nor `hostNetwork` ([README](README.md#pod-security)). |
