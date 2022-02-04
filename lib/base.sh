#!/usr/bin/bash

e()
{
  echo $@ >&2
}

_arg_required()
{
  local position=${1}
  local value=${2}
  shift 2
  if [ "$value" == "" ]
  then
    e "ERROR: Missing required arg at position $position: $@"
    return 1
  fi
}
