#!/bin/bash
set -e
set -o errtrace # Enable the err trap, code will get called when an error is detected
#set -o functrace # If set, the DEBUG and RETURN traps are inherited by shell functions

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && /bin/pwd )"

if test -z $1; then
  echo "Arg1: Cluster-name"
  exit 1
fi

NETWORK=$1
DOCKER_BIN="docker"
PID=$(id -u $(whoami))
#DOCKER_OPTS="DOCKER_HOST=unix:///run/user/$PID/podman/podman.sock"
#DOCKER_OPTS="DOCKER_HOST=unix:///run/podman/podman.sock"
DOCKER_RUN="$DOCKER_BIN run --network $NETWORK --rm"
CLUSTER_NAME=$1
PROJECT="external-apps"
COMPOSE="docker-compose"
KIND_BIN="kind"
EXTERNAL_DNS_USERNAME="external-dns"
EXTERNAL_DNS_PASSWORD="external-dns"

#export $DOCKER_OPTS
export KIND_EXPERIMENTAL_${DOCKER_BIN^^}_NETWORK=$NETWORK
export KIND_EXPERIMENTAL_PROVIDER=$DOCKER_BIN

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/concurrent.lib.sh"

# Retries a command on failure.
# $1 - the max number of attempts
# $2... - the command to run
retry() {
  local -r -i max_attempts="$1"; shift
  local -r cmd="$@"
  local -i attempt_num=1
  
  until $cmd
  do
    if (( attempt_num == max_attempts ))
    then
      echo "Attempt $attempt_num failed and there are no more attempts left!"
      return 1
    else
      echo "Attempt $attempt_num failed! Trying again in $attempt_num seconds..."
      sleep $(( attempt_num++ ))
    fi
  done
}


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

getIPOfContainer() {
  local container=$1
  $DOCKER_BIN container inspect $container --format '{{json .NetworkSettings.Networks }}' | jq -r '."'"$NETWORK"'".IPAddress'
}

getCIDROfNetwork () {
  $DOCKER_BIN inspect $NETWORK --format "{{ (index .IPAM.Config 0).Subnet }}"
}

cleanup() {
  $COMPOSE down
  kind delete cluster --name $CLUSTER_NAME || true
  $DOCKER_BIN network rm $NETWORK || true
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
  echo "Creating Docker network for cluster" >&3 || true
  $DOCKER_BIN network create $NETWORK
  echo "Setting network name in docker-compose file" >&3 || true
  (
    export NETWORK=$NETWORK
    yq e -i ".networks.chat-cluster.name = strenv(NETWORK)" docker-compose.yml
    yq e -i ".networks.chat-cluster.external = true" docker-compose.yml
  )
  
  echo "Setting up metallb network range" >&3
  CIDR=$(getCIDROfNetwork)
  IP_PREFIX=$(echo $CIDR | cut -d '.' -f1-3)
  METALLB_RANGE="${IP_PREFIX}.240-${IP_PREFIX}.250"
  METALLB_RANGE=$METALLB_RANGE yq e -i ".configInline.address-pools[0].addresses[0] = strenv(METALLB_RANGE)" metallb/values.yaml
}



openstackSetup() {
  DESIGNATE_PASSWORD=designate
  DESIGNATE_USERNAME=designate
  
  echo "Creating openstack docker containers" >&3
  $COMPOSE --project-name $PROJECT up --build --remove-orphans -d --force-recreate
  
  echo "Setting ips for bind and designate-mdns in pools file" >&3 || true
  if [[ $DOCKER_BIN == "podman" ]]
  then
    echo "implement for podman"
    exit 1
  elif [[ $DOCKER_BIN == "docker" ]]
  then
    MDNS_IP=$(getIPOfContainer $PROJECT-designate-mdns-1)
    BIND_IP=$(getIPOfContainer $PROJECT-bind-1)
  fi
  (
    BIND_IP=$BIND_IP yq e -i ".[0].nameservers[0].host = strenv(BIND_IP)" openstack-components/designate/manager/pools.yaml
    BIND_IP=$BIND_IP yq e -i ".[0].targets[0].options.host = strenv(BIND_IP)" openstack-components/designate/manager/pools.yaml
    BIND_IP=$BIND_IP yq e -i ".[0].targets[0].options.rndc_host = strenv(BIND_IP)" openstack-components/designate/manager/pools.yaml
    MDNS_IP=$MDNS_IP yq e -i ".[0].targets[0].masters[0].host = strenv(MDNS_IP)" openstack-components/designate/manager/pools.yaml
  )
  
  
  echo "Running migration for designate" >&3
  $COMPOSE exec designate-central bash /var/lib/kolla/config_files/manager/setup.sh
  
  echo "waiting for keystone to become available" >&3
  retry 15 curl -Ls http://localhost:5000/v3
  
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
  echo 'creating designate chat-cluster.com zone' >&3
}

externalDNSSetup() {
  echo 'creating external-dns user' >&3
  openstackRun admin admin \
  keystoneAdmin user create --domain default --project apps --password $EXTERNAL_DNS_PASSWORD $EXTERNAL_DNS_USERNAME
  echo 'creating external-dns role' >&3
  openstackRun admin admin keystoneAdmin \
  role add --project apps --user $EXTERNAL_DNS_USERNAME admin
  
  retry 10 openstackRun apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD  \
  zone create --email dnsmaster@example.com chat-cluster.com.
  
  echo "Add Keycloak to designate dns" >&3
  ip=$(getIPOfContainer $PROJECT-keycloak-1)
  zone_id=$(openstackRun apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD zone list -f value -c id)
  openstackRun apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD \
  recordset create "$zone_id" --type A --record "$ip" keycloak.chat-cluster.com.
  
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
  $KIND_BIN delete cluster --name $CLUSTER_NAME || true
  $KIND_BIN create cluster --config kind/kind.yaml --name $CLUSTER_NAME
  echo "getting kubeconfig" >&3
  $KIND_BIN get kubeconfig --name $CLUSTER_NAME > $HOME/.kube/chat-cluster-config
  
  echo "waiting for cluster to become ready" >&3
  KUBECONFIG=$HOME/.kube/chat-cluster-config \
  kubectl wait --for=condition=Ready=true node --all --timeout=2m
  
  BIND_IP=$(getIPOfContainer $PROJECT-bind-1)
  echo "configure coredns to point to designate-dns" >&3
  kubectl get configmap coredns -n kube-system -o yaml > /tmp/cm.yaml
  cat /tmp/cm.yaml | yq e '.data.Corefile' - > /tmp/Corefile
cat <<EOF >> /tmp/Corefile
chat-cluster.com:53 {
    forward . $BIND_IP
}
EOF
  sed -i 's/^/        /'  /tmp/Corefile
  echo -e "data:\n    Corefile: |" > /tmp/Corefile2
  cat /tmp/Corefile >> /tmp/Corefile2
  
  cat /tmp/cm.yaml | yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' - /tmp/Corefile2 | kubectl apply -f -
  
  kubectl rollout restart deployment coredns -n kube-system
  
  rm /tmp/Corefile
  rm /tmp/cm.yaml
  rm /tmp/Corefile2
  
}

# Creates the realm inside keycloak
keycloakSetup() {
  local ip
  local zone_id
  local keycloak_admin_password
  local keycloak_admin_user
  
  keycloak_admin_password="keycloak"
  keycloak_admin_user="admin"
  $COMPOSE exec keycloak /tmp/scripts/realm.sh $keycloak_admin_user $keycloak_admin_password
  
}

helmDeployments() {
  HELM_DIRS=(cert-manager external-dns nginx-ingress-controller metallb)
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