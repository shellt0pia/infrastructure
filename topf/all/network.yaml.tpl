---
# Dynamic addressing on the `lan0` link (alias defined in the node files):
# - IPv4: DHCP, with a static mapping per node in OPNsense;
# - IPv6: SLAAC with EUI-64 addresses (kernel default), giving a stable ULA address and a
#   predictable GUA address (matched by the OPNsense "Dynamic IPv6 Host" aliases).
# DNS servers and search domain come from DHCP/RDNSS.
apiVersion: v1alpha1
kind: LinkConfig
name: lan0
up: true
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: lan0
---
# Wake-on-LAN (EthernetConfig) is set in the node files: it needs the kernel interface name.
# Set explicitly rather than through DHCP option 42, by name so that the address stays dynamic.
# The name is resolved with the DNS servers given by DHCP/RDNSS. NTS is disabled (default when
# servers are set): OPNsense serves plain NTP, it is itself synced with NTS upstream.
apiVersion: v1alpha1
kind: TimeSyncConfig
ntp:
  servers: {{ .Data.network.ntp_servers | toJson }}
