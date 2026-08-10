#!/usr/bin/env bash
# EC2 user data for HRagab211/-1-Devops-vprofile (Ubuntu 24.04/26.04, x86_64/arm64).
# Architecture used by this lab deployment:
#   EC2/Tomcat -> RDS MariaDB/MySQL
#              -> ElastiCache Serverless Memcached (TLS via local stunnel)
#              -> local RabbitMQ (the application is not compatible with SQS)
#              -> local Elasticsearch 7.10.2 (bound to 127.0.0.1 only)

set -Eeuo pipefail
umask 027

LOG_FILE="/var/log/vprofile-user-data.log"
exec > >(tee -a "$LOG_FILE" | logger -t vprofile-user-data -s 2>/dev/console) 2>&1
trap 'rc=$?; echo "ERROR: line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"; exit "$rc"' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root (EC2 user data runs as root automatically)."
  exit 1
fi

# -----------------------------------------------------------------------------
# REQUIRED: edit these values before pasting the script into EC2 User Data.
# Do not reuse the devops_app database: this repository requires its own
# `accounts` schema and has a different user-table structure.
# -----------------------------------------------------------------------------
RDS_HOST="java-db.cvcw4kkcgfsm.eu-central-1.rds.amazonaws.com"
RDS_PORT="3306"
RDS_DATABASE="accounts"
RDS_USERNAME="hossam"
RDS_PASSWORD="CHANGE_ME_RDS_PASSWORD"

# Use the ElastiCache Serverless Memcached endpoint hostname only (no scheme
# and no port). Serverless requires TLS; stunnel terminates TLS locally because
# the repository's spymemcached 2.12.3 configuration uses plain TCP.
MEMCACHED_HOST="CHANGE_ME_MEMCACHED_ENDPOINT"
MEMCACHED_PORT="11211"
MEMCACHED_LOCAL_HOST="127.0.0.1"
MEMCACHED_LOCAL_PORT="11211"

# Repository and application settings.
REPO_URL="https://github.com/HRagab211/-1-Devops-vprofile.git"
REPO_BRANCH="main"
APP_SOURCE_DIR="/opt/vprofile-src"
TOMCAT_HOME="/opt/tomcat"
TOMCAT_SERIES="10.1"
APP_PORT="8080"

# The code requires native RabbitMQ/AMQP. A random local broker password is
# generated at first boot and embedded into the built WAR.
RABBITMQ_HOST="127.0.0.1"
RABBITMQ_PORT="5672"
RABBITMQ_USERNAME="vprofile"
RABBITMQ_PASSWORD=""

# The source uses Elasticsearch RestHighLevelClient 7.10.2. Keep the matching
# lab version and expose it only over loopback. Port 9200 is HTTP REST; the
# repository's original 9300 value is a transport port and is incorrect here.
ELASTICSEARCH_VERSION="7.10.2"
ELASTICSEARCH_HOST="127.0.0.1"
ELASTICSEARCH_PORT="9200"

for required_value in RDS_HOST RDS_USERNAME RDS_PASSWORD MEMCACHED_HOST; do
  value="${!required_value}"
  if [[ -z "$value" || "$value" == CHANGE_ME* ]]; then
    echo "ERROR: set ${required_value} in the configuration block first."
    exit 2
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "ERROR: ${required_value} must be a single-line value."
    exit 2
  fi
done

if [[ "$MEMCACHED_HOST" == *"://"* || "$MEMCACHED_HOST" == *":"* || "$MEMCACHED_HOST" == *"/"* ]]; then
  echo "ERROR: MEMCACHED_HOST must contain the endpoint hostname only."
  exit 2
fi

if [[ ! "$RDS_DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "ERROR: RDS_DATABASE may contain only letters, numbers, and underscores."
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg jq mariadb-client maven netcat-openbsd \
  openjdk-17-jdk openssl rabbitmq-server stunnel4 tar
RABBITMQ_PASSWORD="$(openssl rand -hex 24)"

# -----------------------------------------------------------------------------
# ElastiCache Serverless Memcached: verify VPC/security-group reachability and
# TLS, then expose a loopback-only plaintext endpoint to the legacy Java client.
# Nothing is exposed from EC2; only Tomcat can reach 127.0.0.1:11211.
# -----------------------------------------------------------------------------
if ! getent ahosts "$MEMCACHED_HOST" >/dev/null; then
  echo "ERROR: cannot resolve Memcached endpoint ${MEMCACHED_HOST}."
  echo "Confirm that the EC2 instance and cache use the same VPC DNS settings."
  exit 6
fi

if ! nc -z -w 5 "$MEMCACHED_HOST" "$MEMCACHED_PORT"; then
  echo "ERROR: cannot reach Memcached at ${MEMCACHED_HOST}:${MEMCACHED_PORT}."
  echo "The EC2 and cache must be in the same VPC. Allow TCP 11211-11212"
  echo "in the cache security group, using the EC2 security group as source."
  exit 6
fi

tls_probe_log="/tmp/vprofile-memcached-tls-probe.log"
if ! timeout 15 openssl s_client \
  -connect "${MEMCACHED_HOST}:${MEMCACHED_PORT}" \
  -servername "$MEMCACHED_HOST" \
  -CAfile /etc/ssl/certs/ca-certificates.crt \
  -verify_return_error -brief </dev/null >"$tls_probe_log" 2>&1; then
  echo "ERROR: TCP is reachable but the Memcached TLS handshake failed."
  sed -n '1,30p' "$tls_probe_log"
  exit 6
fi
rm -f "$tls_probe_log"

install -d -m 0750 -o root -g stunnel4 /etc/stunnel
tee /etc/stunnel/vprofile-memcached.conf >/dev/null <<EOF
client = yes
foreground = yes
setuid = stunnel4
setgid = stunnel4
CAfile = /etc/ssl/certs/ca-certificates.crt
verifyChain = yes

[elasticache-serverless-memcached]
accept = ${MEMCACHED_LOCAL_HOST}:${MEMCACHED_LOCAL_PORT}
connect = ${MEMCACHED_HOST}:${MEMCACHED_PORT}
sni = ${MEMCACHED_HOST}
checkHost = ${MEMCACHED_HOST}
delay = yes
TIMEOUTconnect = 10
EOF
chown root:stunnel4 /etc/stunnel/vprofile-memcached.conf
chmod 0640 /etc/stunnel/vprofile-memcached.conf

tee /etc/systemd/system/vprofile-memcached-tunnel.service >/dev/null <<'EOF'
[Unit]
Description=TLS tunnel to ElastiCache Serverless Memcached
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 /etc/stunnel/vprofile-memcached.conf
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vprofile-memcached-tunnel

cache_version=""
for attempt in {1..10}; do
  cache_version="$(printf 'version\r\nquit\r\n' \
    | timeout 10 nc "$MEMCACHED_LOCAL_HOST" "$MEMCACHED_LOCAL_PORT" 2>/dev/null \
    | tr -d '\r' || true)"
  if grep -q '^VERSION ' <<<"$cache_version"; then
    break
  fi
  sleep 2
done
if ! grep -q '^VERSION ' <<<"$cache_version"; then
  echo "ERROR: the local TLS tunnel could not execute a Memcached command."
  systemctl --no-pager --full status vprofile-memcached-tunnel || true
  journalctl -u vprofile-memcached-tunnel -n 50 --no-pager || true
  exit 6
fi
echo "Memcached TLS tunnel ready: ${cache_version}"

# -----------------------------------------------------------------------------
# RabbitMQ: local compatibility service. SQS cannot replace this because the
# application creates AMQP connections, exchanges, queues, and listeners.
# -----------------------------------------------------------------------------
systemctl enable --now rabbitmq-server

if rabbitmqctl list_users -q | awk '{print $1}' | grep -Fxq "$RABBITMQ_USERNAME"; then
  rabbitmqctl change_password "$RABBITMQ_USERNAME" "$RABBITMQ_PASSWORD"
else
  rabbitmqctl add_user "$RABBITMQ_USERNAME" "$RABBITMQ_PASSWORD"
fi
rabbitmqctl set_permissions -p / "$RABBITMQ_USERNAME" '.*' '.*' '.*'
rabbitmqctl delete_user guest >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Elasticsearch 7.10.2: local lab compatibility service.
# It is old/EOL, so it is bound only to loopback and must never be exposed by
# the EC2 security group.
# -----------------------------------------------------------------------------
case "$(uname -m)" in
  x86_64) es_arch="amd64" ;;
  aarch64|arm64) es_arch="arm64" ;;
  *) echo "ERROR: unsupported Elasticsearch architecture: $(uname -m)"; exit 3 ;;
esac

if ! dpkg-query -W -f='${Status}' elasticsearch 2>/dev/null | grep -q 'install ok installed'; then
  es_deb="elasticsearch-${ELASTICSEARCH_VERSION}-${es_arch}.deb"
  es_url="https://artifacts.elastic.co/downloads/elasticsearch/${es_deb}"
  curl --fail --location --retry 5 --retry-delay 3 "$es_url" -o "/tmp/${es_deb}"
  curl --fail --location --retry 5 --retry-delay 3 "${es_url}.sha512" -o "/tmp/${es_deb}.sha512"
  (
    cd /tmp
    sha512sum --check "${es_deb}.sha512"
  )
  dpkg -i "/tmp/${es_deb}"
  rm -f "/tmp/${es_deb}" "/tmp/${es_deb}.sha512"
fi

install -d -m 0750 -o root -g elasticsearch /etc/elasticsearch/jvm.options.d
tee /etc/elasticsearch/elasticsearch.yml >/dev/null <<EOF
cluster.name: vprofile
node.name: vprofile-node
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: ${ELASTICSEARCH_HOST}
http.port: ${ELASTICSEARCH_PORT}
discovery.type: single-node
xpack.security.enabled: false
EOF
tee /etc/elasticsearch/jvm.options.d/vprofile.options >/dev/null <<'EOF'
-Xms256m
-Xmx256m
EOF
chown root:elasticsearch /etc/elasticsearch/elasticsearch.yml \
  /etc/elasticsearch/jvm.options.d/vprofile.options
chmod 0640 /etc/elasticsearch/elasticsearch.yml \
  /etc/elasticsearch/jvm.options.d/vprofile.options
systemctl enable --now elasticsearch

# -----------------------------------------------------------------------------
# Fetch the exact application source and create its runtime configuration.
# -----------------------------------------------------------------------------
if [[ -e "$APP_SOURCE_DIR" ]]; then
  echo "ERROR: ${APP_SOURCE_DIR} already exists; refusing to overwrite it."
  exit 4
fi
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_SOURCE_DIR"

# Fix the repository's login-route mismatch at build time. Spring Security
# redirects anonymous users to /login, but the controller only maps GET /.
login_controller="$APP_SOURCE_DIR/src/main/java/com/visualpathit/account/controller/UserController.java"
sed -i '0,/@GetMapping("\/")/s//@GetMapping({"\/", "\/login"})/' "$login_controller"
grep -Fq '@GetMapping({"/", "/login"})' "$login_controller"

properties_file="$APP_SOURCE_DIR/src/main/resources/application.properties"
tee "$properties_file" >/dev/null <<EOF
jdbc.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.url=jdbc:mysql://${RDS_HOST}:${RDS_PORT}/${RDS_DATABASE}?useUnicode=true&characterEncoding=UTF-8&zeroDateTimeBehavior=convertToNull&sslMode=PREFERRED
jdbc.username=${RDS_USERNAME}
jdbc.password=${RDS_PASSWORD}

memcached.active.host=${MEMCACHED_LOCAL_HOST}
memcached.active.port=${MEMCACHED_LOCAL_PORT}
memcached.standBy.host=${MEMCACHED_LOCAL_HOST}
memcached.standBy.port=${MEMCACHED_LOCAL_PORT}

rabbitmq.address=${RABBITMQ_HOST}
rabbitmq.port=${RABBITMQ_PORT}
rabbitmq.username=${RABBITMQ_USERNAME}
rabbitmq.password=${RABBITMQ_PASSWORD}

elasticsearch.host=${ELASTICSEARCH_HOST}
elasticsearch.port=${ELASTICSEARCH_PORT}
elasticsearch.cluster=vprofile
elasticsearch.node=vprofile-node

spring.servlet.multipart.max-file-size=128KB
spring.servlet.multipart.max-request-size=128KB
logging.level.org.springframework.security=INFO
spring.security.user.name=admin_vp
spring.security.user.password=admin_vp
spring.security.user.roles=ADMIN
spring.mvc.view.prefix=/WEB-INF/views/
spring.mvc.view.suffix=.jsp
spring.jpa.show-sql=false
spring.jpa.properties.hibernate.format_sql=false
logging.level.org.hibernate.SQL=OFF
logging.level.org.hibernate.type=OFF
logging.level.com.visualpathit.account.service.SecurityServiceImpl=OFF
EOF
chmod 0600 "$properties_file"

# -----------------------------------------------------------------------------
# Initialize only a new/empty application schema. db_backup.sql matches the
# current User entity; accountsdb.sql does not contain all profile columns.
# -----------------------------------------------------------------------------
for attempt in {1..30}; do
  if nc -z -w 3 "$RDS_HOST" "$RDS_PORT"; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    echo "ERROR: cannot reach RDS at ${RDS_HOST}:${RDS_PORT}."
    exit 5
  fi
  sleep 5
done

export MYSQL_PWD="$RDS_PASSWORD"
db_args=(--protocol=TCP --host="$RDS_HOST" --port="$RDS_PORT" --user="$RDS_USERNAME")
mariadb "${db_args[@]}" -e \
  "CREATE DATABASE IF NOT EXISTS \`${RDS_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

table_count="$(mariadb "${db_args[@]}" --batch --skip-column-names information_schema -e \
  "SELECT COUNT(*) FROM tables WHERE table_schema='${RDS_DATABASE}' AND table_name='user';")"
if [[ "$table_count" == "0" ]]; then
  mariadb "${db_args[@]}" "$RDS_DATABASE" < \
    "$APP_SOURCE_DIR/src/main/resources/db_backup.sql"
else
  echo "Database table ${RDS_DATABASE}.user already exists; seed import skipped."
fi
unset MYSQL_PWD

# Build the WAR from the inspected main branch.
export MAVEN_OPTS="-Xms128m -Xmx512m"
cd "$APP_SOURCE_DIR"
mvn -B -DskipTests clean package
war_file="$(find target -maxdepth 1 -type f -name '*.war' -print -quit)"
if [[ -z "$war_file" ]]; then
  echo "ERROR: Maven completed without producing a WAR file."
  exit 7
fi

# -----------------------------------------------------------------------------
# Install the newest available Tomcat 10.1 release and deploy as ROOT.war.
# -----------------------------------------------------------------------------
if ! id tomcat >/dev/null 2>&1; then
  useradd --system --home-dir "$TOMCAT_HOME" --shell /usr/sbin/nologin tomcat
fi
install -d -m 0750 -o tomcat -g tomcat "$TOMCAT_HOME"

tomcat_version="$(curl -fsSL "https://dlcdn.apache.org/tomcat/tomcat-10/" \
  | grep -oE 'v10\.1\.[0-9]+/' | tr -d 'v/' | sort -V | tail -1)"
if [[ -z "$tomcat_version" ]]; then
  echo "ERROR: could not discover the current Tomcat ${TOMCAT_SERIES} release."
  exit 8
fi
tomcat_tar="apache-tomcat-${tomcat_version}.tar.gz"
tomcat_url="https://dlcdn.apache.org/tomcat/tomcat-10/v${tomcat_version}/bin/${tomcat_tar}"
curl --fail --location --retry 5 --retry-delay 3 "$tomcat_url" -o "/tmp/${tomcat_tar}"
curl --fail --location --retry 5 --retry-delay 3 "${tomcat_url}.sha512" -o "/tmp/${tomcat_tar}.sha512"
(
  cd /tmp
  sha512sum --check "${tomcat_tar}.sha512"
)
tar -xzf "/tmp/${tomcat_tar}" --strip-components=1 -C "$TOMCAT_HOME"
rm -f "/tmp/${tomcat_tar}" "/tmp/${tomcat_tar}.sha512"

rm -rf "$TOMCAT_HOME/webapps/ROOT" "$TOMCAT_HOME/webapps/ROOT.war"
install -m 0640 -o tomcat -g tomcat "$war_file" "$TOMCAT_HOME/webapps/ROOT.war"
chown -R tomcat:tomcat "$TOMCAT_HOME"
find "$TOMCAT_HOME/bin" -type f -name '*.sh' -exec chmod 0750 {} +

java_home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
tee /etc/systemd/system/tomcat.service >/dev/null <<EOF
[Unit]
Description=Apache Tomcat 10.1 - VProfile
Wants=network-online.target
After=network-online.target rabbitmq-server.service elasticsearch.service vprofile-memcached-tunnel.service
Requires=rabbitmq-server.service elasticsearch.service vprofile-memcached-tunnel.service

[Service]
Type=simple
User=tomcat
Group=tomcat
UMask=0027
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=${TOMCAT_HOME}"
Environment="CATALINA_BASE=${TOMCAT_HOME}"
Environment="CATALINA_TMPDIR=${TOMCAT_HOME}/temp"
Environment="CATALINA_OPTS=-Xms128m -Xmx512m -Djava.awt.headless=true"
ExecStart=${TOMCAT_HOME}/bin/catalina.sh run
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
SuccessExitStatus=143
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tomcat

# Wait for a valid HTTP response. Redirects are expected before authentication.
for attempt in {1..60}; do
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${APP_PORT}/login" || true)"
  if [[ "$http_code" =~ ^(200|302|303)$ ]]; then
    echo "VProfile deployment succeeded (HTTP ${http_code})."
    echo "Open: http://INSTANCE_PUBLIC_IP:${APP_PORT}/login"
    echo "Deployment log: ${LOG_FILE}"
    exit 0
  fi
  sleep 5
done

echo "ERROR: Tomcat started but the application did not become healthy."
systemctl --no-pager --full status tomcat || true
journalctl -u tomcat -n 150 --no-pager || true
exit 9