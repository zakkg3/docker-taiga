#!/bin/bash

set -o nounset
set -o pipefail
set -o errexit
set -o errtrace
[ -n "${TRACE:-}" ] && set -o xtrace

NGINX_PID=
TAIGA_PID=

BACK_LOCAL_CONFIG=/usr/src/taiga-back/settings/local.py
BACK_DOCKER_CONFIG=/usr/src/taiga-back/settings/docker.py
FRONT_CONFIG=/usr/src/taiga-front-dist/dist/conf.json
NGINX_CONFIG=/etc/nginx/conf.d/default.conf

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
  export NGINX_CONFIG_SOURCE=/etc/nginx/taiga-available/default.conf
  export NGINX_SHARDS_DIR_SOURCE=/etc/nginx/taiga-available/shards
  export NGINX_SHARDS_DIR=/etc/nginx/taiga-shards
  export NGINX_SHARDS_LIST=""
  export CONTRIB_PLUGINS_LIST=""
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
    NGINX_CONFIG_SOURCE=/etc/nginx/taiga-available/ssl.conf
  fi

  # Setup taiga events configuration variables
  if grep -q -i true <<<${TAIGA_EVENTS_ENABLE:-}; then
    NGINX_SHARDS_LIST="${NGINX_SHARDS_LIST:-} taiga_events.conf"
    URL_TAIGA_EVENTS="\"${URL_WS_SCHEME}://${TAIGA_EVENTS_HOSTNAME}/events\""
  fi

  # Setup SAML auth
  if grep -q -i true <<<${SAML_AUTH_ENABLE:-}; then
    NGINX_SHARDS_LIST="${NGINX_SHARDS_LIST:-} saml_auth.conf"
    CONTRIB_PLUGINS_LIST="${CONTRIB_PLUGINS_LIST:-} \"/plugins/saml-auth/saml-auth.json\""
    cat >>/usr/src/taiga-back/taiga/urls.py <<EOF
### SAML Auth
urlpatterns += [url(r'^saml/', include('taiga_contrib_saml_auth.urls'))]
EOF
  fi
  # Setup LDAP environment
  if grep -q -i true <<<${LDAP_AUTH_ENABLE:-}; then
    export LOGIN_FORM_TYPE="ldap"   
  fi
  # Setup SLACK Integration
  if grep -q -i true <<<${SLACK_INTEGRATION_ENABLE:-}; then
    CONTRIB_PLUGINS_LIST="${CONTRIB_PLUGINS_LIST:-} \"/plugins/slack/slack.json\""
  fi

  # Prepare plugins variable
  local CONTRIB_PLUGINS=$(python -c 'import sys; print(", ".join( list(filter(None,sys.argv[1:])) ))' ${CONTRIB_PLUGINS_LIST:-})

  # Template out configuration files
  local NGINX_ENVSUBST_VARIABLES='${NGINX_SHARDS_DIR} ${TAIGA_EVENTS_HOSTNAME}'
  local BACK_ENVSUBST_VARIABLES='${URL_HTTP_SCHEME} ${URL_WS_SCHEME}'
  local FRONT_ENVSUBST_VARIABLES='${URL_HTTP_SCHEME} ${URL_WS_SCHEME} ${TAIGA_HOSTNAME} ${URL_TAIGA_EVENTS} ${CONTRIB_PLUGINS_LIST} ${LOGIN_FORM_TYPE}'
  mkdir -p /etc/nginx/conf.d "${NGINX_SHARDS_DIR}"
  envsubst "${NGINX_ENVSUBST_VARIABLES}" <${NGINX_CONFIG_SOURCE}                   >${NGINX_CONFIG}
  #envsubst "${BACK_ENVSUBST_VARIABLES}"  </opt/taiga-conf/taiga/local.py           >${BACK_LOCAL_CONFIG}
  # Commented to allow mount configmap. aniway this iwll import from .docker *: next line.
  envsubst "${BACK_ENVSUBST_VARIABLES}"  </opt/taiga-conf/taiga/docker-settings.py >${BACK_DOCKER_CONFIG}
  envsubst "${FRONT_ENVSUBST_VARIABLES}" </opt/taiga-conf/taiga/conf.json          >${FRONT_CONFIG}
  for shard in ${NGINX_SHARDS_LIST}; do
    envsubst "${NGINX_ENVSUBST_VARIABLES}" <${NGINX_SHARDS_DIR_SOURCE}/${shard} >${NGINX_SHARDS_DIR}/${shard}
  done
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
