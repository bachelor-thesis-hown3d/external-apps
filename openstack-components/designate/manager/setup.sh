#!/bin/bash

set -e
  
until designate-manage database sync; do
  >&2 echo "Mysql is unavailable - sleeping"
  sleep 1
done

until designate-manage pool update --file /var/lib/kolla/config_files/manager/pools.yaml --delete; do
  >&2 echo "Pool update not yet possible - sleeping"
  sleep 1
done