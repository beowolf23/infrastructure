#!/usr/bin/env bash
#
# bootstrap-gitops.sh
#
# Generates an ArgoCD "app of apps" repository skeleton:
#
#   root  ->  apps/  ->  platform/  ->  monitoring & platform tooling
#                    ->  services/  ->  independent apps, all in one namespace
#
# Usage:
#   ./bootstrap-gitops.sh [-d TARGET_DIR] [-r REPO_URL] [-p REPO_PATH] [-b BRANCH] [-f]
#
#   -d  directory to generate into            (default: ./gitops)
#   -r  git repo URL these manifests live in  (default: https://github.com/org/infrastructure.git)
#   -p  path WITHIN that repo where these
#       manifests live, relative to repo root (default: gitops; "" for root)
#   -b  branch ArgoCD tracks                  (default: main)
#   -f  overwrite TARGET_DIR if it exists
#
# -d is where files land on your disk right now. -p is what gets written into
# every Application's spec.source.path. They are usually the same string, but
# they do not have to be — if your checkout is at ~/work/infra and the gitops
# directory sits at infra/k8s/gitops, that is:
#
#   ./bootstrap-gitops.sh -d ~/work/infra/k8s/gitops -p k8s/gitops
#
# The script only writes files. It never talks to a cluster.

set -euo pipefail

TARGET_DIR="./gitops"
REPO_URL="https://github.com/org/infrastructure.git"
REPO_PATH="gitops"
BRANCH="main"
FORCE=0

while getopts ":d:r:p:b:fh" opt; do
  case "$opt" in
    d) TARGET_DIR="$OPTARG" ;;
    r) REPO_URL="$OPTARG" ;;
    p) REPO_PATH="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    f) FORCE=1 ;;
    h) sed -n '2,32p' "$0"; exit 0 ;;
    \?) echo "unknown option: -$OPTARG" >&2; exit 1 ;;
    :)  echo "option -$OPTARG requires an argument" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Chart versions. Pinned on purpose: with selfHeal enabled an unpinned chart
# upgrades itself the moment upstream publishes. Bump these deliberately.
#
#   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head
#
# Verify each one against the upstream repo before your first sync — the values
# below are a starting point, not current-as-of-today.
# ---------------------------------------------------------------------------
VER_KPS="66.2.1"           # prometheus-community/kube-prometheus-stack
VER_LOKI="6.21.0"          # grafana/loki
VER_TEMPO="1.12.0"         # grafana/tempo
VER_ALLOY="0.10.0"         # grafana/alloy
VER_CERT_MANAGER="v1.16.2" # jetstack/cert-manager
VER_INGRESS_NGINX="4.11.3" # ingress-nginx/ingress-nginx
VER_ESO="0.10.5"           # external-secrets/external-secrets

# Normalise: strip leading/trailing slashes, then build a prefix that is either
# empty (manifests at repo root) or "some/dir/". Every spec.source.path and
# every \$values reference is built from this.
REPO_PATH="${REPO_PATH#/}"
REPO_PATH="${REPO_PATH%/}"
if [[ -n "$REPO_PATH" ]]; then
  P="${REPO_PATH}/"    # for spec.source.path  -> "gitops/apps"
  A="/${REPO_PATH}"    # for manifest-generate-paths -> "/gitops/apps"
else
  P=""
  A=""
fi

if [[ -e "$TARGET_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "${TARGET_DIR:?}"
  else
    echo "error: $TARGET_DIR already exists (use -f to overwrite)" >&2
    exit 1
  fi
fi

mkdir -p "$TARGET_DIR"/{bootstrap/projects,apps,platform,platform-values}
mkdir -p "$TARGET_DIR"/config/observability/{datasources,dashboards,rules,externalsecrets}
mkdir -p "$TARGET_DIR"/services
mkdir -p "$TARGET_DIR"/config/namespaces

cd "$TARGET_DIR"

# ===========================================================================
# bootstrap/ — applied by hand (or Terraform), not managed by ArgoCD
# ===========================================================================

cat > bootstrap/projects/platform.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform tooling owned by the infra team
  sourceRepos:
    - ${REPO_URL}
    - https://prometheus-community.github.io/helm-charts
    - https://grafana.github.io/helm-charts
    - https://charts.jetstack.io
    - https://kubernetes.github.io/ingress-nginx
    - https://charts.external-secrets.io
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  # Platform tooling ships CRDs and cluster-wide RBAC, so it needs this.
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
  orphanedResources:
    warn: true
YAML

cat > bootstrap/projects/services.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: services
  namespace: argocd
spec:
  description: Application workloads, all deployed into the services namespace
  sourceRepos:
    - ${REPO_URL}
    - https://github.com/org/*
  destinations:
    - server: https://kubernetes.default.svc
      namespace: services
  # Empty whitelist: service apps cannot create CRDs, ClusterRoles, or any
  # other cluster-scoped object — even if the manifest is committed.
  clusterResourceWhitelist: []
YAML

cat > bootstrap/root.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  annotations:
    # Monorepo: only regenerate when something under this subtree changed.
    argocd.argoproj.io/manifest-generate-paths: ${A}/apps
  # Removing this finalizer means 'kubectl delete app root' leaves children
  # (and their workloads) running. Keep it for disposable clusters, consider
  # dropping it in production. See README.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${P}apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    # Children are Application CRs — ArgoCD only reads them from its own
    # namespace. Changing this silently breaks the whole pattern.
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - ApplyOutOfSyncOnly=true
YAML

# ===========================================================================
# apps/ — the two parents, watched by root (non-recursive)
# ===========================================================================

cat > apps/platform.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
    argocd.argoproj.io/manifest-generate-paths: ${A}/platform
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${P}platform
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
YAML

cat > apps/services.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: services
  namespace: argocd
  annotations:
    argocd.argoproj.io/manifest-generate-paths: ${A}/services
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: services
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${P}services
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true       # a new service appears as soon as its file lands
      selfHeal: false   # leaf apps choose their own drift policy
      allowEmpty: false
YAML

# ===========================================================================
# platform/ — one Application per tool, ordered by sync wave
# ===========================================================================

# Helper: emit a multi-source Helm Application whose values live in this repo.
# Args: file name, app name, wave, chart repo, chart, version, namespace
helm_app() {
  local file="$1" name="$2" wave="$3" chart_repo="$4" chart="$5" version="$6" ns="$7"
  cat > "platform/${file}" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${name}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "${wave}"
    argocd.argoproj.io/manifest-generate-paths: ${A}/platform-values/${name}.yaml
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: ${chart_repo}
      chart: ${chart}
      targetRevision: ${version}
      helm:
        releaseName: ${name}
        valueFiles:
          - \$values/${P}platform-values/${name}.yaml
    - repoURL: ${REPO_URL}
      targetRevision: ${BRANCH}
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ns}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - SkipDryRunOnMissingResource=true
YAML
}

helm_app external-secrets.yaml       external-secrets       -30 \
  https://charts.external-secrets.io           external-secrets       "${VER_ESO}"           external-secrets
helm_app cert-manager.yaml           cert-manager           -30 \
  https://charts.jetstack.io                   cert-manager           "${VER_CERT_MANAGER}"  cert-manager
helm_app ingress-nginx.yaml          ingress-nginx          -20 \
  https://kubernetes.github.io/ingress-nginx   ingress-nginx          "${VER_INGRESS_NGINX}" ingress-nginx
helm_app kube-prometheus-stack.yaml  kube-prometheus-stack  -10 \
  https://prometheus-community.github.io/helm-charts kube-prometheus-stack "${VER_KPS}"  monitoring
helm_app loki.yaml                   loki                   -10 \
  https://grafana.github.io/helm-charts        loki                   "${VER_LOKI}"          monitoring
helm_app tempo.yaml                  tempo                   -5 \
  https://grafana.github.io/helm-charts        tempo                  "${VER_TEMPO}"         monitoring
helm_app alloy.yaml                  alloy                   -5 \
  https://grafana.github.io/helm-charts        alloy                  "${VER_ALLOY}"         monitoring

# kube-prometheus-stack needs extra diff suppression: the operator's webhook
# CA bundle is injected at runtime and will otherwise sit permanently OutOfSync.
cat >> platform/kube-prometheus-stack.yaml <<'YAML'
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jqPathExpressions:
        - '.spec.conversion.webhook.clientConfig.caBundle'
YAML

cat >> platform/cert-manager.yaml <<'YAML'
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
YAML

# The services namespace itself. Owned by the platform tier because the
# services project cannot create cluster-scoped objects, and because a shared
# namespace wants labels/quota set in one place rather than by whichever app
# happens to sync first.
cat > platform/namespaces.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-25"
    argocd.argoproj.io/manifest-generate-paths: ${A}/config/namespaces
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${P}config/namespaces
  destination:
    server: https://kubernetes.default.svc
    namespace: services
  syncPolicy:
    automated:
      prune: false      # never auto-delete a namespace full of workloads
      selfHeal: true
YAML

cat > config/namespaces/services.yaml <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: services
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: services-quota
  namespace: services
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
YAML

# Plain-manifest Application: dashboards, datasources, rules, ExternalSecrets.
cat > platform/observability-config.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/manifest-generate-paths: ${A}/config/observability
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${P}config/observability
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML

# ===========================================================================
# platform-values/ — Helm values, referenced via \$values from the Apps above.
# Kept OUT of platform/ so the platform parent never tries to apply them as
# Kubernetes objects.
# ===========================================================================

cat > platform-values/external-secrets.yaml <<'YAML'
installCRDs: true
replicaCount: 1
webhook:
  create: true
certController:
  create: true
YAML

cat > platform-values/cert-manager.yaml <<'YAML'
crds:
  enabled: true
  keep: true
replicaCount: 1
prometheus:
  enabled: true
  servicemonitor:
    enabled: true   # requires kube-prometheus-stack CRDs; hence the wave order
YAML

cat > platform-values/ingress-nginx.yaml <<'YAML'
controller:
  replicaCount: 2
  service:
    type: LoadBalancer
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
  podAnnotations:
    prometheus.io/scrape: "true"
YAML

cat > platform-values/kube-prometheus-stack.yaml <<'YAML'
# Grafana ships inside this chart. Set enabled: false and add a standalone
# grafana Application if you want to version it independently.
grafana:
  enabled: true
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: monitoring
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
      searchNamespace: monitoring
  ingress:
    enabled: false   # enable once cert-manager has issued a certificate

prometheus:
  prometheusSpec:
    retention: 15d
    # Pick up ServiceMonitors from every namespace, not just ones the chart
    # labelled itself. Without these four, ServiceMonitors in the services
    # namespace are ignored.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
YAML

cat > platform-values/loki.yaml <<'YAML'
# Single-binary mode: fine for one cluster. Move to simpleScalable once
# ingestion outgrows a single pod.
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 50Gi
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
chunksCache:
  enabled: false
resultsCache:
  enabled: false
YAML

cat > platform-values/tempo.yaml <<'YAML'
tempo:
  retention: 168h
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
persistence:
  enabled: true
  size: 20Gi
serviceMonitor:
  enabled: true
YAML

cat > platform-values/alloy.yaml <<'YAML'
alloy:
  configMap:
    create: true
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
controller:
  type: daemonset
YAML

# ===========================================================================
# config/observability/ — plain manifests, one Application, wave 0
# ===========================================================================

cat > config/observability/kustomization.yaml <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - datasources/loki.yaml
  - datasources/tempo.yaml
  - dashboards/cluster-overview.yaml
  - rules/platform-alerts.yaml
  - externalsecrets/grafana-admin.yaml
  - externalsecrets/alertmanager-slack.yaml
YAML

cat > config/observability/datasources/loki.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-loki
  labels:
    grafana_datasource: "1"
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://loki.monitoring.svc.cluster.local:3100
        jsonData:
          derivedFields:
            - datasourceUid: tempo
              matcherRegex: "trace_id=(\\w+)"
              name: TraceID
              url: "${__value.raw}"
YAML

cat > config/observability/datasources/tempo.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-tempo
  labels:
    grafana_datasource: "1"
data:
  tempo.yaml: |
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        uid: tempo
        access: proxy
        url: http://tempo.monitoring.svc.cluster.local:3100
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
YAML

cat > config/observability/dashboards/cluster-overview.yaml <<'YAML'
# Dashboard JSON goes in the data key. The Grafana sidecar picks this up by
# label — adding a dashboard is one new file, no Grafana restart.
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-overview
  labels:
    grafana_dashboard: "1"
data:
  cluster-overview.json: |
    {
      "title": "Cluster Overview",
      "uid": "cluster-overview",
      "schemaVersion": 39,
      "panels": [],
      "time": { "from": "now-6h", "to": "now" }
    }
YAML

cat > config/observability/rules/platform-alerts.yaml <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-alerts
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: platform.rules
      rules:
        - alert: ArgoCDAppNotSynced
          expr: argocd_app_info{sync_status!="Synced"} > 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD application {{ $labels.name }} is out of sync"
        - alert: ArgoCDAppDegraded
          expr: argocd_app_info{health_status="Degraded"} > 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "ArgoCD application {{ $labels.name }} is degraded"
YAML

cat > config/observability/externalsecrets/grafana-admin.yaml <<'YAML'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-admin
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: cluster-secret-store   # create this for your backend (Vault, ASM, ...)
    kind: ClusterSecretStore
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
    - secretKey: admin-user
      remoteRef:
        key: monitoring/grafana
        property: username
    - secretKey: admin-password
      remoteRef:
        key: monitoring/grafana
        property: password
YAML

cat > config/observability/externalsecrets/alertmanager-slack.yaml <<'YAML'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: alertmanager-slack
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: cluster-secret-store
    kind: ClusterSecretStore
  target:
    name: alertmanager-slack
    creationPolicy: Owner
  data:
    - secretKey: webhook-url
      remoteRef:
        key: monitoring/alertmanager
        property: slack_webhook_url
YAML

# ===========================================================================
# services/ — one Application per app, all landing in the services namespace
# ===========================================================================

service_app() {
  local name="$1" repo="$2" path="$3"
  cat > "services/${name}.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${name}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: services
  source:
    repoURL: ${repo}
    targetRevision: ${BRANCH}
    path: ${path}
  destination:
    server: https://kubernetes.default.svc
    namespace: services
  syncPolicy:
    automated:
      prune: true
      selfHeal: false   # leave off if teams patch during incidents
    # No CreateNamespace: the namespace is owned by platform/namespaces.yaml.
  revisionHistoryLimit: 5
YAML
}

service_app billing-api   https://github.com/org/billing-api   deploy/overlays/prod
service_app web-frontend  https://github.com/org/web-frontend  deploy/overlays/prod

# ===========================================================================
# README
# ===========================================================================

cat > README.md <<YAML
# GitOps repository

Generated skeleton for an ArgoCD app-of-apps deployment.

    root ──> apps/platform.yaml ──> platform/*.yaml  ──> monitoring + tooling
         └─> apps/services.yaml ──> services/*.yaml  ──> app workloads

These manifests live at \`${REPO_PATH}/\` inside \`${REPO_URL}\`. Every
\`spec.source.path\` is written relative to the REPO ROOT, not to this
directory — so they read \`${P}platform\`, not \`platform\`. If you move this
directory, re-run the generator with a new \`-p\` rather than editing by hand.

## Bootstrap

Projects first — a child Application referencing \`project: platform\` is
rejected if the AppProject does not exist yet. Run from the repo root:

    kubectl apply -f ${P}bootstrap/projects/
    kubectl apply -f ${P}bootstrap/root.yaml

Everything after that is a git commit.

## Monorepo notes

Each Application carries \`argocd.argoproj.io/manifest-generate-paths\`, so a
webhook for a commit that only touched \`terraform/\` will not trigger manifest
regeneration for all of these apps. Without it, every push anywhere in the
infrastructure repo refreshes every Application.

Repo credentials are configured per repo URL, so ArgoCD gets read access to the
whole infrastructure repo, not just this subtree. If that is a problem, the
subtree needs to be its own repository.

## Before the first sync

1. Replace \`${REPO_URL}\` if you did not pass \`-r\`.
2. Bump the chart versions in each \`platform/*.yaml\` — the pinned values are
   a starting point. Check with \`helm search repo <chart> --versions\`.
3. Create a \`ClusterSecretStore\` named \`cluster-secret-store\` for your secrets
   backend, or swap the ExternalSecrets for Sealed Secrets / SOPS.
4. Decide on the root finalizer. As written, \`kubectl delete app root\`
   cascades through every child and deletes their workloads.

## Sync waves

    -30  external-secrets, cert-manager     (secrets + certs must exist first)
    -25  namespaces                          (creates the services namespace)
    -20  ingress-nginx
    -10  kube-prometheus-stack, loki        (CRDs land here)
     -5  tempo, alloy
      0  observability-config, services

## Adding things

- New platform tool: add \`platform/<name>.yaml\` + \`platform-values/<name>.yaml\`
- New dashboard: add a ConfigMap under \`config/observability/dashboards/\`
  and list it in the kustomization
- New service: add \`services/<name>.yaml\` (namespace is always \`services\`)

## Where this outgrows itself

A second cluster turns \`platform-values/loki.yaml\` into
\`platform-values/<cluster>/loki.yaml\`, at which point the platform parent
becomes an ApplicationSet with a matrix generator. Past ~30 services, a git
files generator over \`services/*/config.yaml\` beats hand-written specs.

The shared \`services\` namespace is the other thing to watch: one ResourceQuota
covers everything, a NetworkPolicy cannot separate two apps that sit in it, and
Service/ConfigMap names must stay globally unique. Splitting later means adding
namespaces to \`config/namespaces/\` and widening the project destination — the
Application files themselves barely change.
YAML

cd - >/dev/null

echo "Created $TARGET_DIR"
echo
if command -v tree >/dev/null 2>&1; then
  tree -a "$TARGET_DIR"
else
  find "$TARGET_DIR" -type f | sort
fi
echo
echo "Next:"
echo "  kubectl apply -f $TARGET_DIR/bootstrap/projects/"
echo "  kubectl apply -f $TARGET_DIR/bootstrap/root.yaml"
