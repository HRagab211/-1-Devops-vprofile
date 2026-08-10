#!/bin/bash
set -euo pipefail

exec > >(tee -a /var/log/app01-user-data.log | logger -t app01-user-data -s 2>/dev/console) 2>&1

# ==========================================================
# Config
# ==========================================================
TOMCAT_VERSION="9.0.118"
TOMCAT_MAJOR="9"
TOMCAT_HOME="/usr/local/tomcat"

DEPLOY_USER="deploy"
SSM_PREFIX="/deploy/ec2a"

echo "=============================="
echo " Starting app01 provisioning"
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
  sudo \
  openssh-server \
  awscli \
  iproute

systemctl enable --now sshd

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
# Install Tomcat
# ==========================================================
echo "=============================="
echo " Installing Tomcat ${TOMCAT_VERSION}"
echo "=============================="

cd /tmp

wget -q "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"

mkdir -p "$TOMCAT_HOME"

if ! id tomcat >/dev/null 2>&1; then
  useradd --system --home-dir "$TOMCAT_HOME" --shell /sbin/nologin tomcat
fi

tar xzf "apache-tomcat-${TOMCAT_VERSION}.tar.gz" -C /tmp

cp -a "/tmp/apache-tomcat-${TOMCAT_VERSION}/." "$TOMCAT_HOME/"

chown -R tomcat:tomcat "$TOMCAT_HOME"
chmod +x "$TOMCAT_HOME"/bin/*.sh

JAVA_BIN="$(readlink -f /usr/bin/java)"
JAVA_HOME_PATH="${JAVA_BIN%/bin/java}"

cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tomcat
Group=tomcat
WorkingDirectory=$TOMCAT_HOME

Environment=JAVA_HOME=$JAVA_HOME_PATH
Environment=CATALINA_HOME=$TOMCAT_HOME
Environment=CATALINA_BASE=$TOMCAT_HOME
Environment=CATALINA_PID=$TOMCAT_HOME/temp/tomcat.pid

ExecStart=$TOMCAT_HOME/bin/catalina.sh run
ExecStop=$TOMCAT_HOME/bin/catalina.sh stop

Restart=always
RestartSec=10
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tomcat

# ==========================================================
# Create deploy user
# ==========================================================
echo "=============================="
echo " Creating deploy user"
echo "=============================="

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi

DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"

# ==========================================================
# Generate deploy SSH key
# ==========================================================
echo "=============================="
echo " Generating deploy SSH key"
echo "=============================="

DEPLOY_KEY="$DEPLOY_HOME/.ssh/app01-deploy-key"

if [ ! -f "$DEPLOY_KEY" ]; then
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "app01-deploy-key"
fi

cat "$DEPLOY_KEY.pub" >> "$DEPLOY_HOME/.ssh/authorized_keys"
sort -u "$DEPLOY_HOME/.ssh/authorized_keys" -o "$DEPLOY_HOME/.ssh/authorized_keys"

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
chmod 600 "$DEPLOY_HOME/.ssh/authorized_keys"
chmod 400 "$DEPLOY_KEY"

# ==========================================================
# Create deploy inbox
# ==========================================================
echo "=============================="
echo " Creating deploy inbox"
echo "=============================="

mkdir -p /opt/deploy-inbox
chown "$DEPLOY_USER:$DEPLOY_USER" /opt/deploy-inbox
chmod 755 /opt/deploy-inbox

# ==========================================================
# Create deploy script
# ==========================================================
cat > /usr/local/bin/deploy-war.sh <<'EOF'
#!/bin/bash
set -euo pipefail

WAR_FILE="/opt/deploy-inbox/ROOT.war"
TOMCAT_WEBAPPS="/usr/local/tomcat/webapps"

echo "Starting WAR deployment..."

if [ ! -f "$WAR_FILE" ]; then
  echo "ERROR: $WAR_FILE not found"
  exit 1
fi

systemctl stop tomcat || true

rm -rf "$TOMCAT_WEBAPPS/ROOT" "$TOMCAT_WEBAPPS/ROOT.war"

cp "$WAR_FILE" "$TOMCAT_WEBAPPS/ROOT.war"
chown tomcat:tomcat "$TOMCAT_WEBAPPS/ROOT.war"

systemctl start tomcat

echo "Deployment completed successfully."
systemctl status tomcat --no-pager
EOF

chmod +x /usr/local/bin/deploy-war.sh

echo "$DEPLOY_USER ALL=(root) NOPASSWD: /usr/local/bin/deploy-war.sh" > /etc/sudoers.d/deploy-war
chmod 440 /etc/sudoers.d/deploy-war

# ==========================================================
# Store app01 private IP and deploy private key in SSM
# ==========================================================
echo "=============================="
echo " Publishing app01 data to SSM"
echo "=============================="

aws ssm put-parameter \
  --name "$SSM_PREFIX/ssh-private-key" \
  --type "SecureString" \
  --value "$(cat "$DEPLOY_KEY")" \
  --overwrite \
  --region "$AWS_REGION"

aws ssm put-parameter \
  --name "$SSM_PREFIX/private-ip" \
  --type "String" \
  --value "$PRIVATE_IP" \
  --overwrite \
  --region "$AWS_REGION"

echo "=============================="
echo " app01 provisioning completed"
echo "Private IP: $PRIVATE_IP"
echo "Tomcat URL: http://$PRIVATE_IP:8080"
echo "Log file: /var/log/app01-user-data.log"
echo "=============================="

systemctl status tomcat --no-pager || true