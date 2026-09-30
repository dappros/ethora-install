{{/* Names */}}
{{- define "ethora.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ethora.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Component name: <fullname>-<component> */}}
{{- define "ethora.cname" -}}
{{- printf "%s-%s" (include "ethora.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ethora.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "ethora.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ethora.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ethora.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Image: repository:tag, the tag defaulting to the appVersion */}}
{{- define "ethora.image" -}}
{{- $img := index .root.Values.images .name -}}
{{- printf "%s:%s" $img.repository (default .root.Chart.AppVersion $img.tag) -}}
{{- end -}}

{{- define "ethora.secretName" -}}
{{- default (printf "%s-secrets" (include "ethora.fullname" .)) .Values.secrets.existingSecret -}}
{{- end -}}

{{/* Required settings */}}
{{- define "ethora.validate" -}}
{{- if not .Values.admin.email -}}
{{- fail "admin.email is required" -}}
{{- end -}}
{{- if and (not .Values.rootDomain) (not .Values.publicUrl) -}}
{{- fail "set rootDomain (four hosts) or publicUrl (one origin)" -}}
{{- end -}}
{{- if and .Values.rootDomain .Values.publicUrl -}}
{{- fail "set rootDomain or publicUrl, not both" -}}
{{- end -}}
{{- if and (not .Values.mongo.enabled) (not .Values.external.mongo.uri) -}}
{{- fail "mongo.enabled is false: set external.mongo.uri" -}}
{{- end -}}
{{- if and (not .Values.mysql.enabled) (not .Values.external.mysql.host) -}}
{{- fail "mysql.enabled is false: set external.mysql.host" -}}
{{- end -}}
{{- if and (not .Values.redis.enabled) (not .Values.external.redis.host) -}}
{{- fail "redis.enabled is false: set external.redis.host" -}}
{{- end -}}
{{- if and (not .Values.minio.enabled) (not .Values.external.minio.host) -}}
{{- fail "minio.enabled is false: set external.minio.host" -}}
{{- end -}}
{{- end -}}

{{/* Public hosts: a dict of api, web, xmpp, files */}}
{{- define "ethora.hosts" -}}
{{- if .Values.publicUrl -}}
{{- $h := (urlParse .Values.publicUrl).host | splitList ":" | first -}}
{{- dict "api" $h "web" $h "xmpp" $h "files" $h | toYaml -}}
{{- else -}}
{{- $r := .Values.rootDomain -}}
{{- dict "api" (default (printf "api.%s" $r) .Values.hosts.api) "web" (default (printf "app.%s" $r) .Values.hosts.web) "xmpp" (default (printf "xmpp.%s" $r) .Values.hosts.xmpp) "files" (default (printf "files.%s" $r) .Values.hosts.files) | toYaml -}}
{{- end -}}
{{- end -}}

{{/*
The config-render init container: ethora-compose-init writes every service's
configuration and the start scripts into the pod's `config` emptyDir, from
the settings ConfigMap and the secrets. Deterministic, so each pod renders
the same files.
*/}}
{{- define "ethora.renderInit" -}}
- name: config
  image: {{ include "ethora.image" (dict "root" .root "name" "composeInit") }}
  imagePullPolicy: {{ .root.Values.imagePullPolicy }}
  securityContext:
    runAsUser: 0
  envFrom:
    - configMapRef:
        name: {{ include "ethora.cname" (dict "root" .root "component" "settings") }}
    - secretRef:
        name: {{ include "ethora.secretName" .root }}
  env:
    - name: CONFIG_OUT_DIR
      value: /out/config
    - name: MYSQL_INITDB_DIR
      value: /out/mysql-initdb
    # Every secret comes from the Secret; nothing needs to be stored.
    - name: SECRETS_DIR
      value: /tmp/secrets
  volumeMounts:
    - name: config
      mountPath: /out/config
    {{- if .initdb }}
    - name: mysql-initdb
      mountPath: /out/mysql-initdb
    {{- end }}
  resources:
    requests: { cpu: 10m, memory: 16Mi }
{{- end -}}

{{- define "ethora.configVolume" -}}
- name: config
  emptyDir: {}
{{- end -}}

{{- define "ethora.configMount" -}}
- name: config
  mountPath: /ethora/config
  readOnly: true
{{- end -}}

{{- define "ethora.podCommon" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Wait until a TCP port answers (BusyBox nc in the compose-init image). */}}
{{- define "ethora.waitFor" -}}
- name: wait-{{ .name }}
  image: {{ include "ethora.image" (dict "root" .root "name" "composeInit") }}
  imagePullPolicy: {{ .root.Values.imagePullPolicy }}
  command: ["/bin/sh", "-c", "until nc -z -w 3 {{ .host }} {{ .port }}; do echo waiting for {{ .host }}:{{ .port }}; sleep 3; done"]
  resources:
    requests: { cpu: 5m, memory: 8Mi }
{{- end -}}
