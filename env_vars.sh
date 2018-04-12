#!/usr/bin/env bash

SERVICE_NAME='prodsyspa'
SERVICE_USER='p2user'
SERVICE_GROUP='p2group'

export SERVICE_NAME SERVICE_USER SERVICE_GROUP

SERVICE_HOSTNAME='prodsys-pa-ui.cern.ch'

export SERVICE_HOSTNAME

WEBAPP_DIR='/home/web'
CRONJOBS_DIR='/home/cronjobs'

export WEBAPP_DIR CRONJOBS_DIR
