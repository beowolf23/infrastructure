# GitOps repository

Generated skeleton for an ArgoCD app-of-apps deployment.

    root ──> apps/platform.yaml ──> platform/*.yaml  ──> monitoring (Prometheus + Grafana), OTel collector
         └─> apps/services.yaml ──> services/*.yaml  ──> app workloads (via the spring-boot-app chart)

These manifests live at `gitops/` inside `https://github.com/beowolf23/infrastructure.git`. Every
`spec.source.path` is written relative to the REPO ROOT, not to this
directory — so they read `gitops/platform`, not `platform`. If you move this
directory, re-run the generator with a new `-p` rather than editing by hand.

## Bootstrap

Projects first — a child Application referencing `project: platform` is
rejected if the AppProject does not exist yet. Run from the repo root:

    kubectl apply -f gitops/bootstrap/projects/
    kubectl apply -f gitops/bootstrap/root.yaml

Everything after that is a git commit.

## Monorepo notes

Each Application carries `argocd.argoproj.io/manifest-generate-paths`, so a
webhook for a commit that only touched `terraform/` will not trigger manifest
regeneration for all of these apps. Without it, every push anywhere in the
infrastructure repo refreshes every Application.

Repo credentials are configured per repo URL, so ArgoCD gets read access to the
whole infrastructure repo, not just this subtree. If that is a problem, the
subtree needs to be its own repository.

## Before the first sync

1. Replace `https://github.com/beowolf23/infrastructure.git` if you did not pass `-r`.
2. Bump the chart version in `platform/kube-prometheus-stack.yaml` — the
   pinned value is a starting point. Check with
   `helm search repo kube-prometheus-stack --versions`.
3. Decide on the root finalizer. As written, `kubectl delete app root`
   cascades through every child and deletes their workloads.

## Sync waves

    -15  loki
    -10  kube-prometheus-stack   (CRDs land here; bundles Prometheus + Grafana)
     -5  otel-collector          (needs Prometheus + Loki up first)

## Adding things

- New platform tool: add `platform/<name>.yaml` + `platform-values/<name>.yaml`
- New service: add `services/<name>.yaml` (namespace is always `services`) -
  normally done for you by the Backstage `spring-boot-service` template,
  which opens this as a PR after scaffolding the app repo. See
  `gitops/charts/spring-boot-app/README.md`.

## Scope

Platform: Prometheus + Grafana (`kube-prometheus-stack`, with alertmanager,
node-exporter and kube-state-metrics disabled), Loki, and an otel-collector
that bridges OTLP from apps into both. Grafana uses its own auto-generated
admin credentials since there's no secrets backend wired up - check the
`kube-prometheus-stack-grafana` secret in the `monitoring` namespace.

Not (yet) present: cert-manager, external-secrets, ingress-nginx, tracing
(no backend deployed - the otel-collector's traces pipeline is a no-op).
Re-add any of these as `platform/<name>.yaml` + `platform-values/<name>.yaml`.

Services deploy through `gitops/charts/spring-boot-app`, a generic chart
shared by every app - see its README for the Dockerfile/OTel contract new
services need to follow.
