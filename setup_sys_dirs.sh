#!/usr/bin/env bash

DEFAULT_SYS_GROUP='users'

source $(cd `dirname "${BASH_SOURCE[0]}"` && pwd)/env_vars.sh

service_user() {
    groupadd --system ${SERVICE_GROUP}
    useradd --system --gid ${SERVICE_GROUP} --shell /bin/bash ${SERVICE_USER}
}

web_dirs() {
    mkdir ${WEBAPP_DIR}
    chown -R ${SERVICE_USER}:${DEFAULT_SYS_GROUP} ${WEBAPP_DIR}
    chmod -R g+w ${WEBAPP_DIR}

    cd ${WEBAPP_DIR}
    for d in 'services' 'run' 'logs'; do
        mkdir -p "$d"
        chown -R ${SERVICE_USER}:${SERVICE_GROUP} "$d"
    done
}

cronjobs_dirs() {
    mkdir ${CRONJOBS_DIR}
    chown -R ${SERVICE_USER}:${DEFAULT_SYS_GROUP} ${CRONJOBS_DIR}
    chmod -R g+w ${CRONJOBS_DIR}

    cd ${CRONJOBS_DIR}
    for d in 'services' 'logs'; do
        mkdir -p "$d"
        chown -R ${SERVICE_USER}:${SERVICE_GROUP} "$d"
    done
}


ACTIONS_LIST="service_user web_dirs cronjobs_dirs"
[ -n "$1" ] && ACTIONS_LIST="$*"
for action in ${ACTIONS_LIST}; do
  ${action}
done
