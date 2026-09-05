# backstage

A scaffolded Backstage instance (`app/`, via `@backstage/create-app`),
configured to register services through the `spring-boot-service` template
in `../spring-boot-template/`. Deployed via `gitops/platform/backstage.yaml`
+ `gitops/platform-values/backstage.yaml`, using the official
[backstage/charts](https://backstage.github.io/charts) Helm chart.

Verified end-to-end: `yarn install`, a full multi-stage Docker build, and a
running container serving the frontend and enforcing auth on its API
(confirmed via `/api/catalog/entities/by-query` returning 401 without
credentials, 200 for authenticated internal service-to-service calls).

## Building and pushing the image

```sh
cd app
docker build -t ghcr.io/beowolf23/backstage:latest .
docker push ghcr.io/beowolf23/backstage:latest
```

There's no CI wired up for this yet (unlike the spring-boot-template's
`ci.yaml`) - add a workflow under `app/.github/workflows/` the same way if
this needs to rebuild automatically.

## Required secret

The scaffolder's `publish:github` and `publish:github:pull-request` actions
(used by the spring-boot-service template) need a real GitHub token at
runtime:

```sh
kubectl create secret generic backstage-github-token \
  --from-literal=GITHUB_TOKEN=<a PAT with repo + workflow scope> \
  -n backstage
```

Never commit the actual token - `platform-values/backstage.yaml` only
references the secret by name (`extraEnvVarsSecrets`).

## Accessing it

No ingress in this cluster yet:

```sh
kubectl port-forward -n backstage svc/backstage 7007:7007
```

Then open `http://localhost:7007`. `app-config.production.yaml`'s
`app.baseUrl`/`backend.baseUrl` are set to that same localhost URL - update
both if a real hostname/ingress gets added later.

## Known limitations / next steps

- **Database**: SQLite on a per-pod ephemeral volume - fine for one
  replica, lost if the pod is rescheduled to fail over. Set
  `postgresql.enabled: true` in `platform-values/backstage.yaml` and point
  `backstage` at it (see the chart's own `postgresql.*` values) before this
  needs to survive a pod restart reliably or run more than one replica.
- **Auth**: guest provider only. Add a real auth provider (GitHub OAuth is
  the natural one, given the GitHub integration is already configured) via
  `auth.providers` in `app/app-config.production.yaml` before giving anyone
  else access.
- **No CI**: the image has to be built and pushed by hand (see above).
