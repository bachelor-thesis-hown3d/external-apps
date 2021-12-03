#!/bin/sh

until keystone-manage db_sync; do
  >&2 echo "Mysql is unavailable - sleeping"
  sleep 5
done

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone

keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

keystone-manage bootstrap \
--bootstrap-password $KEYSTONE_ADMIN_PASSWORD \
--bootstrap-admin-url http://keystone:5000/v3/ \
--bootstrap-internal-url http://keystone:5000/v3/ \
--bootstrap-public-url http://keystone:5001/v3/ \
--bootstrap-region-id RegionDev

keystone-wsgi-admin -b 0.0.0.0 -p 5000 & keystone-wsgi-public -b 0.0.0.0 -p 5001