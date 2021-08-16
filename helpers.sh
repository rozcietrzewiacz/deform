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
  apiVersion: "raw.import.tf.xxx/v1alpha1" #TODO: Come up with reasonable api name
  kind: ${raw_kind}
target:
  apiVersion: ${target_api_version}
  kind: ${target_kind}
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

_find_target_crd_for_given_raw_crd()
{
  local crd_extracted_params_file=${1}
  local raw_crd_kind=${2}
  shift 2
  #All subsequent parameters are passed to fzf header
  _split_camel_words()
  {
    echo $@ \
    | sed -e 's/[A-Z][a-z0-9]/ \0/g' -E -e 's/[A-Z][A-Z]+/ \0/g' \
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
  #IN1: tfstate-show json
  #IN2: provider name (e.g. "aws", "gcp")

  local tfstate_show=${1}
  local provider=${2-aws}

  #
  #TODO: derive tf provider spec and crossplane crds jsons from provider name
  #TODO: generate the above files in a standardized manner
  local crd_extracted_params=$(realpath "provider-crds/extracted_params-aws_v0.19.0.json")
  local terraform_specs=$(realpath "terraform-provider-scrape/my-own-sed-version_1.json")

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
    ./deform ${tfstate_show} ${provider} xr \
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
  [ -d ${provider}_v2 ] || mkdir ${provider}_v2
  cd ${provider}_v2
  ##### MAIN LOOP #####
  while read line <&3
  do
    eval ${line}
    [ ${raw_kind} ] || continue

    # TODO: Start by fetching crossplane CRD from json
    # TODO: use fzf to select matching crossplane CRD at the start of the main while loop

    local yaml="${raw_kind}.yaml"

    if [ -r "_missing_${yaml}" ] || \
       [ -r "_skip_${yaml}"    ] || \
       [ -r "_edit_${yaml}"    ] || \
       [ -r "${yaml}"          ]
    then
      __e -e "\n>> \e[43;1m ${raw_kind} \e[0m: SKIPPING; $(ls -1 *${yaml}) already exists"
      continue
    fi
    ####################
    __e -e "\n>> \e[44;1m ${raw_kind} \e[0m: Found ${#paths[@]} json paths in spec";
    __e " > finding crossplane CRD match..."

    # TODO This implementation feels ugly. Bouncing back and forth
    #  using "$group.$raw_kind" patern :/
    local crd_match=$(_find_target_crd_for_given_raw_crd ${crd_extracted_params} ${raw_kind} ${paths[@]})
    if [ ! ${crd_match} ]
    then
      ##TODO: output default header
      ##TODO: explode paths
      __e -e " > \e[31;1mNo match found!\e[0m"
      continue
    fi

    local target_kind="$(__get_cr_element ${crd_match} kind)"
    local target_api_version="$(__get_cr_element ${crd_match} apiVersion)"
    local target_args=( $(__get_cr_element ${crd_match} "args|keys|.[]") )
    local target_attrs=( $(__get_cr_element ${crd_match} "attrs|keys|.[]") )

    declare -A imports
    declare -A exports
    local unidentified=( )
    #XXX Collapse array-like paths first (?) For now, skip repeated paths:
    local previous_word=""
    for path in ${paths[@]}
    do
      #"id" is a special parameter indicating `external-name`,
      # hardcoded in the `deform-composer`
      if [ "${path}" == "spec.id" ]; then continue; fi

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
        imports["${path}"]="${arg_matches}"
        #echo "  from: \"${path}\""
        #echo "  to: \"spec.forProvider.${arg_matches}\""
      elif [ ${#attr_matches[@]} -eq 1 ] # path in attrs
      then
        exports["${path}"]="${attr_matches}"
        #echo "#XXX to exports:  from: \"${path}\""
        #echo "#XXX              at: \"status.atProvider.${attr_matches}\""
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

    ##### Combine it all together ####
    #FD4: yaml file output
    exec 4>&1
    exec > _edit_${yaml}
    _yaml_header ${raw_kind} ${target_api_version} ${target_kind}

    __e " > identified ${#imports[@]} argument path matches"
    echo "imports:"
    for k in ${!imports[@]}
    do
      echo "- from: \"$k\""
      echo "  to: \"spec.forProvider.${imports[$k]}\""
    done

    __e " > identified ${#exports[@]} attribute path matches"
    echo "exports:"
    for k in ${!exports[@]}
    do
      echo "- from: \"$k\""
      echo "  at: \"status.atProvider.${exports[$k]}\""
    done

    __e " > NOTE: found ${#unidentified[@]} unidentified paths"
    echo "#unidentified:"
    for path in ${unidentified[@]}
    do
      #TODO: expand as in the previous version
      echo "# \"${path}\""
    done
    ##### Close file and restore stdout before continuing ####
    exec 1>&4 4>&-
  done
  # Close input:
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

tf_extract_provider_params ()
{
  #TODO document usage!
  #TODO Complete the implementation. From history:
  # $ cd terraform-provider-scrape/app/terraform-provider-aws/website/docs/r/
  # ^^^ replace this with e.g. "git clone https://github.com/terraform-providers/terraform-provider-aws.git"
  # $ time ( for f in *; do kind=${f%%.*}; tf_extract_provider_params $kind; done ) | jq -c > ../../../../../my-own-sed-version_1.json
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
