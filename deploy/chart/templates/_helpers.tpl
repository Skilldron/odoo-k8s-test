{{/* Names */}}
{{- define "odoo.shortDigest" -}}
{{ trimPrefix "sha256:" .Values.image.digest | trunc 12 }}
{{- end }}

{{- define "odoo.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{- define "odoo.review" -}}
{{- if eq .Values.environment "review" }}true{{ end }}
{{- end }}

{{/* Review volumes carry the digest (reset on a new image), the others the generation */}}
{{- define "odoo.dataClaim" -}}
{{- if include "odoo.review" . -}}
{{ .Release.Name }}-odoo-data-{{ include "odoo.shortDigest" . }}
{{- else -}}
{{ .Release.Name }}-odoo-data-{{ .Values.generation }}
{{- end }}
{{- end }}

{{- define "odoo.pgdataClaim" -}}
{{ .Release.Name }}-pgdata-{{ include "odoo.shortDigest" . }}
{{- end }}

{{- define "odoo.generatedSecret" -}}
{{ .Release.Name }}-secrets
{{- end }}

{{- define "odoo.appSecret" -}}
{{ .Values.secrets.existingSecret | default (include "odoo.generatedSecret" .) }}
{{- end }}

{{- define "odoo.workers" -}}
{{ index .Values.odoo.config "options" | default dict | dig "workers" 0 | int }}
{{- end }}

{{- define "odoo.host" -}}
{{- if include "odoo.review" . -}}
{{ .Values.project }}-{{ .Release.Name }}.{{ .Values.route.reviewDomain }}
{{- else -}}
{{ .Values.route.host }}
{{- end }}
{{- end }}

{{- define "odoo.mailpitHost" -}}
{{- if include "odoo.review" . -}}
{{ .Values.project }}-{{ .Release.Name }}-mail.{{ .Values.route.reviewDomain }}
{{- else -}}
{{ .Values.route.mailpitHost }}
{{- end }}
{{- end }}

{{/* Labels */}}
{{- define "odoo.selectorLabels" -}}
app.kubernetes.io/name: odoo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "odoo.labels" -}}
{{ include "odoo.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
odoo.dev/environment: {{ .Values.environment }}
{{- end }}

{{/* odoo.conf values: lists joined by commas, booleans as True/False, whole numbers as integers */}}
{{- define "odoo.iniScalar" -}}
{{- if kindIs "bool" . -}}
{{ ternary "True" "False" . }}
{{- else if kindIs "float64" . -}}
{{- if eq (float64 (int64 .)) . }}{{ int64 . }}{{ else }}{{ . }}{{ end }}
{{- else -}}
{{ . }}
{{- end }}
{{- end }}

{{- define "odoo.iniValue" -}}
{{- if kindIs "slice" . -}}
{{- $items := list -}}
{{- range . }}{{ $items = append $items (include "odoo.iniScalar" .) }}{{ end -}}
{{ join "," $items }}
{{- else -}}
{{ include "odoo.iniScalar" . }}
{{- end }}
{{- end }}

{{/* odoo.conf (§6.1): [options] first (imposed options, then the values), then the
other sections in alphabetical order */}}
{{- define "odoo.conf" -}}
[options]
addons_path = /opt/odoo/addons,/opt/odoo/vendor
data_dir = /var/lib/odoo
http_interface = 0.0.0.0
{{- if .Values.mailpit.enabled }}
smtp_server = localhost
smtp_port = 1025
{{- end }}
{{- $options := index .Values.odoo.config "options" | default dict }}
{{- range $name := keys $options | sortAlpha }}
{{- $value := index $options $name }}
{{- if not (kindIs "invalid" $value) }}
{{ $name }} = {{ include "odoo.iniValue" $value }}
{{- end }}
{{- end }}
{{- range $section := keys .Values.odoo.config | sortAlpha }}
{{- if ne $section "options" }}
{{- $opts := index $.Values.odoo.config $section | default dict }}

[{{ $section }}]
{{- range $name := keys $opts | sortAlpha }}
{{- $value := index $opts $name }}
{{- if not (kindIs "invalid" $value) }}
{{ $name }} = {{ include "odoo.iniValue" $value }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Guards (§6.3), evaluated by the ConfigMap, which every render contains */}}
{{- define "odoo.validate" -}}
{{- $v := .Values -}}
{{- if not (has $v.environment (list "review" "recette" "production")) -}}
{{- fail "environment must be review, recette or production" -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $v.image.digest) -}}
{{- fail "image.digest must be sha256:<64 hex>" -}}
{{- end -}}
{{- if and (eq $v.database.type "ephemeral") (ne $v.environment "review") -}}
{{- fail "database.type=ephemeral is reserved to environment=review" -}}
{{- end -}}
{{- if and (eq $v.environment "review") (ne $v.database.type "ephemeral") -}}
{{- fail "environment=review requires database.type=ephemeral" -}}
{{- end -}}
{{- if and (ne $v.environment "review") (not $v.secrets.existingSecret) -}}
{{- fail "secrets.existingSecret is required outside review" -}}
{{- end -}}
{{- if and (eq $v.environment "review") $v.restore.filestore -}}
{{- fail "restore is not available in review" -}}
{{- end -}}
{{- if not (has $v.database.type (list "ephemeral" "external")) -}}
{{- fail "database.type must be ephemeral or external" -}}
{{- end -}}
{{- if and (eq $v.database.type "external") (not $v.database.external.secret) -}}
{{- fail "database.external.secret is required with database.type=external" -}}
{{- end -}}
{{- if $v.route.parentRefs -}}
{{- if and (eq $v.environment "review") (not $v.route.reviewDomain) -}}
{{- fail "route.reviewDomain is required for a review with route.parentRefs" -}}
{{- end -}}
{{- if and (ne $v.environment "review") (not $v.route.host) -}}
{{- fail "route.host is required with route.parentRefs" -}}
{{- end -}}
{{- end -}}
{{- $envNames := list -}}
{{- range $v.secrets.env }}{{ $envNames = append $envNames .name }}{{ end -}}
{{- range $section, $opts := $v.odoo.config -}}
{{- if not (regexMatch "^[a-z0-9_.]+$" $section) -}}
{{- fail (printf "odoo.config: invalid section name %q" $section) -}}
{{- end -}}
{{- range $name, $_ := $opts -}}
{{- if not (regexMatch "^[a-z0-9_.]+$" $name) -}}
{{- fail (printf "odoo.config.%s: invalid option name %q" $section $name) -}}
{{- end -}}
{{- if regexMatch "passw|secret|token" $name -}}
{{- fail (printf "odoo.config.%s.%s: secrets go in secrets.env, not in odoo.conf" $section $name) -}}
{{- end -}}
{{- if and (eq $section "options") (has $name (list "addons_path" "data_dir" "http_interface")) -}}
{{- fail (printf "odoo.config.options.%s is set by the chart" $name) -}}
{{- end -}}
{{- if and (eq $section "options") $v.mailpit.enabled (has $name (list "smtp_server" "smtp_port")) -}}
{{- fail (printf "odoo.config.options.%s is set by the chart when Mailpit is enabled" $name) -}}
{{- end -}}
{{- $envName := ternary (printf "ODOO_%s" ($name | upper)) (printf "ODOO_%s_%s" ($section | upper) ($name | upper)) (eq $section "options") -}}
{{- if has $envName $envNames -}}
{{- fail (printf "odoo.config.%s.%s is also set by secrets.env (%s)" $section $name $envName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Pod and container hardening (PSA restricted) */}}
{{- define "odoo.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
fsGroup: 1000
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "odoo.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/* Environment of Odoo and of the Jobs: secrets read natively by Odoo 20 (§6.1) */}}
{{- define "odoo.env" -}}
- name: ODOO_RC
  value: /etc/odoo/odoo.conf
{{- if eq .Values.database.type "ephemeral" }}
- name: PGHOST
  value: {{ .Release.Name }}-postgres
- name: PGPORT
  value: "5432"
- name: PGUSER
  value: odoo
- name: PGPASSWORD
  valueFrom:
    secretKeyRef: {name: {{ include "odoo.generatedSecret" . }}, key: pg-password}
- name: PGDATABASE
  value: {{ .Values.database.name | quote }}
{{- else }}
{{- $secret := .Values.database.external.secret }}
{{- range $env, $key := dict "PGHOST" "host" "PGPORT" "port" "PGUSER" "username" "PGPASSWORD" "password" "PGDATABASE" "dbname" }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef: {name: {{ $secret }}, key: {{ $key }}}
{{- end }}
{{- end }}
- name: ODOO_ADMIN_PASSWD
  valueFrom:
    secretKeyRef: {name: {{ include "odoo.appSecret" . }}, key: admin-passwd}
{{- if .Values.secrets.existingSecret }}
- name: ODOO_SMTP_PASSWORD
  valueFrom:
    secretKeyRef: {name: {{ .Values.secrets.existingSecret }}, key: smtp-password, optional: true}
{{- end }}
{{- range .Values.secrets.env }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef: {name: {{ .secret }}, key: {{ .key }}}
{{- end }}
{{- end }}

{{- define "odoo.volumeMounts" -}}
- {name: config, mountPath: /etc/odoo, readOnly: true}
- {name: data, mountPath: /var/lib/odoo}
- {name: tmp, mountPath: /tmp}
{{- end }}

{{- define "odoo.volumes" -}}
- name: config
  configMap: {name: {{ .Release.Name }}-config}
- name: data
  persistentVolumeClaim: {claimName: {{ include "odoo.dataClaim" . }}}
- name: tmp
  emptyDir: {}
{{- end }}

{{- define "odoo.podCommon" -}}
serviceAccountName: {{ .Release.Name }}
automountServiceAccountToken: false
securityContext:
  {{- include "odoo.podSecurityContext" . | nindent 2 }}
{{- with .Values.image.pullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end }}
