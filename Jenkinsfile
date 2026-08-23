pipeline {
    agent {
        kubernetes {
            defaultContainer 'maven'

            yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins

  containers:
    - name: maven
      image: maven:3.9-eclipse-temurin-17
      command:
        - cat
      tty: true

    - name: docker
      image: docker:27-cli
      command:
        - cat
      tty: true
      env:
        - name: DOCKER_HOST
          value: tcp://localhost:2375
        - name: DOCKER_TLS_CERTDIR
          value: ""

    - name: dind
      image: docker:27-dind
      securityContext:
        privileged: true
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""

    - name: kubectl
      image: docker.io/alpine/k8s:1.36.4
      imagePullPolicy: IfNotPresent
      command:
        - sh
        - -c
        - cat
      tty: true
'''
        }
    }

    triggers {
    pollSCM('H/2 * * * *')
    }

    options {
        // timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        DOCKERHUB_REPOSITORY = 'YOUR_DOCKERHUB_USERNAME/vprofile-app'
        DOCKERHUB_CREDENTIALS = 'dockerhub-credentials'

        K8S_NAMESPACE = 'vprofile'
        K8S_DEPLOYMENT = 'vprofile-app'
        K8S_CONTAINER = 'app'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm

                script {
                    env.GIT_SHORT_COMMIT = sh(
                        script: 'git rev-parse --short=8 HEAD',
                        returnStdout: true
                    ).trim()

                    env.IMAGE_TAG = "${BUILD_NUMBER}-${GIT_SHORT_COMMIT}"
                    env.VERSIONED_IMAGE =
                        "${DOCKERHUB_REPOSITORY}:${IMAGE_TAG}"
                }

                echo "Building ${VERSIONED_IMAGE}"
            }
        }

        stage('Verify') {
            steps {
                container('maven') {
                    sh '''
                        mvn --batch-mode clean test
                    '''
                }
            }
        }

        stage('Build image') {
            steps {
                container('docker') {
                    sh '''
                        timeout 120 sh -c \
                          'until docker info >/dev/null 2>&1; do sleep 2; done'

                        docker build \
                          --tag "${VERSIONED_IMAGE}" \
                          --tag "${DOCKERHUB_REPOSITORY}:latest" \
                          .
                    '''
                }
            }
        }

        stage('Push image') {
            steps {
                container('docker') {
                    withCredentials([
                        usernamePassword(
                            credentialsId: env.DOCKERHUB_CREDENTIALS,
                            usernameVariable: 'DOCKERHUB_USERNAME',
                            passwordVariable: 'DOCKERHUB_TOKEN'
                        )
                    ]) {
                        sh '''
                            echo "${DOCKERHUB_TOKEN}" |
                              docker login \
                                --username "${DOCKERHUB_USERNAME}" \
                                --password-stdin

                            docker push "${VERSIONED_IMAGE}"
                            docker push "${DOCKERHUB_REPOSITORY}:latest"
                            docker logout
                        '''
                    }
                }
            }
        }

        stage('Deploy') {
            steps {
                container('kubectl') {
                    sh '''
                        kubectl set image \
                          deployment/${K8S_DEPLOYMENT} \
                          ${K8S_CONTAINER}=${VERSIONED_IMAGE} \
                          --namespace=${K8S_NAMESPACE}

                        kubectl rollout status \
                          deployment/${K8S_DEPLOYMENT} \
                          --namespace=${K8S_NAMESPACE} \
                          --timeout=300s
                    '''
                }
            }
        }

        stage('Verify deployment') {
            steps {
                container('kubectl') {
                    sh '''
                        kubectl get deployment,pods,service \
                          --namespace=${K8S_NAMESPACE} \
                          -o wide

                        kubectl get deployment/${K8S_DEPLOYMENT} \
                          --namespace=${K8S_NAMESPACE} \
                          -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}'

                        echo
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Successfully deployed ${VERSIONED_IMAGE}"
        }

        failure {
            container('kubectl') {
                sh '''
                    kubectl get pods \
                      --namespace=${K8S_NAMESPACE} \
                      -o wide || true

                    kubectl get events \
                      --namespace=${K8S_NAMESPACE} \
                      --sort-by=.lastTimestamp |
                      tail -30 || true
                '''
            }
        }

        always {
            cleanWs()
        }
    }
}
