#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
helm upgrade -i cinder-csi --create-namespace -n cinder-csi cpo/openstack-cinder-csi --values $DIR/values.yaml --values $DIR/secret.yaml
