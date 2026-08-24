pipeline {
    agent any

    tools {
        jdk 'JDK17'
        maven 'MAVEN3.9'
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 45, unit: 'MINUTES')
    }

    parameters {
        booleanParam(
            name: 'PUBLISH_TO_NEXUS',
            defaultValue: false,
            description: 'Publish the generated WAR and pom.xml to Nexus'
        )
    }

    environment {
        NEXUS_VERSION       = 'nexus3'
        NEXUS_PROTOCOL      = 'http'
        NEXUS_URL           = '172.31.40.209:8081'
        NEXUS_REPOSITORY    = 'vprofile-release'
        NEXUS_CREDENTIAL_ID = 'nexuslogin'

        MAVEN_ARGS = '--batch-mode --no-transfer-progress -Dmaven.wagon.http.retryHandler.count=3'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        /*
         * Maven verify performs compilation, unit tests, integration tests
         * configured through Maven Failsafe, packaging and verification.
         *
         * This avoids running clean install, test and verify separately.
         */
        stage('Build and Test') {
            steps {
                retry(3) {
                    sh '''
                        set -eu

                        # Remove incomplete Maven downloads left by an interrupted run.
                        find "$HOME/.m2/repository" -type f \
                            \\( -name "*.lastUpdated" -o -name "*.part" \\) \
                            -delete 2>/dev/null || true

                        mvn $MAVEN_ARGS clean verify
                    '''
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

        stage('Checkstyle Analysis') {
            steps {
                sh '''
                    set -eu
                    mvn $MAVEN_ARGS checkstyle:checkstyle
                '''
            }

            post {
                success {
                    echo 'Checkstyle analysis report generated.'
                    archiveArtifacts(
                        artifacts: '**/target/checkstyle-result.xml,**/target/site/checkstyle.html',
                        allowEmptyArchive: true
                    )
                }
            }
        }

        stage('SonarQube Analysis') {
            environment {
                SCANNER_HOME = tool 'sonarscanner4'
            }

            steps {
                withSonarQubeEnv('sonar-pro') {
                    sh '''
                        set -eu

                        SONAR_EXTRA_ARGS=""

                        if [ -f target/site/jacoco/jacoco.xml ]; then
                            SONAR_EXTRA_ARGS="$SONAR_EXTRA_ARGS \
-Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml"
                        fi

                        if [ -f target/checkstyle-result.xml ]; then
                            SONAR_EXTRA_ARGS="$SONAR_EXTRA_ARGS \
-Dsonar.java.checkstyle.reportPaths=target/checkstyle-result.xml"
                        fi

                        "$SCANNER_HOME/bin/sonar-scanner" \
                            -Dsonar.projectKey=vprofile \
                            -Dsonar.projectName=vprofile-repo \
                            -Dsonar.projectVersion="$BUILD_NUMBER" \
                            -Dsonar.sources=src/main \
                            -Dsonar.tests=src/test \
                            -Dsonar.java.binaries=target/classes \
                            -Dsonar.junit.reportPaths=target/surefire-reports \
                            $SONAR_EXTRA_ARGS
                    '''
                }
            }
        }

        stage('SonarQube Quality Gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Publish to Nexus') {
            when {
                expression {
                    return params.PUBLISH_TO_NEXUS
                }
            }

            steps {
                script {
                    def pom = readMavenPom(file: 'pom.xml')
                    def artifacts = findFiles(
                        glob: "target/*.${pom.packaging}"
                    )

                    if (artifacts.length == 0) {
                        error(
                            "No target/*.${pom.packaging} artifact was found."
                        )
                    }

                    if (artifacts.length > 1) {
                        error(
                            "Multiple ${pom.packaging} artifacts were found: " +
                            artifacts.collect { it.path }.join(', ')
                        )
                    }

                    def artifactPath = artifacts[0].path
                    def artifactVersion =
                        "${pom.version}-${env.BUILD_NUMBER}"

                    echo """
Publishing to Nexus:
  File:       ${artifactPath}
  Group ID:   ${pom.groupId}
  Artifact:   ${pom.artifactId}
  Version:    ${artifactVersion}
  Packaging:  ${pom.packaging}
  Repository: ${env.NEXUS_REPOSITORY}
"""

                    nexusArtifactUploader(
                        nexusVersion: env.NEXUS_VERSION,
                        protocol: env.NEXUS_PROTOCOL,
                        nexusUrl: env.NEXUS_URL,
                        repository: env.NEXUS_REPOSITORY,
                        credentialsId: env.NEXUS_CREDENTIAL_ID,
                        groupId: pom.groupId,
                        version: artifactVersion,
                        artifacts: [
                            [
                                artifactId: pom.artifactId,
                                classifier: '',
                                file: artifactPath,
                                type: pom.packaging
                            ],
                            [
                                artifactId: pom.artifactId,
                                classifier: '',
                                file: 'pom.xml',
                                type: 'pom'
                            ]
                        ]
                    )
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline completed successfully.'
        }

        failure {
            echo 'Pipeline failed. Review the failed stage above.'
        }

        cleanup {
            deleteDir()
        }
    }
}
