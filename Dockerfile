# syntax=docker/dockerfile:1.7
#
# vprofile -- multi-stage image.
#
#   Stage 1 compiles the WAR from THIS checkout with Maven. Nothing prebuilt is used:
#           the host target/ directory is excluded by .dockerignore, so the only possible
#           source of the artifact is the `mvn package` run below.
#   Stage 2 packages that WAR into our own Tomcat runtime. No build tools ship in it.
#
# Build:  docker build -t vprofile-app:lab .
#         docker build -t vprofile-app:lab --build-arg GIT_SHA="$(git rev-parse HEAD)" .

# =============================================================================
# Stage 1 -- build
# =============================================================================
# Maven 3.9 on Eclipse Temurin JDK 17, matching pom.xml maven.compiler.source/target=17.
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /build

# Copy the POM on its own first so the dependency resolution layer is cached and only
# invalidated when pom.xml itself changes -- not on every source edit.
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2,sharing=locked \
    mvn -B -ntp dependency:go-offline

# Now the frequently changing sources. .dockerignore keeps target/, .git/, terraform,
# vagrant, ansible and secrets out of the context entirely.
COPY src ./src

# The real build, with tests enabled.
#
# NOTE on tests: src/test contains 4 JUnit 4 classes (11 methods, all pure POJO / standalone
# MockMvc -- no database or network). pom.xml declares junit-jupiter-engine but NOT
# junit-vintage-engine, so Surefire selects the JUnit Platform provider and the JUnit 4
# methods are not discovered. Expect the surefire output to report zero tests run. That is a
# pre-existing property of the POM, not something suppressed here: -DskipTests is deliberately
# NOT used, so any compilation or test failure fails this build.
RUN --mount=type=cache,target=/root/.m2,sharing=locked \
    mvn -B -ntp clean package

# Fail loudly if the expected artifact is missing. artifactId=vprofile, version=v2 and no
# <finalName>/<warName> in pom.xml, so the WAR is exactly target/vprofile-v2.war.
RUN test -f target/vprofile-v2.war \
 && echo "Built WAR: $(ls -l target/vprofile-v2.war)"

# Embed provenance INTO the WAR so the deployed application can prove which checkout it
# came from. See docs/container-lab.md ("Proving the WAR was built from this checkout").
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
RUN mkdir -p /build/warmeta/META-INF \
 && { \
      echo "git.commit=${GIT_SHA}"; \
      echo "build.timestamp=${BUILD_DATE}"; \
      echo "build.war=vprofile-v2.war"; \
      echo "build.maven=$(mvn -v | head -1)"; \
      echo "build.java=$(java -version 2>&1 | head -1)"; \
    } > /build/warmeta/META-INF/build-info.properties \
 && jar --update --file target/vprofile-v2.war -C /build/warmeta META-INF/build-info.properties \
 && cat /build/warmeta/META-INF/build-info.properties

# =============================================================================
# Stage 2 -- runtime
# =============================================================================
# Tomcat 10.1 = Jakarta Servlet 6.0 / JSP 3.1, which is the correct target for this app:
#   * Spring Framework 6.0.11 has a Servlet 6.0 baseline
#   * JSTL impl is org.glassfish.web:jakarta.servlet.jsp.jstl:2.0.0 (JSP 3.0/EE9 era) and the
#     JSPs use the legacy http://java.sun.com/jsp/jstl/core taglib URIs, which Tomcat 11 /
#     JSP 4.0 would not serve
#   * the repository's own deployments (vagrant/*/tomcat.sh, vprofile-ec2-user-data.sh) use 10.1
#
# JRE, not JDK: Jasper compiles JSPs with the Eclipse JDT compiler that Tomcat bundles
# (lib/ecj-4.27.jar), so javac is not needed at runtime. Dropping the JDK removes a compiler
# from the runtime image and shrinks it. Patch-pinned for reproducible rebuilds.
FROM tomcat:10.1.44-jre17-temurin AS runtime

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="vprofile-app" \
      org.opencontainers.image.description="VProfile Spring MVC/JSP application compiled from source and served by Tomcat 10.1 on JDK 17. Requires external MySQL, Memcached and RabbitMQ." \
      org.opencontainers.image.source="https://github.com/HRagab211/-1-Devops-vprofile" \
      org.opencontainers.image.documentation="https://github.com/HRagab211/-1-Devops-vprofile/blob/main/docs/container-lab.md" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="v2" \
      org.opencontainers.image.vendor="vprofile container lab" \
      org.opencontainers.image.licenses="NOASSERTION" \
      org.opencontainers.image.base.name="docker.io/library/tomcat:10.1.44-jre17-temurin"

# Remove the shipped example applications and documentation. The official image keeps them in
# webapps.dist and leaves webapps empty, but both are cleared so nothing but our app is served.
RUN rm -rf "${CATALINA_HOME}/webapps"/* "${CATALINA_HOME}/webapps.dist"

# curl is installed solely so HEALTHCHECK has an HTTP client. It is not a build tool; no
# compiler, Maven, git or source tree exists in this stage.
RUN set -eux; \
    if ! command -v curl >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends curl; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    curl --version | head -1

# Dedicated unprivileged account. Tomcat needs write access to webapps/ (it expands ROOT.war),
# work/ (Jasper JSP compilation output), temp/ and logs/.
#
# The recursive chown runs here, BEFORE the WAR is copied in: a `chown -R` after the COPY would
# rewrite the metadata of every file and duplicate the whole 83 MB artifact into an extra layer.
# The COPY steps below set their own ownership with --chown, so nothing is left root-owned.
RUN groupadd --system --gid 10001 tomcat \
 && useradd  --system --uid 10001 --gid 10001 --home-dir "${CATALINA_HOME}" --shell /usr/sbin/nologin tomcat \
 && chown -R tomcat:tomcat "${CATALINA_HOME}"

COPY --chmod=0755 docker/app/entrypoint.sh /usr/local/bin/entrypoint.sh

# Deploy as ROOT.war -- the application expects the root context. Every JSP builds links from
# ${pageContext.request.contextPath}, pom.xml's jetty plugin pins <contextPath>/</contextPath>,
# and ansible/vpro-app-setup.yml plus vagrant/*/tomcat.sh both install ROOT.war.
COPY --from=build --chown=10001:10001 /build/target/vprofile-v2.war "${CATALINA_HOME}/webapps/ROOT.war"

# A readable copy of the provenance file (the same content is also inside the WAR).
COPY --from=build --chown=10001:10001 /build/warmeta/META-INF/build-info.properties "${CATALINA_HOME}/conf/build-info.properties"

# JVM container awareness. JDK 17 enables UseContainerSupport by default; the percentages make
# the heap track the cgroup memory limit set by Compose/Kubernetes instead of the host's RAM.
# ExitOnOutOfMemoryError makes an OOM a restartable failure rather than a wedged process.
ENV CATALINA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError -Djava.awt.headless=true"

# Bounded wait for TCP dependencies; empty by default so Kubernetes probes can own startup.
ENV WAIT_FOR_TCP="" \
    WAIT_FOR_TIMEOUT="90"

USER 10001:10001

# Only the application port. MySQL/Memcached/RabbitMQ are external services.
EXPOSE 8080

# GET / is the login page (UserController @GetMapping("/") -> login.jsp) and returns 200 for
# anonymous users. It proves the root Spring context, the DispatcherServlet and Jasper all came
# up. Deliberately NOT /login: UserController only maps @PostMapping("/login"), so GET /login
# returns 405. Deliberately NOT /users: that would couple liveness to MySQL and Memcached.
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=5 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/ || exit 1

# entrypoint.sh execs catalina.sh, so the JVM is PID 1 and SIGTERM reaches Tomcat's shutdown
# hook for a graceful connector drain.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["catalina.sh", "run"]
