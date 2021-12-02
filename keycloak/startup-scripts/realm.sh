#!/bin/sh

KEYSTORE_PASSWORD=$(cat $JBOSS_HOME/bin/.jbossclirc | grep password | cut -b 36-)

KCADM=/opt/jboss/keycloak/bin/kcadm.sh 

$KCADM config truststore \
--trustpass $KEYSTORE_PASSWORD \
/opt/jboss/keycloak/standalone/configuration/keystores/https-keystore.jks 

$KCADM config credentials \
--server https://localhost:8443/auth \
--realm master \
--user $KEYCLOAK_USER \
--password $KEYCLOAK_PASSWORD  2>/dev/null


id=$($KCADM get realms/kubernetes --fields id --format 'csv' | tr -d '"')
opts='-s clientId=kubernetes -s redirectUris=["/kubernetes/*"]'
if test -z $id; then
$KCADM create clients -r kubernetes $opts 2>/dev/null
else 
$KCADM update clients/$id -r kubernetes $opts 2>/dev/null
fi

id=$($KCADM get clients -r kubernetes --query clientId=kubernetes --fields id --format 'csv' | tr -d '"')
opts='-s clientId=kubernetes -s redirectUris=["/kubernetes/*"]'
if test -z $id; then
$KCADM create clients -r kubernetes $opts 2>/dev/null
else 
$KCADM update clients/$id -r kubernetes $opts 2>/dev/null
fi

$KCADM get clients/$id/client-secret -r kubernetes