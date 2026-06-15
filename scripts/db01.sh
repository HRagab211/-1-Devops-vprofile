#!/bin/bash
set -euo pipefail

DB_USER="admin"
DB_PASSWORD="admin"
DB_NAME="accounts"

REPO_URL="https://github.com/hkhcoder/vprofile-project.git"
REPO_BRANCH="local"
REPO_DIR="/tmp/vprofile-project"

echo "=============================="
echo " Updating system"
echo "=============================="
sudo dnf update -y

echo "=============================="
echo " Installing required packages"
echo "=============================="
sudo dnf install -y git mariadb105 mariadb105-server

echo "=============================="
echo " Starting MariaDB"
echo "=============================="
sudo systemctl enable mariadb
sudo systemctl start mariadb

echo "=============================="
echo " Creating database and user"
echo "=============================="
sudo mariadb <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';

DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
EOF

echo "=============================="
echo " Cloning vprofile project"
echo "=============================="
cd /tmp

if [ -d "${REPO_DIR}/.git" ]; then
    echo "Repository already exists. Pulling latest changes..."
    cd "${REPO_DIR}"
    git fetch --all
    git checkout "${REPO_BRANCH}"
    git pull || true
else
    git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
    cd "${REPO_DIR}"
fi

echo "=============================="
echo " Importing database backup"
echo "=============================="
if [ ! -f "src/main/resources/db_backup.sql" ]; then
    echo "ERROR: db_backup.sql not found at src/main/resources/db_backup.sql"
    exit 1
fi

sudo mariadb "${DB_NAME}" < src/main/resources/db_backup.sql

echo "=============================="
echo " Restarting MariaDB"
echo "=============================="
sudo systemctl restart mariadb

echo "=============================="
echo " Testing database access"
echo "=============================="
mariadb -u "${DB_USER}" -p"${DB_PASSWORD}" -e "SHOW DATABASES;"

echo "=============================="
echo " Database setup completed"
echo "=============================="