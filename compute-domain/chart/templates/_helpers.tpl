{{/* Common name for the controller workload/identity. */}}
{{- define "computedomain.name" -}}
compute-domain-controller
{{- end -}}

{{/* Namespace (defaults to kube-system, overridable). */}}
{{- define "computedomain.namespace" -}}
{{- default "kube-system" .Values.namespace -}}
{{- end -}}

{{/* Full controller image reference. */}}
{{- define "computedomain.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{/* Standard labels — mirrors the managed-dranet chart. */}}
{{- define "computedomain.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "computedomain.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
kubernetes.azure.com/managedby: aks
{{- end -}}

{{/* Selector labels. */}}
{{- define "computedomain.selectorLabels" -}}
app.kubernetes.io/name: {{ include "computedomain.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
