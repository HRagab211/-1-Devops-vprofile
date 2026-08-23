// =============================================================================
// VProfile -- CI/CD pipeline
// =============================================================================
//
// Build agents run as ephemeral pods in namespace `helm`. The application is delivered
// into namespace `vprofile`. Neither namespace moves.
//
// This file deliberately uses ONLY steps provided by plugins verified as installed on
// this controller (see docs/jenkins-cicd.md, "Plugin dependencies"):
//
//   workflow-*, pipeline-model-definition ... declarative pipeline, sh, echo, script,
//                                             timeout, retry, error, writeFile, readFile
//   git / workflow-scm-step ................. checkout scm
//   credentials-binding ..................... withCredentials
//   kubernetes .............................. agent { kubernetes { ... } }
//
// NOT used, because the providing plugin is NOT installed here:
//   timestamps()   -> timestamper       cleanWs()  -> ws-cleanup
//   githubPush()   -> github            junit()    -> junit
// The agent pod and its workspace are destroyed when the build ends, so there is nothing
// for cleanWs() to clean; plain console output replaces timestamps().

pipeline {

    // -------------------------------------------------------------------------
    // Agent -- three tool containers plus the implicit `jnlp` sidecar.
    // -------------------------------------------------------------------------
    // No `docker` CLI container and no privileged `dind` sidecar: image building is done
    // by rootless BuildKit, which needs no Docker daemon and no host socket. See
    // docs/jenkins-cicd.md, "Why rootless BuildKit and not Docker-in-Docker".
    agent {
        kubernetes {
            defaultContainer 'maven'
            // The pod is created in the namespace the Jenkins Kubernetes cloud is
            // configured for (`helm`). It is NOT pinned here, so this file never
            // silently relocates build agents.
            yaml '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    app.kubernetes.io/name: jenkins-agent
    app.kubernetes.io/part-of: vprofile-ci
spec:
  # Dedicated identity, created by kubernetes/jenkins-deployer-rbac.yaml. NOT the
  # namespace `default` account, and NOT the `jenkins` controller account (which can
  # create pods in `helm` -- a power the agent has no reason to inherit).
  serviceAccountName: jenkins-deployer
  automountServiceAccountToken: true
  restartPolicy: Never

  # No hostNetwork, no hostPID, no hostIPC, no hostPath volume, no docker.sock.
  # Every volume in this pod is an emptyDir that dies with the build.
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  containers:
    # -- Java 17 / Maven 3.9, matching pom.xml maven.compiler.source/target=17 ----
    - name: maven
      image: docker.io/maven:3.9-eclipse-temurin-17
      imagePullPolicy: IfNotPresent
      command: ["cat"]
      tty: true
      # The image defaults to root, whose HOME is /root and unwritable at uid 1000.
      # Pointing HOME at the shared workspace gives Maven a writable ~/.m2 that is
      # per-build and dies with the pod -- a cache with no shared writable storage.
      env:
        - name: HOME
          value: /home/jenkins/agent
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 2Gi

    # -- Rootless BuildKit: daemonless OCI image builder --------------------------
    - name: buildkit
      image: docker.io/moby/buildkit:v0.27.0-rootless
      imagePullPolicy: IfNotPresent
      command: ["cat"]
      tty: true
      env:
        # Without a process sandbox buildkitd does not need CAP_SYS_ADMIN. This is what
        # lets the container run unprivileged.
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
        # Registry credentials are written here at run time, mode 0600, and removed in the
        # same shell. HOME stays /home/user: rootlesskit needs its own ~/.local.
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
      securityContext:
        privileged: false
        runAsUser: 1000
        runAsGroup: 1000
        # Each of the three relaxations below is the documented minimum for rootless
        # BuildKit, and none of them grants host access:
        #   allowPrivilegeEscalation -- setuid /usr/bin/newuidmap must be able to run;
        #                               with no_new_privs it fails "operation not permitted"
        #   SETUID/SETGID            -- the caps newuidmap needs to write the uid/gid map
        #   seccomp/AppArmor         -- unshare(CLONE_NEWUSER) and the nested mounts the
        #                               builder performs inside its own user namespace
        # Everything else is dropped. Verified on this cluster; see docs/jenkins-cicd.md.
        allowPrivilegeEscalation: true
        capabilities:
          drop: ["ALL"]
          add: ["SETUID", "SETGID"]
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
      volumeMounts:
        - name: buildkit-state
          mountPath: /home/user/.local/share/buildkit
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 3Gi

    # -- kubectl + curl -----------------------------------------------------------
    # docker.io/alpine/k8s:1.36.2 -- verified on this cluster to exist for linux/amd64
    # and to contain /bin/sh, kubectl v1.36.2 and curl. There is no 1.36.4 tag, and a
    # distroless kubectl image cannot be used because Jenkins runs every step via `sh`.
    - name: kubectl
      image: docker.io/alpine/k8s:1.36.2
      imagePullPolicy: IfNotPresent
      command: ["cat"]
      tty: true
      env:
        - name: HOME
          value: /home/jenkins/agent
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi

  volumes:
    - name: buildkit-state
      emptyDir: {}
'''
        }
    }

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameters {
        booleanParam(
            name: 'DEPLOY_TO_VPROFILE',
            defaultValue: false,
            description: 'Push the image and roll Deployment/vprofile-app in namespace ' +
                         'vprofile. Ignored unless the build is also on DEPLOY_BRANCH. ' +
                         'When false the build compiles, tests and builds the image ' +
                         'without exporting or deploying anything.'
        )
        string(
            name: 'DEPLOY_BRANCH',
            defaultValue: 'jenkins',
            description: 'The only branch allowed to push and deploy. Default taken from ' +
                         'the branch this Jenkins job is configured to track (*/jenkins).'
        )
        string(
            name: 'REGISTRY_HOST',
            defaultValue: 'docker.io',
            description: 'Container registry host.'
        )
        string(
            name: 'REGISTRY_REPOSITORY',
            defaultValue: 'hragab211/profile-app',
            description: 'Repository within REGISTRY_HOST. Default discovered from the ' +
                         'image currently running in Deployment/vprofile-app. Change it ' +
                         'if CI should publish somewhere else.'
        )
        string(
            name: 'REGISTRY_CREDENTIALS_ID',
            defaultValue: 'dockerhub-credentials',
            description: 'Jenkins username/password credential used to authenticate to ' +
                         'the registry. Only the ID appears here -- never the secret.'
        )
        string(
            name: 'VPROFILE_SMOKE_URL',
            defaultValue: 'http://vprofile-nginx.vprofile.svc.cluster.local/',
            description: 'Read-only smoke-test URL, reached through the existing nginx ' +
                         'Service. The in-cluster DNS name is the default so no node IP ' +
                         'is hardcoded. NodePort alternative: http://192.168.56.15:30080/'
        )
    }

    // -------------------------------------------------------------------------
    // Triggers -- polling, not webhooks.
    // -------------------------------------------------------------------------
    // Jenkins is reachable only on a private Vagrant network, so GitHub cannot deliver a
    // webhook to it; githubPush() would also require the (uninstalled) GitHub plugin.
    // pollSCM is core SCMTrigger functionality and needs no plugin.
    triggers {
        pollSCM('H/5 * * * *')
    }

    // -------------------------------------------------------------------------
    // Options -- all core / installed-plugin functionality.
    // -------------------------------------------------------------------------
    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        skipDefaultCheckout(true)
    }

    environment {
        K8S_NAMESPACE  = 'vprofile'
        K8S_DEPLOYMENT = 'vprofile-app'
        // Verified against the live manifest: kubernetes/app-deployment.yaml declares a
        // single container literally named `app`. Not an assumption -- re-verified at run
        // time by the 'Validate environment' stage before anything is changed.
        K8S_CONTAINER  = 'app'
        // pom.xml: artifactId=vprofile, version=v2, no <finalName>.
        WAR_PATH       = 'target/vprofile-v2.war'
    }

    stages {

        // =====================================================================
        stage('Checkout') {
        // =====================================================================
            steps {
                script {
                    // skipDefaultCheckout(true) above means this is the only checkout, so
                    // the revision below is exactly what the rest of the build uses.
                    def scmVars = checkout scm

                    def sha = (scmVars.GIT_COMMIT ?: '').trim()
                    if (!(sha ==~ /^[0-9a-f]{40}$/)) {
                        error("Refusing to build: SCM returned no usable commit SHA " +
                              "(got '${sha}'). An immutable image tag cannot be derived.")
                    }
                    if (!(env.BUILD_NUMBER ==~ /^[0-9]+$/)) {
                        error("Refusing to build: BUILD_NUMBER '${env.BUILD_NUMBER}' " +
                              "is not numeric.")
                    }

                    env.GIT_FULL_SHA  = sha
                    env.GIT_SHORT_SHA = sha.take(8)

                    // A plain (non-multibranch) job leaves BRANCH_NAME unset, so the
                    // branch is derived from the SCM result: "origin/jenkins" -> "jenkins".
                    def rawBranch = (scmVars.GIT_BRANCH ?: env.BRANCH_NAME ?: '').trim()
                    env.GIT_BRANCH_NAME = rawBranch.replaceFirst(/^origin\//, '')

                    env.IMAGE_TAG = "${env.GIT_SHORT_SHA}-${env.BUILD_NUMBER}"
                    env.IMAGE_REF = "${params.REGISTRY_HOST}/" +
                                    "${params.REGISTRY_REPOSITORY}:${env.IMAGE_TAG}"

                    // Reject a malformed reference now rather than at push time.
                    if (!(env.IMAGE_REF ==~ /^[A-Za-z0-9._:-]+(\/[A-Za-z0-9._-]+)+:[A-Za-z0-9._-]{1,128}$/)) {
                        error("Refusing to build: '${env.IMAGE_REF}' is not a valid " +
                              "image reference. Check REGISTRY_HOST / REGISTRY_REPOSITORY.")
                    }

                    // The single gate guarding every mutating action in this pipeline.
                    env.DEPLOY_ALLOWED = (params.DEPLOY_TO_VPROFILE &&
                                          env.GIT_BRANCH_NAME == params.DEPLOY_BRANCH)
                                         ? 'true' : 'false'

                    echo """
                    Commit ......... ${env.GIT_FULL_SHA}
                    Branch ......... ${env.GIT_BRANCH_NAME}
                    Image .......... ${env.IMAGE_REF}
                    Deploy branch .. ${params.DEPLOY_BRANCH}
                    Deploy request . ${params.DEPLOY_TO_VPROFILE}
                    Push + deploy .. ${env.DEPLOY_ALLOWED}
                    """.stripIndent()

                    if (env.DEPLOY_ALLOWED != 'true') {
                        echo 'Gate CLOSED: this build will compile, test and build the ' +
                             'image only. Nothing is pushed and nothing is deployed.'
                    }
                }
            }
        }

        // =====================================================================
        stage('Validate environment') {
        // =====================================================================
            steps {
                container('maven') {
                    sh 'set -eu; mvn --version; java -version'
                }
                container('buildkit') {
                    sh 'set -eu; buildctl --version; command -v buildctl-daemonless.sh'
                }
                container('kubectl') {
                    // Read-only. Nothing here changes cluster state.
                    sh '''
                        set -eu
                        kubectl version --client
                        curl --version | head -1
                    '''
                }
            }
        }

        // =====================================================================
        stage('Verify cluster access') {
        // =====================================================================
            // Fails fast, before Maven burns several minutes, if RBAC is missing or the
            // Deployment does not look the way this pipeline expects.
            when { expression { env.DEPLOY_ALLOWED == 'true' } }
            steps {
                container('kubectl') {
                    timeout(time: 3, unit: 'MINUTES') {
                        sh '''
                            set -eu

                            echo "--- permissions that MUST be granted ---"
                            kubectl auth can-i get   deployment/vprofile-app -n "${K8S_NAMESPACE}"
                            kubectl auth can-i patch deployment/vprofile-app -n "${K8S_NAMESPACE}"
                            kubectl auth can-i list  pods                    -n "${K8S_NAMESPACE}"

                            echo "--- permissions that MUST be denied ---"
                            # `can-i` exits non-zero on "no", which is the desired answer
                            # here, so each check is inverted explicitly.
                            for probe in "delete pvc" "get secrets" "delete namespace" \
                                         "patch statefulset/vprofile-db" \
                                         "patch deployment/vprofile-nginx"; do
                                # shellcheck disable=SC2086
                                if kubectl auth can-i $probe -n "${K8S_NAMESPACE}" >/dev/null 2>&1; then
                                    echo "FAIL: the deployer ServiceAccount can '$probe' in ${K8S_NAMESPACE}."
                                    echo "      That exceeds least privilege. Re-apply kubernetes/jenkins-deployer-rbac.yaml."
                                    exit 1
                                fi
                                echo "denied (correct): $probe"
                            done

                            echo "--- target Deployment ---"
                            kubectl get deployment "${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" >/dev/null

                            # Exactly one container, and it is the one we intend to update.
                            names=$(kubectl get deployment "${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" \
                                      -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\\n"}{end}')
                            count=$(printf '%s\\n' "$names" | grep -c . )
                            if [ "$count" -ne 1 ] || [ "$names" != "${K8S_CONTAINER}" ]; then
                                echo "FAIL: expected exactly one container named '${K8S_CONTAINER}', found: $names"
                                exit 1
                            fi
                            echo "container to update: ${K8S_CONTAINER}"
                        '''
                    }
                }
            }
        }

        // =====================================================================
        stage('Build and test') {
        // =====================================================================
            steps {
                container('maven') {
                    timeout(time: 20, unit: 'MINUTES') {
                        // `verify`, not `test`: it runs the full lifecycle through the war
                        // plugin, so the artifact the image will contain is actually
                        // produced. -DskipTests is deliberately NOT used -- a test failure
                        // fails this stage and the build stops here.
                        sh '''
                            set -eu
                            mvn --batch-mode --no-transfer-progress clean verify
                        '''
                    }
                    // The image build compiles independently inside the Dockerfile, so this
                    // stage is the test gate; the WAR check confirms the build is coherent.
                    sh '''
                        set -eu
                        test -f "${WAR_PATH}" || {
                            echo "FAIL: expected artifact ${WAR_PATH} was not produced."
                            exit 1
                        }
                        ls -l "${WAR_PATH}"
                    '''
                }
            }
        }

        // =====================================================================
        stage('Build image') {
        // =====================================================================
            steps {
                container('buildkit') {
                    timeout(time: 25, unit: 'MINUTES') {
                        script {
                            // Gate closed -> build to validate the Dockerfile, export
                            // nothing. Gate open -> build and push in one step, so the
                            // pushed digest is exactly what was just built.
                            if (env.DEPLOY_ALLOWED != 'true') {
                                sh '''
                                    set -eu
                                    buildctl-daemonless.sh build \
                                      --frontend dockerfile.v0 \
                                      --local context=. \
                                      --local dockerfile=. \
                                      --opt filename=Dockerfile \
                                      --opt build-arg:GIT_SHA="${GIT_FULL_SHA}" \
                                      --opt build-arg:BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                      --progress=plain
                                    echo "Image built and discarded (deploy gate is closed)."
                                '''
                            } else {
                                withCredentials([usernamePassword(
                                    credentialsId: params.REGISTRY_CREDENTIALS_ID,
                                    usernameVariable: 'REGISTRY_USERNAME',
                                    passwordVariable: 'REGISTRY_PASSWORD'
                                )]) {
                                    // `set -eu`, never `set -x`: tracing this shell would
                                    // echo the credential into the console log.
                                    sh '''
                                        set -eu

                                        umask 077
                                        mkdir -p "${DOCKER_CONFIG}"
                                        # Remove the auth file however this shell exits.
                                        trap 'rm -f "${DOCKER_CONFIG}/config.json"' EXIT INT TERM

                                        # `printf` is a shell builtin here, so the secret is
                                        # never an argv of a separate process and never
                                        # appears in /proc/<pid>/cmdline. `base64 | tr -d`
                                        # rather than `base64 -w0`: this image is BusyBox,
                                        # whose base64 applet has no -w.
                                        auth=$(printf '%s:%s' "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" | base64 | tr -d '\\n')

                                        # Docker Hub is addressed by its legacy index URL in
                                        # docker config; other registries by their host.
                                        if [ "${REGISTRY_HOST}" = "docker.io" ]; then
                                            key="https://index.docker.io/v1/"
                                        else
                                            key="${REGISTRY_HOST}"
                                        fi

                                        printf '{"auths":{"%s":{"auth":"%s"}}}' "$key" "$auth" \
                                          > "${DOCKER_CONFIG}/config.json"
                                        unset auth

                                        buildctl-daemonless.sh build \
                                          --frontend dockerfile.v0 \
                                          --local context=. \
                                          --local dockerfile=. \
                                          --opt filename=Dockerfile \
                                          --opt build-arg:GIT_SHA="${GIT_FULL_SHA}" \
                                          --opt build-arg:BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                          --output type=image,name="${IMAGE_REF}",push=true \
                                          --progress=plain

                                        echo "Pushed ${IMAGE_REF}"
                                    '''
                                }
                            }
                        }
                    }
                }
            }
        }

        // =====================================================================
        stage('Deploy') {
        // =====================================================================
            when { expression { env.DEPLOY_ALLOWED == 'true' } }
            steps {
                container('kubectl') {
                    script {
                        // Recorded before anything changes, so the rollback path can report
                        // exactly what it is returning to.
                        env.PREVIOUS_IMAGE = sh(
                            returnStdout: true,
                            script: '''
                                set -eu
                                kubectl get deployment "${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" \
                                  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${K8S_CONTAINER}')].image}"
                            '''
                        ).trim()
                        echo "Currently deployed: ${env.PREVIOUS_IMAGE}"
                        echo "Rolling out to ...: ${env.IMAGE_REF}"

                        try {
                            timeout(time: 8, unit: 'MINUTES') {
                                sh '''
                                    set -eu
                                    # Only the image of one container of one Deployment.
                                    # MySQL, Memcached, RabbitMQ, nginx, Secrets, ConfigMaps
                                    # and PVCs are never referenced. No `apply -k` here:
                                    # ordinary delivery must not reconcile the whole stack.
                                    kubectl set image \
                                      "deployment/${K8S_DEPLOYMENT}" \
                                      "${K8S_CONTAINER}=${IMAGE_REF}" \
                                      -n "${K8S_NAMESPACE}"

                                    kubectl rollout status \
                                      "deployment/${K8S_DEPLOYMENT}" \
                                      -n "${K8S_NAMESPACE}" \
                                      --timeout=300s
                                '''
                            }

                            // Confirm the Deployment really carries the intended tag.
                            sh '''
                                set -eu
                                live=$(kubectl get deployment "${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" \
                                        -o jsonpath="{.spec.template.spec.containers[?(@.name=='${K8S_CONTAINER}')].image}")
                                echo "Deployment reports: $live"
                                [ "$live" = "${IMAGE_REF}" ] || {
                                    echo "FAIL: expected ${IMAGE_REF}"
                                    exit 1
                                }
                            '''

                            // -------- Smoke test: read-only, through nginx ---------------
                            // GET / is the login page. Verified on this cluster: / -> 200
                            // (and /login -> 405, which is why it is not the target). No
                            // form is submitted, no credential is sent, no data changes.
                            timeout(time: 5, unit: 'MINUTES') {
                                sh '''
                                    set -eu
                                    url="${VPROFILE_SMOKE_URL}"
                                    echo "Smoke testing ${url}"

                                    attempt=1
                                    max=5
                                    while [ "$attempt" -le "$max" ]; do
                                        code=$(curl --silent --show-error \
                                                    --output /dev/null \
                                                    --write-out '%{http_code}' \
                                                    --connect-timeout 5 \
                                                    --max-time 20 \
                                                    "$url" || echo "000")
                                        echo "attempt ${attempt}/${max}: HTTP ${code}"
                                        # 200 is the only accepted status.
                                        if [ "$code" = "200" ]; then
                                            echo "Smoke test passed."
                                            exit 0
                                        fi
                                        attempt=$((attempt + 1))
                                        [ "$attempt" -le "$max" ] && sleep 10
                                    done

                                    echo "FAIL: smoke test never returned 200."
                                    exit 1
                                '''
                            }

                        } catch (err) {
                            echo "Rollout or smoke test failed: ${err}"

                            // ---- Diagnostics: read-only, no pod deletion --------------
                            sh '''
                                set +e
                                echo "===== pods ====="
                                kubectl get pods -n "${K8S_NAMESPACE}" -o wide \
                                  -l app.kubernetes.io/name=vprofile-app
                                echo "===== rollout ====="
                                kubectl describe deployment "${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" \
                                  | sed -n '/Conditions:/,/Events:/p'
                                echo "===== recent events ====="
                                kubectl get events -n "${K8S_NAMESPACE}" \
                                  --sort-by=.lastTimestamp | tail -30
                                echo "===== application logs ====="
                                kubectl logs -n "${K8S_NAMESPACE}" \
                                  -l app.kubernetes.io/name=vprofile-app \
                                  --all-containers --tail=100 --prefix
                                exit 0
                            '''

                            // ---- Roll back and wait for it ----------------------------
                            echo "Rolling back to ${env.PREVIOUS_IMAGE}"
                            sh '''
                                set -eu
                                kubectl rollout undo "deployment/${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}"
                                kubectl rollout status "deployment/${K8S_DEPLOYMENT}" \
                                  -n "${K8S_NAMESPACE}" --timeout=300s
                                echo "Rolled back to: $(kubectl get deployment "${K8S_DEPLOYMENT}" \
                                  -n "${K8S_NAMESPACE}" \
                                  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${K8S_CONTAINER}')].image}")"
                            '''

                            error("Deployment failed and was rolled back to " +
                                  "${env.PREVIOUS_IMAGE}. See the diagnostics above.")
                        }
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Post -- echo only.
    // -------------------------------------------------------------------------
    // Nothing here runs `sh`, kubectl or any filesystem step: a global post block also
    // executes when the agent pod never started, and an `sh` there would fail the build
    // for a second, misleading reason. cleanWs() is absent by design -- the agent pod and
    // its emptyDir workspace are deleted when the build ends.
    post {
        success {
            echo 'Pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed. Review the stage logs above.'
        }
        aborted {
            echo 'Pipeline was aborted.'
        }
        always {
            echo "Final result: ${currentBuild.currentResult}"
        }
    }
}
