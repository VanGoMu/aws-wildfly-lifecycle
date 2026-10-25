#!/usr/bin/env bash
# The InstallWildFly document (Run Command, as root). Owner of Java, the WildFly binaries, the
# CodeDeploy agent, ansible-core, the systemd unit, /etc/wildfly-lifecycle/ and the platform
# scripts of /opt/wildfly-lifecycle/bin/. Idempotent with markers, so it also runs on an instance
# born from a backup AMI. It never touches standalone.xml: <system-properties> belongs to Ansible
# and <deployments> to WildFly.
# shellcheck disable=SC2154  # the SSM_* variables come from the document (check_parameters)
set -euo pipefail

PARAMETERS=(Region Environment ConfigPath SecretId AppPort HealthPath JavaPackage WildFlyVersion
  WildFlySha256 WildFlySource CodeDeployAgentVersion PlatformSource PlatformSha256)
PLATFORM_BIN=/opt/wildfly-lifecycle/bin
UNIT=/etc/systemd/system/wildfly.service
# The application on every interface; the management interface (9990) on loopback only.
BIND="-b 0.0.0.0 -bmanagement 127.0.0.1"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# The document hands its parameters over as SSM_<name> variables (interpolationType ENV_VAR):
# nothing is interpolated into this text. An older SSM Agent ignores ENV_VAR and leaves them unset.
check_parameters() {
  local name variable
  for name in "${PARAMETERS[@]}"; do
    variable="SSM_${name}"
    [ -n "${!variable+set}" ] \
      || die "${variable} is not set: interpolationType ENV_VAR needs SSM Agent 3.3.2746.0+"
  done
}

verify() { printf '%s  %s\n' "$1" "$2" | sha256sum --check --status || die "${2}: bad SHA-256"; }

# AL2023 locks its repositories to the release of the AMI: the same AMI installs the same packages.
install_packages() {
  dnf install -y --quiet "$SSM_JavaPackage" jq unzip tar gzip ansible-core python3-lxml
  id -u wildfly >/dev/null 2>&1 \
    || useradd --system --home-dir /opt/wildfly --shell /sbin/nologin wildfly
}

# fetch() travels inside platform.zip, so the zip itself comes with this minimal download.
install_platform() {
  local zip=/tmp/platform.zip
  if [ -f "${PLATFORM_BIN}/.platform-${SSM_PlatformSha256}" ]; then
    log "platform scripts ${SSM_PlatformSha256:0:12} already installed"
    return 0
  fi
  case "$SSM_PlatformSource" in
    s3://*)
      local path="${SSM_PlatformSource#s3://}"
      aws s3api get-object \
        --region "$SSM_Region" \
        --bucket "${path%%/*}" \
        --key "${path#*/}" \
        "$zip" >/dev/null ;;
    file://*) cp "${SSM_PlatformSource#file://}" "$zip" ;;
    *) die "unsupported source: ${SSM_PlatformSource}" ;;
  esac
  verify "$SSM_PlatformSha256" "$zip"
  rm -rf "$PLATFORM_BIN"
  install -d -m 0755 "$PLATFORM_BIN" /opt/wildfly-lifecycle/release/wars
  unzip -q "$zip" -d "$PLATFORM_BIN"
  touch "${PLATFORM_BIN}/.platform-${SSM_PlatformSha256}"
  rm -f "$zip"
  log "platform scripts ${SSM_PlatformSha256:0:12} installed"
}

# A different WildFly version is a new instance, never an in-place upgrade.
install_wildfly() {
  local version="$SSM_WildFlyVersion" home="/opt/wildfly-${SSM_WildFlyVersion}" current
  current=$(readlink /opt/wildfly || true)
  if [ ! -f "${home}/.installed-${version}" ]; then
    [ -z "$current" ] || die "${current##*/} is installed: WildFly ${version} needs a new instance"
    fetch "$SSM_WildFlySource" /tmp/wildfly.tar.gz
    verify "$SSM_WildFlySha256" /tmp/wildfly.tar.gz
    rm -rf "$home"
    tar -xzf /tmp/wildfly.tar.gz -C /opt
    chown -R wildfly:wildfly "$home"
    touch "${home}/.installed-${version}"
    rm -f /tmp/wildfly.tar.gz
  fi
  ln -sfn "$home" /opt/wildfly
  log "WildFly ${version} in ${home}"
}

# Pinned: the 2.x agent never updates itself, only with `codedeploy-agent update`.
install_codedeploy_agent() {
  local version="$SSM_CodeDeployAgentVersion" installer=/tmp/codedeploy-install
  if [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' codedeploy-agent || true)" != "$version" ]; then
    curl --fail --silent --show-error --location --retry 3 --output "$installer" \
      "https://aws-codedeploy-${SSM_Region}.s3.${SSM_Region}.amazonaws.com/latestv2/install"
    chmod 0755 "$installer"
    AWS_REGION="$SSM_Region" "$installer" auto \
      -v "releases/codedeploy-agent-${version}.$(uname -m).rpm"
    rm -f "$installer"
  fi
  systemctl enable --now codedeploy-agent
  log "CodeDeploy agent ${version}"
}

# What the platform scripts need and is not secret, so they take no parameters.
write_instance_env() {
  install -d -m 0755 /etc/wildfly-lifecycle
  cat > /etc/wildfly-lifecycle/instance.env <<ENV
REGION=${SSM_Region}
ENVIRONMENT=${SSM_Environment}
CONFIG_PATH=${SSM_ConfigPath}
SECRET_ID=${SSM_SecretId}
APP_PORT=${SSM_AppPort}
HEALTH_PATH=${SSM_HealthPath}
WILDFLY_VERSION=${SSM_WildFlyVersion}
CODEDEPLOY_AGENT_VERSION=${SSM_CodeDeployAgentVersion}
ANSIBLE_CORE_VERSION=$(rpm -q --qf '%{VERSION}' ansible-core)
ENV
}

# Port and bind as flags, not in standalone.xml. The '+' runs the helper as root despite
# User=wildfly; it writes the secrets to /run/wildfly (tmpfs, removed when the service stops).
# WildFly restarts only if the unit changed.
write_unit() {
  cat > "${UNIT}.new" <<UNIT
[Unit]
Description=WildFly (aws-wildfly-lifecycle)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=wildfly
Group=wildfly
RuntimeDirectory=wildfly
RuntimeDirectoryMode=0750
ExecStartPre=+${PLATFORM_BIN}/fetch-secrets.sh
EnvironmentFile=-/run/wildfly/secrets.env
ExecStart=/opt/wildfly/bin/standalone.sh ${BIND} -Djboss.http.port=${SSM_AppPort}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  if cmp -s "${UNIT}.new" "$UNIT"; then
    rm -f "${UNIT}.new"
    systemctl enable --now wildfly
  else
    mv -f "${UNIT}.new" "$UNIT"
    systemctl daemon-reload
    systemctl enable wildfly
    systemctl restart wildfly
  fi
}

main() {
  check_parameters
  install_packages
  install_platform
  # shellcheck source=remote/common.sh
  source "${PLATFORM_BIN}/common.sh"
  REGION="$SSM_Region"
  install_wildfly
  install_codedeploy_agent
  write_instance_env
  write_unit
  wait_running || die "WildFly is not running: journalctl -u wildfly"
  log "WildFly ${SSM_WildFlyVersion} running on ${SSM_AppPort}"
}

main "$@"
