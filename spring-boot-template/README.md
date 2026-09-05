# spring-boot-template

A Backstage Software Template for a standard Java 25 / Spring Boot 4
service. Verified end-to-end (build, tests, Docker image, container
startup, `/actuator/health`, and the sample endpoint) against real Spring
Boot 4.1.1 on real Java 25 - see `skeleton/README.md` for what the
generated app looks like and how to run it standalone.

## Structure

- `template.yaml` - the Backstage `Template` manifest (parameters + steps).
- `skeleton/` - what gets copied into a new service repo via `fetch:template`:
  pom.xml, source, Dockerfile, and `catalog-info.yaml`. Contains Nunjucks
  placeholders (`${{ values.name }}` etc.) that Backstage fills in - it's
  not meant to be built as-is from this location.
- `github-workflows/.github/workflows/ci.yaml` - fetched separately via
  `fetch:plain` (not `fetch:template`), which never runs any templating
  engine. It has to live outside `skeleton/`: `fetch:template` renders
  every `${{ }}` it finds in the whole tree regardless of
  `copyWithoutRender` globs, which silently emptied every GitHub Actions
  expression (`github.actor`, `secrets.GITHUB_TOKEN`, etc.) when this was
  tried inside `skeleton/.github/`.
- `gitops-registration/` - the `Application` + `ImageUpdater` CR (see
  Continuous deployment below) + values file the template PRs into
  `gitops/services/` and `gitops/services-values/` for each new service,
  deployed via `gitops/charts/spring-boot-app`.

## Registering this template in Backstage

Add a `catalog.locations` entry pointing at this file:

```yaml
catalog:
  locations:
    - type: url
      target: https://github.com/beowolf23/infrastructure/blob/main/spring-boot-template/template.yaml
      rules:
        - allow: [Template]
```

## Continuous deployment

The app's own CI (`github-workflows/.github/workflows/ci.yaml`) only builds,
tests, and pushes the image - it does **not** touch the gitops repo, and
needs no secret beyond the default `GITHUB_TOKEN`. Pushing a new image to a
static `latest` tag doesn't trigger a redeploy on its own (ArgoCD only
watches git, not the registry), so a separate, centrally-run component -
[`argocd-image-updater`](https://github.com/beowolf23/infrastructure/blob/main/gitops/platform/argocd-image-updater.yaml) -
polls `ghcr.io/beowolf23/<name>` for the newest `sha-<commit>` tag and
commits it into `gitops/services-values/<name>.yaml` itself. That commit is
what ArgoCD's `selfHeal` reacts to.

Per-service config for this is an `ImageUpdater` CR that
`gitops-registration/` generates automatically alongside the `Application` -
no manual step per new service. Image Updater itself needs two secrets
created **once**, centrally, in the `argocd` namespace (not per service):

```sh
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=beowolf23 \
  --docker-password=<PAT with read:packages> -n argocd

kubectl create secret generic git-creds \
  --from-literal=username=beowolf23 \
  --from-literal=password=<PAT with repo scope on this repo> -n argocd
```

## Using it without Backstage

Nothing stops you from copying `skeleton/` by hand and manually replacing
the `${{ values.* }}` placeholders (`name`, `description`, `owner`,
`groupId`) - Backstage is the intended path, but it's not required.
