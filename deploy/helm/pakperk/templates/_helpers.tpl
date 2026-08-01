{{- define "pakperk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pakperk.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "pakperk.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "pakperk.labels" -}}
app.kubernetes.io/name: {{ include "pakperk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{- define "pakperk.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pakperk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pakperk.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "pakperk.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "pakperk.appImage" -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- end -}}

{{- define "pakperk.siteImage" -}}
{{- printf "%s@%s" .Values.siteImage.repository .Values.siteImage.digest -}}
{{- end -}}

{{- define "pakperk.componentLabels" -}}
{{ include "pakperk.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "pakperk.bool" -}}{{ ternary "true" "false" . }}{{- end -}}

{{- define "pakperk.apiSecretCopyInit" -}}
- name: materialize-owner-only-secrets
  image: {{ include "pakperk.appImage" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["/bin/sh", "-ceu"]
  args:
    - |
      # Reclaim a restarted init container's tmpfs directory before touching
      # files. With only CAP_CHOWN, uid 0 cannot write a 0700 directory owned
      # by 10001 until this ownership transition has happened.
      chown 0:0 /work
      chmod 0700 /work
      rm -f /work/LLM_API_KEY /work/API_ORIGIN_HASH_SECRET /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS
      install -m 0400 /source/LLM_API_KEY /work/LLM_API_KEY
      chown 10001:10001 /work/LLM_API_KEY
      install -m 0400 /source/API_ORIGIN_HASH_SECRET /work/API_ORIGIN_HASH_SECRET
      chown 10001:10001 /work/API_ORIGIN_HASH_SECRET
      {{- if .Values.features.accounts }}
      install -m 0400 /source/ACCOUNT_IDENTITY_FINGERPRINT_KEYS /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS
      chown 10001:10001 /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS
      {{- end }}
      {{- if .Values.features.accountDeletion }}
      install -m 0400 /source/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS
      chown 10001:10001 /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS
      install -m 0600 /source/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS
      chown 10001:10001 /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS
      {{- end }}
      chown 10001:10001 /work
  securityContext:
    runAsNonRoot: false
    runAsUser: 0
    runAsGroup: 0
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
      add: ["CHOWN"]
  volumeMounts:
    - { name: secret-source, mountPath: /source, readOnly: true }
    - { name: owner-secrets, mountPath: /work }
{{- end -}}

{{- define "pakperk.apiSecretVolumes" -}}
- name: secret-source
  secret:
    secretName: {{ .Values.secret.existingSecret }}
    defaultMode: 0400
    items:
      - { key: {{ .Values.secret.llmApiKeyKey }}, path: LLM_API_KEY }
      - { key: {{ .Values.secret.apiOriginHashKey }}, path: API_ORIGIN_HASH_SECRET }
      {{- if .Values.features.accounts }}
      - { key: {{ .Values.secret.identityFingerprintKeysKey }}, path: ACCOUNT_IDENTITY_FINGERPRINT_KEYS }
      {{- end }}
      {{- if .Values.features.accountDeletion }}
      - { key: {{ .Values.secret.deletionLedgerSigningKeysKey }}, path: ACCOUNT_DELETION_LEDGER_SIGNING_KEYS }
      - { key: {{ .Values.secret.deletionProviderIdentityKeysKey }}, path: ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS }
      {{- end }}
- name: owner-secrets
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
{{- end -}}

{{- define "pakperk.paperSecretCopyInit" -}}
- name: materialize-owner-only-secrets
  image: {{ include "pakperk.appImage" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["/bin/sh", "-ceu"]
  args:
    - |
      chown 0:0 /work
      chmod 0700 /work
      rm -f /work/LLM_API_KEY
      install -m 0400 /source/LLM_API_KEY /work/LLM_API_KEY
      chown 10001:10001 /work/LLM_API_KEY
      chown 10001:10001 /work
  securityContext:
    runAsNonRoot: false
    runAsUser: 0
    runAsGroup: 0
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
      add: ["CHOWN"]
  volumeMounts:
    - { name: secret-source, mountPath: /source, readOnly: true }
    - { name: owner-secrets, mountPath: /work }
{{- end -}}

{{- define "pakperk.paperSecretVolumes" -}}
- name: secret-source
  secret:
    secretName: {{ .Values.secret.existingSecret }}
    defaultMode: 0400
    items:
      - { key: {{ .Values.secret.llmApiKeyKey }}, path: LLM_API_KEY }
- name: owner-secrets
  emptyDir:
    medium: Memory
    sizeLimit: 64Ki
{{- end -}}

{{- define "pakperk.deletionSecretCopyInit" -}}
- name: materialize-owner-only-secrets
  image: {{ include "pakperk.appImage" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["/bin/sh", "-ceu"]
  args:
    - |
      chown 0:0 /work
      chmod 0700 /work
      rm -f /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS /work/OIDC_ADMIN_CLIENT_SECRET
      install -m 0400 /source/ACCOUNT_IDENTITY_FINGERPRINT_KEYS /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS
      chown 10001:10001 /work/ACCOUNT_IDENTITY_FINGERPRINT_KEYS
      install -m 0400 /source/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS
      chown 10001:10001 /work/ACCOUNT_DELETION_LEDGER_SIGNING_KEYS
      install -m 0600 /source/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS
      chown 10001:10001 /work/ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS
      install -m 0400 /source/OIDC_ADMIN_CLIENT_SECRET /work/OIDC_ADMIN_CLIENT_SECRET
      chown 10001:10001 /work/OIDC_ADMIN_CLIENT_SECRET
      chown 10001:10001 /work
  securityContext:
    runAsNonRoot: false
    runAsUser: 0
    runAsGroup: 0
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
      add: ["CHOWN"]
  volumeMounts:
    - { name: secret-source, mountPath: /source, readOnly: true }
    - { name: owner-secrets, mountPath: /work }
{{- end -}}

{{- define "pakperk.deletionSecretVolumes" -}}
- name: secret-source
  secret:
    secretName: {{ .Values.secret.existingSecret }}
    defaultMode: 0400
    items:
      - { key: {{ .Values.secret.identityFingerprintKeysKey }}, path: ACCOUNT_IDENTITY_FINGERPRINT_KEYS }
      - { key: {{ .Values.secret.deletionLedgerSigningKeysKey }}, path: ACCOUNT_DELETION_LEDGER_SIGNING_KEYS }
      - { key: {{ .Values.secret.deletionProviderIdentityKeysKey }}, path: ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS }
      - { key: {{ .Values.secret.oidcAdminClientSecretKey }}, path: OIDC_ADMIN_CLIENT_SECRET }
- name: owner-secrets
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
{{- end -}}

{{- define "pakperk.dnsEgress" -}}
- to:
    - namespaceSelector:
        matchLabels: {{ toYaml .Values.networkPolicy.dnsNamespaceSelector | nindent 10 }}
      podSelector:
        matchLabels: {{ toYaml .Values.networkPolicy.dnsPodSelector | nindent 10 }}
  ports:
    - { protocol: UDP, port: 53 }
    - { protocol: TCP, port: 53 }
{{- end -}}

{{- define "pakperk.databaseEgress" -}}
{{- range .Values.networkPolicy.databaseCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: {{ $.Values.networkPolicy.databasePort }} }]
{{- end }}
{{- end -}}

{{- define "pakperk.apiHttpsEgress" -}}
{{- range .Values.networkPolicy.apiHttpsCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: 443 }]
{{- end }}
{{- end -}}

{{- define "pakperk.paperHttpsEgress" -}}
{{- range .Values.networkPolicy.paperHttpsCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: 443 }]
{{- end }}
{{- end -}}

{{- define "pakperk.identityAdminHttpsEgress" -}}
{{- range .Values.networkPolicy.identityAdminHttpsCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: 443 }]
{{- end }}
{{- end -}}

{{- define "pakperk.telemetryEgress" -}}
{{- range .Values.networkPolicy.telemetryCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: {{ $.Values.networkPolicy.telemetryPort }} }]
{{- end }}
{{- end -}}
