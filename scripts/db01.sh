#!/bin/bash
set -euo pipefail

exec > >(tee -a /var/log/db01-user-data.log | logger -t db01-user-data -s 2>/dev/console) 2>&1

# ==========================================================
# Config
# ==========================================================
DB_USER="admin"
DB_PASSWORD="admin"
DB_NAME="accounts"

REPO_URL="https://github.com/HRagab211/-1-Devops-vprofile.git"
REPO_BRANCH="main"
REPO_DIR="/tmp/-1-Devops-vprofile"

PUBLISH_TO_SSM="true"
SSM_DB_IP_PARAM="/deploy/db/private-ip"

echo "=============================="
echo " Starting db01 provisioning"
echo "=============================="

# ==========================================================
# Update system and install packages
# ==========================================================
dnf update -y

dnf install -y \
  git \
  awscli \
  mariadb105 \
  mariadb105-server \
  iproute

# ==========================================================
# Get metadata
# ==========================================================
IMDS_TOKEN="$(curl -fsS -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
  http://169.254.169.254/latest/api/token || true)"

if [ -n "$IMDS_TOKEN" ]; then
  IMDS_CURL="curl -fsS -H X-aws-ec2-metadata-token:$IMDS_TOKEN"
else
  IMDS_CURL="curl -fsS"
fi

PRIVATE_IP="$($IMDS_CURL http://169.254.169.254/latest/meta-data/local-ipv4)"
INSTANCE_DOCUMENT="$($IMDS_CURL http://169.254.169.254/latest/dynamic/instance-identity/document)"
AWS_REGION="$(echo "$INSTANCE_DOCUMENT" | awk -F\" '/region/ {print $4}')"

echo "Private IP: $PRIVATE_IP"
echo "AWS Region: $AWS_REGION"

# ==========================================================
# Configure MariaDB
# ==========================================================
cat > /etc/my.cnf.d/99-vprofile.cnf <<EOF
[mysqld]
bind-address=0.0.0.0
port=3306
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF

# ==========================================================
# Start MariaDB
# ==========================================================
systemctl enable --now mariadb

# ==========================================================
# Create database and user
# ==========================================================
mariadb <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';

DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
EOF

# ==========================================================
# Clone project and import DB
# ==========================================================
cd /tmp

if [ -d "${REPO_DIR}/.git" ]; then
  cd "${REPO_DIR}"
  git fetch --all
  git checkout "${REPO_BRANCH}"
  git pull origin "${REPO_BRANCH}" || true
else
  rm -rf "${REPO_DIR}"
  git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
  cd "${REPO_DIR}"
fi

DB_BACKUP_FILE="src/main/resources/db_backup.sql"

if [ ! -f "$DB_BACKUP_FILE" ]; then
  echo "ERROR: db_backup.sql not found at $DB_BACKUP_FILE"
  exit 1
fi

IMPORT_MARKER="/var/lib/db01-imported-${DB_NAME}"

if [ ! -f "$IMPORT_MARKER" ]; then
  mariadb "${DB_NAME}" < "$DB_BACKUP_FILE"
  touch "$IMPORT_MARKER"
  echo "Database imported successfully."
else
  echo "Database backup already imported before. Skipping import."
fi

systemctl restart mariadb

# ==========================================================
# Publish DB private IP to SSM
# ==========================================================
if [ "$PUBLISH_TO_SSM" = "true" ]; then
  if aws ssm put-parameter \
    --name "$SSM_DB_IP_PARAM" \
    --type "String" \
    --value "$PRIVATE_IP" \
    --overwrite \
    --region "$AWS_REGION"; then
    echo "DB private IP published to SSM: $SSM_DB_IP_PARAM"
  else
    echo "WARNING: Could not publish DB private IP to SSM. Check IAM role permissions."
  fi
fi

# ==========================================================
# Test
# ==========================================================
mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SHOW DATABASES;"
mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e "SHOW TABLES;" || true

echo "=============================="
echo " db01 provisioning completed"
echo "Private IP: $PRIVATE_IP"
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo "Password: $DB_PASSWORD"
echo "JDBC host: $PRIVATE_IP:3306"
echo "Log file: /var/log/db01-user-data.log"
echo "=============================="

ss -lntp | grep 3306 || true