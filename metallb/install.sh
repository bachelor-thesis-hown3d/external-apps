#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade -i metallb bitnami/metallb -n metallb --create-namespace --values $DIR/values.yaml