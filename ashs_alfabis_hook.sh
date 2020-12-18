#!/bin/bash
set -x -e

# Set PATH to the workspace tool
PATH=/data/picsl/pauly/bin:$PATH

# Extract the hook data from the environment
IFS=, read -r ticket_id product t_start t_length <<< ${ASHS_HOOK_DATA?}

# Set default t_start and t_length
if [[ ! t_start ]]; then
  t_start=0.0
  t_length=1.0
fi

# Simple case statement to split 
case "${1?}" in 
  progress)
    chunk_start=$(echo $t_start $t_length ${2?} | awk '{print $1+$2*$3}')
    chunk_end=$(echo $t_start $t_length ${3?} | awk '{print $1+$2*$3}')
    itksnap-wt -dssp-tickets-set-progress $ticket_id $chunk_start $chunk_end ${4?}
    ;;
  info|warning|error)
    itksnap-wt -dssp-tickets-log $ticket_id ${1?} "${2?}"
    ;;
  attach)
    itksnap-wt -dssp-tickets-attach $ticket_id "${2?}" "${3?}"
    ;;
esac
