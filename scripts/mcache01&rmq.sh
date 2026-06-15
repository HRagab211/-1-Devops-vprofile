#!/bin/bash
set -euo pipefail

RABBITMQ_USER="test"
RABBITMQ_PASSWORD="test"

echo "=============================="
echo " Updating system"
echo "=============================="
sudo dnf update -y

echo "=============================="
echo " Installing common packages"
echo "=============================="
sudo dnf install -y wget curl logrotate ca-certificates

# ==========================================================
# Install Memcached
# ==========================================================
echo "=============================="
echo " Installing Memcached"
echo "=============================="
sudo dnf install -y memcached

sudo systemctl enable memcached
sudo systemctl start memcached

echo "=============================="
echo " Configuring Memcached to listen on all interfaces"
echo "=============================="

if [ -f /etc/sysconfig/memcached ]; then
    sudo sed -i 's/^OPTIONS=.*/OPTIONS="-l 0.0.0.0"/' /etc/sysconfig/memcached
else
    echo 'OPTIONS="-l 0.0.0.0"' | sudo tee /etc/sysconfig/memcached
fi

sudo systemctl restart memcached
sudo systemctl --no-pager status memcached || true

echo "=============================="
echo " Testing Memcached port"
echo "=============================="
sudo ss -lntp | grep 11211 || true

# ==========================================================
# Install RabbitMQ
# ==========================================================
echo "=============================="
echo " Installing RabbitMQ official repositories"
echo "=============================="

ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
    echo "ERROR: This RabbitMQ repo method is intended for x86_64 Amazon Linux 2023."
    echo "Current architecture: $ARCH"
    exit 1
fi

sudo rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc"
sudo rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key"
sudo rpm --import "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key"

sudo tee /etc/yum.repos.d/rabbitmq.repo > /dev/null <<'EOF'
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

echo "=============================="
echo " Installing Erlang and RabbitMQ"
echo "=============================="
sudo dnf clean all
sudo dnf makecache -y
sudo dnf install -y erlang rabbitmq-server

echo "=============================="
echo " Starting RabbitMQ"
echo "=============================="
sudo systemctl enable rabbitmq-server
sudo systemctl start rabbitmq-server

echo "=============================="
echo " Enabling RabbitMQ Management Plugin"
echo "=============================="
sudo rabbitmq-plugins enable rabbitmq_management

echo "=============================="
echo " Creating RabbitMQ user"
echo "=============================="
if sudo rabbitmqctl list_users | grep -q "^${RABBITMQ_USER}[[:space:]]"; then
    sudo rabbitmqctl change_password "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}"
else
    sudo rabbitmqctl add_user "${RABBITMQ_USER}" "${RABBITMQ_PASSWORD}"
fi

sudo rabbitmqctl set_user_tags "${RABBITMQ_USER}" administrator
sudo rabbitmqctl set_permissions -p / "${RABBITMQ_USER}" ".*" ".*" ".*"

echo "=============================="
echo " Disabling guest remote restriction by using custom user instead"
echo "=============================="
sudo rabbitmqctl delete_user guest || true

sudo systemctl restart rabbitmq-server

echo "=============================="
echo " RabbitMQ status"
echo "=============================="
sudo systemctl --no-pager status rabbitmq-server || true
sudo rabbitmqctl status || true

echo "=============================="
echo " Listening ports"
echo "=============================="
sudo ss -lntp | grep -E '11211|5672|15672' || true

echo "=============================="
echo " Done"
echo "Memcached: 11211"
echo "RabbitMQ AMQP: 5672"
echo "RabbitMQ UI: http://SERVER_IP:15672"
echo "RabbitMQ user: ${RABBITMQ_USER}"
echo "RabbitMQ password: ${RABBITMQ_PASSWORD}"
echo "=============================="