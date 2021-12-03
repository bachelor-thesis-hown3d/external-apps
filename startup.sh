#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

NETWORK=omegalul-chat-cluster
DOCKER="docker run --network $NETWORK --rm"
OPENSTACK_ENV="-e OS_PROJECT_DOMAIN_NAME=Default \
-e OS_USER_DOMAIN_NAME=Default \
-e OS_PROJECT_NAME=admin \
-e OS_USERNAME=admin \
-e OS_PASSWORD=keystoneAdmin \
-e OS_AUTH_URL=http://keystone:5000/v3 \
-e OS_IDENTITY_API_VERSION=3 \
-e OS_IMAGE_API_VERSION=2"
OPENSTACK="$DOCKER $OPENSTACK_ENV openstacktools/openstack-client openstack"
CLUSTER_NAME=chat-cluster

cleanup() {
  pushd $DIR/openstack-components >/dev/null
  docker-compose stop 
  docker-compose rm --force || true
  popd
  kind delete cluster --name $CLUSTER_NAME || true
  docker network rm $NETWORK || true
  exit 1
}

networkSetup() {
  echo "Creating Docker network for cluster!"
  docker network create --subnet 10.255.255.0/24 $NETWORK || { echo "can't create docker network" >&2; exit 1; }
  NETWORK=$NETWORK yq e -i '.networks.openstack.name = strenv(NETWORK)' docker-compose.yml
}

openstackSetup() {
DESIGNATE_PASSWORD=designate
DESIGNATE_USERNAME=designate

echo "Creating openstack docker containers"

pushd openstack-components >/dev/null
docker-compose up --build --remove-orphans -d --force-recreate
popd >/dev/null


until curl -Ls http://localhost:5000/v3; do
  >&2 echo "Keystone is unavailable - sleeping"
  sleep 3
done


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

# TODO: error: no_servers_configured, maybe uses wrong pool
printf 'creating designate chat-cluster.com zone!'
$OPENSTACK zone create --email dnsmaster@example.com chat-cluster.com.

printf 'testing if zone worked'
$DOCKER tutum/dnsutils dig @bind chat-cluster.com
}

externalDNSSetup() {
EXTERNAL_DNS_USERNAME="external-dns"
EXTERNAL_DNS_PASSWORD="external-dns"

printf 'creating external-dns user\n'
$OPENSTACK user create --domain default --password $EXTERNAL_DNS_PASSWORD $EXTERNAL_DNS_USERNAME

cat << EOF > external-dns/secret.yaml
extraEnv:
  - name: OS_USERNAME
    value: $EXTERNAL_DNS_USERNAME
  - name: OS_PASSWORD
    value: $EXTERNAL_DNS_PASSWORD
EOF
}

# Kind will be ready after exiting this func
kindSetup() {
  KIND_EXPERIMENTAL_DOCKER_NETWORK=$NETWORK kind create cluster --config kind/kind.yaml --name $CLUSTER_NAME
  kind get kubeconfig --name chat-cluster > $HOME/.kube/chat-cluster-config

  KUBECONFIG=$HOME/.kube/chat-cluster-config \
    kubectl wait --for=condition=Ready=true node --all --timeout=2m
}

helmDeployments() {
  HELM_DIRS=(cert-manager external-dns nginx-ingress-controller)
  for helm_dir in "${HELM_DIRS[@]}"; do
    pushd $DIR/$helm_dir &>/dev/null
    sh install.sh
    popd &>/dev/null
  done
}

trap cleanup EXIT

networkSetup
openstackSetup
kindSetup
externalDNSSetup
helmDeployments
