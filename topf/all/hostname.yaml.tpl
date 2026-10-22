---
# The FQDN (`host` in topf.yaml) sets the hostname and the domain name: the Talos API
# certificate then includes the FQDN used to reach the node. The Kubernetes node name and the
# etcd member name are the short hostname (Talos default, `machine.kubelet.registerWithFQDN: false`).
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
