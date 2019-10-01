#!/bin/bash
set -e -o pipefail
 
prepare_system() {
  ### Install system dependencies
  apt-get update
  DEBIAN_FRONTEND="noninteractive" \
    apt-get install -y --no-install-recommends locales gettext ca-certificates nginx libxmlsec1-dev pkg-config
  rm -rf /var/lib/apt/lists/*
  ### Setup system locale
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
  locale-gen
  update-locale LANGUAGE=en LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
}

install_python_dependencies() {
  LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" \
    pip install --no-cache-dir -r requirements.txt
}

install_configuration_files() {
  ### Setup legacy configuration symlinks
  mkdir -p /usr/src/taiga-front-dist/dist/js/
  ln -s ../conf.json /usr/src/taiga-front-dist/dist/js/conf.json
  ### Install nginx files
  cp -r /opt/taiga-conf/nginx /etc/
  ### Install nginx stdout/stderr symlinks
  ln -sf /dev/stdout /var/log/nginx/access.log
  ln -sf /dev/stderr /var/log/nginx/error.log
}

install_static_files() {
  python manage.py collectstatic --noinput
}

install_plugins() {
  # SAML auth
  pip install taiga-contrib-saml-auth==1.1.0
  mkdir -p /usr/src/taiga-front-dist/dist/plugins/saml-auth
  curl -L -o /tmp/taiga-contrib-saml-auth.tgz https://github.com/jgiannuzzi/taiga-contrib-saml-auth/archive/1.1.0.tar.gz
  tar -x -f /tmp/taiga-contrib-saml-auth.tgz --strip-components=3 -C /usr/src/taiga-front-dist/dist/plugins/saml-auth taiga-contrib-saml-auth-1.1.0/front/dist
  pip install taiga-contrib-ldap-auth-ext
}

prepare_system
install_python_dependencies
install_configuration_files
install_static_files
install_plugins
