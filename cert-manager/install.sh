#!/bin/sh
VERSION="v1.6.1"
helm repo add jetstack https://charts.jetstack.io
helm upgrade -i cert-manager jetstack/cert-manager --version $VERSION --create-namespace -n cert-manager --set installCRDs=true
