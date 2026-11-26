{{- define "selkies-user.name" -}}
{{- printf "selkies-%s" .Values.user.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "selkies-user.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: selkies
app.kubernetes.io/user: {{ .Values.user.name }}
{{- end -}}

{{- define "selkies-user.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: selkies
app.kubernetes.io/user: {{ .Values.user.name }}
{{- end -}}
