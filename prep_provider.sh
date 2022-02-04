#!/usr/bin/bash
. lib/base.sh

tf_extract_provider_params ()
{
  #TODO document usage!
  local kind=$1
  [ -f ${kind}.* ] || return
  echo -n "{
  \"kind\": \"${kind}\",
  \"args\": ["
  cat ${kind}.* \
    | sed -n -e '/^##* Arguments* Ref/,/^#/p' \
    | sed -e 's/"/\\"/g' \
    | sed -n -E -e 's#^ *([*-] *)`([a-z][^`]*)`.*$#"\2",#p' \
    | sort | uniq \
    | tr '\n' ' ' \
    | head -c-2
  echo -n "],
  \"attrs\": ["
  cat ${kind}.* \
    | sed -n -e '/^##* Attributes* Ref/,/^#/p' \
    | sed -e 's/"/\\"/g' \
    | sed -n -E -e 's#^ *([*-] *)`([a-z][^`]*)`.*$#"\2",#p' \
    | sort | uniq \
    | tr '\n' ' ' \
    | head -c-2
  echo "]"
  echo "}"
}

_yaml2json()
{
  if which yaml2json &> /dev/null
  then
    e "> Using yaml2json tool"
    < ${1} yaml2json
  else
    e "> yaml2json tool not found. Using kubectl."
    #One could use something like yq here... But kubectl is actually faster,
    # as long as we use local (kind) cluster
    #KUBECONFIG=
    kubectl apply --dry-run="client" --validate=false -o json -f ${1} \
      | jq -c '.items[]'
  fi
}

_sanitize_yaml()
{
  #See: github.com/bronze1man/yaml2json/issues/23
  # - Tools like `yaml2json` by "bronze1man" break when there's
  # a "New Document" marker (---) at the bottom of yaml.
  # We strip it just in case.
  local inFile=$1
  local lastLine=$(tail -n1 ${inFile})
  if [ "$lastLine" == "---" ]
  then
    echo ">> WARNING: detected empty doc at the end of ${inFile}. Sanitizing..."
    local tmpfile=$(mktemp "XXXXXX.yaml")
    head -n -1 ${inFile} > ${tmpfile} \
      && mv ${tmpfile} ${inFile}
  fi
}

populate_cache ()
{
  [ ${1} ] ||
  {
    e "usage: $FUNCNAME <provider>"
    return
  }
  local provider=$1
  [ -d ".cache/${provider}" ] || mkdir -p ".cache/${provider}"
  local jq_dir=$(realpath ./jq)
  local tf_docs="terraform-provider-${provider}"
  local xp_crds="crossplane-provider-${provider}"
  local tf_tag="main"
  local xp_tag="v0.23.0"

  (
    cd ".cache/${provider}"
    ## subshell to prevent cd headaches
    ## TODO(?) just move to a standalone script
    [ -d ${tf_docs}/website/docs/r ] || \
    (
      git clone --depth=1 --filter=blob:none --sparse \
        https://github.com/terraform-providers/${tf_docs}.git \
        ${tf_docs}
      cd ${tf_docs}
      git sparse-checkout set "website/docs/r/"
    )
    ### Skipping tag selection now. The modules in tfstate output don't include
    ###  version information anyway.
    #git ls-remote --tags origin "v*[^}]" | cut -d '/' -f 3
    [ -f "tf-params_${tf_tag}.json" ] || \
    (
      cd ${tf_docs}/website/docs/r/ &> /dev/null \
      && for f in *
      do
        local kind=${f%%.*}
        tf_extract_provider_params ${kind}
      done \
      | jq -c
    ) \
    | tee \
      >( jq -Cc "{tf_${provider}: .kind}" ) \
      >( echo ">> Extracted spec of $(wc -l) modules" ) \
    > tf-params_${tf_tag}.json

    [ -d ${xp_crds} ] || mkdir -p ${xp_crds}

    #TODO: most fit for a Makefile
    #TODO: force re-download
    [ -r ${xp_crds}/crds_${xp_tag}.yaml ] \
    || \
    curl "https://doc.crds.dev/raw/github.com/crossplane/provider-${provider}@${xp_tag}" \
    > ${xp_crds}/crds_${xp_tag}.yaml
    _sanitize_yaml ${xp_crds}/crds_${xp_tag}.yaml

    [ -r ${xp_crds}/crds_${xp_tag}.json ] \
    || \
    _yaml2json ${xp_crds}/crds_${xp_tag}.yaml \
    > ${xp_crds}/crds_${xp_tag}.json


    [ -r xp-params_${xp_tag}.json ] \
    || \
    < ${xp_crds}/crds_${xp_tag}.json \
      jq -c -f "${jq_dir}/transform-crossplane-crds.jq" \
    | tee \
      >( jq -Cc '{xp_id:.id}' ) \
      >( echo ">> Extracted spec of $(wc -l) crds" ) \
    > xp-params_${xp_tag}.json
  ) #// inside .cache/${provider}
}


