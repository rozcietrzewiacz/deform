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
    echo "Usage: $FUNCNAME <json_file> [provider]"
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

# cover ()
# {
#   ./deform <( cat $@ ) aws xr | jq '.kind' -r | sort | uniq -c | sort -g \
#   | column -J --table-columns "count,kind" \
#   | jq -c '.table[]|.status=(.|@sh "kAAAAAind=\(.kind); ls aws/${kind}.yaml")'
#   #do
#   #    echo -e "\e[35m >> \e[0m ${kind}($count)\ttesting...";
#   #done \
# }

cover ()
{
  local provider=$1
  if [ ! ${provider} ] || [ ! -d ${provider} ]
  then
    echo "Usage: $FUNCNAME <provider> FILES..."
    return
  fi
  shift
  ###XXX Consider: https://stackoverflow.com/questions/26717277/accessing-a-json-object-in-bash-associative-array-list-another-model/51690860#51690860
  ./deform <( cat $@ ) ${provider} xr | jq '.kind' -r | sort | uniq -c | sort -g \
    | while read count kind; do
      echo -e "${kind}($count)\t$(ls ${provider}/${kind}.yaml 2>/dev/null || if [ -f ${provider}/_edit_${kind}.yaml ]; then echo -n "(WIP)"; else echo -n "(MISSING)"; fi )"
    done \
    | column -t \
    | while IFS=$'\r\n' read -r LINE; do
      echo -e "\e[35m >> \e[0m $LINE"
    done
}

cover_stats()
{
  local provider=$1
  if [ ! ${provider} ] || [ ! -d ${provider} ]
  then
    echo "Usage: $FUNCNAME <provider> FILES..."
    return
  fi
  shift
  for f in "$@"
  do
    #TODO: Optimize - remove second invocation of "cover"
    cover ${provider} $f \
      | echo -e "\e[35m >> ${f} \e[0m: $(grep -cF '.yaml')/$( cover ${provider} ${f} | wc -l  )"
  done
}
