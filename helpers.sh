_yaml_header()
{
  local K=$1
  cat << YAML
source:
  apiVersion: "raw.import.tf.xxx/v1alpha1" #TODO: Come up with reasonable api name
  kind: $K
target:
  apiVersion: #XXX COPY-PASTE FROM https://doc.crds.dev/github.com/crossplane/provider-aws/ s3.aws.crossplane.io/ XXX v1beta1
  kind: #XXX (GUESS) search for: ${K#Aws}
imports:
YAML
}

_yaml_import_expand()
{
  cat << YAML
- from: "$1"
  to: "spec.forProvider." #XXX
YAML
}

_yaml_helpful_footer()
{
  cat << 'YAML'
##### COPY-PASTE helpers ####
  transforms:
  - type: convert
    convert:
      toType: string
  - map:
      "false": "Disabled"
      "true": "Enabled"
    type: map
YAML
}

prep_files () 
{
  local provider=${2-aws}
  local generated=()

  [ $# -gt 0 ] || {
    echo "Usage: $0 <json_file> [provider]"
    return 1
  }
  
  ## WHY like this? BECAUSE BASH! Cannot alter variables from a pipe.
  ### See: https://unix.stackexchange.com/questions/224576/how-do-i-append-an-item-to-an-array-in-a-pipeline
  while read lin
  do
    eval $lin
    local yaml="${provider}/${kind}.yaml"
    if [ -r ${yaml} ]; then 
      echo " > ${yaml} already exists. SKIPPING.";
      #ls ${yaml} | grep --color=always "${kind}.yaml"
    else
      echo -e "\n\e[44;1m>> Found ${#paths[@]} json paths in spec for $kind \e[0m";
      echo " > generating ${yaml}"
      _yaml_header $kind >> ${yaml}
      for p in ${paths[@]}; do
        _yaml_import_expand $p >> ${yaml}
      done
      _yaml_helpful_footer >> ${yaml}
      echo " > ${yaml} generated"
      generated+=("$yaml")
      echo
    fi
  done < <(./deform $1 $2 xr \
    | jq -r '
      @sh "
        kind=\(.kind)
        paths=(\({spec}|[paths(scalars) | map(.|tostring) | join(".")]))
        "
      '
  )

  echo
  echo "-+-+-+-+-+-+-+-+-+-+-+-+-"
  echo " > Generated ${#generated[@]} new files."
  echo "============ ${generated[@]}"

  if [ ${#generated[@]} -gt 0 ]
  then
    echo " > Press <Enter> to edit the files one by one or <Ctrl-C> to skip."
    read
    for f in "${generated[@]}"
    do
      vim ${provider}/$f
      echo "Is ${provider}/${f} ready? [y/N]"
      read reply && {
        if [ "$reply" == "y" ]; then
          echo "mv ${provider}/${f} ${provider}/${f#_edit_}"
          rm -i ${provider}/$f ###XXX
        fi
      }
    done
  fi
}