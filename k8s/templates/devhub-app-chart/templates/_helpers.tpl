{{/* Required values, checked once so every template can assume them. */}}
{{- define "devhub-app.name" -}}
{{- required "app.name is required" .Values.app.name -}}
{{- end -}}

{{- define "devhub-app.labels" -}}
app: {{ include "devhub-app.name" . }}
app.kubernetes.io/name: {{ include "devhub-app.name" . }}
app.kubernetes.io/managed-by: devhub-app-chart
{{- end -}}

{{/*
Whether any route needs sign-in: the whole app (auth.enabled), the exception
paths of an otherwise-public app, or an extra workload with auth: true.
*/}}
{{- define "devhub-app.authActive" -}}
{{- $wl := false -}}
{{- range .Values.extraWorkloads }}{{- if and .auth .host }}{{- $wl = true }}{{- end }}{{- end -}}
{{- if or .Values.auth.enabled (gt (len .Values.auth.exceptPaths) 0) $wl -}}true{{- end -}}
{{- end -}}

{{/*
The HTTPRoute the OIDC SecurityPolicy attaches to. With auth.enabled the main
route is protected and the exceptions route stays public; without it the
exceptions route is the protected one.
*/}}
{{- define "devhub-app.protectedRoute" -}}
{{- if .Values.auth.enabled -}}
{{- include "devhub-app.name" . -}}
{{- else -}}
{{- include "devhub-app.name" . -}}-exceptions
{{- end -}}
{{- end -}}
