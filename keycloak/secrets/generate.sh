#!/bin/bash

# thanks to dex!
# https://raw.githubusercontent.com/dexidp/dex/master/examples/k8s/gencert.sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cat << EOF > $DIR/req.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = keycloak.chat-cluster.com
EOF

openssl genrsa -out $DIR/ca-key.pem 2048
openssl req -x509 -new -nodes -key $DIR/ca-key.pem -days 10 -out $DIR/ca.pem -subj "/CN=kube-ca"

openssl genrsa -out $DIR/tls.key 2048
openssl req -new -key $DIR/tls.key -out $DIR/csr.pem -subj "/CN=kube-ca" -config $DIR/req.cnf
openssl x509 -req -in $DIR/csr.pem -CA $DIR/ca.pem -CAkey $DIR/ca-key.pem -CAcreateserial -out $DIR/tls.crt -days 10 -extensions v3_req -extfile $DIR/req.cnf