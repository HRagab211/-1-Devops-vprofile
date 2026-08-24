pipeline {
    agent {
        kubernetes {
            defaultContainer 'maven'

            yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-deployer

  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: maven
      image: docker.io/maven:3.9-eclipse-temurin-17
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
          cpu: 300m
          memory: 768Mi
        limits:
          cpu: "2"
          memory: 2Gi

    - name: buildkit
      image: docker.io/moby/buildkit:v0.27.0-rootless
      imagePullPolicy: IfNotPresent
      command: ["cat"]
      tty: true
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
      securityContext:
        privileged: false
        runAsUser: 1000
        runAsGroup: 1000
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
          cpu: 300m
          memory: 768Mi
        limits:
          cpu: "2"
          memory: 2Gi

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

    triggers {
        // Check the configured jenkins branch every two minutes.
        pollSCM('H/2 * * * *')
    }

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 45, unit: 'MINUTES')
    }

    environment {
        REGISTRY_IMAGE = 'docker.io/hragab211/profile-app'

        K8S_NAMESPACE  = 'vprofile'
        K8S_DEPLOYMENT = 'vprofile-app'
        APP_CONTAINER  = 'vprofile-app'

        MAVEN_ARGS = '--batch-mode --no-transfer-progress -Dmaven.wagon.http.retryHandler.count=3'
    }

    stages {
        stage('Checkout Jenkins Branch') {
            steps {
                script {
                    def scmVariables = checkout scm

                    def checkedOutBranch =
                        scmVariables.GIT_BRANCH ?: env.BRANCH_NAME ?: ''

                    checkedOutBranch = checkedOutBranch
                        .replaceFirst('^origin/', '')
                        .replaceFirst('^refs/remotes/origin/', '')

                    if (checkedOutBranch != 'jenkins') {
                        error(
                            "Deployment is allowed only from the jenkins branch. " +
                            "Checked out branch: ${checkedOutBranch}"
                        )
                    }

                    env.GIT_COMMIT_SHORT =
                        scmVariables.GIT_COMMIT.take(12)

                    env.IMAGE_TAG =
                        "${env.GIT_COMMIT_SHORT}-${env.BUILD_NUMBER}"

                    env.FULL_IMAGE =
                        "${env.REGISTRY_IMAGE}:${env.IMAGE_TAG}"

                    echo """
Branch:     ${checkedOutBranch}
Commit:     ${scmVariables.GIT_COMMIT}
Image:      ${env.FULL_IMAGE}
Latest tag: ${env.REGISTRY_IMAGE}:latest
"""
                }
            }
        }

        stage('Resolve Dependencies') {
            steps {
                container('maven') {
                    timeout(time: 10, unit: 'MINUTES') {
                        retry(3) {
                            sh '''
                                set -eu

                                find "$HOME/.m2/repository" -type f \
                                    \\( -name "*.lastUpdated" -o -name "*.part" \\) \
                                    -delete 2>/dev/null || true

                                mvn $MAVEN_ARGS dependency:go-offline
                            '''
                        }
                    }
                }
            }
        }

        stage('Build and Test Application') {
            steps {
                container('maven') {
                    timeout(time: 20, unit: 'MINUTES') {
                        sh '''
                            set -eu

                            mvn $MAVEN_ARGS clean verify

                            WAR_FILE="$(find target -maxdepth 1 \
                                -type f -name "*.war" | head -1)"

                            if [ -z "$WAR_FILE" ]; then
                                echo "No WAR file was created in target/"
                                find target -maxdepth 2 -type f || true
                                exit 1
                            fi

                            echo "Generated WAR: $WAR_FILE"
                        '''
                    }
                }
            }

            post {
                always {
                    junit(
                        testResults: '**/target/surefire-reports/*.xml,**/target/failsafe-reports/*.xml',
                        allowEmptyResults: true
                    )
                }

                success {
                    archiveArtifacts(
                        artifacts: '**/target/*.war',
                        fingerprint: true,
                        onlyIfSuccessful: true
                    )
                }
            }
        }

        stage('Build and Push Docker Image') {
            steps {
                container('buildkit') {
                    timeout(time: 20, unit: 'MINUTES') {
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'dockerhub-login',
                                usernameVariable: 'DOCKERHUB_USERNAME',
                                passwordVariable: 'DOCKERHUB_TOKEN'
                            )
                        ]) {
                            sh '''
                                set -eu

                                test -f Dockerfile || {
                                    echo "Dockerfile was not found in the repository root."
                                    exit 1
                                }

                                mkdir -p "$DOCKER_CONFIG"
                                chmod 700 "$DOCKER_CONFIG"

                                AUTH="$(
                                    printf '%s' \
                                        "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" |
                                    base64 |
                                    tr -d '\\n'
                                )"

                                umask 077

                                printf \
                                  '{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}\\n' \
                                  "$AUTH" > "$DOCKER_CONFIG/config.json"

                                trap 'rm -f "$DOCKER_CONFIG/config.json"' EXIT

                                echo "Building $FULL_IMAGE"

                                buildctl-daemonless.sh build \
                                    --progress plain \
                                    --frontend dockerfile.v0 \
                                    --local context="$WORKSPACE" \
                                    --local dockerfile="$WORKSPACE" \
                                    --opt filename=Dockerfile \
                                    --output "type=image,\\"name=${FULL_IMAGE},${REGISTRY_IMAGE}:latest\\",push=true" \
                                    --export-cache type=inline

                                echo "Pushed:"
                                echo "  $FULL_IMAGE"
                                echo "  $REGISTRY_IMAGE:latest"
                            '''
                        }
                    }
                }
            }
        }

        stage('Apply Kubernetes Changes') {
            steps {
                container('kubectl') {
                    script {
                        sh 'mkdir -p .jenkins-deploy'

                        /*
                         * Create a temporary Kustomize overlay.
                         * Nothing is committed back to Git.
                         */
                        writeFile(
                            file: '.jenkins-deploy/kustomization.yaml',
                            text: """\
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../kubernetes

images:
  - name: docker.io/hragab211/profile-app
    newName: ${env.REGISTRY_IMAGE}
    newTag: ${env.IMAGE_TAG}
"""
                        )
                    }

                    sh '''
                        set -eu

                        echo "Checking Kubernetes access..."

                        kubectl auth can-i patch deployments \
                            -n "$K8S_NAMESPACE" |
                        grep -q '^yes$' || {
                            echo "jenkins-deployer cannot patch deployments."
                            exit 1
                        }

                        echo "Applying Kubernetes manifests..."

                        kubectl apply -k .jenkins-deploy

                        # Explicitly ensure the Deployment uses the immutable image.
                        kubectl set image \
                            "deployment/$K8S_DEPLOYMENT" \
                            "$APP_CONTAINER=$FULL_IMAGE" \
                            -n "$K8S_NAMESPACE"

                        kubectl annotate \
                            "deployment/$K8S_DEPLOYMENT" \
                            -n "$K8S_NAMESPACE" \
                            kubernetes.io/change-cause="Jenkins build $BUILD_NUMBER - $FULL_IMAGE" \
                            --overwrite
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            steps {
                container('kubectl') {
                    timeout(time: 7, unit: 'MINUTES') {
                        sh '''
                            set -eu

                            if ! kubectl rollout status \
                                "deployment/$K8S_DEPLOYMENT" \
                                -n "$K8S_NAMESPACE" \
                                --timeout=5m
                            then
                                echo "Deployment failed. Rolling back..."

                                kubectl rollout undo \
                                    "deployment/$K8S_DEPLOYMENT" \
                                    -n "$K8S_NAMESPACE"

                                kubectl rollout status \
                                    "deployment/$K8S_DEPLOYMENT" \
                                    -n "$K8S_NAMESPACE" \
                                    --timeout=5m || true

                                exit 1
                            fi

                            DEPLOYED_IMAGE="$(
                                kubectl get deployment "$K8S_DEPLOYMENT" \
                                    -n "$K8S_NAMESPACE" \
                                    -o jsonpath="{.spec.template.spec.containers[?(@.name=='$APP_CONTAINER')].image}"
                            )"

                            if [ "$DEPLOYED_IMAGE" != "$FULL_IMAGE" ]; then
                                echo "Unexpected deployed image: $DEPLOYED_IMAGE"
                                echo "Expected image: $FULL_IMAGE"
                                exit 1
                            fi

                            kubectl get pods \
                                -n "$K8S_NAMESPACE" \
                                -l app=vprofile-app \
                                -o wide

                            echo "Successfully deployed $FULL_IMAGE"
                        '''
                    }
                }
            }
        }

        stage('Application Check') {
            steps {
                container('kubectl') {
                    sh '''
                        set -eu

                        curl --fail --silent --show-error \
                            --location \
                            --retry 5 \
                            --retry-delay 5 \
                            http://vprofile-nginx.vprofile.svc.cluster.local/ \
                            >/dev/null

                        echo "Application HTTP check passed."
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "CI/CD completed successfully: ${env.FULL_IMAGE}"
        }

        failure {
            echo 'CI/CD failed. Check the failed stage output.'
        }

        cleanup {
            deleteDir()
        }
    }
}
