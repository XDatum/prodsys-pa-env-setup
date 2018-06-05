#!/usr/bin/env bash

#
# required: python, pip,
# required: python-devel.x86_64, gcc.x86_64
#

OS='centos'
OSRELEASE='7'
PLATFORM='x86_64'

source $(cd `dirname "${BASH_SOURCE[0]}"` && pwd)/env_vars.sh

WEBAPP_LOG_DIR=${WEBAPP_DIR}/logs

DJANGOAPP_DIR=${WEBAPP_DIR}/service
DJANGOAPP_NAME='p2paweb'

pkgs() {
    cd ${WEBAPP_DIR}
    sudo -u ${SERVICE_USER} -H bash << EOF
    virtualenv .
    . bin/activate
    pip install Django==1.11.* djangorestframework gunicorn setproctitle celery argparse numpy
EOF
}

nginx() {
    cat << EOF > /etc/yum.repos.d/nginx.repo
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/${OS}/${OSRELEASE}/${PLATFORM}/
gpgcheck=0
enabled=1
EOF

    yum install -y nginx
    mv /etc/nginx/conf.d/ssl.conf{,.disabled}
    rm -f /etc/nginx/conf.d/*.conf

    NGINX_ACCESS_LOG_FILE=${WEBAPP_LOG_DIR}/nginx-access.log
    NGINX_ERROR_LOG_FILE=${WEBAPP_LOG_DIR}/nginx-error.log

    cat << EOF > /etc/nginx/conf.d/nginx.conf
user  nginx;
worker_processes  4;

pid  /var/run/nginx.pid;

events {
    worker_connections    1024;
    accept_mutex          on;       # "on" if nginx worker_processes > 1
    use                   epoll;    # for Linux 2.6+
}


http {
    include              /etc/nginx/mime.types;
    default_type         application/octet-stream;

    log_format  main     '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                         '\$status \$body_bytes_sent "\$http_referer" '
                         '"\$http_user_agent" "\$http_x_forwarded_for"';

    sendfile             on;
    #tcp_nopush          on;
    keepalive_timeout    65;
    #gzip                on;

    upstream web_app_server {
        server    unix:${WEBAPP_DIR}/run/gunicorn.sock fail_timeout=0;
    }

    server {
        listen         80;
        server_name    ${SERVICE_HOSTNAME};
        return         301    https://\$server_name:443\$request_uri;
    }

    server {
        listen         443 ssl;
        server_name    ${SERVICE_HOSTNAME};

        error_page     497    https://\$server_name:\$server_port\$request_uri;

        add_header     Strict-Transport-Security max-age=31536000;
        add_header     X-Frame-Options DENY;
        add_header     X-Content-Type-Options nosniff;

        ssl_certificate           /etc/ssl/server.crt;
        ssl_certificate_key       /etc/ssl/server.key;
        ssl_client_certificate    /etc/ssl/certs/ca-bundle.crt;
        ssl_verify_client         on;
        ssl_verify_depth          7;

        ssl_session_timeout       10m;
        ssl_session_cache         shared:SSL:50m;

        ssl_protocols    TLSv1 TLSv1.1 TLSv1.2;
        ssl_prefer_server_ciphers    on;
        ssl_ciphers    'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';

        access_log    ${NGINX_ACCESS_LOG_FILE}  main;
        error_log     ${NGINX_ERROR_LOG_FILE};

        location / {
            try_files    \$uri    @proxy_to_app;
        }

        location @proxy_to_app {
            proxy_set_header    X-SSL-User-DN          \$ssl_client_s_dn;
            proxy_set_header    X-SSL-Authenticated    \$ssl_client_verify;
            proxy_set_header    X-Rest-API             0; # Change to 1 to bypass
            proxy_set_header    X-Real-IP              \$remote_addr;
            proxy_set_header    X-Scheme               \$scheme;

            proxy_set_header    X-Forwarded-For        \$proxy_add_x_forwarded_for;
            proxy_set_header    X-Forwarded-Proto      \$scheme;
            proxy_set_header    Host                   \$http_host;

            proxy_redirect      off;
            proxy_pass          http://web_app_server;
        }

        location /static/ {
            alias    ${DJANGOAPP_DIR}/${DJANGOAPP_NAME}/static/;
        }
    }
}
EOF

    touch ${NGINX_ACCESS_LOG_FILE} ${NGINX_ERROR_LOG_FILE}
    chown nginx:nginx ${NGINX_ACCESS_LOG_FILE} ${NGINX_ERROR_LOG_FILE}

    setenforce 0
    chkconfig --levels 345 nginx on
    service nginx status && service nginx reload || service nginx start
}

supervisor() {
    SUPERVISOR_CONFIG_FILE=/etc/supervisord.conf
    SUPERVISOR_CONFIG_DIR=/etc/supervisord.d/

    pip install supervisor
    echo_supervisord_conf > ${SUPERVISOR_CONFIG_FILE}
    mkdir ${SUPERVISOR_CONFIG_DIR}

    cat << EOF >> ${SUPERVISOR_CONFIG_FILE}
[include]
files = ${SUPERVISOR_CONFIG_DIR}*.conf
EOF

    cat << EOF > /etc/rc.d/init.d/supervisord
#!/bin/sh
#
# /etc/rc.d/init.d/supervisord
#
# Supervisor is a client/server system that
# allows its users to monitor and control a
# number of processes on UNIX-like operating
# systems.
#
# chkconfig: - 64 36
# description: Supervisor Server
# processname: supervisord

# Source init functions
. /etc/rc.d/init.d/functions

prog="supervisord"

prog_bin="/usr/local/bin/\${prog}"
prog_config="${SUPERVISOR_CONFIG_FILE}"
prog_pidfile="/var/run/\${prog}.pid"

start()
{
       echo -n \$"Starting \${prog}: "
       daemon \${prog_bin} -c \${prog_config} --pidfile \${prog_pidfile}
       [ -f \${prog_pidfile} ] && success \$"\${prog} startup" || failure \$"\${prog} startup"
       echo
}

stop()
{
       echo -n \$"Shutting down \${prog}: "
       [ -f \${prog_pidfile} ] && killproc \${prog} || success \$"\${prog} shutdown"
       echo
}

case "\$1" in

 start)
   start
 ;;

 stop)
   stop
 ;;

 status)
       status \${prog}
 ;;

 restart)
   stop
   start
 ;;

 *)
   echo "Usage: \$0 {start|stop|restart|status}"
 ;;

esac
EOF

    chmod +x /etc/rc.d/init.d/supervisord
    chkconfig --add supervisord
    chkconfig supervisord on
    service supervisord status && service supervisord reload || service supervisord start
}

gunicorn() {
    GUNICORN_START_FILE=${WEBAPP_DIR}/bin/gunicorn_start
    GUNICORN_LOG_FILE=${WEBAPP_LOG_DIR}/gunicorn_supervisor.log

    cat << EOF > ${GUNICORN_START_FILE}
#!/usr/bin/env bash

NAME=${SERVICE_NAME}
DJANGODIR=${DJANGOAPP_DIR}
SOCKFILE=${WEBAPP_DIR}/run/gunicorn.sock
USER=${SERVICE_USER}
GROUP=${SERVICE_GROUP}
NUM_WORKERS=4
DJANGO_SETTINGS_MODULE=config.settings
DJANGO_WSGI_MODULE=config.wsgi

echo "Starting gunicorn \$NAME as \`whoami\`"

cd \${DJANGODIR}
. ../bin/activate
export DJANGO_SETTINGS_MODULE=\${DJANGO_SETTINGS_MODULE}
export PYTHONPATH=\${DJANGODIR}:\${PYTHONPATH}

RUNDIR=\$(dirname \${SOCKFILE})
test -d \${RUNDIR} || mkdir -p \${RUNDIR}

exec ../bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \${NAME} \
  --workers \${NUM_WORKERS} \
  --user=\${USER} --group=\${GROUP} \
  --bind=unix:\${SOCKFILE} \
  --log-level=info \
  --log-file=-
EOF

    touch ${GUNICORN_LOG_FILE}
    chown ${SERVICE_USER}:${SERVICE_GROUP} ${GUNICORN_START_FILE} ${GUNICORN_LOG_FILE}
    chmod u+x ${GUNICORN_START_FILE}

    cat << EOF > /etc/supervisord.d/supervisord_${SERVICE_NAME}.conf
[program:${SERVICE_NAME}]
#directory=${DJANGOAPP_DIR}
command=${GUNICORN_START_FILE}
user=${SERVICE_USER}
stdout_logfile=${GUNICORN_LOG_FILE}
redirect_stderr=true
autostart=true
autorestart=true
environment=LANG=en_US.UTF-8,LC_ALL=en_US.UTF-8
EOF

    supervisorctl add ${SERVICE_NAME}
    supervisorctl start ${SERVICE_NAME}
}

rabbitmq() {
    yum install erlang
    yum install rabbitmq-server.noarch

    # wget http://packages.erlang-solutions.com/erlang-solutions-1.0-1.noarch.rpm
    # rpm -Uvh erlang-solutions-1.0-1.noarch.rpm
    # yum install erlang

    # wget https://dl.bintray.com/rabbitmq/all/rabbitmq-server/3.7.5/rabbitmq-server-3.7.5-1.el7.noarch.rpm
    # rpm --import https://www.rabbitmq.com/rabbitmq-release-signing-key.asc
    # yum install rabbitmq-server-3.7.5-1.el7.noarch.rpm

    chkconfig rabbitmq-server on
    service rabbitmq-server status && service rabbitmq-server reload || service rabbitmq-server start

    rabbitmqctl add_user pa xxxxxxx
    rabbitmqctl add_vhost pa
    rabbitmqctl set_permissions -p pa pa ".*" ".*" ".*"
}

celery() {
    CELERY_START_FILE=${WEBAPP_DIR}/bin/celery_start
    CELERY_LOG_FILE=${WEBAPP_LOG_DIR}/celery_supervisor.log

    cat << EOF > ${CELERY_START_FILE}
#!/usr/bin/env bash

NAME=config.celery
DJANGODIR=${DJANGOAPP_DIR}
EXECDIR=${WEBAPP_DIR}/bin

echo "Starting celery \$NAME as \`whoami\`"

. \${EXECDIR}/activate
export PYTHONPATH=\${DJANGODIR}:\${PYTHONPATH}

exec \${EXECDIR}/celery \
  worker -A \${NAME} \
  --loglevel=INFO
EOF

    touch ${CELERY_LOG_FILE}
    chown ${SERVICE_USER}:${SERVICE_GROUP} ${CELERY_START_FILE} ${CELERY_LOG_FILE}
    chmod u+x ${CELERY_START_FILE}

    cat << EOF > /etc/supervisord.d/supervisord_celery.conf
[program:${SERVICE_NAME}-celery]
#directory=${DJANGOAPP_DIR}
command=${CELERY_START_FILE}
user=${SERVICE_USER}
numprocs=1
stdout_logfile=${CELERY_LOG_FILE}
redirect_stderr=true
autostart=true
autorestart=true
startsecs=10
stopwaitsecs = 600
stopasgroup=true
priority=1000
EOF

    supervisorctl add ${SERVICE_NAME}-celery
    supervisorctl start ${SERVICE_NAME}-celery
}


ACTIONS_LIST="pkgs nginx supervisor gunicorn rabbitmq celery"
[ -n "$1" ] && ACTIONS_LIST="$*"
for action in ${ACTIONS_LIST}; do
  ${action}
done
