# This script can be sourced either as part of zoneinit-finalize
# or directly from head-node global zone, when reconfiguring the zone
# for whatever the reason using /opt/smartdc/etc/configure

# enable slow query logging (anything beyond 200ms right now)
echo "log_min_duration_statement = 200" >> /var/pgsql/data90/postgresql.conf

# Import postgres manifest straight from the pkgsrc file:
if [[ -z $(/usr/bin/svcs -a|grep postgresql) ]]; then
  echo "Importing posgtresql service"
  /usr/sbin/svccfg import /opt/local/share/smf/manifest/postgresql:pg90.xml
  sleep 10 # XXX
  #/usr/sbin/svccfg -s svc:/network/postgresql:pg90 refresh
  /usr/sbin/svcadm enable -s postgresql
else
  echo "Restarting postgresql service"
  /usr/sbin/svcadm disable -s postgresql
  /usr/sbin/svcadm enable -s postgresql
  sleep 2
fi

# CAPI specific

# Note these files should have been created by previous Rake task.
# If we copy these files post "gsed", everything is reset:
if [[ ! -e /opt/smartdc/capi/config/config.ru ]]; then
  cp /opt/smartdc/capi/config/config.ru.sample /opt/smartdc/capi/config/config.ru
fi

if [[ ! -e /opt/smartdc/capi/config/config.yml ]]; then
   cd /opt/smartdc/capi && \
   MAIL_TO="${MAIL_TO}" \
   MAIL_FROM="${MAIL_FROM}" \
   CAPI_HTTP_ADMIN_USER="${CAPI_HTTP_ADMIN_USER}" \
   CAPI_HTTP_ADMIN_PW="${CAPI_HTTP_ADMIN_PW}" \
   /opt/local/bin/rake install:config -f /opt/smartdc/capi/Rakefile && \
   sleep 1 && \
   chown jill:jill /opt/smartdc/capi/config/config.yml
fi

if [[ ! -e /opt/smartdc/capi/gems/gems ]] || [[ $(ls /opt/smartdc/capi/gems/gems| wc -l) -eq 0 ]]; then
  echo "Unpacking frozen gems for Customers API."
  (cd /opt/smartdc/capi; PATH=/opt/local/bin:$PATH /opt/local/bin/rake gems:deploy -f /opt/smartdc/capi/Rakefile)
fi

if [[ ! -e /opt/smartdc/capi/config/unicorn.smf ]]; then
  echo "Creating Customers API Unicorn Manifest."
  /opt/local/bin/ruby -rerb -e "user='jill';group='jill';app_environment='production';application='capi'; working_directory='/opt/smartdc/capi'; puts ERB.new(File.read('/opt/smartdc/capi/smartdc/unicorn.smf.erb')).result" > /opt/smartdc/capi/config/unicorn.smf
  chown jill:jill /opt/smartdc/capi/config/unicorn.smf
fi

if [[ ! -e /opt/smartdc/capi/config/unicorn.conf ]]; then
  echo "Creating Customers API Unicorn Configuration file."
  /opt/local/bin/ruby -rerb -e "app_port='8080'; worker_processes=$WORKERS; working_directory='/opt/smartdc/capi'; application='capi'; puts ERB.new(File.read('/opt/smartdc/capi/smartdc/unicorn.conf.erb')).result" > /opt/smartdc/capi/config/unicorn.conf
  chown jill:jill /opt/smartdc/capi/config/unicorn.conf
fi

echo "Configuring Customers API Database."
cat > /opt/smartdc/capi/config/database.yml <<CAPI_DB
:development: &defaults
  :adapter: postgres
  :database: capi
  :host: $POSTGRES_HOST
  :username: $POSTGRES_USER
  :password: $POSTGRES_PW
  :encoding: UTF-8
:test:
  <<: *defaults
  :database: capi_test
:production:
  <<: *defaults
  :database: capi

CAPI_DB

if [[ ! -e /opt/smartdc/capi/tmp/pids ]]; then
  su - jill -c "mkdir -p /opt/smartdc/capi/tmp/pids"
fi


# Just in case, create /var/logadm
if [[ ! -d /var/logadm ]]; then
  mkdir -p /var/logadm
fi

# Log rotation:
cat >> /etc/logadm.conf <<LOGADM
capi -C 100 -c -s 10m /opt/smartdc/capi/log/*.log
postgresql -C 5 -c -s 100m /var/log/postgresql90.log
LOGADM
