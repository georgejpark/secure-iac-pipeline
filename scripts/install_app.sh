#!/usr/bin/env bash
#
# install-app.sh <env>
#
# Installs the inspection service on every app container in one environment.
#
# Why this is a separate step and not part of the pipeline:
#   Terraform talks to the Proxmox API to build machines; it never logs into
#   them, and the runner holds no SSH key for a workload. This is a separation
#   of duties, not a network impossibility -- the runner sits on the SAME /24 as
#   its own environment's containers and could reach them. What it cannot reach
#   is any OTHER environment. So installing the application is a separate stage
#   that runs here on the host.
#
# Safe to run repeatedly. A container that is already serving is skipped.

set -euo pipefail

ENVIRONMENT="${1:-}"
case "$ENVIRONMENT" in
  dev|stage|prod) ;;
  *) echo "usage: $0 <dev|stage|prod>" >&2; exit 2 ;;
esac

VERSION="$(cat /opt/app-source/VERSION)"
SRC=/opt/app-source

# Find every running container named app-<env>-N and note its VMID.
mapfile -t VMIDS < <(pct list | awk -v pat="^app-${ENVIRONMENT}-" \
  '$3 ~ pat && $2 == "running" {print $1}')

if [ "${#VMIDS[@]}" -eq 0 ]; then
  echo "no running app-${ENVIRONMENT}-* containers found"; exit 0
fi

echo "environment=${ENVIRONMENT}  version=${VERSION}  containers=${#VMIDS[@]}"

for VMID in "${VMIDS[@]}"; do
  NAME="$(pct list | awk -v id="$VMID" '$1 == id {print $3}')"

  # Already serving the right version? Leave it alone.
  if pct exec "$VMID" -- curl -fsS --max-time 3 http://127.0.0.1:8080/version 2>/dev/null \
       | grep -q "\"${VERSION}\""; then
    echo "  ${NAME} (${VMID})  already serving ${VERSION}  - skipped"
    continue
  fi

  echo "  ${NAME} (${VMID})  installing ${VERSION} ..."

  # 1. The service account the app runs as. Never root.
  pct exec "$VMID" -- bash -c \
    'id rapta >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/rapta --shell /usr/sbin/nologin rapta'

  # 2. Python, curl, and the venv module.
  #    Test for what is actually needed, not for what looks close enough:
  #    "python3 -m venv --help" succeeds on a stock Debian 13 container even
  #    though building a venv then fails, because the help text lives in the
  #    stdlib while the machinery lives in a separate package. Import ensurepip
  #    instead -- that is the piece that is genuinely missing.
  pct exec "$VMID" -- bash -c '
    need=""
    command -v python3 >/dev/null 2>&1 || need="$need python3"
    command -v curl    >/dev/null 2>&1 || need="$need curl"
    python3 -c "import ensurepip" >/dev/null 2>&1 || need="$need python3-venv"
    if [ -n "$need" ]; then
      export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
      # Output goes to a log rather than the screen. apt prints several hundred
      # lines here and it buries the thing we actually want to read.
      { apt-get update -qq && apt-get install -y -qq $need; } >/var/log/app-install.log 2>&1 \
        || { echo "apt failed, see /var/log/app-install.log inside the container"; tail -20 /var/log/app-install.log; exit 1; }
    fi
    python3 -c "import ensurepip"
  '

  # 3. Copy this release into its own directory. Old releases stay on disk,
  #    which is what makes a rollback a symlink change instead of a redeploy.
  REL="/opt/rapta/inspection/releases/${VERSION}"
  pct exec "$VMID" -- mkdir -p "$REL"
  for f in app.py requirements.txt VERSION; do
    pct push "$VMID" "${SRC}/${f}" "${REL}/${f}" --perms 644
  done

  # 4. A virtualenv per release, so two releases can need different packages.
  pct exec "$VMID" -- bash -c "test -x ${REL}/venv/bin/python || python3 -m venv ${REL}/venv"
  pct exec "$VMID" -- bash -c "${REL}/venv/bin/pip install -q --disable-pip-version-check -r ${REL}/requirements.txt >>/var/log/app-install.log 2>&1 || true"

  # 5. Flip the symlink. This is the actual release: one atomic pointer move.
  pct exec "$VMID" -- ln -sfn "$REL" /opt/rapta/inspection/current
  pct exec "$VMID" -- chown -R rapta:rapta /opt/rapta

  # 6. The systemd unit. Points at 'current', never at a version, so a
  #    rollback needs no change here.
  pct push "$VMID" "${SRC}/inspection-service.service" \
    /etc/systemd/system/inspection-service.service --perms 644
  pct exec "$VMID" -- systemctl daemon-reload
  pct exec "$VMID" -- systemctl enable --quiet inspection-service
  pct exec "$VMID" -- systemctl restart inspection-service

  # 7. Wait for it. The app holds /health at 503 for a startup grace period,
  #    so checking immediately would race and report a false failure.
  OK=no
  for _ in $(seq 1 20); do
    if pct exec "$VMID" -- curl -fsS --max-time 2 http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then
      OK=yes; break
    fi
    sleep 1
  done

  if [ "$OK" = yes ]; then
    echo "    ${NAME} serving $(pct exec "$VMID" -- curl -fsS http://127.0.0.1:8080/version)"
  else
    echo "    ${NAME} DID NOT COME UP"
    pct exec "$VMID" -- systemctl status inspection-service --no-pager -l | head -20
    exit 1
  fi
done

echo "done"
