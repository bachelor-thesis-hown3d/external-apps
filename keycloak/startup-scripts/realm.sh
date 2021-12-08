#!/bin/sh

KEYSTORE_PASSWORD=$(cat $JBOSS_HOME/bin/.jbossclirc | grep password | cut -b 36-)
KEYCLOAK_ADMIN_USER=$1
KEYCLOAK_ADMIN_PASSWORD=$2
KCADM=/opt/jboss/keycloak/bin/kcadm.sh 

$KCADM config truststore \
--trustpass $KEYSTORE_PASSWORD \
/opt/jboss/keycloak/standalone/configuration/keystores/https-keystore.jks 

$KCADM config credentials \
--server https://localhost:8443/auth \
--realm master \
--user $KEYCLOAK_ADMIN_USER \
--password $KEYCLOAK_ADMIN_PASSWORD  

$KCADM create realms -s realm=kubernetes -s enabled=true

#id=$($KCADM get clients -r kubernetes --query clientId=kubernetes --fields id --format 'csv' | tr -d '"')
opts='-s clientId=kubernetes -s redirectUris=["http://localhost:7070/kubernetes/*"]'
#if test -z $id; then
clientID=$($KCADM create clients -r kubernetes $opts | awk -F \' '{print $(NF-1)}')
#else 
#$KCADM update clients/$id -r kubernetes $opts
#fi

#$KCADM get clients/kubernetes/client-secret -r kubernetes