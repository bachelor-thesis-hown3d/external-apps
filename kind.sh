#!/bin/sh



DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export OIDC_ISSUER="--oidc-issuer-url=https://localhost:8443/auth/realms/kubernetes"
export OIDC_CLIENT_ID="--oidc-client-id=kubernetes"
export OIDC_CLIENT_SECRET="--oidc-client-secret=$1"

pushd $DIR

#KIND_EXPERIMENTAL_DOCKER_NETWORK=keycloak_kind kind create cluster --config kind.yaml || true

kind get kubeconfig --name chat-cluster > $HOME/.kube/chat-cluster-config

yq e -i '.users[0].user.exec.args[2] = strenv(OIDC_ISSUER)' oidc.yaml
yq e -i '.users[0].user.exec.args[3] = strenv(OIDC_CLIENT_ID)' oidc.yaml
yq e -i '.users[0].user.exec.args[4] = strenv(OIDC_CLIENT_SECRET)' oidc.yaml

# merge files
#yq e -i '.contexts[0].context.user = "oidc"' $HOME/.kube/chat-cluster-config

yq ea -i 'select(fi == 0) *+ select(fi == 1)' $HOME/.kube/chat-cluster-config oidc.yaml




