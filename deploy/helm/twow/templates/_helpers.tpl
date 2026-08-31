{{- define "twow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "twow.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "twow.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "twow.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "twow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "twow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "twow.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Credentials are accepted only by reference. This chart never creates a Secret and
has no value that holds a password: one in values.yaml lands in git, in
`helm get values` and in CI logs. If existingSecret is unset the release-named
Secret is assumed, which you must create yourself before installing.
*/}}
{{- define "twow.dbSecretName" -}}
{{- default (printf "%s-db" (include "twow.fullname" .)) .Values.database.existingSecret -}}
{{- end -}}

{{/*
Environment shared by every container that talks to the database. The password
is injected as an env var and stamped into the config by an init container,
because the server reads a flat file and does no substitution of its own.
*/}}
{{- define "twow.dbEnv" -}}
- name: DB_HOST
  value: {{ .Values.database.host | quote }}
- name: DB_PORT
  value: {{ .Values.database.port | quote }}
- name: DB_USER
  value: {{ .Values.database.user | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "twow.dbSecretName" . }}
      key: {{ .Values.database.secretKeys.password }}
{{- end -}}
