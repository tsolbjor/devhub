{{/* Required values, checked once so every template can assume them. */}}
{{- define "devhub-app.name" -}}
{{- required "app.name is required" .Values.app.name -}}
{{- end -}}

{{- define "devhub-app.labels" -}}
app: {{ include "devhub-app.name" . }}
app.kubernetes.io/name: {{ include "devhub-app.name" . }}
app.kubernetes.io/managed-by: devhub-app-chart
{{- end -}}
