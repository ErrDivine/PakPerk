{{- define "pakperk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pakperk.boundedNameBase" -}}
{{- $value := printf "%s" .value | trimSuffix "-" -}}
{{- $maxLength := int .maxLength -}}
{{- if le (len $value) $maxLength -}}
{{- $value -}}
{{- else -}}
{{- $digest := sha256sum $value | trunc 8 -}}
{{- $prefixLength := sub $maxLength 9 | int -}}
{{- printf "%s-%s" ($value | trunc $prefixLength | trimSuffix "-") $digest | trunc $maxLength | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "pakperk.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- include "pakperk.boundedNameBase" (dict "value" .Values.fullnameOverride "maxLength" 45) -}}
{{- else -}}
{{- $rawName := printf "%s-%s" .Release.Name (include "pakperk.name" .) -}}
{{- include "pakperk.boundedNameBase" (dict "value" $rawName "maxLength" 45) -}}
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

{{- define "pakperk.componentServiceAccountName" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $base := default (include "pakperk.fullname" $root) $root.Values.serviceAccount.name -}}
{{- if not $root.Values.serviceAccount.create -}}
{{- $base = required "serviceAccount.name base is required when serviceAccount.create=false" $root.Values.serviceAccount.name -}}
{{- end -}}
{{- $maxBaseLength := sub 62 (len $component) | int -}}
{{- $boundedBase := include "pakperk.boundedNameBase" (dict "value" $base "maxLength" $maxBaseLength) -}}
{{- printf "%s-%s" $boundedBase $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pakperk.migrationServiceAccountName" -}}
{{- printf "%s-migration" (include "pakperk.fullname" . | trunc 53 | trimSuffix "-") | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pakperk.otelServiceName" -}}
{{- printf "pakperk-%s-%s" .component .root.Values.environment -}}
{{- end -}}

{{/*
Return the inclusive numeric bounds of a canonical IPv4 CIDR as "start,end".
The paper/provider and identity-admin boundaries deliberately accept only
canonical IPv4 CIDRs: Helm has no native dual-stack CIDR containment primitive,
and silently accepting an IPv6 range that cannot be compared would fail open.
*/}}
{{- define "pakperk.ipv4CidrBounds" -}}
{{- $cidr := . -}}
{{- if not (regexMatch `^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$` $cidr) -}}
{{- fail (printf "%s must be a canonical IPv4 CIDR" $cidr) -}}
{{- end -}}
{{- $parts := splitList "/" $cidr -}}
{{- $octets := splitList "." (index $parts 0) -}}
{{- range $octet := $octets -}}
{{- if or (gt (int $octet) 255) (and (gt (len $octet) 1) (hasPrefix "0" $octet)) -}}
{{- fail (printf "%s must be a canonical IPv4 CIDR" $cidr) -}}
{{- end -}}
{{- end -}}
{{- $prefix := int (index $parts 1) -}}
{{- if lt $prefix 8 -}}
{{- fail (printf "%s must use an IPv4 prefix between /8 and /32" $cidr) -}}
{{- end -}}
{{- $address := add (mul (int64 (index $octets 0)) 16777216) (mul (int64 (index $octets 1)) 65536) (mul (int64 (index $octets 2)) 256) (int64 (index $octets 3)) -}}
{{- $blockSize := int64 1 -}}
{{- range until (sub 32 $prefix | int) -}}
{{- $blockSize = mul $blockSize 2 -}}
{{- end -}}
{{- $start := mul (div $address $blockSize) $blockSize -}}
{{- if ne $address $start -}}
{{- fail (printf "%s must start at its canonical network address" $cidr) -}}
{{- end -}}
{{- $end := sub (add $start $blockSize) 1 -}}
{{- printf "%d,%d" $start $end -}}
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

{{- define "pakperk.arxivHttpsEgress" -}}
{{- range .Values.networkPolicy.arxivHttpsCidrs }}
- to: [{ ipBlock: { cidr: {{ . | quote }} } }]
  ports: [{ protocol: TCP, port: 443 }]
{{- end }}
{{- end -}}

{{- define "pakperk.modelHttpsEgress" -}}
{{- range .Values.networkPolicy.modelHttpsCidrs }}
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
