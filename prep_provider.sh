
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
  #One could use something like yq here... But kubectl is actually much faster!
  KUBECONFIG= kubectl apply --dry-run="client" --validate=false -o json -f -
}

populate_cache ()
{
  [ ${1} ] || 
  {
    echo "usage: $FUNCNAME <provider>" >/dev/stderr
    return
  }
  local provider=$1
  [ -d ".cache/${provider}" ] || mkdir -p ".cache/${provider}"
  local jq_dir=$(realpath ./jq)
  local tf_docs="terraform-provider-${provider}"
  local xp_crds="crossplane-provider-${provider}"
  local tf_tag="main"
  local xp_tag="v0.19.0"

  (
    cd ".cache/${provider}"
    ## subshell to prevent cd headaches
    ## TODO(?) just move to a standalone script
    [ -d ${tf_docs}/website/docs/r ] || \
    (
      ## v1
      #git init $tf_docs
      #cd $tf_docs
      #git remote add origin https://github.com/terraform-providers/terraform-provider-aws.git
      #git config core.sparseCheckout true
      #echo "website/docs/r/" >> .git/info/sparse-checkout
      #git pull --depth=5 --no-tags origin main #XXX TAG!!

      ## v2
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
      >( jq -Cc '{kind}' ) \
      >( echo ">> Extracted spec of $(wc -l) modules" ) \
    > tf-params_${tf_tag}.json

    [ -d ${xp_crds} ] || mkdir -p ${xp_crds}

    #TODO: most fit for a Makefile
    #TODO: force re-download
    [ -r ${xp_crds}/crds_${xp_tag}.json ] \
    && \
    curl "https://doc.crds.dev/raw/github.com/crossplane/provider-${provider}@${xp_tag}" \
    | _yaml2json \
    | jq -c '.items' \
    > ${xp_crds}/crds_${xp_tag}.json
    

    [ -r xp-params_${xp_tag}.json ] \
    && \
    < ${xp_crds}/crds_${xp_tag}.json \
      jq -c -f "${jq_dir}/transform-crossplane-crds.jq" \
    | tee \
      >( jq -Cc '{id}' ) \
      >( echo ">> Extracted spec of $(wc -l) crds" ) \
    > xp-params_${xp_tag}.json
  ) #// inside .cache/${provider}
}


