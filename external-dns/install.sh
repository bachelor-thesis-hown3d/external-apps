#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade -i external-dns -n external-dns --create-namespace bitnami/external-dns --values $DIR/values.yaml --values $DIR/secret.yaml
