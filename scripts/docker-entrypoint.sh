#!/bin/bash

set -o nounset
set -o pipefail
set -o errexit
set -o errtrace
[ -n "${TRACE:-}" ] && set -o xtrace

NGINX_PID=
TAIGA_PID=

BACK_LOCAL_CONFIG_FILE=/usr/src/taiga-back/settings/local.py
BACK_DOCKER_CONFIG_FILE=/usr/src/taiga-back/settings/docker.py
FRONT_CONFIG_FILE=/usr/src/taiga-front-dist/dist/conf.json
NGINX_CONFIG_FILE=/etc/nginx/conf.d/default.conf

printerr() {
  echo "${@}" >&2
}

wait_for_db() {
  : "${TAIGA_SLEEP:=0}"
  echo "Waiting for DB to come up (timeout ${TAIGA_SLEEP} seconds)..."
  while [ "${TAIGA_SLEEP}" -gt 0 ]; do
    TAIGA_SLEEP=$((TAIGA_SLEEP-1))
    DB_CHECK_STATUS=$(python /opt/taiga-bin/checkdb.py >/dev/null 2>&1; echo ${?})
    grep -q "[02]" <<< "${DB_CHECK_STATUS}" && return 0
    sleep 1
  done
  echo "Max sleep time reached while waiting for DB. Giving up."
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

setup_config_files() {
  echo "Templating out taiga and nginx configuration files"
  if [ -z "${TAIGA_HOSTNAME:-}" ]; then
    printerr "You have to provide TAIGA_HOSTNAME env var."
    exit 1
  fi
  export NGINX_SOURCE_CONFIG=/etc/nginx/taiga-available/default.conf
  export NGINX_TAIGA_EVENTS_SHARD=""
  export URL_HTTP_SCHEME=http
  export URL_WS_SCHEME=ws
  export URL_TAIGA_EVENTS=null

  # Setup SSL configuration variables
  if grep -q -i true <<<${TAIGA_SSL_BY_REVERSE_PROXY}; then
    echo "Enabling external SSL support! SSL handling must be done by a reverse proxy or a similar system"
    URL_HTTP_SCHEME=https
    URL_WS_SCHEME=wss
  elif grep -q -i true <<<${TAIGA_SSL}; then
    echo "Enabling SSL support! Certificate and key will be read from files '/etc/nginx/ssl/ssl.crt' and /etc/nginx/ssl/ssl.key"
    URL_HTTP_SCHEME=https
    URL_WS_SCHEME=wss
    NGINX_SOURCE_CONFIG=/etc/nginx/taiga-available/ssl.conf
  fi

  # Setup taiga events configuration variables
  if grep -q -i true <<<${TAIGA_EVENTS_ENABLE:-}; then
    NGINX_TAIGA_EVENTS_SHARD="    # Events
    location /events {
       proxy_pass http://${TAIGA_EVENTS_HOSTNAME}/events;
       proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_connect_timeout 7d;
       proxy_send_timeout 7d;
       proxy_read_timeout 7d;
    }"
    URL_TAIGA_EVENTS="\"${URL_WS_SCHEME}://${TAIGA_EVENTS_HOSTNAME}/events\""
  fi

  # Template out configuration files
  local NGINX_ENVSUBST_VARIABLES='${NGINX_TAIGA_EVENTS_SHARD}'
  local BACK_ENVSUBST_VARIABLES='${URL_HTTP_SCHEME} ${URL_WS_SCHEME}'
  local FRONT_ENVSUBST_VARIABLES='${URL_HTTP_SCHEME} ${URL_WS_SCHEME} ${TAIGA_HOSTNAME} ${URL_TAIGA_EVENTS}'
  mkdir -p /etc/nginx/conf.d
  envsubst "${NGINX_ENVSUBST_VARIABLES}" <${NGINX_SOURCE_CONFIG}                   >${NGINX_CONFIG_FILE}
  envsubst "${BACK_ENVSUBST_VARIABLES}"  </opt/taiga-conf/taiga/local.py           >${BACK_LOCAL_CONFIG_FILE}
  envsubst "${BACK_ENVSUBST_VARIABLES} " </opt/taiga-conf/taiga/docker-settings.py >${BACK_DOCKER_CONFIG_FILE}
  envsubst "${FRONT_ENVSUBST_VARIABLES}" </opt/taiga-conf/taiga/conf.json          >${FRONT_CONFIG_FILE}
}

shutdown_trap () {
  echo "Received SIGTERM signal. Shutting down services..."
  ps -p $NGINX_PID >/dev/null 2>&1 && nginx -s stop
  ps -p $TAIGA_PID >/dev/null 2>&1 && kill -s SIGTERM $TAIGA_PID
  echo "Sent stop signal to all services. Unregistering SIGTERM handler."
  trap '' SIGTERM
}

main() {
  # Template out the required configuration files, based on env vars
  setup_config_files

  # Wait for DB to come up, before continuing
  if ! wait_for_db; then
    echo "Database is not yet reachable. Continuing execution anyway."
  fi

  # Setup database automatically if needed
  if [ -z "${TAIGA_SKIP_DB_CHECK:-}" ]; then
    setup_db
    if [ -n "${TAIGA_DB_CHECK_ONLY:-}" ]; then
      echo "Requested database-check only run. Exiting."
      exit 0
    fi
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
