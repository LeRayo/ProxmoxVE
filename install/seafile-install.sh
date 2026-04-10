#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Tiklaw (OpenClaw)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://manual.seafile.com/latest/setup_binary/installation/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Refreshing APT metadata"
$STD apt update
msg_ok "Refreshed APT metadata"

msg_info "Installing dependencies"
$STD apt install -y \
  mariadb-server \
  redis-server \
  python3 \
  python3-dev \
  python3-setuptools \
  python3-pip \
  python3-ldap \
  python3-rados \
  python3.13-venv \
  libmariadb-dev-compat \
  default-libmysqlclient-dev \
  libmemcached-dev \
  libldap2-dev \
  libsasl2-dev \
  ldap-utils \
  build-essential \
  pkg-config \
  libhiredis-dev \
  wget \
  pwgen
msg_ok "Installed dependencies"

SEAFILE_ROOT=/opt/seafile
SEAFILE_USER=seafile
SEAFILE_CONF_DIR=${SEAFILE_ROOT}/conf
SEAFILE_STATE_DIR=/etc/seafile-installer
SEAFILE_SETUP_ENV=$(mktemp /tmp/seafile-setup.XXXXXX.env)
cleanup() {
  rm -f "${SEAFILE_SETUP_ENV}"
}
trap cleanup EXIT
as_seafile() {
  runuser -u "${SEAFILE_USER}" -- "$@"
}
mkdir -p "${SEAFILE_ROOT}" "${SEAFILE_STATE_DIR}"

get_lxc_ip

SEAFILE_TARBALL_URL="${SEAFILE_TARBALL_URL:-}"
SEAFILE_SERVER_NAME="${SEAFILE_SERVER_NAME:-seafile}"
SEAFILE_SERVER_HOSTNAME="${SEAFILE_SERVER_HOSTNAME:-$LOCAL_IP}"
SEAFILE_FILESERVER_PORT="${SEAFILE_FILESERVER_PORT:-8082}"
SEAFILE_ADMIN_EMAIL="${SEAFILE_ADMIN_EMAIL:-admin@change.me}"
SEAFILE_ADMIN_PASSWORD="${SEAFILE_ADMIN_PASSWORD:-$(pwgen -s 20 1)}"
SEAFILE_DB_PASS="${SEAFILE_DB_PASS:-$(pwgen -s 24 1)}"
JWT_PRIVATE_KEY="${JWT_PRIVATE_KEY:-$(pwgen -s 40 1)}"

if [[ -z "${SEAFILE_TARBALL_URL}" ]]; then
  msg_error "SEAFILE_TARBALL_URL environment variable is required"
  exit 1
fi

msg_info "Using Seafile installation parameters"
msg_ok "Tarball URL provided"
msg_ok "Server hostname: ${SEAFILE_SERVER_HOSTNAME}"
if [[ "${SEAFILE_ADMIN_EMAIL}" == "admin@change.me" ]]; then
  msg_warn "No admin email provided; using temporary placeholder ${SEAFILE_ADMIN_EMAIL}"
else
  msg_ok "Admin email: ${SEAFILE_ADMIN_EMAIL}"
fi

msg_info "Persisting installer state"
cat <<STATE_EOF > ${SEAFILE_STATE_DIR}/seafile-installer.conf
SEAFILE_TARBALL_URL='${SEAFILE_TARBALL_URL}'
SEAFILE_SERVER_NAME='${SEAFILE_SERVER_NAME}'
SEAFILE_SERVER_HOSTNAME='${SEAFILE_SERVER_HOSTNAME}'
SEAFILE_FILESERVER_PORT='${SEAFILE_FILESERVER_PORT}'
SEAFILE_ADMIN_EMAIL='${SEAFILE_ADMIN_EMAIL}'
STATE_EOF
chmod 600 ${SEAFILE_STATE_DIR}/seafile-installer.conf
msg_ok "Persisted installer state"

msg_info "Preparing MariaDB and Redis"
systemctl enable -q --now mariadb redis-server
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ccnet_db CHARACTER SET utf8;
CREATE DATABASE IF NOT EXISTS seafile_db CHARACTER SET utf8;
CREATE DATABASE IF NOT EXISTS seahub_db CHARACTER SET utf8;
CREATE USER IF NOT EXISTS 'seafile'@'localhost' IDENTIFIED BY '${SEAFILE_DB_PASS}';
ALTER USER 'seafile'@'localhost' IDENTIFIED BY '${SEAFILE_DB_PASS}';
GRANT ALL PRIVILEGES ON ccnet_db.* TO 'seafile'@'localhost';
GRANT ALL PRIVILEGES ON seafile_db.* TO 'seafile'@'localhost';
GRANT ALL PRIVILEGES ON seahub_db.* TO 'seafile'@'localhost';
FLUSH PRIVILEGES;
SQL
msg_ok "Prepared MariaDB and Redis"

if ! id -u ${SEAFILE_USER} >/dev/null 2>&1; then
  msg_info "Creating seafile user"
  /usr/sbin/adduser --disabled-password --gecos "" ${SEAFILE_USER}
  msg_ok "Created seafile user"
fi
chown -R ${SEAFILE_USER}:${SEAFILE_USER} ${SEAFILE_ROOT}

msg_info "Setting up Python virtual environment"
as_seafile python3 -m venv ${SEAFILE_ROOT}/python-venv
runuser -u ${SEAFILE_USER} -- bash -lc "source ${SEAFILE_ROOT}/python-venv/bin/activate && pip3 install --timeout=3600 boto3 oss2 twilio configparser pytz sqlalchemy==2.0.* pymysql==1.1.* jinja2 django-pylibmc pylibmc redis django-redis psd-tools lxml django==5.2.* cffi==1.17.1 future==1.0.* mysqlclient==2.2.* captcha==0.7.* django_simple_captcha==0.6.* pyjwt==2.10.* djangosaml2==1.11.* pysaml2==7.5.* pycryptodome==3.23.* python-ldap==3.4.* pillow==11.3.* pillow-heif==1.0.* cairosvg==2.8.* scikit-learn==1.7.*"
msg_ok "Set up Python virtual environment"

msg_info "Downloading Seafile tarball"
TARBALL_NAME=$(basename "${SEAFILE_TARBALL_URL%%\?*}")
TARBALL_PATH=${SEAFILE_ROOT}/${TARBALL_NAME}
as_seafile wget -O "${TARBALL_PATH}" "${SEAFILE_TARBALL_URL}"
if ! tar -tf "${TARBALL_PATH}" >/dev/null 2>&1; then
  msg_error "Downloaded tarball is not a valid archive"
  exit 1
fi
msg_ok "Downloaded Seafile tarball"

msg_info "Extracting Seafile tarball"
as_seafile tar -C "${SEAFILE_ROOT}" -xf "${TARBALL_PATH}"
SEAFILE_EXTRACTED_DIR=$(tar -tf "${TARBALL_PATH}" | sed -n '1s#/.*##p')
if [[ -z "${SEAFILE_EXTRACTED_DIR}" ]]; then
  msg_error "Unable to determine extracted Seafile directory"
  exit 1
fi
SEAFILE_INSTALL_DIR="${SEAFILE_ROOT}/${SEAFILE_EXTRACTED_DIR}"
msg_ok "Extracted Seafile tarball"

msg_info "Running Seafile setup"
cat <<EOF_SETUP > ${SEAFILE_SETUP_ENV}
export LC_ALL=C
export PYTHONUNBUFFERED=1
export SEAFILE_SERVER_NAME='${SEAFILE_SERVER_NAME}'
export SEAFILE_SERVER_HOSTNAME='${SEAFILE_SERVER_HOSTNAME}'
export SEAFILE_FILESERVER_PORT='${SEAFILE_FILESERVER_PORT}'
export SEAFILE_DB_PASS='${SEAFILE_DB_PASS}'
EOF_SETUP
chown ${SEAFILE_USER}:${SEAFILE_USER} ${SEAFILE_SETUP_ENV}
chmod 600 ${SEAFILE_SETUP_ENV}
runuser -u ${SEAFILE_USER} -- bash -lc "source ${SEAFILE_SETUP_ENV}; source ${SEAFILE_ROOT}/python-venv/bin/activate; cd ${SEAFILE_INSTALL_DIR}; printf '\n%s\n%s\n\n%s\n2\n127.0.0.1\n3306\nseafile\n%s\nccnet_db\nseafile_db\nseahub_db\n\n' \"\${SEAFILE_SERVER_NAME}\" \"\${SEAFILE_SERVER_HOSTNAME}\" \"\${SEAFILE_FILESERVER_PORT}\" \"\${SEAFILE_DB_PASS}\" | ./setup-seafile-mysql.sh"
if [[ ! -L "${SEAFILE_ROOT}/seafile-server-latest" ]]; then
  msg_error "Seafile setup did not complete successfully; seafile-server-latest symlink is missing"
  exit 1
fi
if [[ ! -f "${SEAFILE_ROOT}/seafile-server-latest/seafile.sh" ]]; then
  msg_error "Seafile setup did not complete successfully; seafile-server-latest/seafile.sh is missing"
  exit 1
fi
msg_ok "Ran Seafile setup"

msg_info "Creating Seafile environment file"
mkdir -p ${SEAFILE_CONF_DIR}
cat <<ENV_EOF > ${SEAFILE_CONF_DIR}/.env
JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
SEAFILE_SERVER_PROTOCOL=http
SEAFILE_SERVER_HOSTNAME=${SEAFILE_SERVER_HOSTNAME}
SEAFILE_MYSQL_DB_HOST=127.0.0.1
SEAFILE_MYSQL_DB_PORT=3306
SEAFILE_MYSQL_DB_USER=seafile
SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_DB_PASS}
SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db
SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=seahub_db
CACHE_PROVIDER=redis
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
ENV_EOF
chown ${SEAFILE_USER}:${SEAFILE_USER} ${SEAFILE_CONF_DIR}/.env
chmod 600 ${SEAFILE_CONF_DIR}/.env
msg_ok "Created Seafile environment file"

msg_info "Creating run_with_venv helper"
cat <<'EOF_VENV' > ${SEAFILE_ROOT}/run_with_venv.sh
#!/bin/bash
dir_name="$(cd "$(dirname "$0")" && pwd)"
source "${dir_name}/python-venv/bin/activate"
script="$1"
shift 1
exec "${dir_name}/seafile-server-latest/${script}" "$@"
EOF_VENV
chown ${SEAFILE_USER}:${SEAFILE_USER} ${SEAFILE_ROOT}/run_with_venv.sh
chmod 755 ${SEAFILE_ROOT}/run_with_venv.sh
msg_ok "Created run_with_venv helper"

msg_info "Creating systemd services"
cat <<EOF_SEAFILE >/etc/systemd/system/seafile.service
[Unit]
Description=Seafile
After=network.target mariadb.service redis-server.service

[Service]
Type=forking
ExecStart=bash ${SEAFILE_ROOT}/run_with_venv.sh seafile.sh start
ExecStop=bash ${SEAFILE_ROOT}/seafile-server-latest/seafile.sh stop
LimitNOFILE=infinity
User=${SEAFILE_USER}
Group=${SEAFILE_USER}

[Install]
WantedBy=multi-user.target
EOF_SEAFILE

cat <<EOF_SEAHUB >/etc/systemd/system/seahub.service
[Unit]
Description=Seafile hub
After=network.target seafile.service

[Service]
Type=forking
ExecStart=bash ${SEAFILE_ROOT}/run_with_venv.sh seahub.sh start
ExecStop=bash ${SEAFILE_ROOT}/seafile-server-latest/seahub.sh stop
User=${SEAFILE_USER}
Group=${SEAFILE_USER}

[Install]
WantedBy=multi-user.target
EOF_SEAHUB
systemctl daemon-reload
msg_ok "Created systemd services"

sed -i 's#^bind = ".*"#bind = "0.0.0.0:8000"#' ${SEAFILE_CONF_DIR}/gunicorn.conf.py

msg_info "Starting Seafile services"
systemctl enable -q --now seafile.service
systemctl enable -q seahub.service
if ! systemctl start seahub.service; then
  runuser -u ${SEAFILE_USER} -- bash -lc "cd ${SEAFILE_ROOT}/seafile-server-latest && yes | bash ./seahub.sh start"
fi
sleep 5
if ! systemctl is-active --quiet seafile.service; then
  msg_error "seafile.service is not active after startup"
  systemctl --no-pager --full status seafile.service || true
  exit 1
fi
if ! systemctl is-active --quiet seahub.service; then
  msg_error "seahub.service is not active after startup"
  systemctl --no-pager --full status seahub.service || true
  exit 1
fi
msg_ok "Started Seafile services"

msg_info "Checking Seafile HTTP endpoints"
SEAHUB_HTTP_URL="http://${SEAFILE_SERVER_HOSTNAME}:8000"
FILESERVER_HTTP_URL="http://${SEAFILE_SERVER_HOSTNAME}:${SEAFILE_FILESERVER_PORT}"
for _ in $(seq 1 10); do
  if curl -fsSI "${SEAHUB_HTTP_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if curl -fsSI "${SEAHUB_HTTP_URL}" >/dev/null 2>&1; then
  msg_ok "Seahub HTTP endpoint is reachable on ${SEAHUB_HTTP_URL}"
else
  msg_warn "Seahub HTTP endpoint did not answer yet on ${SEAHUB_HTTP_URL}"
fi
if curl -fsSI "${FILESERVER_HTTP_URL}" >/dev/null 2>&1; then
  msg_ok "Seafile fileserver endpoint is reachable on ${FILESERVER_HTTP_URL}"
else
  msg_warn "Seafile fileserver endpoint did not answer yet on ${FILESERVER_HTTP_URL}"
fi

msg_info "Creating credentials file"
cat <<CREDS_EOF > /root/seafile.creds
Seahub URL: http://${SEAFILE_SERVER_HOSTNAME}:8000
Seafile Fileserver URL: http://${SEAFILE_SERVER_HOSTNAME}:${SEAFILE_FILESERVER_PORT}
Seafile Admin Email: ${SEAFILE_ADMIN_EMAIL}
Seafile Admin Password: ${SEAFILE_ADMIN_PASSWORD}
Seafile DB Password: ${SEAFILE_DB_PASS}
Tarball URL: ${SEAFILE_TARBALL_URL}
CREDS_EOF
chmod 600 /root/seafile.creds
msg_ok "Created credentials file"

motd_ssh
customize
cleanup_lxc
