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
  colorize()
  {
    local color=$1
    local needle=$2
    local col
    local ret=$'\e[0m'
    case $color in
      RED)
        col=$'\e[31;1m'
        ;;
      ORANGE)
        col=$'\e[33;1m';
        ;;
      BLUE)
        col=$'\e[34;1m';
        ;;
    esac
    sed  -E "s#(${needle})#${col}\0${ret}#g"
  }

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
    | echo ">> ${f} $(grep -cE '(.yaml$|WIP)')/$( cover ${provider} ${f} | wc -l  )" \
    | colorize BLUE '>>' \
    | sed -E 's#[^0-9]([0-9]+)/\1#[34;1m\0\t(ALL!)[0m#g'
  done \
  | column -t
}

#XXX pseudocode outline for utilizing docs (terraform-provider-scrape)
#_decide_on_target ()
#{
#    if docs[input.type] has input.param in "args"; then
#        output:;
#        {
#            - from: "spec.$input.param";
#            to: "spec.forProvider.(toCamel input.param)"
#        };
#    else
#        output:;
#        {
#            - from: "spec.$input.param";
#            at: "status.atProvider.(toCamel input.param)"
#        };
#    fi
#}
#
#
#_find_param_candidate () #arg1: canditate_target_type
#{
#  get_provider_crd  canditate_target_type \
#    | list_param_paths \
#    | smart_grep   each param word split by "_"
#
##[IDEA]
##  $ < provider-crds/aws_v0.19.0.json jq '.[]|.spec|[(.group/"."|.[0]),.names.kind]'
## - though this includes things like
## [
##   "servicediscovery",
##   "PublicDNSNamespace"
## ]
##
## - it can be hard to split the camel-cased words... One would have to run
## through the string, detect capital letters and in each case check
## if the next letter isn't capital as well.
#}

extract_params ()
{
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

#guess_config_for ()
#{
#  local kind=${1}
#  local crds_file=${2}
#  local kind_words=$(echo $kind | tr '_' ' ')
#  local candidates=

select_mappings ()
{
  split_words()
  {
    sed -e 's/[A-Z][a-z0-9]/.\0/g' -E -e 's/[A-Z][A-Z]+/.\0/g' | tr '[A-Z]' '[a-z]'
  }
  [ -f $1 ] || return 1
  [ -f $2 ] || return 2
  local crossplane_crds=$1
  local terraform_specs=$2
  [ $3 ] || return 3
  local output=$3
  shift 3
  < ${crossplane_crds} jq '.[]|.spec|((.group/"."|.[0]) + " " + .names.kind)' -r \
    | while read group kind
      do
        local grep_ext_regex
        grep_ext_regex=$(< ${crossplane_crds} \
          jq -c -r '
            .[]
            | select(.spec.names.kind=="'${kind}'")
            | .spec.versions[0].schema.openAPIV3Schema
                    | .properties.spec.properties
                    | .forProvider.properties
                    | keys
            ' \
          | sed -e 's/[A-Z][a-z0-9]/.\0/g' -E -e 's/[A-Z][A-Z]+/.\0/g' \
          | tr '[A-Z]' '[a-z]' | tr '[],' '()|' \
          | sed -e 's/"/\\b/g'
        )
        

        echo ">>>> grep -E \"${grep_ext_regex}\""

        #break #######################################
        
        ## TODO make it in a single call
        echo -en "${group}.${kind}   " >> ${output}

        #FIXME: all the subsequent jq parsings of $crossplane_crds are WRONG (they don't select group - e.g. Cluster...) and can be removed altogether
        < ${terraform_specs} jq -c '.kind' -r \
        | fzf -1 -i -q "${kind} ${group}" \
            --no-info \
            --reverse \
            --preview-window=left,30% \
            --preview="echo selected terraform module parameters:; < ${terraform_specs} jq -C 'select(.kind==\"'{}'\")' | grep --color=always -C99 -E \"${grep_ext_regex}\"" \
            --header="$(
                < ${crossplane_crds} \
                  jq '
                    .[]
                    | select(.spec.names.kind=="'${kind}'")
                    | .spec.versions[0].schema.openAPIV3Schema
                    | .description';
                echo -e "\e[44m=> arguments in spec.forProvider:\e[0m";
                < ${crossplane_crds} \
                  jq -C '
                    .[]
                    | select(.spec.names.kind=="'${kind}'")
                    | .spec.versions[0].schema.openAPIV3Schema
                    | .properties.spec.properties
                    | .forProvider.properties 
                    | keys';
                echo -e "\e[44m=> parameters in status.atProvider:\e[0m";
                < ${crossplane_crds} \
                  jq -C '
                    .[]
                    | select(.spec.names.kind=="'${kind}'")
                    | .spec.versions[0].schema.openAPIV3Schema.properties
                    | .status.properties
                    | .atProvider.properties 
                    | keys';
                echo -e \
                  "\n\e[44m== select best matching terraform module from below list ==\e[0m\n "
                )" \
            $@ \
        >> ${output}
        sleep 1
        #break #XXX
      done
}
