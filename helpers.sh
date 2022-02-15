#!/usr/bin/bash
. lib/base.sh

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


generate_translation_configs ()
{
  #IN1: tfstate-show json
  #IN2: provider name (e.g. "aws", "gcp")
  local tfstate_show=${1}
  _arg_required 1 "${tfstate_show}" tfstate-show file || return 1
  local provider=${2-aws}
  local crd_extracted_params=$(realpath .cache/${provider}/xp-params_v*.json)
  local terraform_specs=$(realpath ".cache/${provider}/tf-params_main.json")
  local xp_groupKinds=( $(< ${crd_extracted_params} \
    jq -r '"\(.id):\(.group + .kind)"' ))
  local xp_kinds=( $(< ${crd_extracted_params} \
    jq -r '"\(.id):\(.kind)"' ))

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

  _find_target_crd_for_given_raw_crd()
  {
    local raw_crd_kind=${1}
    shift 1
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

    ### Strategy:
    # - try to match <group><kind> first
    # - if no single match found, try <kind> alone
    # - if still no match was found, use fzf with <group>.<kind> (i.e. "id")
    local matches matchCount
    __try()
    {
      matches=$( printf "%s\n" ${@} | grep -i -E "${eregex_kind_words}" )
      matchCount=$( <<< "${matches}" wc -w)
    }

    __try ${xp_groupKinds[@]}
    [ $matchCount -eq 1 ] || \
    __try ${xp_kinds[@]}

    [ "${SKIP_FZF}" ] || \
    [ $matchCount -eq 1 ] || \
    matches=$(
      printf "%s\n" ${xp_groupKinds[@]%%:*} \
        | fzf -i -q "${kind_words}" \
          --no-info \
          --reverse \
          --preview-window=right,65% \
          --preview="echo Selected Crossplane provider CRD parameters:;
              < ${crd_extracted_params} jq -C '
                select(.id == \"'{}'\")
                | del(.id)
                | del(.group)
               '" \
          --header=$'SELECT MATCH FOR \e[44;1m '${raw_crd_kind}$' \e[0m\n'"$(
              printf "%s\n" $@ | head -n 30;
              echo v----------------------v)"
    )

    matchCount=$( <<< "${matches}" wc -w)
    [ $matchCount -eq 1 ] && \
    echo "${matches}" | cut -d ':' -f 1
  }

  ############################################################################
  #FD3: MAIN LOOP INPUT
  exec 3< <(
    < ${tfstate_show} jq -f jq/from-tfstate-output_parse-modules.jq \
      --arg provider ${provider} \
      | jq -s -f jq/from-type+value-to-raw-xr.jq \
      | jq -s '
def meld(a; b):
  .
  | a as $a | b as $b
  | if ($a|type) == "object" and ($b|type) == "object"
    then
      reduce ([$a,$b] | add | keys_unsorted[]) as $k
      (
        {};
        .[$k] = meld( $a[$k]; $b[$k])
      )
    elif ($a|type) == "array" and ($b|type) == "array"
    then
      $a + $b
    elif $b == null
      then $a
    else
      $b
    end
;
        .
        | group_by(.kind)
        | map(reduce .[] as $p ({}; meld(.;$p)))
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
      _e -e "\n>> \e[43;1m ${raw_kind} \e[0m: SKIPPING; $(ls -1 *${yaml}) already exists"
      continue
    fi
    _e -e "\n>> \e[44;1m ${raw_kind} \e[0m: Found ${#paths[@]} json paths in spec";
    _e " > finding crossplane CRD match..."

    # TODO This is ugly. Bouncing back and forth via "$group.$raw_kind" :/
    local crd_match=$(_find_target_crd_for_given_raw_crd ${raw_kind} ${paths[@]})
    if [ ! ${crd_match} ]
    then
      _e -e " > \e[31;1mNo match found! Marking as missing.\e[0m"
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
        #NOPE: This is now added in the composition helm template.
        #imports["${path}"]="metadata.annotations['crossplane.io/external-name']"
        # Just skip.
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
        ##XXX NO! Wrong way! Probably should just be skipped anyway..
        exports["${path}"]="status.atProvider.${attr_matches}"
      elif [ ${#arg_matches[@]} -gt 1 ] || [ ${#attr_matches[@]} -gt 1 ]
      then
        _e "#ERROR: multiple matches found for ${path}"
        echo "#possible  ARGs: ${arg_matches[@]}"
        echo "#possible ATTRs: ${attr_matches[@]}"
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

    _e " > identified ${#imports[@]} argument path matches"
    echo "imports:"
    for k in ${!imports[@]}
    do
      echo "- from: \"$k\""
      echo "  to: \"${imports[$k]}\""
    done

    _e " > identified ${#exports[@]} attribute path matches"
    echo "exports:"
    for k in ${!exports[@]}
    do
      echo "- from: \"$k\""
      echo "  at: \"${exports[$k]}\""
    done

    _e " > NOTE: found ${#unidentified[@]} unidentified paths"
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
  _support()
  {
    local kind=$1
    [ -f "${provider}/${kind}.yaml" ] && {
      _greenb $(ls "${provider}/${kind}.yaml")
      return
    }
    [ -f "${provider}/_edit_${kind}.yaml" ] && {
      _yellow "(WIP)"
      return
    }
    [ -f "${provider}/_missing_${kind}.yaml" ] && {
      _redb "(UNSUPPORTED)"
      return
    }
    echo -n "(UNKNOWN)"
  }
  #Use "cat" to support supplying multiple files/wildcards as input arguments
  cat $@ \
    | jq --arg provider ${provider} -f jq/from-tfstate-output_parse-modules.jq \
    | jq -s -f jq/from-type+value-to-raw-xr.jq -c \
    | jq '.kind' -r | sort | uniq -c | sort -g \
    | while read count kind; do
      echo -e "${count}\t${kind}\t$(_support ${kind})"
    done \
    | column -t
}

cover_stats()
{
  local countBy
  summary()
  {
    local file=${1} total=0 supported=0 wip=0 unsupported=0 unknown=0 add=0
    while read count kind status
    do
      if [ "$countBy" == "KINDS" ]; then add=1; else add=${count}; fi
      : $[ total += add ]
      _dbg "HERE: $count $kind $status"
      case $status in
        *"${kind}.yaml"*)
          : $[ supported += add ]
          _dbg "SUPPORTED $kind found - total supported so far: $supported"
          ;;
        *"(WIP)"*)
          : $[ wip += add ]
          ;;
        *"(UNSUPPORTED)"*)
          : $[ unsupported += add ]
          ;;
        *"(UNKNOWN)"*)
          : $[ unknown += add ]
          ;;
      esac
    done
    local YAY=
    if [ $total -eq $supported ]; then YAY=$(_greenb "(ALL!)"); fi
    local check=$[ supported + wip + unsupported + unknown ]
    echo "$file $total ${supported}${YAY} $wip $unsupported $unknown"
  }

  local provider=$1
  if [ ! "${provider}" ] || [ ! -d "${provider}" ]
  then
    _e "Usage: $FUNCNAME <provider> [-r] FILES..."
    _e "  If -r parameter is given, the stats are presented based on exact" \
       " resource numbers defined for each individual kind within each file." \
       " Otherwise, only the number of supported kinds is considered."
    return
  fi
  shift
  if [ "${1}" == "-r" ]
  then
    countBy="RESOURCES"
    _e "> NOTE: Listing based on exact resource count"
    shift
  else
    countBy="KINDS"
    _e "> NOTE: Listing based on number of distinct kinds only"
  fi
  {
    #Header:
    echo  FILE  TOTAL_${countBy}  SUPPORTED  WIP  UNSUPPORTED  UNKNOWN
    for f in "$@"
    do
      cover ${provider} ${f} \
      | summary "${f}"
    done
  } \
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


k-children ()
{
  local parent=$1
  shift 1
  for kid in $(kubectl get $parent -o json | jq -cr '.spec.resourceRefs[]')
  do
    local kid0=$( <<< "$kid" \
      jq -r '"\(.kind|ascii_downcase).\(.apiVersion|split("/")[0])/\(.name)"'
    )
    _e "-------- ${kid0} -------"
    kubectl get ${kid0} $@
  done
}


related_events ()
{
  _get_related()
  {
    local res=$1
    [ "${res}" ] && \
    kubectl get events -n default -o json \
      | jq '
        [
          .items[]
          |select(.involvedObject.name=='$( <<<$res jq '.name' )')
          |{type,reason,age:(now - (.lastTimestamp|fromdate)|floor),message}
        ]
        |sort_by(.age)
        |reverse
        |.[]
        '
  }

  local obj_full=$(kubectl get $@ -o json | jq -c)
  local obj_spec=$(<<<${obj_full} jq -c '.spec')
  local obj_meta=$(<<<${obj_full} jq -c '{apiVersion,kind,name:.metadata.name}')
  _e -e ">> Querying events directly referencing ${obj_meta}..."
  _get_related "${obj_meta}"

  local parent_res=$(<<<${obj_spec} jq -c '.resourceRef?|select(.!=null)')
  if [ "${parent_res}" ]
  then
    _e -e ">> Discovered parent resource:\n  $(<<<${parent_res} jq -cC)\n querying events...";
    _get_related "${parent_res}"
  fi

  local child_res=$(<<<${obj_spec} jq -c '.resourceRefs[]?|select(.!=null)')
  if [ "$child_res" ]
  then
    _e -e "\e[32m>> Discovered $(<<<${child_res} wc -l) child resources:\e[0m"
    echo "${child_res}" \
    | while read -r child
    do
      _e " >>events for \"${child}\" <<"
      _get_related "${child}"
    done
  fi
}
