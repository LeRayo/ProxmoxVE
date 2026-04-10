#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Tiklaw (OpenClaw)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://manual.seafile.com/latest/setup_binary/installation/

APP="seafile"
mode="${mode:-default}"
var_container_storage="${var_container_storage:-lxcencrypt}"
var_template_storage="${var_template_storage:-local}"
var_tags="${var_tags:-cloud;files}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

build_func_tmp=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func -o "${build_func_tmp}"
python3 - <<'PY_BUILD' "${build_func_tmp}"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/${var_install}.sh'
new = 'https://raw.githubusercontent.com/LeRayo/ProxmoxVE/main/install/${var_install}.sh'
if old not in text:
    raise SystemExit('Expected install raw URL not found in build.func')
text = text.replace(old, new)
text = text.replace('lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/LeRayo/ProxmoxVE/main/install/${var_install}.sh)"', 'echo "DEBUG install url: https://raw.githubusercontent.com/LeRayo/ProxmoxVE/main/install/${var_install}.sh"; lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/LeRayo/ProxmoxVE/main/install/${var_install}.sh)"')
path.write_text(text)
PY_BUILD
source "${build_func_tmp}"
rm -f "${build_func_tmp}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info "$APP"
  check_container_storage
  check_container_resources

  if [[ ! -f /etc/seafile-installer/seafile-installer.conf ]]; then
    msg_error "No ${APP} installer state found!"
    exit
  fi

  source /etc/seafile-installer/seafile-installer.conf
  if [[ -z "${SEAFILE_TARBALL_URL:-}" ]]; then
    msg_error "No Seafile tarball URL configured!"
    exit
  fi

  local seafile_root=/opt/seafile
  local seafile_user=seafile
  local tarball_name tarball_path extracted_dir
  local seahub_http_url fileserver_http_url
  tarball_name=$(basename "${SEAFILE_TARBALL_URL%%\?*}")
  tarball_path="${seafile_root}/${tarball_name}"
  seahub_http_url="http://${SEAFILE_SERVER_HOSTNAME:-127.0.0.1}:8000"
  fileserver_http_url="http://${SEAFILE_SERVER_HOSTNAME:-127.0.0.1}:${SEAFILE_FILESERVER_PORT:-8082}"

  msg_info "Stopping Seafile services"
  systemctl stop seahub.service || true
  systemctl stop seafile.service || true
  msg_ok "Stopped Seafile services"

  msg_info "Refreshing Python dependencies"
  runuser -u ${seafile_user} -- bash -lc "source ${seafile_root}/python-venv/bin/activate && pip3 install --timeout=3600 boto3 oss2 twilio configparser pytz sqlalchemy==2.0.* pymysql==1.1.* jinja2 django-pylibmc pylibmc redis django-redis psd-tools lxml django==5.2.* cffi==1.17.1 future==1.0.* mysqlclient==2.2.* captcha==0.7.* django_simple_captcha==0.6.* pyjwt==2.10.* djangosaml2==1.11.* pysaml2==7.5.* pycryptodome==3.23.* python-ldap==3.4.* pillow==11.3.* pillow-heif==1.0.* cairosvg==2.8.* scikit-learn==1.7.*"
  msg_ok "Refreshed Python dependencies"

  msg_info "Downloading updated Seafile tarball"
  runuser -u ${seafile_user} -- wget -O "${tarball_path}" "${SEAFILE_TARBALL_URL}"
  if ! tar -tf "${tarball_path}" >/dev/null 2>&1; then
    msg_error "Downloaded tarball is not a valid archive"
    exit
  fi
  msg_ok "Downloaded updated tarball"

  msg_info "Extracting updated Seafile tarball"
  runuser -u ${seafile_user} -- tar -C "${seafile_root}" -xf "${tarball_path}"
  extracted_dir=$(tar -tf "${tarball_path}" | sed -n '1s#/.*##p')
  if [[ -z "${extracted_dir}" ]]; then
    msg_error "Unable to determine extracted Seafile directory"
    exit
  fi
  ln -sfn "${seafile_root}/${extracted_dir}" "${seafile_root}/seafile-server-latest"
  msg_ok "Extracted updated tarball"

  if [[ -x "${seafile_root}/seafile-server-latest/upgrade/upgrade_12.0_13.0.sh" ]]; then
    msg_info "Running Seafile major upgrade script"
    runuser -u ${seafile_user} -- bash -lc "source ${seafile_root}/python-venv/bin/activate && cd ${seafile_root}/seafile-server-latest && yes | bash upgrade/upgrade_12.0_13.0.sh"
    msg_ok "Ran major upgrade script"
  fi

  msg_info "Starting Seafile services"
  systemctl start seafile.service
  systemctl start seahub.service || runuser -u ${seafile_user} -- bash -lc "cd ${seafile_root}/seafile-server-latest && yes | bash ./seahub.sh start"
  sleep 5
  if ! systemctl is-active --quiet seafile.service; then
    msg_error "seafile.service is not active after update"
    systemctl --no-pager --full status seafile.service || true
    exit
  fi
  if ! systemctl is-active --quiet seahub.service; then
    msg_error "seahub.service is not active after update"
    systemctl --no-pager --full status seahub.service || true
    exit
  fi
  msg_ok "Started Seafile services"

  if curl -fsSI "${seahub_http_url}" >/dev/null 2>&1; then
    msg_ok "Seahub HTTP endpoint is reachable on ${seahub_http_url}"
  else
    msg_warn "Seahub HTTP endpoint did not answer yet on ${seahub_http_url}"
  fi
  if curl -fsSI "${fileserver_http_url}" >/dev/null 2>&1; then
    msg_ok "Seafile fileserver endpoint is reachable on ${fileserver_http_url}"
  else
    msg_warn "Seafile fileserver endpoint did not answer yet on ${fileserver_http_url}"
  fi

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description
