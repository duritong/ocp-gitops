#!/bin/bash

set -euf -o pipefail


if [ -z "${1-}" ]; then
  echo "USAGE: $0 CLUSTER_NAME"
  exit 1
fi

CLUSTER_NAME=$1

cwd=$(dirname $(dirname $(readlink -f $0)))
if [ ! -f "${cwd}/cluster-definitions/${CLUSTER_NAME}/cluster.json" ]; then
  echo "Main cluster config ${cwd}/cluster-definitions/${CLUSTER_NAME}/cluster.json does not exist!"
  exit 1
fi
if ! [ "$(oc get console cluster -o jsonpath='{.status.consoleURL}' | sed 's/.*apps\.\([^\.]*\)\..*/\1/')" == "${CLUSTER_NAME}" ]; then
  echo "Cluster named ${CLUSTER_NAME} is not the one we are connected to... Make sure we are connected to the right cluster!"
  exit 1
fi

git ls-files --error-unmatch "${cwd}/cluster-definitions/${CLUSTER_NAME}/cluster.json" 2>&1 > /dev/null
if [ $? -gt 0 ]; then
  echo "We do not have a cluster-definition in cluster-definitions/${CLUSTER_NAME}/cluster.json"
  echo "Ensure that you created this definition and it is in git and pushed!"
  exit 1
fi

git ls-files --error-unmatch "${cwd}/cluster-config/overlays/${CLUSTER_NAME}/kustomization.yaml" 2>&1 > /dev/null
if [ $? -gt 0 ]; then
  echo "We do not have a cluster overlay in cluster-config/overlays/${CLUSTER_NAME}/kustomization.yaml"
  echo "Ensure that you created this overlay and it is in git and pushed!"
  exit 1
fi

echo "Bootstrapping gitops..."

echo "Creating openshift-gitops namespace to bootstrap secrets..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-gitops
EOF
echo -n "Waiting for Namespace to exist."
while ! [ "$(oc get namespace openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" == "Active" ]; do echo -n '.'; sleep 1; done
echo

oc kustomize bootstrap/openshift-gitops/ | oc apply -f

until oc get deployment -n openshift-gitops openshift-gitops-server 2>/dev/null >/dev/null; do echo -n '.'; sleep 1; done
echo
oc wait --for=condition=Available -n openshift-gitops deployment/openshift-gitops-server

echo "OpenShift GitOps is ready! The cluster should bootstrap itself..."
