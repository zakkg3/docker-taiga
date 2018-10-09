#!/bin/bash

set -o nounset
set -o pipefail
set -o errexit
set -o errtrace
[ -n "${TRACE:-}" ] && set -o xtrace

NGINX_PID=
TAIGA_PID=

printerr() {
  echo "${@}" >&2
}

setup_db() {
  echo "Running database check"
  python /checkdb.py
  DB_CHECK_STATUS=$?

  if [ ${DB_CHECK_STATUS} -eq 1 ]; then
    printerr "Failed to connect to database server or database does not exist."
    exit 1
  elif [ ${DB_CHECK_STATUS} -eq 2 ]; then
    echo "Configuring initial database"
    python manage.py migrate --noinput
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
  sed -i "s/eventsUrl\": null/eventsUrl\": \"ws:\/\/${TAIGA_HOSTNAME}\/events\"/g" /taiga/conf.json
  sed -i "s/TAIGA_EVENTS_HOSTNAME/${TAIGA_EVENTS_HOSTNAME}/" /etc/nginx/conf.d/default.conf
}

enable_external_ssl() {
  echo "Enabling external SSL support! SSL handling must be done by a reverse proxy or a similar system"
  sed -i "s/http:\/\//https:\/\//g" /taiga/conf.json
  sed -i "s/ws:\/\//wss:\/\//g" /taiga/conf.json
}

enable_ssl() {
  echo "Enabling SSL support!"
  sed -i "s/http:\/\//https:\/\//g" /taiga/conf.json
  sed -i "s/ws:\/\//wss:\/\//g" /taiga/conf.json
  mv /etc/nginx/ssl.conf /etc/nginx/conf.d/default.conf
}

disable_ssl() {
  echo "Disabling SSL support!"
  sed -i "s/https:\/\//http:\/\//g" /taiga/conf.json
  sed -i "s/wss:\/\//ws:\/\//g" /taiga/conf.json
}

shutdown_trap () {
  echo "Received SIGTERM signal. Shutting down services..."
  nginx -s stop
  kill -s SIGTERM $TAIGA_PID
  echo "Sent stop signal to all services."
}

main() {
  # Sleep when asked to, to allow the database time to start
  # before Taiga tries to run /checkdb.py below.
  : "${TAIGA_SLEEP:=0}"
  sleep "${TAIGA_SLEEP}"

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
  sed -i "s/TAIGA_HOSTNAME/${TAIGA_HOSTNAME:-}/g" /taiga/conf.json

  # Look to see if we should set the "eventsUrl"
  if [ ! -z "${TAIGA_EVENTS_ENABLE:-}" ]; then
    enable_taiga_events
  fi

  # Handle enabling/disabling SSL
  if [ "${TAIGA_SSL_BY_REVERSE_PROXY:-}" = "True" ]; then
    enable_external_ssl
  elif [ "${TAIGA_SSL:-}" = "True" ]; then
    enable_ssl
  elif grep -q "wss://" "/taiga/conf.json"; then
    disable_ssl
  fi

  # Start nginx service and Taiga Django server, as background shell processes
  echo "Starting taiga+nginx"
  nginx -g "daemon off;" &
  NGINX_PID=${!}

  exec "${@}" &
  TAIGA_PID=${!}

  # Register handler for clean termination of the processes
  trap shutdown_trap SIGTERM

  # Wait until both processes have exited
  wait ${NGINX_PID}
  wait ${TAIGA_PID}
  echo "All background services have exited. Terminating."
}

main "${@}"
