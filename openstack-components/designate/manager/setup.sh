#!/bin/bash
set -e

# Retries a command on failure.
# $1 - the max number of attempts
# $2... - the command to run
retry() {
  local -r -i max_attempts="$1"; shift
  local -r cmd="$@"
  local -i attempt_num=1
  
  until $cmd
  do
    if (( attempt_num == max_attempts ))
    then
      echo "Attempt $attempt_num failed and there are no more attempts left!"
      return 1
    else
      echo "Attempt $attempt_num failed! Trying again in $attempt_num seconds..."
      sleep $(( attempt_num++ ))
    fi
  done
}

retry 10 designate-manage database sync
if test $? -ne 0; then
  exit 1
fi

retry 10 designate-manage pool update --file /var/lib/kolla/config_files/manager/pools.yaml --delete
if test $? -ne 0; then
  exit 1
fi