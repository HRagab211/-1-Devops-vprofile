#!/bin/bash
set -euo pipefail

exec > >(tee -a /var/log/builder-user-data.log | logger -t builder-user-data -s 2>/dev/console) 2>&1

# ==========================================================
# Config
# ==========================================================
REPO_URL="https://github.com/HRagab211/-1-Devops-vprofile.git"
REPO_BRANCH="main"
DIR_NAME="/tmp/-1-Devops-vprofile"

APP_EC2_USER="deploy"
REMOTE_WAR_PATH="/opt/deploy-inbox/ROOT.war"
REMOTE_DEPLOY_COMMAND="sudo /usr/local/bin/deploy-war.sh"

DB_NAME="accounts"
DB_USER="admin"
DB_PASSWORD="admin"

RABBITMQ_USER="test"
RABBITMQ_PASSWORD="test"

SSM_APP_IP_PARAM="/deploy/ec2a/private-ip"
SSM_APP_KEY_PARAM="/deploy/ec2a/ssh-private-key"
SSM_DB_IP_PARAM="/deploy/db/private-ip"
SSM_CACHE_IP_PARAM="/deploy/cache/private-ip"
SSM_RABBITMQ_IP_PARAM="/deploy/rabbitmq/private-ip"

MAVEN_VERSION="3.9.9"
MAVEN_HOME="/opt/maven"

SSH_DIR="/root/.ssh"
DEPLOY_KEY="$SSH_DIR/app01-deploy-key"

echo "=============================="
echo " Starting builder provisioning"
echo "=============================="

# ==========================================================
# Update system and install packages
# ==========================================================
dnf update -y

dnf install -y \
  java-17-amazon-corretto \
  java-17-amazon-corretto-devel \
  git \
  wget \
  tar \
  gzip \
  unzip \
  rsync \
  openssh-clients \
  awscli

# ==========================================================
# Get AWS region
# ==========================================================
IMDS_TOKEN="$(curl -fsS -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
  http://169.254.169.254/latest/api/token || true)"

if [ -n "$IMDS_TOKEN" ]; then
  IMDS_CURL="curl -fsS -H X-aws-ec2-metadata-token:$IMDS_TOKEN"
else
  IMDS_CURL="curl -fsS"
fi

INSTANCE_DOCUMENT="$($IMDS_CURL http://169.254.169.254/latest/dynamic/instance-identity/document)"
AWS_REGION="$(echo "$INSTANCE_DOCUMENT" | awk -F\" '/region/ {print $4}')"

echo "AWS Region: $AWS_REGION"

# ==========================================================
# Helper: get SSM parameter with retry
# ==========================================================
get_ssm_parameter() {
  local name="$1"
  local decrypt="${2:-false}"
  local value=""

  for attempt in $(seq 1 60); do
    if [ "$decrypt" = "true" ]; then
      value="$(aws ssm get-parameter \
        --name "$name" \
        --with-decryption \
        --region "$AWS_REGION" \
        --query "Parameter.Value" \
        --output text 2>/dev/null || true)"
    else
      value="$(aws ssm get-parameter \
        --name "$name" \
        --region "$AWS_REGION" \
        --query "Parameter.Value" \
        --output text 2>/dev/null || true)"
    fi

    if [ -n "$value" ] && [ "$value" != "None" ]; then
      echo "$value"
      return 0
    fi

    echo "Waiting for SSM parameter: $name ; attempt $attempt/60"
    sleep 10
  done

  echo "ERROR: Could not read SSM parameter: $name" >&2
  return 1
}

# ==========================================================
# Install Maven manually
# ==========================================================
echo "=============================="
echo " Installing Maven ${MAVEN_VERSION}"
echo "=============================="

cd /tmp

wget -q "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"

tar -xzf "apache-maven-${MAVEN_VERSION}-bin.tar.gz"

rm -rf "/opt/apache-maven-${MAVEN_VERSION}" "$MAVEN_HOME"

mv "apache-maven-${MAVEN_VERSION}" "/opt/apache-maven-${MAVEN_VERSION}"
ln -s "/opt/apache-maven-${MAVEN_VERSION}" "$MAVEN_HOME"

export PATH="$MAVEN_HOME/bin:$PATH"
export MAVEN_OPTS="-Xmx512m"

mvn -version

# ==========================================================
# Fetch infrastructure values from SSM
# ==========================================================
echo "=============================="
echo " Fetching deployment values from SSM"
echo "=============================="

APP_EC2_IP="$(get_ssm_parameter "$SSM_APP_IP_PARAM")"
DB_PRIVATE_IP="$(get_ssm_parameter "$SSM_DB_IP_PARAM")"
CACHE_PRIVATE_IP="$(get_ssm_parameter "$SSM_CACHE_IP_PARAM")"
RABBITMQ_PRIVATE_IP="$(get_ssm_parameter "$SSM_RABBITMQ_IP_PARAM")"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

get_ssm_parameter "$SSM_APP_KEY_PARAM" true > "$DEPLOY_KEY"
chmod 400 "$DEPLOY_KEY"

echo "app01 IP: $APP_EC2_IP"
echo "db01 IP: $DB_PRIVATE_IP"
echo "cache IP: $CACHE_PRIVATE_IP"
echo "rabbitmq IP: $RABBITMQ_PRIVATE_IP"

# ==========================================================
# Test SSH connection to app01
# ==========================================================
echo "=============================="
echo " Testing SSH to app01"
echo "=============================="

ssh -i "$DEPLOY_KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "$APP_EC2_USER@$APP_EC2_IP" \
  "hostname && whoami"

# ==========================================================
# Clone repository
# ==========================================================
echo "=============================="
echo " Cloning repository"
echo "=============================="

rm -rf "$DIR_NAME"

git clone \
  --branch "$REPO_BRANCH" \
  "$REPO_URL" \
  "$DIR_NAME"

cd "$DIR_NAME"

# ==========================================================
# Update application.properties
# ==========================================================
echo "=============================="
echo " Updating application.properties"
echo "=============================="

APP_PROPS="src/main/resources/application.properties"

if [ ! -f "$APP_PROPS" ]; then
  echo "ERROR: $APP_PROPS not found"
  exit 1
fi

set_property() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

set_property "jdbc.url" "jdbc:mysql://${DB_PRIVATE_IP}:3306/${DB_NAME}?useUnicode=true&characterEncoding=UTF-8&zeroDateTimeBehavior=convertToNull" "$APP_PROPS"
set_property "jdbc.username" "$DB_USER" "$APP_PROPS"
set_property "jdbc.password" "$DB_PASSWORD" "$APP_PROPS"

set_property "memcached.active.host" "$CACHE_PRIVATE_IP" "$APP_PROPS"
set_property "memcached.active.port" "11211" "$APP_PROPS"

set_property "rabbitmq.address" "$RABBITMQ_PRIVATE_IP" "$APP_PROPS"
set_property "rabbitmq.port" "5672" "$APP_PROPS"
set_property "rabbitmq.username" "$RABBITMQ_USER" "$APP_PROPS"
set_property "rabbitmq.password" "$RABBITMQ_PASSWORD" "$APP_PROPS"

# Fallback replacements if old hostnames are used somewhere else
sed -i "s/db01:3306/${DB_PRIVATE_IP}:3306/g" "$APP_PROPS"
sed -i "s/cache01/${CACHE_PRIVATE_IP}/g" "$APP_PROPS"
sed -i "s/mc01/${CACHE_PRIVATE_IP}/g" "$APP_PROPS"
sed -i "s/mq01/${RABBITMQ_PRIVATE_IP}/g" "$APP_PROPS"
sed -i "s/rmq01/${RABBITMQ_PRIVATE_IP}/g" "$APP_PROPS"

echo "Final application.properties important values:"
grep -E "jdbc.url|jdbc.username|jdbc.password|memcached|rabbitmq" "$APP_PROPS" || true

# ==========================================================
# Build project
# ==========================================================
echo "=============================="
echo " Building project"
echo "=============================="

mvn clean package -DskipTests

WAR_FILE="$(find target -maxdepth 1 -type f -name "*.war" | head -n 1)"

if [ -z "$WAR_FILE" ]; then
  echo "ERROR: No WAR file found in target/"
  exit 1
fi

echo "WAR file found: $WAR_FILE"

# ==========================================================
# Send WAR to app01
# ==========================================================
echo "=============================="
echo " Sending WAR to app01"
echo "=============================="

rsync -az \
  -e "ssh -i $DEPLOY_KEY -o StrictHostKeyChecking=accept-new" \
  "$WAR_FILE" \
  "$APP_EC2_USER@$APP_EC2_IP:$REMOTE_WAR_PATH"

# ==========================================================
# Run deploy script on app01
# ==========================================================
echo "=============================="
echo " Running deploy script on app01"
echo "=============================="

ssh -i "$DEPLOY_KEY" \
  -o StrictHostKeyChecking=accept-new \
  "$APP_EC2_USER@$APP_EC2_IP" \
  "$REMOTE_DEPLOY_COMMAND"

echo "=============================="
echo " Builder deployment completed successfully"
echo "Log file: /var/log/builder-user-data.log"
echo "=============================="