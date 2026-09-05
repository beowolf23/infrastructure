# syntax=docker/dockerfile:1

FROM eclipse-temurin:25-jdk-alpine AS build
WORKDIR /workspace

# Cache dependency resolution separately from source changes.
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B dependency:go-offline

COPY src/ src/
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -DskipTests package \
 && java -Djarmode=tools -jar target/*.jar extract \
      --layers dependencies,application \
      --destination extracted

# Pin the OTel Java agent - the shared spring-boot-app Helm chart sets
# JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar and expects
# it here. Check github.com/open-telemetry/opentelemetry-java-instrumentation
# releases for newer versions; pin a version, not "latest", for reproducible
# builds.
FROM curlimages/curl:8.22.0 AS otel-agent
RUN curl -sSLo /tmp/opentelemetry-javaagent.jar \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.31.1/opentelemetry-javaagent.jar

FROM eclipse-temurin:25-jre-alpine
WORKDIR /app

RUN addgroup -S app && adduser -S app -G app
USER app

COPY --from=otel-agent --chown=app:app /tmp/opentelemetry-javaagent.jar /otel/opentelemetry-javaagent.jar

# The application jar is thin - its manifest Class-Path points at a
# sibling lib/ directory, so dependency jars (rarely change - cached
# layer) and the app jar (changes every build) stay in separate COPY
# layers, matching the layout the manifest expects. (No snapshot-dependencies
# layer - add one back if a dependency ever pins a -SNAPSHOT version.)
COPY --from=build --chown=app:app /workspace/extracted/dependencies/lib/ ./lib/
COPY --from=build --chown=app:app /workspace/extracted/application/*.jar ./app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
