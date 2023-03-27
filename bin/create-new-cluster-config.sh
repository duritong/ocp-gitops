#!/bin/bash


set -e

cluster_name=$1

if [ -z $cluster_name ]; then
  echo "USAGE: $0 CLUSTER_NAME"
  exit 1
fi

cwd=$(dirname $(dirname $(readlink -f $0)))

[ -d "${cwd}/cluster-config/overlays/${cluster_name}" ] && rm -rf "${cwd}/cluster-config/overlays/${cluster_name}"
[ -d "${cwd}/cluster-definitions/${cluster_name}" ] && rm -rf "${cwd}/cluster-definitions/${cluster_name}"

cp -a "${cwd}/bin/templates/cluster-config" "${cwd}/cluster-config/overlays/${cluster_name}"
cp -a "${cwd}/bin/templates/cluster-definitions" "${cwd}/cluster-definitions/${cluster_name}"

find "${cwd}/cluster-config/overlays/${cluster_name}" "${cwd}/cluster-definitions/${cluster_name}" -type f -exec sed -i "s/CLUSTER_NAME/${cluster_name}/" {} \;
