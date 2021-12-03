#!/bin/bash
set -o errtrace # Enable the err trap, code will get called when an error is detected
#set -o functrace # If set, the DEBUG and RETURN traps are inherited by shell functions

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && /bin/pwd )"

NETWORK=chat-cluster
DOCKER_BIN="podman"
PID=$(id -u $(whoami))
DOCKER_OPTS="DOCKER_HOST=unix:///run/user/$PID/podman/podman.sock"
DOCKER_RUN="$DOCKER_BIN run --network $NETWORK --rm"
CLUSTER_NAME=chat-cluster
COMPOSE="docker-compose"

export $DOCKER_OPTS
export KIND_EXPERIMENTAL_${DOCKER_BIN^^}_NETWORK=$NETWORK
export KIND_EXPERIMENTAL_PROVIDER=$DOCKER_BIN

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/concurrent.lib.sh"


openstackRun() {
  local project=$1
  local username=$2
  local password=$3
  shift 3
  local command=$*
  OPENSTACK_ENV=(
  "-e OS_PROJECT_DOMAIN_NAME=Default"
  "-e OS_USER_DOMAIN_NAME=Default"
  "-e OS_PROJECT_NAME=$project"
  "-e OS_USERNAME=$username"
  "-e OS_PASSWORD=$password"
  "-e OS_AUTH_URL=http://keystone:5000/v3"
  "-e OS_IDENTITY_API_VERSION=3"
  "-e OS_IMAGE_API_VERSION=2"
  )
  OPENSTACK="$DOCKER_RUN $(printf '%s ' "${OPENSTACK_ENV[@]}") docker.io/openstacktools/openstack-client openstack"

  $OPENSTACK $command
}

cleanup() {
  $COMPOSE down 
  kind delete cluster --name $CLUSTER_NAME || true
  $DOCKER_BIN network rm $NETWORK --force || true
  exit 1
}

error() {
  local parent_lineno="$1"
  local message="$2"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}"
  else
    echo "Error on or near line ${parent_lineno}; exiting with status ${code}"
  fi
  cleanup
  exit "${code}"
}

networkSetup() {
  echo "Creating Docker network for cluster" >&3
  $DOCKER_BIN network create --subnet 10.255.255.0/24 $NETWORK || true
  echo "Setting network name in docker-compose file" >&3
  NETWORK=$NETWORK yq e -i '.networks.openstack.name = strenv(NETWORK)' docker-compose.yml
}

openstackSetup() {
DESIGNATE_PASSWORD=designate
DESIGNATE_USERNAME=designate

echo "Creating openstack docker containers" >&3
$COMPOSE up --build --remove-orphans -d --force-recreate

echo "waiting for keystone to become available" >&3 
until curl -Ls http://localhost:5000/v3; do
  echo "Keystone is unavailable - sleeping" 
  sleep 3
done


echo 'creating service project' >&3
openstackRun admin admin \
  keystoneAdmin project create service --domain default
echo 'creating apps project' >&3
openstackRun admin admin \
  keystoneAdmin project create apps --domain default

echo 'creating designate user' >&3
openstackRun admin admin \
  keystoneAdmin user create --domain default --password $DESIGNATE_PASSWORD $DESIGNATE_USERNAME 
echo 'creating designate role' >&3
openstackRun admin admin \
  keystoneAdmin role add --project service --user $DESIGNATE_USERNAME admin
echo 'creating designate service' >&3
openstackRun admin admin \
  keystoneAdmin service create --name $DESIGNATE_USERNAME --description "DNS" dns
echo 'creating designate endpoint' >&3
openstackRun admin admin \
  keystoneAdmin endpoint create --region RegionDev dns public http://designate-api:9001
}

externalDNSSetup() {
EXTERNAL_DNS_USERNAME="external-dns"
EXTERNAL_DNS_PASSWORD="external-dns"

OPENSTACK_ENV+=("-e OS_PROJECT_NAME=")

echo 'creating external-dns user' >&3
openstackRun admin admin \
  keystoneAdmin user create --domain default --project apps --password $EXTERNAL_DNS_PASSWORD $EXTERNAL_DNS_USERNAME
echo 'creating external-dns role' >&3
openstackRun admin admin keystoneAdmin \
  role add --project apps --user $EXTERNAL_DNS_USERNAME admin 

echo 'creating designate chat-cluster.com zone' >&3
until openstackRun apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD \
  zone create --email dnsmaster@example.com chat-cluster.com.; do
  
  echo "waiting for pool to become ready - sleeping"
  sleep 5
done

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
  echo "creating kind cluster" >&3
  kind delete cluster --name $CLUSTER_NAME || true
  kind create cluster --config kind/kind.yaml --name $CLUSTER_NAME 
  echo "getting kubeconfig" >&3
  kind get kubeconfig --name chat-cluster > $HOME/.kube/chat-cluster-config 

  KUBECONFIG=$HOME/.kube/chat-cluster-config \
    kubectl wait --for=condition=Ready=true node --all --timeout=2m
}

# Creates the realm inside keycloak
keycloakSetup() {
  KEYCLOAK_ADMIN_PASSWORD=keycloak
  KEYCLOAK_ADMIN_USER=admin
  $COMPOSE exec keycloak /tmp/scripts/realm.sh $KEYCLOAK_ADMIN_USER $KEYCLOAK_ADMIN_PASSWORD
}

helmDeployments() {
  HELM_DIRS=(cert-manager external-dns nginx-ingress-controller)
  for helm_dir in "${HELM_DIRS[@]}"; do
    pushd $DIR/$helm_dir &>/dev/null
    echo "Installing $helm_dir" >&3
    sh install.sh &
    popd &>/dev/null
  done
}

#trap 'error ${LINENO}' ERR

concurrent \
  - "network Setup" networkSetup \
  --and-then \
  - "openstack Setup" openstackSetup \
  - "kind Setup" kindSetup \
  - "external-dns Setup" externalDNSSetup \
  - "helm Deployments" helmDeployments \
  - "keycloak Setup" keycloakSetup \
  --require "openstack Setup" \
  --before "external-dns Setup" \
  --before "keycloak Setup" \
  --require "kind Setup" \
  --before "helm Deployments"