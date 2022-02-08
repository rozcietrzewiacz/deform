#!/usr/bin/bash

_e()
{
  echo "$@" >&2
}

_dbg()
{
  [ $DEBUG ] && echo "DEBUG: " $@ >&2
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

#Colorizing supplied text inline
_green()  { echo -en "\e[32m$@\e[0m";   }
_greenb() { echo -en "\e[32;1m$@\e[0m"; }
_redb()   { echo -en "\e[31;1m$@\e[0m"; }
_purple() { echo -en "\e[35m$@\e[0m";   }
_yellow() { echo -en "\e[33m$@\e[0m";   }

#Alternative colorizing approach, based on filtering entire text chunks
_colorize()
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
