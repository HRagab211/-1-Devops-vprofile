# Jenkins CI/CD for VProfile

How `Jenkinsfile` in this repository builds, publishes and deploys the application, and
why it is shaped the way it is. Everything below was verified against the running lab on
2026-08-23; the commands that produced each claim are included so you can re-run them.

## The lab

| | |
|---|---|
| Cluster | kubeadm on Vagrant, `v1.36.4`, CRI-O `1.36.3`, Ubuntu 22.04, kernel 5.15 |
| Nodes | `master01` 192.168.56.15, `worker01` 192.168.56.14, `worker02` 192.168.56.13 |
| Jenkins | Helm chart, namespace `helm`, controller pod `jenkins-0`, UI on NodePort 32000 |
| Build agents | ephemeral pods, namespace `helm` |
| Application | namespace `vprofile` |
| Public entry point | Service `vprofile-nginx`, NodePort `30080` |
| Job | `vprofile-app`, plain Pipeline job, SCM `https://github.com/HRagab211/-1-Devops-vprofile`, branch `*/jenkins` |

Build agents stay in `helm`. The application stays in `vprofile`. The pipeline never moves
either one.

## Pipeline stages

| # | Stage | Container | Gated | What it does |
|---|---|---|---|---|
| 1 | Checkout | jnlp | no | `checkout scm`; derives and validates the commit SHA, build number and image reference; computes the deploy gate |
| 2 | Validate environment | maven, buildkit, kubectl | no | Proves every tool the later stages call actually exists in its container |
| 3 | Verify cluster access | kubectl | yes | `kubectl auth can-i` allow **and** deny checks; confirms `Deployment/vprofile-app` exists and has exactly one container named `app` |
| 4 | Build and test | maven | no | `mvn --batch-mode --no-transfer-progress clean verify`, then asserts `target/vprofile-v2.war` exists |
| 5 | Build image | buildkit | partly | Rootless BuildKit builds from `Dockerfile`. Gate closed: build only, nothing exported. Gate open: build **and push** in one operation |
| 6 | Deploy | kubectl | yes | Records the current image, `kubectl set image`, `rollout status`, verifies the live image, then the smoke test. Rolls back on any failure |

Stage 3 runs before Maven deliberately: a missing RBAC grant fails in seconds instead of
after a multi-minute build.

## Deployment gating

Two independent conditions, both required, before anything is pushed or deployed:

1. the build is on the branch named by the `DEPLOY_BRANCH` parameter (default `jenkins`,
   taken from the branch the Jenkins job is actually configured to track), **and**
2. the `DEPLOY_TO_VPROFILE` boolean parameter is `true` (default **`false`**).

So the default build — including every poll-triggered build and every feature branch —
compiles, tests and builds the image, and publishes nothing. Deploying is a deliberate
"Build with Parameters" action.

No `input` step is used. An interactive approval would hang every unattended poll-triggered
build until it timed out, which in a lab is worse than useless; the parameter provides the
same "a human decided this" property without blocking automation.

## Plugin dependencies

Installed plugins were read directly from the controller:

```bash
kubectl -n helm exec jenkins-0 -c jenkins -- ls /var/jenkins_home/plugins
```

Every non-core step the Jenkinsfile uses, and its provider:

| Step / construct | Provided by | Installed |
|---|---|---|
| `pipeline { }`, `stages`, `options`, `parameters`, `when`, `post` | `pipeline-model-definition` | yes |
| `sh`, `echo`, `error`, `timeout`, `retry`, `script` | `workflow-basic-steps`, `workflow-cps`, `workflow-durable-task-step` | yes |
| `checkout scm` | `workflow-scm-step` + `git` | yes |
| `withCredentials(usernamePassword(...))` | `credentials-binding` | yes |
| `agent { kubernetes { yaml ... } }`, `container(...)` | `kubernetes` | yes |
| `disableConcurrentBuilds()`, `buildDiscarder(logRotator(...))`, `skipDefaultCheckout()` | Jenkins core | n/a |
| `triggers { pollSCM(...) }` | Jenkins core (`SCMTrigger`) | n/a |

Deliberately **not** used, because the providing plugin is **not** installed:

| Step | Plugin | Replacement here |
|---|---|---|
| `timestamps()` | `timestamper` | plain console output |
| `cleanWs()` | `ws-cleanup` | nothing to replace — the agent pod and its `emptyDir` workspace are deleted when the build ends |
| `githubPush()` | `github` | `pollSCM('H/5 * * * *')` |
| `junit()` | `junit` | Maven fails the stage on a test failure; Surefire XML stays in the console log |
| `docker.withRegistry()` | `docker-workflow` (installed, but unused) | a `config.json` written from `withCredentials` — no Docker daemon exists to talk to |
| `withSonarQubeEnv()`, `waitForQualityGate()`, `dependencyCheckPublisher()`, `recordIssues()` | various | not used at all |

`options { timeout(...) }` needs no `build-timeout` plugin: declarative maps it onto the
core `timeout` step.

The Jenkinsfile was validated by this controller's own declarative linter:

```bash
curl -s -u "$USER:$PASS" -b /tmp/ck -H "Jenkins-Crumb: $CRUMB" \
  -X POST -F "jenkinsfile=<Jenkinsfile" \
  http://<jenkins>:8080/pipeline-model-converter/validate
# -> Jenkinsfile successfully validated.
```

## Why rootless BuildKit and not Docker-in-Docker

The previous pipeline ran a `docker:27-dind` sidecar with `privileged: true` and a
`docker:27-cli` container pointed at it over `tcp://localhost:2375`.

A privileged container shares the host kernel with all capabilities and an unmasked
`/dev`. Anyone able to change `Jenkinsfile` — which is just a commit on a branch Jenkins
polls — could therefore execute as root on `worker01` or `worker02`. The plaintext
daemon socket on localhost was additionally reachable by every other container in the
agent pod. Mounting the host's `/var/run/docker.sock` would be worse still, and is not
used anywhere here.

**Kaniko was rejected**: Google archived the project, and it does not support the
`# syntax=docker/dockerfile:1.7` directive or the `RUN --mount=type=cache` instructions
this repository's `Dockerfile` actually uses.

**Rootless BuildKit was chosen**: actively maintained, daemonless, needs no Docker socket,
and is the reference implementation of the Dockerfile frontend, so every feature the
existing `Dockerfile` uses works unchanged.

It was proved to work on this cluster before being committed — an unprivileged pod that
really executed a `RUN` step:

```bash
kubectl run ... --image=docker.io/moby/buildkit:v0.27.0-rootless   # privileged: false
# #5 [2/2] RUN echo hello > /x && cat /x
# #5 0.109 hello
# #5 DONE 0.2s
# BUILDKIT_ROOTLESS_OK
```

The builder container is **not privileged** and drops all capabilities. Three relaxations
remain, and each is the documented minimum:

| Setting | Why it is needed | Why it is not a host escape |
|---|---|---|
| `allowPrivilegeEscalation: true` | the setuid binary `/usr/bin/newuidmap` writes the uid/gid map. With `no_new_privs` set it fails `operation not permitted` — this was observed, not assumed | it only lets an in-image setuid binary work; it grants nothing on the host |
| `capabilities: add: [SETUID, SETGID]` | `newuidmap` needs them in the bounding set to raise its own privileges | two capabilities scoped to the container's own user namespace, with `ALL` dropped first |
| `seccompProfile`/`appArmorProfile: Unconfined` | `unshare(CLONE_NEWUSER)` and the nested mounts the builder performs inside its own user namespace | the process still runs as uid 1000 in an unprivileged user namespace |

Compare with what was removed: no `privileged: true`, no host socket, no Docker daemon, no
`CAP_SYS_ADMIN`. The host prerequisites (`kernel.unprivileged_userns_clone=1`,
`user.max_user_namespaces=7690`) were confirmed on `worker01`.

## Agent pod

Four containers: the implicit `jnlp` sidecar plus `maven`, `buildkit` and `kubectl`.

| Container | Image | Verified |
|---|---|---|
| maven | `docker.io/maven:3.9-eclipse-temurin-17` | matches `pom.xml` `maven.compiler.source/target=17` |
| buildkit | `docker.io/moby/buildkit:v0.27.0-rootless` | exists, `linux/amd64`, real build executed on this cluster |
| kubectl | `docker.io/alpine/k8s:1.36.2` | exists, `linux/amd64` + `arm64`, contains `/bin/sh`, `kubectl v1.36.2`, `curl` |

`docker.io/alpine/k8s:1.36.4` **does not exist** — `docker manifest inspect` returns not
found. `1.36.2` is one patch behind the `v1.36.4` API server, well inside the supported
kubectl skew. A distroless kubectl image cannot be used at all, because Jenkins runs every
`sh` step through a shell.

The tool-image check that was actually run:

```bash
kubectl run kubectl-image-test -n helm --image=docker.io/alpine/k8s:1.36.2 \
  --restart=Never --command -- sh -c 'kubectl version --client && which sh kubectl curl && echo IMAGE_OK'
kubectl logs kubectl-image-test -n helm
kubectl delete pod kubectl-image-test -n helm
```

Pod hardening:

* dedicated `jenkins-deployer` ServiceAccount — not `default`, not the `jenkins` controller
  account (which can create pods in `helm`)
* `runAsNonRoot: true`, uid/gid/fsGroup `1000` for every container, so all containers share
  the workspace `emptyDir` as the same user
* `seccompProfile: RuntimeDefault` at pod level; only the builder container overrides it
* `capabilities: drop: [ALL]` everywhere; only the builder adds SETUID/SETGID
* no `hostNetwork`, no `hostPID`, no `hostIPC`, no `hostPath`, no `/var/run/docker.sock`
* CPU and memory requests and limits on every container
* every volume is an `emptyDir` that dies with the build

`maven` and `kubectl` get `HOME=/home/jenkins/agent` because their images default to root
and `/root` is not writable at uid 1000. This also puts Maven's `~/.m2` in the per-build
workspace: a cache with no shared writable storage.

## RBAC

`kubernetes/jenkins-deployer-rbac.yaml` creates a ServiceAccount in `helm`, a Role in
`vprofile`, and a RoleBinding in `vprofile` whose subject is the `helm` ServiceAccount.
That cross-namespace subject is what lets agents stay in `helm` while the application
stays in `vprofile`.

It is **not** in `kustomization.yaml`, deliberately: that kustomization pins
`namespace: vprofile`, which would rewrite the ServiceAccount into the wrong namespace,
and RBAC is a one-off cluster grant that an application build must never reconcile.

Apply it once, as an administrator:

```bash
kubectl apply -f kubernetes/jenkins-deployer-rbac.yaml
```

Granted: `list`/`watch` on Deployments (read-only, and unrestricted because
`rollout status` watches the collection and a collection watch cannot be narrowed by
`resourceNames`); `get`/`patch`/`update` on **`deployments/vprofile-app` only**;
read-only ReplicaSets, Pods, pod logs, Events, Services and Endpoints.

Not granted, each omission load-bearing: `cluster-admin`, any wildcard apiGroup/resource/
verb, Secrets, ConfigMaps, PVCs, PVs, StatefulSets, Namespaces, `pods/exec`,
`pods/portforward`, pod deletion, and any `create` or `delete` on the Deployment.

The `resourceNames: ["vprofile-app"]` restriction is what *mechanically* prevents the
pipeline from patching `vprofile-nginx`, `vprofile-cache` or `vprofile-rabbitmq`, rather
than merely asking it not to. `vprofile-db` is a StatefulSet and is not in the Role at all.

Verify — the first three must say `yes`, the rest must say `no`:

```bash
SA=system:serviceaccount:helm:jenkins-deployer

kubectl auth can-i get   deployment/vprofile-app  -n vprofile --as=$SA   # yes
kubectl auth can-i patch deployment/vprofile-app  -n vprofile --as=$SA   # yes
kubectl auth can-i list  pods                     -n vprofile --as=$SA   # yes

kubectl auth can-i delete pvc                       -n vprofile --as=$SA # no
kubectl auth can-i get    secrets                   -n vprofile --as=$SA # no
kubectl auth can-i delete namespace                 -n vprofile --as=$SA # no
kubectl auth can-i patch  statefulset/vprofile-db   -n vprofile --as=$SA # no
kubectl auth can-i patch  deployment/vprofile-nginx -n vprofile --as=$SA # no
kubectl auth can-i '*'    '*'                       -n vprofile --as=$SA # no
kubectl auth can-i create pods                      -n vprofile --as=$SA # no
```

The pipeline runs the same allow **and** deny checks itself, from the agent's own token,
in the "Verify cluster access" stage, and fails if a denial unexpectedly succeeds.

## Deployment behaviour

Ordinary delivery changes exactly one field:

```bash
kubectl set image deployment/vprofile-app app=<registry>/<repo>:<sha>-<build> -n vprofile
kubectl rollout status deployment/vprofile-app -n vprofile --timeout=300s
```

The container name `app` is read from `kubernetes/app-deployment.yaml` and re-verified at
run time; the pipeline refuses to proceed unless the Deployment has exactly one container
with that name.

`kubectl apply -k kubernetes/` is **not** run on application builds. A client dry-run
shows exactly why:

```
$ kubectl apply --dry-run=client -k kubernetes/
secret/vprofile-secret          configured   <-- rewrites credentials
deployment.apps/vprofile-app    configured   <-- reverts the image to the placeholder
statefulset.apps/vprofile-db    configured   <-- touches the database
```

`app-deployment.yaml` still carries `image: YOUR_REGISTRY/YOUR_VPROFILE_IMAGE:YOUR_TAG`, so
an `apply -k` during delivery would replace the freshly deployed image with an unpullable
placeholder. Use `apply -k` only when you intend to reconcile the whole stack, by hand.

MySQL, Memcached, RabbitMQ, nginx, PVCs, Secrets and ConfigMaps are never referenced by
the pipeline, and RBAC would refuse it anyway.

## Smoke test

Read-only `GET /` through the existing nginx Service, after the rollout reports success.

The default `VPROFILE_SMOKE_URL` is the in-cluster Service DNS name
`http://vprofile-nginx.vprofile.svc.cluster.local/`, so no node IP is hardcoded and the
test still goes through nginx. The NodePort form `http://192.168.56.15:30080/` works too
and can be passed as the parameter.

`GET /` is correct and was confirmed live: `/` returns **200** (the login page — it touches
no backing service), while `/login` returns **405**, because `UserController` only maps
`@PostMapping("/login")`. 200 is the only accepted status. Nothing is submitted, no
credential is sent, no data changes.

Bounds: `--connect-timeout 5`, `--max-time 20`, at most 5 attempts 10s apart, all inside a
5-minute stage `timeout`.

## Rollback

`kubectl set image`, `rollout status`, the live-image check and the smoke test all run
inside one `try`. On any failure the pipeline:

1. collects read-only diagnostics — pod states, Deployment conditions, the last 30
   namespace events, the last 100 lines of application logs;
2. runs `kubectl rollout undo deployment/vprofile-app -n vprofile`;
3. waits for the rollback with `rollout status --timeout=300s`;
4. prints the image it landed back on;
5. fails the build.

It never deletes pods to "fix" a rollout, never deletes or recreates the Deployment, and
never touches a namespace, PVC or PV.

## Timeouts and concurrency

`disableConcurrentBuilds()` prevents overlapping deployments. Overall build timeout 30
minutes, plus stage-level bounds: cluster checks 3 min, Maven 20 min, image build and push
25 min, rollout 8 min, smoke test 5 min. There is no `retry` around Maven or the image
build — a deterministic code failure must not be retried. The smoke test's 5 bounded
attempts are the only retry loop.

## Credentials

| Jenkins credential ID | Kind | Used for |
|---|---|---|
| `dockerhub-credentials` | Username with password | authenticating to the registry for the image push |

The ID is a parameter (`REGISTRY_CREDENTIALS_ID`); no secret value appears in this
repository. At push time it is bound with `withCredentials` and written to a
`config.json` under `DOCKER_CONFIG` in the ephemeral workspace at `umask 077`, removed by
a shell `trap` however the shell exits.

The credential never reaches a process argument: the `printf` that builds the auth string
is a shell builtin, so nothing appears in `/proc/<pid>/cmdline`. `set -x` is never used in
a shell that holds a credential.

## Registry and image policy

| Parameter | Default | Source |
|---|---|---|
| `REGISTRY_HOST` | `docker.io` | the image running in the cluster |
| `REGISTRY_REPOSITORY` | `hragab211/profile-app` | discovered — this is what `Deployment/vprofile-app` is running right now |
| `REGISTRY_CREDENTIALS_ID` | `dockerhub-credentials` | the only credential in the Jenkins store |

> The repository default was **discovered from the running cluster**, not chosen. The old
> Jenkinsfile carried a different, unresolved placeholder
> (`YOUR_DOCKERHUB_USERNAME/vprofile-app`). Confirm `hragab211/profile-app` is where you
> want CI to publish, or override the parameter.

Tags are `<8-char-git-sha>-<build-number>` — immutable, and derived only from values
Jenkins controls. `latest` is never pushed and never deployed. Before the build starts, the
pipeline rejects a commit SHA that is not 40 hex characters, a non-numeric build number,
and an image reference that fails a syntax check.

## Known limitations

* **Tests compile but none execute.** `src/test` holds 4 JUnit **4** classes, while
  `pom.xml` declares `junit-jupiter-engine` without `junit-vintage-engine`. Surefire
  selects the JUnit Platform provider and discovers zero tests, so `clean verify` reports
  `Tests run: 0`. `-DskipTests` is *not* used and a real failure would still fail the
  build — the suite is simply not being discovered. Fixing it means adding
  `junit-vintage-engine` to `pom.xml`, which is an application dependency change and out of
  scope for this pipeline work.
* **The application is compiled twice** — once by the `mvn verify` test gate, once inside
  the `Dockerfile`'s builder stage. That is the `Dockerfile`'s deliberate provenance
  design (its `.dockerignore` excludes `target/` so the WAR can only come from the
  in-container build). The cost is build time, not correctness.
* **BuildKit's cache is per-build.** The `emptyDir` dies with the pod, so every build pulls
  base layers again. A persistent cache would mean shared writable storage between builds,
  which is a larger security decision than it looks.
* **Polling, not webhooks.** Jenkins is on a private Vagrant network. Builds start within 5
  minutes of a push, not instantly.

## Commands to run before the first deployment

```bash
# 1. Grant the pipeline its identity (once, as cluster admin)
kubectl apply -f kubernetes/jenkins-deployer-rbac.yaml

# 2. Confirm least privilege
SA=system:serviceaccount:helm:jenkins-deployer
kubectl auth can-i patch deployment/vprofile-app -n vprofile --as=$SA   # expect: yes
kubectl auth can-i delete pvc                    -n vprofile --as=$SA   # expect: no

# 3. Confirm the registry credential exists and can push to the chosen repository
#    (Jenkins > Manage Jenkins > Credentials: ID `dockerhub-credentials`)

# 4. Dry run: build with DEPLOY_TO_VPROFILE = false.
#    Compiles, tests and builds the image. Pushes nothing, deploys nothing.

# 5. Real delivery: on branch `jenkins`, Build with Parameters,
#    DEPLOY_TO_VPROFILE = true.
```
