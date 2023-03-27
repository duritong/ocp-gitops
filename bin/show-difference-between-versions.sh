#!/bin/bash

set -e

old_version_str=$1
new_version_str=$2

cluster=$3
repodir=$(dirname $(dirname $(readlink -f $0)))
cluster_overlay_file="${repodir}/cluster-config/overlays/${cluster}/apps-of-apps/kustomization.yaml"
cluster_yaml_file="${repodir}/cluster-definitions/${cluster}/cluster.yaml"

function usage() {
  echo "USAGE: $0 OLD_VERSION NEW_VERSION CLUSTER_NAME"
}

if [ -z "${old_version_str}" ] || [ -z "${new_version_str}" ] || [ ! -f "${cluster_overlay_file}" ] || [ ! -f "${cluster_yaml_file}" ]; then
  usage
  exit 1
fi
if [ "${old_version_str}" == "${new_version_str}" ]; then
  echo "Old version '${old_version_str}' and new version '${new_version_str}' are the same not much sense"
  exit 1
fi

if [ "${old_version_str}" == "current" ]; then
  old_version="$(jq -r '.platform_version' < "${repodir}/cluster-definitions/${cluster}/cluster.yaml")"
else
  old_version="${old_version_str}"
fi

if [ "${new_version_str}" == "current" ]; then
  new_version="$(jq -r '.platform_version' < "${repodir}/cluster-definitions/${cluster}/cluster.yaml")"
else
  new_version="${new_version_str}"
fi

if [ -z "${old_version}" ] || [ -z "${new_version}" ] || [ ! -f "${cluster_overlay_file}" ] || [ ! -f "${cluster_yaml_file}" ]; then
  usage
  echo
  echo "Required files:"
  echo
  echo " * ${cluster_overlay_file}"
  echo " * ${cluster_yaml_file}"
  echo
  exit 1
fi

echo "Creating differences for cluster: ${cluster}"
echo

#### git functions
function init_bare_git() {
  local repo=$1

  local git_bare="${git_base}/$(echo -n $repo | sed -e 's@^https://@@' -e 's@/@_@g')/bare"
  if [[ ! "${repo}" =~ ^https: ]]; then
    repo="https://${repo}"
  fi
  if [ ! -f "${git_bare}/HEAD" ]; then
    git clone -q --bare "${repo}" "${git_bare}"
  fi
  echo "${git_bare}"
}

function init_git() {
  local repo=$1
  local revision=$2

  local git_bare="$(init_bare_git "${repo}")"
  local location="$(dirname "${git_bare}")/${revision}"
  if [ ! -d "${location}/.git" ]; then
    mkdir "${location}"

    pushd "${location}" > /dev/null
    if [ $? -gt 0 ]; then
      echo "Error while chaning into ${location} - Aborting!" > /dev/stderr
      exit 1
    fi
    git init -q
    git remote add origin "${git_bare}"
    git fetch -q origin "${revision}"
    git checkout -q FETCH_HEAD
  
    popd > /dev/null
  fi
  echo $location
}

### end of git functions

temp_dir=$(mktemp -d)
git_base="${temp_dir}/git"
mkdir "${git_base}"

main_git_url=$(git --git-dir=${repodir}/.git --work-tree=${repodir} remote get-url origin)
echo -n "Cloning current repo as a base"
init_bare_git "${main_git_url}" > /dev/null
git_head=$(init_git "${main_git_url}" HEAD)
echo " DONE"

old_cluster_definition_dir="${temp_dir}/old_definition"
new_cluster_definition_dir="${temp_dir}/new_definition"

old_output_dir="${temp_dir}/${old_version_str}"
echo "Old definitions will be placed here: ${old_output_dir}"
mkdir -p "${old_cluster_definition_dir}/bin" "${old_output_dir}"

if [ "${new_version_str}" != "skip" ]; then
  new_output_dir="${temp_dir}/${new_version_str}"
  echo "New definitions will be placed here: ${new_output_dir}"
  mkdir -p "${new_cluster_definition_dir}/bin" "${new_output_dir}"
fi

echo -n "Preparing generation..."

if [[ "${old_version_str}" =~ ^4\. ]]; then
  old_version_file="${repodir}/versions/${old_version_str}/version.yaml"

  bootstrap_old_revision=$(yq -r '.version.apps_of_apps.revision' < "${old_version_file}")
  git_bootstrap_old_revision=$(init_git "${main_git_url}" "${bootstrap_old_revision}")

  cp -a "${git_bootstrap_old_revision}"/{versions,cluster-definitions} "${old_cluster_definition_dir}/"
  yq -i ".platform_version = \"${old_version}\"" "${old_cluster_definition_dir}/cluster-definitions/${cluster}/cluster.yaml"
else
  if [ "${old_version_str}" == "current" ]; then
    git_bootstrap_old_revision="${repodir}"
  else
    git_bootstrap_old_revision=$(init_git "${main_git_url}" "${old_version_str}")
  fi
  cp -a "${git_bootstrap_old_revision}"/{versions,cluster-definitions} "${old_cluster_definition_dir}/"
fi

if [[ "${new_version_str}" =~ ^4\. ]]; then
  new_version_file="${repodir}/versions/${new_version_str}/version.yaml"

  bootstrap_new_revision=$(yq -r '.version.apps_of_apps.revision' < "${new_version_file}")
  git_bootstrap_new_revision=$(init_git "${main_git_url}" "${bootstrap_new_revision}")

  cp -a "${git_bootstrap_new_revision}"/{versions,cluster-definitions} "${new_cluster_definition_dir}/"
  yq -i ".platform_version = \"${new_version}\"" "${new_cluster_definition_dir}/cluster-definitions/${cluster}/cluster.yaml"
elif [ "${new_version_str}" == "skip" ]; then
  echo "Skipping preparing of new version"
else
  if [ "${new_version_str}" == "current" ]; then
    git_bootstrap_new_revision="${repodir}"
  else
    git_bootstrap_new_revision=$(init_git "${main_git_url}" "${new_version_str}")
  fi
  cp -a "${git_bootstrap_new_revision}"/{versions,cluster-definitions} "${new_cluster_definition_dir}/"
fi

echo " DONE"
echo

echo -n "Generating old bootstrap..."
oc kustomize ${git_bootstrap_old_revision}/cluster-config/overlays/${cluster}/apps-of-apps | yq -r > "${old_output_dir}/bootstrap.yaml"
for var in $(yq -o json < "${old_output_dir}/bootstrap.yaml" | jq '.' | grep '{{' | sed -e 's/[^{]*{{[ ]*//' -e 's/[ ]*}}[^}]*$//' -e 's/[ ]*}}[^{]*{{[ ]*/\n/g' | sort -u); do 
  sed -i -e "s/{{ *${var} *}}/$(yq -r .${var} < ${old_cluster_definition_dir}/cluster-definitions/${cluster}/cluster.yaml)/g" "${old_output_dir}/bootstrap.yaml"
done
echo " DONE"

if [ "${new_version_str}" != "skip" ]; then
  echo -n "Generating new bootstrap..."
  oc kustomize ${git_bootstrap_new_revision}/cluster-config/overlays/${cluster}/apps-of-apps | yq -r > "${new_output_dir}/bootstrap.yaml"
  for var in $(yq -o json < "${new_output_dir}/bootstrap.yaml" | jq '.' | grep '{{' | sed -e 's/[^{]*{{[ ]*//' -e 's/[ ]*}}[^}]*$//' -e 's/[ ]*}}[^{]*{{[ ]*/\n/g' | sort -u); do 
    sed -i -e "s/{{ *${var} *}}/$(yq -r .${var} < ${new_cluster_definition_dir}/cluster-definitions/${cluster}/cluster.yaml)/g" "${new_output_dir}/bootstrap.yaml"
  done
  echo " DONE"
  echo
fi

function render_kustomize_app() {
  target_dir=$1
  shift
  src_app=$1
  shift
  src_spec=$1
  shift

  src_repo=$(echo "${src_spec}" | base64 -d | jq -r ".source.repoURL")
  src_revision=$(echo "${src_spec}" | base64 -d | jq -r ".source.targetRevision")

  src_repo=$(init_git "${src_repo}" "${src_revision}")

  src_path=$(echo "${src_spec}" | base64 -d | jq -r ".source.path")
  path="${src_repo}/${src_path}"

  output="${target_dir}/${src_app}.yaml"
  oc kustomize "${path}" | yq -r > "${output}"
  echo "${output}"
}

function render_helm_app() {
  target_dir=$1
  shift
  src_app=$1
  shift
  src_spec=$1
  shift

  src_repo=$(echo "${src_spec}" | base64 -d | jq -r ".source.repoURL")
  src_revision=$(echo "${src_spec}" | base64 -d | jq -r ".source.targetRevision")

  src_repo=$(init_git "${src_repo}" "${src_revision}")

  src_path=$(echo "${src_spec}" | base64 -d | jq -r ".source.path")
  path="${src_repo}/${src_path}"

  helm_release_name=$(echo "${src_spec}" | base64 -d | jq -r ".source.helm.releaseName // \"${src_app}\"")
  helm_values_files=$(echo "${src_spec}" | base64 -d | jq -r '.source.helm.valueFiles // [] | join(" --values ")')
  helm_values=$(echo "${src_spec}" | base64 -d | jq -r '.source.helm.parameters // [] | map(.name + "=" + .value) | join(",")')

  output="${target_dir}/${src_app}.yaml"
  pushd ${path} > /dev/null
  if [ $? -gt 0 ]; then
    echo "Error while chaning into ${path} - Aborting!" > /dev/stderr
    exit 1
  fi
  str=""
  if [ ! -z "${helm_values_files}" ]; then
    str="${str}--values ${helm_values_files} "
  fi
  if [ ! -z "${helm_values}" ]; then
    str="${str}--set ${helm_values} "
  fi
  helm template "${helm_release_name}" . ${str}| yq -r > "${output}"

  popd > /dev/null
  echo "${output}"
}

function recurse_into_file() {
  file=$1
  echo "${prefix}Generating sub-apps for ${file}..."
  SAVEIFS=$IFS
  IFS=$(echo -en "\n\b")

  apps_helm=($(yq -o json < "${file}" | jq -r '. | select(.kind == "ApplicationSet" and (.spec.template.spec.source | has("helm"))) | .spec.template.metadata.name + "  " + (.spec.template.spec | @base64)'))
  apps_helm+=($(yq -o json < "${file}" | jq -r '. | select(.kind == "Application" and (.spec.source | has("helm"))) | .metadata.name + "  " + (.spec | @base64)'))

  apps_kustomize=($(yq -o json < "${file}" | jq -r '. | select(.kind == "ApplicationSet" and (.spec.template.spec.source | has("helm") | not)) | .spec.template.metadata.name + "  " + (.spec.template.spec | @base64)'))
  apps_kustomize+=($(yq -o json < "${file}" | jq -r '. | select(.kind == "Application" and (.spec.source | has("helm") | not )) | .metadata.name + "  " + (.spec | @base64)'))

  IFS=$SAVEIFS
  local old_prefix=$prefix
  prefix=+=" "
  for app_data in "${apps_helm[@]}"; do
    app_data_arr=( $app_data )
    gen_file=$(render_helm_app "$(dirname $file)" "${app_data_arr[@]}")
  done
  for app_data in "${apps_kustomize[@]}"; do
    app_data_arr=( $app_data )
    gen_file=$(render_kustomize_app "$(dirname $file)" "${app_data_arr[@]}")
  done
  prefix="${old_prefix}"
  echo "${prefix}DONE Generating sub-apps for ${file}..."
}

prefix=""
recurse_into_file "${old_output_dir}/bootstrap.yaml"
if [ "${new_version_str}" != "skip" ]; then
  recurse_into_file "${new_output_dir}/bootstrap.yaml"

  echo
  echo "Generating all configs done - you can now see the difference by executing the following command:"
  echo
  echo "diff -Naur ${old_output_dir} ${new_output_dir}"
  echo
else
  echo
  echo "Generating all configs done - you can now inspect the generated config in ${old_output_dir}"
  echo
fi
