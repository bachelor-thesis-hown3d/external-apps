#!/bin/bash
CLUSTER=$1
#
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
#
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade -i ingress-controller ingress-nginx/ingress-nginx --create-namespace -n nginx-ingress --values $DIR/values.yaml

openstackSetup() {
  LB_ID=$(openstack loadbalancer list --name $CLUSTER -c id -f value)

# Listener
openstack loadbalancer listener create $LB_ID --protocol HTTP --name nginx-ingress-http --protocol-port 80  
openstack loadbalancer listener create $LB_ID --protocol HTTPS --name nginx-ingress-https --protocol-port 443

# Pools
openstack loadbalancer pool create --name nginx-ingress-http --lb-algorithm LEAST_CONNECTIONS --listener nginx-ingress-http --protocol HTTP
openstack loadbalancer pool create --name nginx-ingress-https --lb-algorithm LEAST_CONNECTIONS --listener nginx-ingress-https --protocol HTTPS

HTTP_NODE_PORT=$(yq e ".controller.service.nodePorts.http" $DIR/values.yaml)
HTTPS_NODE_PORT=$(yq e ".controller.service.nodePorts.https" $DIR/values.yaml)

# Members
SERVER_JSON=$(openstack server list -f json)
k8s_node_names=$(echo $SERVER_JSON | jq '.[].Name' | grep k8s-node)
for node in $k8s_node_names
do
  CLUSTER_NETWORK="$CLUSTER-network"
  IP=$(echo $SERVER_JSON | jq ".[]|select(.Name==$node)" | jq -r ".Networks.\"${CLUSTER_NETWORK}\"[0]")
  openstack loadbalancer member create nginx-ingress-http --address $IP --protocol-port $HTTP_NODE_PORT
  openstack loadbalancer member create nginx-ingress-https --address $IP --protocol-port $HTTPS_NODE_PORT
done
}
