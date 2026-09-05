# GitOps repository

Generated skeleton for an ArgoCD app-of-apps deployment.

    root ──> apps/platform.yaml ──> platform/*.yaml  ──> monitoring + tooling
         └─> apps/services.yaml ──> services/*.yaml  ──> app workloads

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
2. Bump the chart versions in each `platform/*.yaml` — the pinned values are
   a starting point. Check with `helm search repo <chart> --versions`.
3. Create a `ClusterSecretStore` named `cluster-secret-store` for your secrets
   backend, or swap the ExternalSecrets for Sealed Secrets / SOPS.
4. Decide on the root finalizer. As written, `kubectl delete app root`
   cascades through every child and deletes their workloads.

## Sync waves

    -30  external-secrets, cert-manager     (secrets + certs must exist first)
    -25  namespaces                          (creates the services namespace)
    -20  ingress-nginx
    -10  kube-prometheus-stack, loki        (CRDs land here)
     -5  tempo, alloy
      0  observability-config, services

## Adding things

- New platform tool: add `platform/<name>.yaml` + `platform-values/<name>.yaml`
- New dashboard: add a ConfigMap under `config/observability/dashboards/`
  and list it in the kustomization
- New service: add `services/<name>.yaml` (namespace is always `services`)

## Where this outgrows itself

A second cluster turns `platform-values/loki.yaml` into
`platform-values/<cluster>/loki.yaml`, at which point the platform parent
becomes an ApplicationSet with a matrix generator. Past ~30 services, a git
files generator over `services/*/config.yaml` beats hand-written specs.

The shared `services` namespace is the other thing to watch: one ResourceQuota
covers everything, a NetworkPolicy cannot separate two apps that sit in it, and
Service/ConfigMap names must stay globally unique. Splitting later means adding
namespaces to `config/namespaces/` and widening the project destination — the
Application files themselves barely change.
