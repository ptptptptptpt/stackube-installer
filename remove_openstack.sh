#!/bin/bash
#

programDir=`dirname $0`
programDir=$(readlink -f $programDir)
parentDir="$(dirname $programDir)"
programDirBaseName=$(basename $programDir)

set -x

## clean certificates
source ${programDir}/lib_tls.sh || exit 1
cleanup_CA || exit 1



## remove docker containers
stackubeConstaners=`docker ps -a | awk '{print $NF}' | grep '^stackube_' `
if [ "${stackubeConstaners}" ]; then
    docker kill -s 9 $stackubeConstaners
    docker rm -f $stackubeConstaners || exit 1
fi

## rm dirs
rm -fr /etc/stackube/openstack  /var/log/stackube/openstack  /var/lib/stackube/openstack  || exit 1



exit 0

