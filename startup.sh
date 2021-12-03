#!/bin/sh
set -e

echo "Creating Docker network for cluster!"

docker network create --subnet 10.255.255.0/24 chat-cluster || true

echo "Creating openstack docker containers"

pushd openstack-components >/dev/null
docker-compose up --build --remove-orphans -d --force-recreate




until curl -Ls http://localhost:5000/v3; do
  >&2 echo "Keystone is unavailable - sleeping"
  sleep 3
done

OPENSTACK_ENV="-e OS_PROJECT_DOMAIN_NAME=Default \
-e OS_USER_DOMAIN_NAME=Default \
-e OS_PROJECT_NAME=admin \
-e OS_USERNAME=admin \
-e OS_PASSWORD=keystoneAdmin \
-e OS_AUTH_URL=http://keystone:5000/v3 \
-e OS_IDENTITY_API_VERSION=3 \
-e OS_IMAGE_API_VERSION=2"
DESIGNATE_PASSWORD=designate
DESIGNATE_USERNAME=designate
DOCKER="docker run --network chat-cluster --rm"
OPENSTACK="$DOCKER $OPENSTACK_ENV openstacktools/openstack-client openstack"

printf 'creating service project\n'
$OPENSTACK project create service --domain default

printf 'creating designate user\n'
$OPENSTACK user create --domain default --password $DESIGNATE_PASSWORD $DESIGNATE_USERNAME 
printf 'creating designate role\n'
$OPENSTACK role add --project service --user $DESIGNATE_USERNAME admin
printf 'creating designate service\n'
$OPENSTACK service create --name $DESIGNATE_USERNAME --description "DNS" dns
printf 'creating designate endpoint\n'
$OPENSTACK endpoint create --region RegionDev dns public http://designate-api:9001/v2

$OPENSTACK dns service list

printf 'creating designate chat-cluster.com zone!'
$OPENSTACK zone create --email dnsmaster@example.com --attributes=[chat-cluster:True] chat-cluster.com.

printf 'testing if zone worked'
$DOCKER tutum/dnsutils dig @bind chat-cluster.com