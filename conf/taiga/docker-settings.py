# -*- coding: utf-8 -*-
# Importing common provides default settings, see:
# https://github.com/taigaio/taiga-back/blob/master/settings/common.py
import os
import json
from .common import *

def load_file(path):
    with open(path, 'r') as file:
        return file.read()

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.getenv('TAIGA_DB_NAME'),
        'HOST': os.getenv('TAIGA_DB_HOST'),
        'USER': os.getenv('TAIGA_DB_USER'),
        'PASSWORD': os.getenv('TAIGA_DB_PASSWORD')
    }
}

TAIGA_HOSTNAME = os.getenv('TAIGA_HOSTNAME')
URL_HTTP_SCHEME = '${URL_HTTP_SCHEME}'

SITES['api']['scheme'] = URL_HTTP_SCHEME
SITES['api']['domain'] = TAIGA_HOSTNAME
SITES['front']['scheme'] = URL_HTTP_SCHEME
SITES['front']['domain'] = TAIGA_HOSTNAME

MEDIA_URL  = URL_HTTP_SCHEME + '://' + TAIGA_HOSTNAME + '/media/'
STATIC_URL = URL_HTTP_SCHEME + '://' + TAIGA_HOSTNAME + '/static/'

SECRET_KEY = os.getenv('TAIGA_SECRET_KEY')

RABBIT_HOST = os.getenv('RABBIT_HOST') or ""
REDIS_HOST  = os.getenv('REDIS_HOST') or ""

if os.getenv('TAIGA_EVENTS_ENABLE').lower() == "true":
    from .celery import *

    BROKER_URL = 'amqp://guest:guest@{}'.format(RABBIT_HOST)
    CELERY_RESULT_BACKEND = 'redis://{}/0'.format(REDIS_HOST)
    CELERY_ENABLED = True

    EVENTS_PUSH_BACKEND = "taiga.events.backends.rabbitmq.EventsPushBackend"
    EVENTS_PUSH_BACKEND_OPTIONS = {"url": "amqp://guest:guest@{}/".format(REDIS_HOST)}

if os.getenv('TAIGA_ENABLE_EMAIL').lower() == 'true':
    DEFAULT_FROM_EMAIL = os.getenv('TAIGA_EMAIL_FROM')
    CHANGE_NOTIFICATIONS_MIN_INTERVAL = 300 # in seconds

    EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'

    if os.getenv('TAIGA_EMAIL_USE_TLS').lower() == 'true':
        EMAIL_USE_TLS = True
    else:
        EMAIL_USE_TLS = False

    EMAIL_HOST = os.getenv('TAIGA_EMAIL_HOST')
    EMAIL_PORT = int(os.getenv('TAIGA_EMAIL_PORT'))
    EMAIL_HOST_USER = os.getenv('TAIGA_EMAIL_USER')
    EMAIL_HOST_PASSWORD = os.getenv('TAIGA_EMAIL_PASS')

#########################################
## IMPORTERS
#########################################

# Configuration for the GitHub importer
# Remember to enable it in the front client too.
if os.getenv('TAIGA_ENABLE_GITHUB_IMPORTER', '').lower() == 'true':
    IMPORTERS["github"] = {
        "active": True,
        "client_id": os.getenv("TAIGA_GITHUB_CLIENT_ID"),
        "client_secret": os.getenv("TAIGA_GITHUB_CLIENT_SECRET")}

# Configuration for the Trello importer
# Remember to enable it in the front client too.
if os.getenv('TAIGA_ENABLE_TRELLO_IMPORTER', '').lower() == 'true':
    IMPORTERS["trello"] = {
        "active": True, # Enable or disable the importer
        "api_key": os.getenv("TAIGA_TRELLO_API_KEY"),
        "secret_key": os.getenv("TAIGA_TRELLO_SECRET_KEY")}

# Configuration for the Jira importer
# Remember to enable it in the front client too.
if os.getenv('TAIGA_ENABLE_JIRA_IMPORTER', '').lower() == 'true':
    IMPORTERS["jira"] = {
        "active": True, # Enable or disable the importer
        "consumer_key": os.getenv("TAIGA_JIRA_CONSUMER_KEY"),
        "cert": load_file(os.getenv("TAIGA_JIRA_CERT_FILE")),
        "pub_cert": load_file(os.getenv("TAIGA_JIRA_PUB_CERT"))}

# Configuration for the Asane importer
# Remember to enable it in the front client too.
if os.getenv('TAIGA_ENABLE_ASANA_IMPORTER', '').lower() == 'true':
    IMPORTERS["asana"]["active"] = True
    IMPORTERS["asana"]["app_id"] = os.getenv("TAIGA_ASANA_APP_ID")
    IMPORTERS["asana"]["app_secret"] = os.getenv("TAIGA_ASANA_APP_SECRET")
    IMPORTERS["asana"]["callback_url"] = "{}://{}/project/new/import/asana".format(
                                                                                  SITES["front"]["scheme"],
                                                                                  SITES["front"]["domain"])

#########################################
## SAML AUTH
#########################################

if os.getenv("SAML_AUTH_ENABLE").lower() == "true":
  INSTALLED_APPS += ["taiga_contrib_saml_auth"]
  SAML_AUTH = json.loads(os.getenv("SAML_AUTH_JSON_CONFIG") or 'null')
