---
# NUT client: shut the node down when the NAS (NUT server) reports the UPS battery as low.
# Talos only supports `/sbin/poweroff` as shutdown command.
# The credentials are embedded in a text block, which topf cannot resolve with vals (it only
# runs vals on non-template files with a value starting with a reference). They are read from
# 1Password by mod.just and passed in the environment of topf, see README.md. They are not
# masked in the diffs.
{{- if not (and (env "NUT_USERNAME") (env "NUT_PASSWORD")) }}
{{- fail "NUT_USERNAME and NUT_PASSWORD are not set, run topf with `just topf run`" }}
{{- end }}
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: nut-client
configFiles:
  - mountPath: /usr/local/etc/nut/upsmon.conf
    content: |
      MONITOR {{ .Data.ups.name }}@{{ .Data.ups.server }} 1 {{ env "NUT_USERNAME" }} {{ env "NUT_PASSWORD" }} secondary
      MINSUPPLIES 1
      SHUTDOWNCMD "/sbin/poweroff"
      POLLFREQ 5
      POLLFREQALERT 5
      HOSTSYNC 15
      DEADTIME 15
      FINALDELAY 0
