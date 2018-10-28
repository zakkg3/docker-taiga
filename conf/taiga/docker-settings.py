# -*- coding: utf-8 -*-
# Importing common provides default settings, see:
# https://github.com/taigaio/taiga-back/blob/master/settings/common.py
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

SITES['api']['domain'] = TAIGA_HOSTNAME
SITES['front']['domain'] = TAIGA_HOSTNAME

MEDIA_URL  = 'http://' + TAIGA_HOSTNAME + '/media/'
STATIC_URL = 'http://' + TAIGA_HOSTNAME + '/static/'

SECRET_KEY = os.getenv('TAIGA_SECRET_KEY')

if os.getenv('TAIGA_SSL').lower() == 'true' or os.getenv('TAIGA_SSL_BY_REVERSE_PROXY').lower() == 'true':
    SITES['api']['scheme'] = 'https'
    SITES['front']['scheme'] = 'https'

    MEDIA_URL  = 'https://' + TAIGA_HOSTNAME + '/media/'
    STATIC_URL = 'https://' + TAIGA_HOSTNAME + '/static/'

if os.getenv('RABBIT_PORT') is not None and os.getenv('REDIS_PORT') is not None:
    from .celery import *

    BROKER_URL = 'amqp://guest:guest@rabbit:5672'
    CELERY_RESULT_BACKEND = 'redis://redis:6379/0'
    CELERY_ENABLED = True

    EVENTS_PUSH_BACKEND = "taiga.events.backends.rabbitmq.EventsPushBackend"
    EVENTS_PUSH_BACKEND_OPTIONS = {"url": "amqp://guest:guest@rabbit:5672//"}

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
        "pub_cert": load_file(os.getenv("TIAGA_JIRA_PUB_CERT"))}

# Configuration for the Asane importer
# Remember to enable it in the front client too.
if os.getenv('TAIGA_ENABLE_ASANA_IMPORTER', '').lower() == 'true':
    IMPORTERS["asana"]["active"] = True
    IMPORTERS["asana"]["app_id"] = os.getenv("TAIGA_ASANA_APP_ID")
    IMPORTERS["asana"]["app_secret"] = os.getenv("TAIGA_ASANA_APP_SECRET")
    IMPORTERS["asana"]["callback_url"] = "{}://{}/project/new/import/asana".format(
                                                                                  SITES["front"]["scheme"],
                                                                                  SITES["front"]["domain"])
