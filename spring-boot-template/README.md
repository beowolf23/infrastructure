# spring-boot-template

A Backstage Software Template for a standard Java 25 / Spring Boot 4
service. Verified end-to-end (build, tests, Docker image, container
startup, `/actuator/health`, and the sample endpoint) against real Spring
Boot 4.1.1 on real Java 25 - see `skeleton/README.md` for what the
generated app looks like and how to run it standalone.

## Structure

- `template.yaml` - the Backstage `Template` manifest (parameters + steps).
- `skeleton/` - what gets copied into a new service repo: pom.xml, source,
  Dockerfile, CI, and `catalog-info.yaml`. Contains Nunjucks placeholders
  (`${{ values.name }}` etc.) that Backstage fills in - it's not meant to
  be built as-is from this location.
- `gitops-registration/` - the small `Application` + values file the
  template PRs into `gitops/services/` and `gitops/services-values/` for
  each new service, deployed via `gitops/charts/spring-boot-app`.

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

`skeleton/.github/workflows/ci.yaml` doesn't just build and push the image -
its `update-gitops` job commits the new `sha-<commit>` tag into
`gitops/services-values/<name>.yaml` in this repo after every successful
build on main. That commit is what ArgoCD's `selfHeal` actually reacts to;
pushing a new image to the same `latest` tag on its own does **not**
trigger a redeploy, since ArgoCD only watches git, not the registry.

This needs a **`GITOPS_DEPLOY_TOKEN` secret on each new service repo** - a
GitHub PAT (classic or fine-grained) with `repo` scope on
`beowolf23/infrastructure`, since the built-in `GITHUB_TOKEN` can only
write to the repo its own workflow runs in. Add it under the new repo's
Settings → Secrets and variables → Actions.

## Using it without Backstage

Nothing stops you from copying `skeleton/` by hand and manually replacing
the `${{ values.* }}` placeholders (`name`, `description`, `owner`,
`groupId`) - Backstage is the intended path, but it's not required.
