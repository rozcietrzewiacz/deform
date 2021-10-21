_yaml_header()
{
  #In1: raw kind name
  #In2: target apiGroup
  #In3: target kind
  local raw_kind=$1
  local target_api_version=$2
  local target_kind=$3
  cat << YAML
source:
  apiVersion: "raw.import.deform.io/v1alpha1"
  kind: ${raw_kind}
target:
  apiVersion: ${target_api_version}
  kind: ${target_kind}
YAML
}

_yaml_helpful_footer()
{
  cat << 'YAML'
##### COPY-PASTE helpers ####

  to: "spec.forProvider."
  at: "metadata.annotations['import.deform.io/']"

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

_find_target_crd_for_given_raw_crd()
{
  local crd_extracted_params_file=${1}
  local raw_crd_kind=${2}
  shift 2
  #All subsequent parameters are passed to fzf header
  _split_camel_words()
  {
    echo $@ \
    | sed -E -e 's/[A-Z][A-Z]+/ \0/g' -e 's/[A-Z][a-z0-9]/ \0/g' \
    | tr '[A-Z]' '[a-z]' | cut -d ' ' -f 3-
    # Deform's "raw crd" kind name is based on terraform module name, where
    # the first word is the provider name. Due to how the first sed expression
    # above is structured, there is also an extra space at the beginning.
    # All this considered, we start from the third segment.
  }
  local kind_words="$(_split_camel_words ${raw_crd_kind})"

  # Concept: the arrays include entries in the form:
  # "<id>:<greppable>", where:
  #    <id> - the "<group>.<kind>" string, as .id in crd_extracted_params_file
  #    <greppable> - either "<group><kind>" or "<kind>" alone
  #
  # Thus egrep only focuses on the second part, starting with ":"
  local eregex_kind_words=":\<${kind_words// /.?}\>"

  local xp_groupKinds=( $(< ${crd_extracted_params_file} \
    jq -r '"\(.id):\(.group + .kind)"' ))
  local xp_kinds=( $(< ${crd_extracted_params_file} \
    jq -r '"\(.id):\(.kind)"' ))

  ### Strategy:
  # - try to match <group><kind> first
  # - if no single match found, try <kind> alone
  # - if still no match was found, use fzf with <group>.<kind> (i.e. "id")
  {
    printf "%s\n" ${xp_groupKinds[@]} \
      | grep -i -E "${eregex_kind_words}" \
    || printf "%s\n" ${xp_kinds[@]} \
      | grep -i -E "${eregex_kind_words}" \
    || printf "%s\n" ${xp_groupKinds[@]%%:*} \
      | fzf -i -q "${kind_words}" \
          --no-info \
          --reverse \
          --preview-window=right,65% \
          --preview="echo Selected Crossplane provider CRD parameters:;
              < ${crd_extracted_params_file} jq -C '
                select(.id == \"'{}'\")
                | del(.id)
                | del(.group)
               '" \
          --header=$'SELECT MATCH FOR \e[44;1m '${raw_crd_kind}$' \e[0m\n'"$(
              printf "%s\n" $@ | head -n 30;
              echo v----------------------v)"

  } | cut -d ':' -f 1
}

prep_files ()
{
  #TODO RENAME to eg. "generate_conversion_configs"

  #IN1: tfstate-show json
  #IN2: provider name (e.g. "aws", "gcp")
  local tfstate_show=${1}
  local provider=${2-aws}
  #
  #TODO: derive tf provider spec and crossplane crds jsons from provider name
  #TODO: generate the above files in a standardized manner
  local crd_extracted_params=$(realpath ".cache/${provider}/xp-params_v0.19.0.json")
  local terraform_specs=$(realpath ".cache/${provider}/tf-params_main.json")

  __get_cr_element()
  {
    #In1: id
    #In2: desired key
    #In3+: extra jq args
    local id=${1}
    local key=${2}
    shift 2
    < ${crd_extracted_params} jq -r 'select(.id=="'${id}'").'${key} $@
  }
  __e()
  {
    echo "$@" > /dev/stderr
  }

  #FD3: MAIN LOOP INPUT
  exec 3< <(
    ./deform ${tfstate_show} xr ${provider} \
      | jq -s '
        .
        | group_by(.kind)
        | map(reduce .[] as $p ({}; . * $p))
        | .[]
      ' \
      | jq -r '
        @sh "raw_kind=\(.kind) paths=(\({spec}|[paths(scalars) | map(.|tostring) | join(".")]))"
        '
  )
  [ -d ${provider} ] || mkdir ${provider}
  cd ${provider}

  ##### MAIN LOOP #####
  while read line <&3
  do
    eval ${line}
    [ ${raw_kind} ] || continue

    local yaml="${raw_kind}.yaml"
    if [ -r "_missing_${yaml}" ] || \
       [ -r "_skip_${yaml}"    ] || \
       [ -r "_edit_${yaml}"    ] || \
       [ -r "${yaml}"          ]
    then
      __e -e "\n>> \e[43;1m ${raw_kind} \e[0m: SKIPPING; $(ls -1 *${yaml}) already exists"
      continue
    fi
    __e -e "\n>> \e[44;1m ${raw_kind} \e[0m: Found ${#paths[@]} json paths in spec";
    __e " > finding crossplane CRD match..."

    # TODO This is ugly. Bouncing back and forth via "$group.$raw_kind" :/
    local crd_match=$(_find_target_crd_for_given_raw_crd ${crd_extracted_params} ${raw_kind} ${paths[@]})
    if [ ! ${crd_match} ]
    then
      __e -e " > \e[31;1mNo match found! Marking as missing.\e[0m"
      ##TODO (?) output default header
      ##TODO (?) explode paths
      touch "_missing_${yaml}"
      continue
    fi

    local target_kind=$(__get_cr_element ${crd_match} "kind")
    local target_api_version=$(__get_cr_element ${crd_match} "apiVersion")
    local target_args=( $(__get_cr_element ${crd_match} "args|keys|.[]") )
    local target_attrs=( $(__get_cr_element ${crd_match} "attrs|keys|.[]") )

    declare -A imports; imports=( )
    declare -A exports; exports=( )
    local unidentified=( )
    #XXX Collapse array-like paths first (?) For now, skip repeated paths:
    local previous_word=""
    for path in ${paths[@]}
    do
      #"id" is a special parameter indicating `external-name`,
      # hardcoded in the `deform-composer`
      if [ "${path}" == "spec.id" ]
      then
        imports["${path}"]="metadata.annotations['crossplane.io/external-name']"
        continue
      elif [ "${path}" == "spec.arn" ]
      then
        imports["${path}"]="metadata.annotations['import.deform.io/arn']"
        continue
      fi

      local word=$( echo "${path}" | cut -d '.' -f 2 | tr -d _ )
      #TODO: This section really cries out for a proper programming language!
      # We should be checking referenced object's properties instead of treating
      # paths as strings.
      if [ "${word}" == "${previous_word}" ]; then continue; fi
      local arg_matches=( $(printf "%s\n" ${target_args[@]} \
        | grep -i "\<${word}\>") )
      local attr_matches=( $(printf "%s\n" ${target_attrs[@]} \
        | grep -i "\<${word}\>") )

      if [ ${#arg_matches[@]} -eq 1 ] # path in args
      then
        imports["${path}"]="spec.forProvider.${arg_matches}"
      elif [ ${#attr_matches[@]} -eq 1 ] # path in attrs
      then
        exports["${path}"]="status.atProvider.${attr_matches}"
      elif [ ${#arg_matches[@]} -gt 1 ] || [ ${#attr_matches[@]} -gt 1 ]
      then
        __e "#ERROR: multiple matches found for ${path}:"
        echo "#  ARG: ${arg_matches[@]}"
        echo "# ATTR: ${attr_matches[@]}"
      else
        unidentified+=( ${path} )
      fi
      previous_word=${word}
    done

    ### Combine it all together ##
    #FD4: yaml file output
    exec 4>&1
    exec > _edit_${yaml}
    _yaml_header ${raw_kind} ${target_api_version} ${target_kind}

    __e " > identified ${#imports[@]} argument path matches"
    echo "imports:"
    for k in ${!imports[@]}
    do
      echo "- from: \"$k\""
      echo "  to: \"${imports[$k]}\""
    done

    __e " > identified ${#exports[@]} attribute path matches"
    echo "exports:"
    for k in ${!exports[@]}
    do
      echo "- from: \"$k\""
      echo "  at: \"${exports[$k]}\""
    done

    __e " > NOTE: found ${#unidentified[@]} unidentified paths"
    echo "#unidentified:"
    for path in ${unidentified[@]}
    do
      echo "#- from: \"${path}\""
    done
    ## Close file and restore stdout before continuing ##
    exec 1>&4 4>&-
  done
  ## Close input ##
  exec 3>&-
  cd - &> /dev/null
}

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
  ./deform <( cat $@ ) xr ${provider} | jq '.kind' -r | sort | uniq -c | sort -g \
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
  if [ ! "${provider}" ] || [ ! -d "${provider}" ]
  then
    echo "Usage: $FUNCNAME <provider> FILES..."
    return
  fi
  shift
  for f in "$@"
  do
    #TODO: Optimize - remove second invocation of "cover"
    cover ${provider} $f \
    | echo ">> ${f} $(grep -cE '(.yaml$)')/$( cover ${provider} ${f} | wc -l  )" \
    | colorize BLUE '>>' \
    | sed -E 's#[^0-9]([0-9]+)/\1#[34;1m\0\t(ALL!)[0m#g'
  done \
  | column -t
}


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

apply_compositions()
{
  ## TODO: Cleanup. Most (check!) of the functionality is moved to deform itself
  local MSG_BOTTOM=
  local PROVIDER_CONFIG_NAME=${PROVIDER_CONFIG_NAME:-}
  [ "$1" ] || {
    echo "ERROR: You need to specifiy the provider" > /dev/stderr
    return 1
  }
  local PROVIDER=${1}
  if [ "$2" ]
  then
    local deformConfigs="$2"
  else
    echo "WARNING: No deform config file specified."
    read -p "Itereate over all complete configs under ${PROVIDER}/? [Y/n] " re
    case "$re" in
      [Nn])
        echo "Exiting"
        return 0
        ;;
      *)
        local deformConfigs="${PROVIDER}/${PROVIDER^}*.yaml"
        ;;
    esac
  fi
  ### Detecting providerConfig, if not specified ###
  declare -a providerConfigs
  [ "$PROVIDER_CONFIG_NAME" ] || {
    echo "PROVIDER_CONFIG_NAME not set. Attempting auto-detect..." > /dev/stderr
    providerConfigs=( $(
      kubectl get ProviderConfig.${PROVIDER}.crossplane.io \
        -o jsonpath='{.items[*].metadata.name}') )
    if [ ${#providerConfigs[@]} -gt 1 ]
    then
      #TODO: TEST
      MSG_BOTTOM+="\nWARNING: Found more than one ProviderConfigs! Using first one."
    elif [ -z "${#providerConfigs[@]}" ]
    then
      #TODO: TEST
      MSG_BOTTOM+="\nWARNING: No ProviderConfig.${PROVIDER}.crossplane.io found"
    fi
    PROVIDER_CONFIG_NAME="${providerConfigs[0]}"
    MSG_BOTTOM+="\nGuessed ProviderConfig name: \"${PROVIDER_CONFIG_NAME}\". To skip auto-detection next time, run:\nexport PROVIDER_CONFIG_NAME=\"${PROVIDER_CONFIG_NAME}\""
  }

  tmpCompositions=$(mktemp .cache/compositions_XXXX.yaml)
  local counter=0
  for config in $deformConfigs
  do
    local sourceName=${config#*/}
    sourceName=${sourceName%.yaml}

    # Not very clear, since helm outputs '---' at the start: echo "###### ${config}"
    helm template \
      "deform-${sourceName}" \
      deform-composer/ \
      --values=${config} \
      --set providerConfig=${PROVIDER_CONFIG_NAME}
    if [ $? -eq 0 ]
    then
      counter=$[ counter + 1 ]
    else
      echo "### ERROR encountered in $config" > /dev/stderr
    fi
  done > ${tmpCompositions}
  MSG_BOTTOM+="\nGenerated ${counter} compositions."

  kubectl apply -f "${tmpCompositions}"
  if [ $? -eq 0 ]
  then
    echo "Compositions applied successfully." > /dev/stderr
    if [ "${DEBUG}" ]
    then
      echo "DEBUG enabled. Leaving "${tmpCompositions}" for inspection." > /dev/stderr
    else
      rm "${tmpCompositions}"
    fi
  else
    MSG_BOTTOM+="\nFAILED to apply compositions. ${tmpCompositions} file left for manual inspection."
  fi

  [ "$MSG_BOTTOM" ] && echo -e "\e[35;1m$MSG_BOTTOM\e[0m"
}
