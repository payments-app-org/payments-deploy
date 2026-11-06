{{/* Метки для поиска подов сервиса: по ним Service и Deployment находят свои поды */}}
{{- define "java-service.selector" -}}
app.kubernetes.io/name: {{ required "name обязателен" .Values.name }}
{{- end }}

{{- define "java-service.labels" -}}
{{ include "java-service.selector" . }}
app.kubernetes.io/part-of: payments-app
app.kubernetes.io/version: {{ .Values.image.tag | trunc 12 | quote }}
{{- end }}
