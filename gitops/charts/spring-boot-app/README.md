# spring-boot-app

Generic chart for a standard Spring Boot service. A team using this only
needs to write their app, a Dockerfile that follows the contract below, and
a small values file - everything else (health probes, metrics, logs) is
wired in by the chart.

## The Dockerfile contract

This chart sets `JAVA_TOOL_OPTIONS=-javaagent:<otel.javaagent.path>`
(default `/otel/opentelemetry-javaagent.jar`) whenever
`otel.javaagent.enabled` is true (the default). Your image needs to put the
[OpenTelemetry Java agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation)
jar at that exact path. In your Dockerfile:

```dockerfile
FROM eclipse-temurin:21-jre
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar
COPY target/my-app.jar /app/app.jar
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

The agent auto-instruments Spring/JVM, captures Logback/Log4j2 output, and
ships everything via OTLP with zero code changes in the app itself - this
is why `javaagent.enabled` is required for logs, and is the easiest way to
get metrics too.

Your app also needs Spring Boot Actuator on the classpath
(`spring-boot-starter-actuator`) for the liveness/readiness probes to work -
nothing else needs configuring, the chart sets the env vars that expose the
health groups.

## Minimal values.yaml for an app

```yaml
image:
  repository: ghcr.io/your-org/your-app
  tag: "1.4.2"

env:
  SPRING_PROFILES_ACTIVE: prod
```

## Wiring it into gitops

Add an ArgoCD Application referencing this chart by local path, plus your
values file, the same way `platform/*.yaml` references remote charts:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: your-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: services
  source:
    repoURL: https://github.com/beowolf23/infrastructure.git
    targetRevision: main
    path: gitops/charts/spring-boot-app
    helm:
      valueFiles:
        - ../../services-values/your-app.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: services
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## What's NOT handled yet

- **Traces**: `otel.traces.enabled` defaults to `false` - there's no tracing
  backend in the cluster yet. Once one exists (e.g. Tempo), flip it on; the
  agent is already capturing spans, they're just not being exported.
- **Ingress/HPA**: not included - add them to this chart when a real app
  needs them, rather than guessing at the shape now.
