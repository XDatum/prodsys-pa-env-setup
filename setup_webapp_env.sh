#!/usr/bin/env bash

#
# required: python, pip,
# required: python-devel.x86_64, gcc.x86_64
#

OS='centos'
OSRELEASE='7'
PLATFORM='x86_64'

source $(cd `dirname "${BASH_SOURCE[0]}"` && pwd)/env_vars.sh

pkgs() {
    cd ${WEBAPP_DIR}
    sudo -u ${SERVICE_USER} -H bash << EOF
    virtualenv .
    . bin/activate
    pip install Django==1.11.11 gunicorn setproctitle argparse numpy
EOF
}

gunicorn() {
    GUNICORN_START_FILE='${WEBAPP_DIR}/bin/gunicorn_start'

    cat << EOF > ${WEBAPP_DIR}/bin/gunicorn_start
#!/usr/bin/env bash

NAME="${SERVICE_NAME}"
DJANGODIR=${WEBAPP_DIR}/services
SOCKFILE=${WEBAPP_DIR}/run/gunicorn.sock
USER=${SERVICE_USER}
GROUP=${SERVICE_GROUP}
NUM_WORKERS=4
DJANGO_SETTINGS_MODULE=config.settings
DJANGO_WSGI_MODULE=config.wsgi

echo "Starting \$NAME as \`whoami\`"

cd \${DJANGODIR}
. ../bin/activate
export DJANGO_SETTINGS_MODULE=\${DJANGO_SETTINGS_MODULE}
export PYTHONPATH=\${DJANGODIR}:\${PYTHONPATH}

RUNDIR=\$(dirname \${SOCKFILE})
test -d \${RUNDIR} \|| mkdir -p \${RUNDIR}

exec ../bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \${NAME} \
  --workers \${NUM_WORKERS} \
  --user=\${USER} --group=\${GROUP} \
  --bind=unix:\${SOCKFILE} \
  --log-level=info \
  --log-file=-
EOF
    chown ${SERVICE_USER}:${SERVICE_GROUP} ${GUNICORN_START_FILE}
    chmod u+x ${GUNICORN_START_FILE}

    touch ${WEBAPP_DIR}/logs/gunicorn_supervisor.log
    chown ${SERVICE_USER}:${SERVICE_GROUP} '${WEBAPP_DIR}/logs/gunicorn_supervisor.log'
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

    log_format  main     \'\$remote_addr - \$remote_user [\$time_local] "\$request" \'
                         \'\$status \$body_bytes_sent "\$http_referer" \'
                         \'"\$http_user_agent" "\$http_x_forwarded_for"\';

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

        ssl_certificate           /etc/pki/CA/certs/server.crt;
        ssl_certificate_key       /etc/pki/CA/private/server.key;
        ssl_client_certificate    /etc/ssl/certs/ca-bundle.crt;
        ssl_verify_client         on;
        ssl_verify_depth          7;

        ssl_session_timeout       10m;
        ssl_session_cache         shared:SSL:50m;

        ssl_protocols    TLSv1 TLSv1.1 TLSv1.2;
        ssl_prefer_server_ciphers    on;
        ssl_ciphers    \'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA\';

        access_log    ${WEBAPP_DIR}/logs/nginx-access.log  main;
        error_log     ${WEBAPP_DIR}/logs/nginx-error.log;

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
            alias    ${WEBAPP_DIR}/services/p2paweb/static/;
        }
    }
}
EOF
    chkconfig --levels 345 nginx on
    service nginx status && service nginx reload || service nginx start
}

supervisor() {
    pip install supervisor
    echo_supervisord_conf > /etc/supervisord.conf
    mkdir /etc/supervisord.d/
    cat << EOF >> /etc/supervisord.conf
[include]
files = /etc/supervisord.d/*.conf
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

prefix="/usr/"
exec_prefix="\${prefix}"
prog_bin="\${exec_prefix}bin/supervisord"
PIDFILE="/var/run/\${prog}.pid"

start()
{
       echo -n \$"Starting \${prog}: "
       daemon \${prog_bin} --pidfile \${PIDFILE}
       [ -f \${PIDFILE} ] && success \$"\${prog} startup" || failure \$"\${prog} startup"
       echo
}

stop()
{
       echo -n \$"Shutting down \${prog}: "
       [ -f \${PIDFILE} ] && killproc \${prog} || success \$"\${prog} shutdown"
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

    cat << EOF > /etc/supervisord.d/supervisord_${SERVICE_NAME}.conf
[program:${SERVICE_NAME}]
#directory=${WEBAPP_DIR}/services
command=${WEBAPP_DIR}/bin/gunicorn_start
#environment=DJANGO_ENV="prod"
user=${SERVICE_USER}
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile = ${WEBAPP_DIR}/logs/gunicorn_supervisor.log
environment=LANG=en_US.UTF-8,LC_ALL=en_US.UTF-8
EOF
    sudo supervisorctl add ${SERVICE_NAME}
    sudo supervisorctl start ${SERVICE_NAME}

    service supervisord status && service supervisord reload || service supervisord start
}


ACTIONS_LIST="pkgs gunicorn nginx supervisor"
[ -n "$1" ] && ACTIONS_LIST="$*"
for action in ${ACTIONS_LIST}; do
  ${action}
done
