#!/bin/bash
set -e
set -o errtrace # Enable the err trap, code will get called when an error is detected
#set -o functrace # If set, the DEBUG and RETURN traps are inherited by shell functions

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && /bin/pwd )"



#export $DOCKER_OPTS
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
  local network=$1
  local project=$2
  local username=$3
  local password=$4
  shift 4
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
  OPENSTACK="${DOCKER_BIN} run --network=$network --rm $(printf '%s ' "${OPENSTACK_ENV[@]}") docker.io/openstacktools/openstack-client openstack"
  
  $OPENSTACK $command
}

getIPOfContainer() {
  local network=$1
  local container=$2
  $DOCKER_BIN container inspect $container --format '{{json .NetworkSettings.Networks }}' | jq -r '."'"$network"'".IPAddress'
}

getCIDROfNetwork () {
  local network=$1
  $DOCKER_BIN inspect $network --format "{{ (index .IPAM.Config 0).Subnet }}"
}

cleanup() {
  local network
  local cluster_name
  network=$1
  cluster_name=$1
  $COMPOSE down
  kind delete cluster --name $cluster_name || true
  $DOCKER_BIN network rm $network || true
  sudo sed '/keycloak/d' /etc/hosts >/dev/null
  exit 0
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
  local network
  network=$1
  echo "Creating Docker network for cluster" >&3 || true
  $DOCKER_BIN network create $network || true
  echo "Setting network name in docker-compose file" >&3 || true
  (
    export NETWORK=$network
    yq e -i ".networks.chat-cluster.name = strenv(NETWORK)" docker-compose.yml
    yq e -i ".networks.chat-cluster.external = true" docker-compose.yml
  )
  
  echo "Setting up metallb network range" >&3
  CIDR=$(getCIDROfNetwork $network)
  IP_PREFIX=$(echo $CIDR | cut -d '.' -f1-3)
  METALLB_RANGE="${IP_PREFIX}.240-${IP_PREFIX}.250"
  METALLB_RANGE=$METALLB_RANGE yq e -i ".configInline.address-pools[0].addresses[0] = strenv(METALLB_RANGE)" metallb/values.yaml
}



openstackSetup() {
  local network
  network=$1
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
    MDNS_IP=$(getIPOfContainer $network $PROJECT-designate-mdns-1)
    BIND_IP=$(getIPOfContainer $network $PROJECT-bind-1)
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
  openstackRun $network admin admin keystoneAdmin \
  project create service --domain default
  echo 'creating apps project' >&3
  openstackRun $network admin admin keystoneAdmin \
  project create apps --domain default
  
  echo 'creating designate user' >&3
  openstackRun $network admin admin keystoneAdmin \
  user create --domain default --password $DESIGNATE_PASSWORD $DESIGNATE_USERNAME
  echo 'creating designate role' >&3
  openstackRun $network admin admin \
  keystoneAdmin role add --project service --user $DESIGNATE_USERNAME admin
  echo 'creating designate service' >&3
  openstackRun $network admin admin \
  keystoneAdmin service create --name $DESIGNATE_USERNAME --description "DNS" dns
  echo 'creating designate endpoint' >&3
  openstackRun $network admin admin \
  keystoneAdmin endpoint create --region RegionDev dns public http://designate-api:9001
  echo 'creating designate chat-cluster.com zone' >&3
}

externalDNSSetup() {
  local network
  network=$1
  echo 'creating external-dns user' >&3
  openstackRun $network admin admin \
  keystoneAdmin user create --domain default --project apps --password $EXTERNAL_DNS_PASSWORD $EXTERNAL_DNS_USERNAME
  echo 'creating external-dns role' >&3
  openstackRun $network admin admin keystoneAdmin \
  role add --project apps --user $EXTERNAL_DNS_USERNAME admin
  
  retry 10 openstackRun $network apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD  \
  zone create --email dnsmaster@example.com chat-cluster.com.
  
  echo "Add Keycloak to designate dns" >&3
  ip=$(getIPOfContainer $network $PROJECT-keycloak-1)
  zone_id=$(openstackRun $network apps $EXTERNAL_DNS_USERNAME $EXTERNAL_DNS_PASSWORD zone list -f value -c id)
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
  local network
  local cluster_name
  network=$1
  cluster_name=$1
  
  export KIND_EXPERIMENTAL_${DOCKER_BIN^^}_NETWORK=$network
  echo "creating kind cluster" >&3
  $KIND_BIN delete cluster --name $cluster_name || true
  $KIND_BIN create cluster --config kind/kind.yaml --name $cluster_name
  echo "getting kubeconfig" >&3
  $KIND_BIN get kubeconfig --name $cluster_name > $HOME/.kube/chat-cluster-config
  
  echo "waiting for cluster to become ready" >&3
  KUBECONFIG=$HOME/.kube/chat-cluster-config \
  kubectl wait --for=condition=Ready=true node --all --timeout=2m
  
  #BIND_IP=$(getIPOfContainer $PROJECT-bind-1)
  #echo "configure coredns to point to designate-dns" >&3
  #CoreDNSWithDesignateDNS $BIND_IP
}

# $1 = IP of Bind DNS
CoreDNSWithDesignateDNS() {
  kubectl get configmap coredns -n kube-system -o yaml > /tmp/cm.yaml
  cat /tmp/cm.yaml | yq e '.data.Corefile' - > /tmp/Corefile
cat <<EOF >> /tmp/Corefile
chat-cluster.com:53 {
    forward . $1
    cache 30
    errors
    log
    debug
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
  local $network
  local keycloak_admin_password
  local keycloak_admin_user
  local ip
  
  network=$1
  keycloak_admin_password="keycloak"
  keycloak_admin_user="admin"
  $COMPOSE exec keycloak /tmp/scripts/realm.sh $keycloak_admin_user $keycloak_admin_password
  
  echo "add keycloak ip to hosts file, might need password since it's run as sudo" >&3
  ip=$(getIPOfContainer $network $PROJECT-keycloak-1)
  echo "$ip keycloak" | sudo tee -a /etc/hosts > /dev/null
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

usage() {
  echo -e "start: Start local cluster and openstack\n\tArg1: Cluster-name"
  echo -e "cleanup: delete local cluster and openstack\n\tArg1: Cluster-name"
}

#trap 'error ${LINENO}' ERR
DOCKER_BIN="docker"
#DOCKER_OPTS="DOCKER_HOST=unix:///run/user/$PID/podman/podman.sock"
#DOCKER_OPTS="DOCKER_HOST=unix:///run/podman/podman.sock"
PROJECT="external-apps"
COMPOSE="docker-compose"
KIND_BIN="kind"
EXTERNAL_DNS_USERNAME="external-dns"
EXTERNAL_DNS_PASSWORD="external-dns"

case "$1" in
  "start")
    shift
    cluster_name=$1
    if test -z "$cluster_name"; then
      echo -e "Start: \nArg1: Cluster-name"
      exit 1
    fi
    concurrent \
    - "network Setup" networkSetup "$cluster_name" \
    --and-then \
    - "openstack Setup" openstackSetup $cluster_name \
    - "kind Setup" kindSetup "$cluster_name" \
    - "external-dns Setup" externalDNSSetup $cluster_name \
    - "helm Deployments" helmDeployments \
    - "keycloak Setup" keycloakSetup $cluster_name \
    --require "openstack Setup" \
    --before "external-dns Setup" \
    --before "keycloak Setup" \
    --require "kind Setup" \
    --before "helm Deployments"
  ;;
  "cleanup")
    shift
    cleanup $1
  ;;
  *)
    usage
  ;;
esac
