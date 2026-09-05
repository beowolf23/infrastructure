# ${{ values.name }}

${{ values.description }}

Generated from [spring-boot-template](https://github.com/beowolf23/spring-boot-template) - Java 25, Spring Boot 4.

## Local development

```sh
./mvnw spring-boot:run
curl localhost:8080/api/greeting
```

## Test

```sh
./mvnw verify
```

Runs unit tests, the `@WebMvcTest` slice test, and the Spotless format check.
Run `./mvnw spotless:apply` to auto-fix formatting.

## Build the image

```sh
docker build -t ${{ values.name }} .
docker run -p 8080:8080 ${{ values.name }}
```

## Observability

Metrics and logs leave via the OpenTelemetry Java agent (baked into the
image at `/otel/opentelemetry-javaagent.jar`) - no code in this repo talks
to Prometheus or Loki directly. See the
[spring-boot-app chart README](https://github.com/beowolf23/infrastructure/blob/main/gitops/charts/spring-boot-app/README.md)
for how that's wired up, and how to disable it (`otel.enabled: false`) if
you need to.

Health probes use Spring Boot's Actuator liveness/readiness groups
(`/actuator/health/liveness`, `/actuator/health/readiness`) - the chart
points Kubernetes probes at these already.

## Deploying

This app is meant to be deployed via the shared `spring-boot-app` Helm
chart in the infrastructure repo, not its own chart. See that chart's
README for the ArgoCD Application snippet to add.
