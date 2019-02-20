#!/bin/bash
set -x -e

# =====================================
# = Script to run ASHS for DSS ticket =
# =====================================

# Create a temporary directory for this process
if [[ ! $TMPDIR ]]; then
  TMPDIR=$(mktemp -d /tmp/ashs_daemon.XXXXXX) || exit 1
fi


# This function uploads the logs from ASHS to the server
function upload_logs()
{
  local ticket_id=${1?}
  local workdir=${2?}
  local tarball=$TMPDIR/ashs_ticket_$(printf %08d $ticket_id).tgz
  tar -czvf $tarball $workdir/dump/*

  if [[ -d $workdir/dump ]]; then
    itksnap-wt -dssp-tickets-attach $ticket_id "ASHS logs" $tarball "application/x-tgz"
    itksnap-wt -dssp-tickets-log info "ASHS execution logs uploaded"
  fi
}

# This function sends an error message to the server
function fail_ticket()
{
  local ticket_id=${1?}
  local message=${2?}

  itksnap-wt -dssp-tickets-fail $ticket_id "$message"
  exit -1
}

# Read the command-line arguments
unset ASHS_ROOT ASHS_ATLAS TICKET_ID SERVER WORKDIR_BASE TOKEN
while getopts "r:a:t:s:w:k:" opt; do

  case $opt in

    r) ASHS_ROOT=$OPTARG;;
    a) ASHS_ATLAS=$OPTARG;;
    t) TICKET_ID=$OPTARG;;
    s) SERVER=$OPTARG;;
    w) WORKDIR_BASE=$OPTARG;;
    k) TOKEN=$OPTARG;;

  esac
done

# Set the working directory
WORKDIR=$WORKDIR_BASE/$(printf ticket_%08d $TICKET_ID)

# Set the path
PATH=$ASHS_ROOT/ext/Linux/bin:$PATH

# Login with provided token
if [[ $SERVER && $TOKEN ]]; then
  itksnap-wt -dss-auth $SERVER <<< $TOKEN
fi

# If unable to login, exit
if [[ $? -ne 0 ]]; then
  echo "Failed to login"
  exit -1
fi

# Notify ticket that we started processing (because we may be rerunning)
itksnap-wt \
  -dssp-tickets-log $TICKET_ID info "Starting ticket processing in container $(hostname)" \
  -dssp-tickets-set-progress $TICKET_ID 0 1 0

if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to update ticket properties"
fi

# Download the ticket
itksnap-wt -dssp-tickets-download $TICKET_ID $WORKDIR > $TMPDIR/download.txt

# If the download failed we mark the ticket as failed
if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to download the ticket after 1 attempts"
fi

# Find the workspace file in the download
WSFILE=$(cat $TMPDIR/download.txt | grep '^1>.*itksnap$' | sed -e "s/^1> //")
itksnap-wt -i $WSFILE -ll

# Get the layer tagged T1
T1_FILE=$(itksnap-wt -P -i $WSFILE -llf T1-MRI)
if [[ $(echo $T1_FILE | wc -w) -ne 1 || ! -f $T1_FILE ]]; then
  fail_ticket $TICKET_ID "Missing tag 'T1-MRI' in ticket workspace"
fi

# Get the layer tagged T2
T2_FILE=$(itksnap-wt -P -i $WSFILE -llf T2-MRI)
if [[ $(echo $T2_FILE | wc -w) -ne 1 || ! -f $T2_FILE ]]; then
  fail_ticket $TICKET_ID "Missing tag 'T2-MRI' in ticket workspace"
fi

# Provide callback info for ASHS to update progress and send log messages
export ASHS_ROOT
export ASHS_HOOK_SCRIPT=$(dirname $(readlink -m $0))/ashs_alfabis_hook.sh
export ASHS_HOOK_DATA=$TICKET_ID

# The 8-digit ticket id string
IDSTRING=$(printf %08d $TICKET_ID)

# Ready to roll!
$ASHS_ROOT/bin/ashs_main.sh \
  -a $ASHS_ATLAS \
  -g $T1_FILE -f $T2_FILE \
  -w $WORKDIR/ashs \
  -I $IDSTRING \
  -H -P 

# Return code
ASHS_RC=$?

# Upload the logs
upload_logs $TICKET_ID $WORKDIR/ashs

# Check the error code
if [[ $ASHS_RC -ne 0 ]]; then
  # TODO: we need to supply some debugging information, this is not enough
  # ASHS crashed - report the error
  upload_logs $TICKET_ID $WORKDIR/ashs
  fail_ticket $TICKET_ID "ASHS execution failed"
fi

# TODO: package up the results into a mergeable workspace (?)
for what in heur corr_usegray corr_nogray; do
  $ASHS_ROOT/ext/$(uname)/bin/c3d \
    $WORKDIR/ashs/final/${IDSTRING}_left_lfseg_${what}.nii.gz \
    $WORKDIR/ashs/final/${IDSTRING}_right_lfseg_${what}.nii.gz \
    -shift 100 -replace 100 0 -add \
    -o $WORKDIR/${IDSTRING}_lfseg_${what}.nii.gz
done

# Create a new workspace
itksnap-wt -i $WSFILE \
  -las $WORKDIR/${IDSTRING}_lfseg_corr_usegray.nii.gz -psn "JLF/CL result" \
  -las $WORKDIR/${IDSTRING}_lfseg_corr_nogray.nii.gz -psn "JLF/CL-lite result" \
  -las $WORKDIR/${IDSTRING}_lfseg_heur.nii.gz -psn "JLF result" \
  -labels-clear \
  -labels-add $ASHS_ATLAS/snap/snaplabels.txt 0 "Left %s" \
  -labels-add $ASHS_ATLAS/snap/snaplabels.txt 100 "Right %s" \
  -o $WORKDIR/${IDSTRING}_results.itksnap \
  -dssp-tickets-upload $TICKET_ID 

if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to upload ticket"
fi

# Set the log (ticket uploaded)
itksnap-wt -dssp-tickets-log $TICKET_ID info "Uploaded result workspace"

# Set the result to success
itksnap-wt -dssp-tickets-success $TICKET_ID
