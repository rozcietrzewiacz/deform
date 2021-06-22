_yaml_header()
{
  local K=$1
  cat << YAML
source:
  apiVersion: "raw.import.tf.xxx/v1alpha1" #TODO: Come up with reasonable api name
  kind: ${K}
target:
  #XXX apiVersion, kind - COPY-PASTE FROM https://doc.crds.dev/github.com/crossplane/provider-aws/ - search for: ${K#Aws}
imports:
YAML
}

_yaml_import_expand()
{
  cat << YAML
- from: "$1"
YAML
}

_yaml_helpful_footer()
{
  cat << 'YAML'
##### COPY-PASTE helpers ####

  to: "spec.forProvider."
  to: "metadata."

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
    unset kind
    eval $lin
    [ $kind ] || continue

    cd ${provider}
    local yaml="${kind}.yaml"

    if [ -r "_missing_${yaml}" ] || \
       [ -r "_skip_${yaml}"    ] || \
       [ -r "_edit_${yaml}"    ] || \
       [ -r "${yaml}"          ]
    then
      echo " > $(ls -1 *${yaml}) already exists; SKIPPING ${kind}"
    #ls ${yaml} | grep --color=always "${kind}.yaml"
    else
      local yaml_edit="_edit_${yaml}"
      echo -e "\n\e[44;1m>> Found ${#paths[@]} json paths in spec for $kind \e[0m";
      echo " > generating ${yaml_edit}"
      _yaml_header $kind >> ${yaml_edit}
      for p in ${paths[@]}; do
        _yaml_import_expand $p >> ${yaml_edit}
      done
      _yaml_helpful_footer >> ${yaml_edit}
      echo " > ${yaml_edit} generated"
      generated+=("$yaml_edit")
      echo
    fi
    cd -
  done < <(
  #####
  ./deform $1 ${provider} xr \
    | jq -s '
      .
      | group_by(.kind)
      | map(reduce .[] as $p ({}; . * $p))
      | .[]
    ' \
    | jq -r '
      @sh "kind=\(.kind) paths=(\({spec}|[paths(scalars) | map(.|tostring) | join(".")]))"
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
