#!/bin/bash
# Runs one Airflow component in a container, in the foreground. Installed by the
# bootstrap as /usr/local/bin/airflow-run and started by the airflow-<component>
# systemd services:  airflow-run <db-migrate|api-server|scheduler|dag-processor|triggerer>
#
# Health checks: a component that hangs (not just one that exits) is detected.
# With podman the unhealthy container is killed and systemd restarts it.
# Docker only marks it unhealthy (see `docker ps`); it has no kill-on-unhealthy.
set -euo pipefail

# RUNTIME (full path to podman or docker), IMAGE and SELINUX_LABEL (z or empty),
# written by the bootstrap.
# shellcheck disable=SC1091
. /etc/airflow/run.conf

c=${1:?usage: airflow-run <component>}
home=/usr/local/airflow
label=${SELINUX_LABEL:+:$SELINUX_LABEL}

args=(
  run --rm --name "airflow-$c" --network host
  --env-file /etc/airflow/airflow.env
  -v "/opt/airflow/dags:$home/dags:ro${SELINUX_LABEL:+,$SELINUX_LABEL}"
  -v "/opt/airflow/logs:$home/logs$label"
  -v "/opt/airflow/config:$home/config$label"
)

health=''
case "$c" in
  db-migrate) cmd=(airflow db migrate) ;;
  api-server)
    cmd=(airflow api-server --port 8080)
    health="python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/v2/monitor/health', timeout=20)\""
    ;;
  scheduler)
    cmd=(airflow scheduler)
    health='airflow jobs check --job-type SchedulerJob --local'
    ;;
  dag-processor)
    cmd=(airflow dag-processor)
    health='airflow jobs check --job-type DagProcessorJob --local'
    ;;
  triggerer)
    cmd=(airflow triggerer)
    health='airflow jobs check --job-type TriggererJob --local'
    ;;
  *)
    echo "unknown component: $c" >&2
    exit 2
    ;;
esac

if [ -n "$health" ]; then
  args+=(--health-cmd "$health" --health-interval 60s --health-timeout 45s --health-start-period 180s --health-retries 3)
  if [ "${RUNTIME##*/}" = podman ]; then args+=(--health-on-failure kill); fi
fi

exec "$RUNTIME" "${args[@]}" "$IMAGE" "${cmd[@]}"
