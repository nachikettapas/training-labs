#!/usr/bin/env bash

set -o errexit -o nounset

TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)

source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
source "$CONFIG_DIR/openstack"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Install the Telemetry service
# http://docs.openstack.org/kilo/install-guide/install/apt/content/ceilometer-controller-install.html
#------------------------------------------------------------------------------

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openstackrc.sh"

# Create Ceilometer user and database.
ceilometer_admin_user=$(service_to_user_name ceilometer)

mongodb_user=$(service_to_db_user ceilometer)

echo "Creating the ceilometer database."
mongo --host "$(hostname_to_ip controller)" --eval "
    db = db.getSiblingDB(\"ceilometer\");
    db.addUser({user: \"${mongodb_user}\",
    pwd: \"${CEILOMETER_DBPASS}\",
    roles: [ \"readWrite\", \"dbAdmin\" ]})"

echo "Creating ceilometer user and giving it admin role under service tenant."
openstack user create \
    --password "$CEILOMETER_PASS" \
    "$ceilometer_admin_user"

openstack role add \
    --project "$SERVICE_PROJECT_NAME" \
    --user "$ceilometer_admin_user" \
    "$ADMIN_ROLE_NAME"

echo "Registering ceilometer with keystone so that other services can locate it."
openstack service create \
    --name ceilometer \
    --description "Telemetry" \
    metering

openstack endpoint create \
    --publicurl http://controller:8777 \
    --internalurl http://controller:8777 \
    --adminurl http://controller:8777 \
    --region "$REGION" \
    metering

echo "Installing ceilometer."
sudo apt-get install -y ceilometer-api ceilometer-collector \
                        ceilometer-agent-central \
                        ceilometer-agent-notification \
                        ceilometer-alarm-evaluator \
                        ceilometer-alarm-notifier \
                        python-ceilometerclient

function get_database_url {
    local database_host=controller

    echo "mongodb://$mongodb_user:$CEILOMETER_DBPASS@$database_host:27017/ceilometer"
}

database_url=$(get_database_url)
echo "Database connection: $database_url."

echo "Configuring ceilometer.conf."
conf=/etc/ceilometer/ceilometer.conf
iniset_sudo $conf database connection "$database_url"

# Configure RabbitMQ variables
iniset_sudo $conf DEFAULT rpc_backend rabbit

iniset_sudo $conf oslo_messaging_rabbit rabbit_host controller
iniset_sudo $conf oslo_messaging_rabbit rabbit_userid openstack
iniset_sudo $conf oslo_messaging_rabbit rabbit_password "$RABBIT_PASS"

# Configure the [DEFAULT] section
iniset_sudo $conf DEFAULT auth_strategy keystone

# Configure [keystone_authtoken] section.
iniset_sudo $conf keystone_authtoken auth_uri http://controller:5000/v2.0
iniset_sudo $conf keystone_authtoken identity_uri http://controller:35357
iniset_sudo $conf keystone_authtoken admin_tenant_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken admin_user "$ceilometer_admin_user"
iniset_sudo $conf keystone_authtoken admin_password "$CEILOMETER_PASS"

# Configure [service_credentials] section.
iniset_sudo $conf service_credentials os_auth_url http://controller:5000/v2.0
iniset_sudo $conf service_credentials os_username "$ceilometer_admin_user"
iniset_sudo $conf service_credentials os_tenant_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf service_credentials os_password "$CEILOMETER_PASS"
iniset_sudo $conf service_credentials os_endpoint_type internalURL
iniset_sudo $conf service_credentials os_region_name "$REGION"

# Configure [publisher] section.
iniset_sudo $conf publisher telemetry_secret "$TELEMETRY_SECRET"

iniset_sudo $conf DEFAULT verbose "$OPENSTACK_VERBOSE"

echo "Restarting telemetry service."
sudo service ceilometer-agent-central restart
sudo service ceilometer-agent-notification restart
sudo service ceilometer-api restart
sudo service ceilometer-collector restart
sudo service ceilometer-alarm-evaluator restart
sudo service ceilometer-alarm-notifier restart

#------------------------------------------------------------------------------
# Configure the Image service
# http://docs.openstack.org/kilo/install-guide/install/apt/content/ceilometer-glance.html
#------------------------------------------------------------------------------

# Configure the Image Service to send notifications to the message bus

echo "Configuring glance-api.conf."
conf=/etc/glance/glance-api.conf

# Configure [DEFAULT] section.
iniset_sudo $conf DEFAULT notification_driver messagingv2
iniset_sudo $conf DEFAULT rpc_backend rabbit
iniset_sudo $conf DEFAULT rabbit_host controller
iniset_sudo $conf DEFAULT rabbit_userid openstack
iniset_sudo $conf DEFAULT rabbit_password "$RABBIT_PASS"

echo "Configuring glance-registry.conf."
conf=/etc/glance/glance-registry.conf

# Configure [DEFAULT] section.
iniset_sudo $conf DEFAULT notification_driver messagingv2
iniset_sudo $conf DEFAULT rpc_backend rabbit
iniset_sudo $conf DEFAULT rabbit_host controller
iniset_sudo $conf DEFAULT rabbit_userid openstack
iniset_sudo $conf DEFAULT rabbit_password "$RABBIT_PASS"

sudo service glance-registry restart
sudo service glance-api restart

#------------------------------------------------------------------------------
# Configure the Block Storage service
# http://docs.openstack.org/kilo/install-guide/install/apt/content/ceilometer-cinder.html
#------------------------------------------------------------------------------

# Configure the Block Storage Service to send notifications to the message bus

echo "Configuring cinder.conf."
conf=/etc/cinder/cinder.conf

# Configure [DEFAULT] section.
iniset_sudo $conf DEFAULT control_exchange cinder
iniset_sudo $conf DEFAULT notification_driver messagingv2

echo "Restarting cinder services."
sudo service cinder-api restart
sudo service cinder-scheduler restart
