#!/bin/bash

set -o nounset
set -o pipefail
set -o errexit
set -o errtrace
[ -n "${TRACE:-}" ] && set -o xtrace

NGINX_PID=
TAIGA_PID=

BACK_CONFIG_FILE=/usr/src/taiga-back/settings/local.py
FRONT_CONFIG_FILE=/usr/src/taiga-front-dist/dist/conf.json

printerr() {
  echo "${@}" >&2
}

wait_for_db() {
  : "${TAIGA_SLEEP:=0}"
  echo "Waiting for DB to come up (timeout ${TAIGA_SLEEP} seconds)..."
  while [ "${TAIGA_SLEEP}" -ge 0 ]; do
    TAIGA_SLEEP=$((TAIGA_SLEEP-1))
    DB_CHECK_STATUS=$(python /opt/taiga-bin/checkdb.py >/dev/null 2>&1; echo ${?})
    grep -q "[02]" <<< "${DB_CHECK_STATUS}" && return 0
    [ "${TAIGA_SLEEP}" -gt 0 ] && sleep 1
  done
  echo "Timed out while waiting for DB. Giving up."
  return 1
}

setup_db() {
  echo "Running database check"
  DB_CHECK_STATUS=$(python /opt/taiga-bin/checkdb.py >/dev/null 2>&1; echo ${?})

  if [ "${DB_CHECK_STATUS}" -eq 1 ]; then
    printerr "Failed to connect to database server or database does not exist."
    exit 1
  fi

  echo "Apply database migrations"
  python manage.py migrate --noinput

  if [ "${DB_CHECK_STATUS}" -eq 2 ]; then
    echo "Configuring initial database"
    python manage.py loaddata initial_user
    python manage.py loaddata initial_project_templates
    python manage.py compilemessages
  fi

  echo "Database checks completed."
}

generate_static_files() {
  echo "Static content folder not found. Generating it."
  python manage.py collectstatic --noinput
  echo "Static content folder generated."
}

enable_taiga_events() {
  echo "Enabling Taiga Events"
  mv /etc/nginx/taiga-events.conf /etc/nginx/conf.d/default.conf
  sed -i "s/eventsUrl\": null/eventsUrl\": \"ws:\/\/${TAIGA_HOSTNAME}\/events\"/g" "${FRONT_CONFIG_FILE}"
  sed -i "s/TAIGA_EVENTS_HOSTNAME/${TAIGA_EVENTS_HOSTNAME}/" /etc/nginx/conf.d/default.conf
}

enable_external_ssl() {
  echo "Enabling external SSL support! SSL handling must be done by a reverse proxy or a similar system"
  sed -i "s/http:\/\//https:\/\//g" "${FRONT_CONFIG_FILE}"
  sed -i "s/ws:\/\//wss:\/\//g" "${FRONT_CONFIG_FILE}"
}

enable_ssl() {
  echo "Enabling SSL support!"
  sed -i "s/http:\/\//https:\/\//g" "${FRONT_CONFIG_FILE}"
  sed -i "s/ws:\/\//wss:\/\//g" "${FRONT_CONFIG_FILE}"
  mv /etc/nginx/ssl.conf /etc/nginx/conf.d/default.conf
}

disable_ssl() {
  echo "Disabling SSL support!"
  sed -i "s/https:\/\//http:\/\//g" "${FRONT_CONFIG_FILE}"
  sed -i "s/wss:\/\//ws:\/\//g" "${FRONT_CONFIG_FILE}"
}

shutdown_trap () {
  echo "Received SIGTERM signal. Shutting down services..."
  ps -p $NGINX_PID >/dev/null 2>&1 && nginx -s stop
  ps -p $TAIGA_PID >/dev/null 2>&1 && kill -s SIGTERM $TAIGA_PID
  echo "Sent stop signal to all services. Unregistering SIGTERM handler."
  trap '' SIGTERM
}

main() {
  # Wait for DB to come up, before continuing
  if ! wait_for_db; then
    printerr "Waiting for DB failed. Aborting."
    exit 1
  fi

  # Install to-be-templated configuration files
  cp /opt/taiga-conf/taiga/local.py "${BACK_CONFIG_FILE}"
  cp /opt/taiga-conf/taiga/conf.json "${FRONT_CONFIG_FILE}"

  # Setup database automatically if needed
  if [ -z "${TAIGA_SKIP_DB_CHECK:-}" ]; then
    setup_db
  fi

  # Exit after initializing the database
  if [ -n "${TAIGA_DB_CHECK_ONLY:-}" ]; then
    echo "Requested database-check only run. Exiting."
    exit 0
  fi

  # Look for static folder, if it does not exist, then generate it
  if [ ! -d "/usr/src/taiga-back/static" ]; then
    generate_static_files
  fi

  if [ -z "${TAIGA_HOSTNAME:-}" ]; then
    printerr "You have to provide TAIGA_HOSTNAME env var."
    exit 1
  fi

  # Automatically replace "TAIGA_HOSTNAME" with the environment variable
  sed -i "s/TAIGA_HOSTNAME/${TAIGA_HOSTNAME:-}/g" "${FRONT_CONFIG_FILE}"

  # Look to see if we should set the "eventsUrl"
  if [ ! -z "${TAIGA_EVENTS_ENABLE:-}" ]; then
    enable_taiga_events
  fi

  # Handle enabling/disabling SSL
  if [ "${TAIGA_SSL_BY_REVERSE_PROXY:-}" = "True" ]; then
    enable_external_ssl
  elif [ "${TAIGA_SSL:-}" = "True" ]; then
    enable_ssl
  elif grep -q "wss://" "${FRONT_CONFIG_FILE}"; then
    disable_ssl
  fi

  # Start the requested services, as background shell processes
  : "${TAIGA_COMPONENT:=}"
  if [ -z "${TAIGA_COMPONENT}" -o "${TAIGA_COMPONENT}" = "front" ]; then
    echo "Starting nginx..."
    nginx -g "daemon off;" &
    NGINX_PID=${!}
  fi

  if [ -z "${TAIGA_COMPONENT}" -o "${TAIGA_COMPONENT}" = "back" ]; then
    echo "Starting taiga backend..."
    exec "${@}" &
    TAIGA_PID=${!}
  fi
    
  # Register handler for clean termination of the processes
  echo "Registering SIGTERM handler..."
  trap shutdown_trap SIGTERM

  # Wait until both processes have exited
  echo "All background services have been started. Waiting on PIDs: ${NGINX_PID} ${TAIGA_PID}"
  wait -n ${NGINX_PID} ${TAIGA_PID} || true
  echo "At least one of the background services has terminated. Sending SIGTERM to shell..."
  kill -SIGTERM $$
  wait ${NGINX_PID} ${TAIGA_PID} || true
  echo "All background services have exited. Terminating."
}

main "${@}"
