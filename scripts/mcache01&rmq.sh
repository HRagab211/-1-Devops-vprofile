#!/bin/bash
set -euo pipefail

exec > >(tee -a /var/log/cache-mq-user-data.log | logger -t cache-mq-user-data -s 2>/dev/console) 2>&1

# ==========================================================
# Config
# ==========================================================
RABBITMQ_USER="test"
RABBITMQ_PASSWORD="test"

PUBLISH_TO_SSM="true"
SSM_CACHE_IP_PARAM="/deploy/cache/private-ip"
SSM_RABBITMQ_IP_PARAM="/deploy/rabbitmq/private-ip"

echo "=============================="
echo " Starting cache/mq provisioning"
echo "=============================="

# ==========================================================
# Update system and install common packages
# ==========================================================
dnf update -y

dnf install -y \
  wget \
  logrotate \
  ca-certificates \
  iproute \
  awscli

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
# Install Memcached
# ==========================================================
dnf install -y memcached

if [ -f /etc/sysconfig/memcached ]; then
  if grep -q '^OPTIONS=' /etc/sysconfig/memcached; then
    sed -i 's#^OPTIONS=.*#OPTIONS="-l 0.0.0.0 -U 0"#' /etc/sysconfig/memcached
  else
    echo 'OPTIONS="-l 0.0.0.0 -U 0"' >> /etc/sysconfig/memcached
  fi
else
  echo 'OPTIONS="-l 0.0.0.0 -U 0"' > /etc/sysconfig/memcached
fi

systemctl enable --now memcached
systemctl restart memcached

# ==========================================================
# Install RabbitMQ repositories
# ==========================================================
ARCH="$(uname -m)"

if [ "$ARCH" != "x86_64" ]; then
  echo "ERROR: This RabbitMQ repo method is intended for x86_64 Amazon Linux 2023."
  echo "Current architecture: $ARCH"
  exit 1
fi

rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc"
rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key"
rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key"

cat > /etc/yum.repos.d/rabbitmq.repo <<'EOF'
[modern-erlang]
name=modern-erlang-el9
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
        https://yum2.rabbitmq.com/erlang/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[modern-erlang-noarch]
name=modern-erlang-el9-noarch
baseurl=https://yum1.rabbitmq.com/erlang/el/9/noarch
        https://yum2.rabbitmq.com/erlang/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9]
name=rabbitmq-el9
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
        https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9-noarch]
name=rabbitmq-el9-noarch
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md
EOF

# ==========================================================
# Install Erlang and RabbitMQ
# ==========================================================
dnf clean all
dnf makecache -y
dnf install -y erlang rabbitmq-server

# ==========================================================
# Configure RabbitMQ
# ==========================================================
cat > /etc/rabbitmq/rabbitmq.conf <<EOF
listeners.tcp.default = 5672

management.tcp.port = 15672
management.tcp.ip = 0.0.0.0
EOF

chown rabbitmq:rabbitmq /etc/rabbitmq/rabbitmq.conf
chmod 640 /etc/rabbitmq/rabbitmq.conf

rabbitmq-plugins enable --offline rabbitmq_management

systemctl enable --now rabbitmq-server
rabbitmqctl await_startup

# ==========================================================
# Create RabbitMQ user
# ==========================================================
if rabbitmqctl list_users | awk '{print $1}' | grep -qx "${RABBITMQ_USER}"; then
  rabbitmqctl change_password "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}"
else
  rabbitmqctl add_user "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}"
fi

rabbitmqctl set_user_tags "${RABBITMQ_USER}" administrator
rabbitmqctl set_permissions -p / "${RABBITMQ_USER}" ".*" ".*" ".*"

if rabbitmqctl list_users | awk '{print $1}' | grep -qx "guest"; then
  rabbitmqctl delete_user guest
fi

systemctl restart rabbitmq-server
rabbitmqctl await_startup

# ==========================================================
# Publish private IP to SSM
# ==========================================================
if [ "$PUBLISH_TO_SSM" = "true" ]; then
  if aws ssm put-parameter \
    --name "$SSM_CACHE_IP_PARAM" \
    --type "String" \
    --value "$PRIVATE_IP" \
    --overwrite \
    --region "$AWS_REGION"; then
    echo "Cache private IP published to SSM."
  else
    echo "WARNING: Could not publish cache private IP to SSM."
  fi

  if aws ssm put-parameter \
    --name "$SSM_RABBITMQ_IP_PARAM" \
    --type "String" \
    --value "$PRIVATE_IP" \
    --overwrite \
    --region "$AWS_REGION"; then
    echo "RabbitMQ private IP published to SSM."
  else
    echo "WARNING: Could not publish RabbitMQ private IP to SSM."
  fi
fi

echo "=============================="
echo " cache/mq provisioning completed"
echo "Private IP: $PRIVATE_IP"
echo "Memcached: $PRIVATE_IP:11211"
echo "RabbitMQ AMQP: $PRIVATE_IP:5672"
echo "RabbitMQ UI: http://$PRIVATE_IP:15672"
echo "RabbitMQ user: $RABBITMQ_USER"
echo "RabbitMQ password: $RABBITMQ_PASSWORD"
echo "Log file: /var/log/cache-mq-user-data.log"
echo "=============================="

systemctl --no-pager status memcached || true
systemctl --no-pager status rabbitmq-server || true
ss -lntp | grep -E '11211|5672|15672' || true