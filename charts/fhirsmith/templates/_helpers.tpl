{{/*
Expand the name of the chart.
*/}}
{{- define "fhirsmith.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fhirsmith.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fhirsmith.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fhirsmith.labels" -}}
helm.sh/chart: {{ include "fhirsmith.chart" . }}
{{ include "fhirsmith.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fhirsmith.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fhirsmith.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fhirsmith.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fhirsmith.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Workload kind: "Deployment" (default) or "StatefulSet".

Use a StatefulSet when running more than one replica with persistence: the
Deployment mounts a single shared PVC, which a second replica scheduled onto
another node cannot attach (Multi-Attach). volumeClaimTemplates give each
replica its own volume instead. FHIRsmith's terminology cache is immutable and
read-only at runtime (see tx/README.md upstream), so per-replica copies are
equivalent to a shared one.
*/}}
{{- define "fhirsmith.workloadKind" -}}
{{- $kind := default "Deployment" .Values.workload.kind -}}
{{- if not (has $kind (list "Deployment" "StatefulSet")) -}}
{{- fail (printf "workload.kind must be \"Deployment\" or \"StatefulSet\", got %q" $kind) -}}
{{- end -}}
{{- if and (eq $kind "Deployment") .Values.persistence.enabled -}}
{{- /* With an HPA or KEDA the Deployment's replicas field is unmanaged, so the
       ceiling is the autoscaler's maximum rather than replicaCount. */}}
{{- $source := ternary "autoscaling.maxReplicas" "replicaCount" .Values.autoscaling.enabled -}}
{{- $max := ternary (int (default 1 .Values.autoscaling.maxReplicas)) (int .Values.replicaCount) .Values.autoscaling.enabled -}}
{{- if .Values.keda.enabled -}}
{{- /* Same resolution as templates/scaledobject.yaml; $source names the key the
       ceiling actually came from so the failure points at what to change. */}}
{{- $source = "replicaCount" -}}
{{- $max = int .Values.replicaCount -}}
{{- if gt (int .Values.keda.minReplicaCount) $max -}}
{{- $source = "keda.minReplicaCount" -}}
{{- $max = int .Values.keda.minReplicaCount -}}
{{- end -}}
{{- if not (kindIs "invalid" .Values.keda.cron.desiredReplicas) -}}
{{- $source = "keda.cron.desiredReplicas" -}}
{{- $max = int .Values.keda.cron.desiredReplicas -}}
{{- end -}}
{{- if not (kindIs "invalid" .Values.keda.maxReplicaCount) -}}
{{- $source = "keda.maxReplicaCount" -}}
{{- $max = int .Values.keda.maxReplicaCount -}}
{{- end -}}
{{- end -}}
{{- if gt $max 1 -}}
{{- fail (printf "%s = %d with persistence.enabled requires workload.kind: StatefulSet — a Deployment shares one ReadWriteOnce PVC across all replicas, which cannot be attached by more than one node." $source $max) -}}
{{- end -}}
{{- end -}}
{{- $kind -}}
{{- end -}}

{{/*
Whether the data volume comes from a StatefulSet volumeClaimTemplate rather
than from the pod's own volumes list.
*/}}
{{- define "fhirsmith.usesClaimTemplate" -}}
{{- and (eq (include "fhirsmith.workloadKind" .) "StatefulSet") .Values.persistence.enabled -}}
{{- end -}}

{{/*
Pod template, shared by the Deployment and the StatefulSet so the two cannot
drift. The only difference is the data volume: with a volumeClaimTemplate the
StatefulSet provides it, otherwise it is a PVC or an emptyDir declared here.
*/}}
{{- define "fhirsmith.podTemplate" -}}
metadata:
  annotations:
    checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "fhirsmith.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "fhirsmith.serviceAccountName" . }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: {{ .Chart.Name }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.service.port }}
          protocol: TCP
      env:
        # FHIRsmith reads config.json from $FHIRSMITH_DATA_DIR and listens on $PORT.
        - name: FHIRSMITH_DATA_DIR
          value: {{ .Values.dataDir | quote }}
        - name: PORT
          value: {{ .Values.service.port | quote }}
        {{- range .Values.env }}
        - name: {{ .name }}
          value: {{ .value | quote }}
        {{- end }}
      envFrom:
        {{- range .Values.secretNames }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      livenessProbe:
        {{- toYaml .Values.livenessProbe | nindent 8 }}
      readinessProbe:
        {{- toYaml .Values.readinessProbe | nindent 8 }}
      startupProbe:
        {{- toYaml .Values.startupProbe | nindent 8 }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        # Writable data dir (terminology cache, logs). config.json and
        # library.yml are layered in read-only via subPath from the ConfigMap.
        - name: data
          mountPath: {{ .Values.dataDir }}
        - name: config
          mountPath: {{ .Values.dataDir }}/config.json
          subPath: config.json
          readOnly: true
        - name: config
          mountPath: {{ .Values.dataDir }}/library.yml
          subPath: library.yml
          readOnly: true
        {{- with .Values.volumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  volumes:
    {{- if not (eq (include "fhirsmith.usesClaimTemplate" .) "true") }}
    - name: data
    {{- if .Values.persistence.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "fhirsmith.fullname" . }}-data
    {{- else }}
      emptyDir: {}
    {{- end }}
    {{- end }}
    - name: config
      configMap:
        name: {{ include "fhirsmith.fullname" . }}-config
    {{- with .Values.volumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
