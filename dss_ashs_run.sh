#!/bin/bash
# vim: set ts=2 sw=2 expandtab :
set -x

# =====================================
# = Script to run ASHS for DSS ticket =
# =====================================

# Create a temporary directory for this process
if [[ ! $TMPDIR ]]; then
  TMPDIR=$(mktemp -d /tmp/ashs_daemon.XXXXXX) || exit -1
fi

# This function uploads the logs from ASHS to the server
function upload_logs()
{
  local ticket_id=${1?}
  local workdir=${2?}
  local product=${3?}
  local html=$TMPDIR/ashs_ticket_$(printf %08d $ticket_id).html

  if [[ -d $workdir/dump ]]; then

  # Generate the file
  cat > $html <<-HTMLHEAD
		<!doctype html>
		<html lang="en">
		<head>
		  <meta charset="utf-8">
		  <title>ASHS log for ticket $ticket_id</title>
		</head>
		<body>
		<h1>ASHS log for ticket $ticket_id</h1>
		HTMLHEAD

    for fn in $(ls $workdir/dump); do
      echo "<h2>$fn</h2>"
      echo "<code>"
      cat $workdir/dump/$fn
      echo "</code>"
    done >> $html

    # Upload the log
    itksnap-wt -dssp-tickets-attach $ticket_id "${product} execution log" $html "text/html"
    itksnap-wt -dssp-tickets-log $ticket_id info "${product} execution logs uploaded"
  fi
}

# This function sends an error message to the server. The job itself exits with a 
# zero return code, so that Kube does not try scheduling it again
function fail_ticket()
{
  local ticket_id=${1?}
  local message=${2?}

  itksnap-wt -dssp-tickets-fail $ticket_id "$message"
  exit 0
}

# Read the command-line arguments
unset ASHS_ROOT ASHS_ATLAS TICKET_ID SERVER WORKDIR_BASE TOKEN ICV_ATLAS
TAG_T1="T1-MRI"
TAG_T2="T2-MRI"
SHIFT_LEFT=0
SHIFT_RIGHT=100
SHIFT_ICV=200
while getopts "r:a:t:s:w:k:I:g:f:R:L:J:" opt; do

  case $opt in

    r) ASHS_ROOT=$OPTARG;;
    a) ASHS_ATLAS=$OPTARG;;
    t) TICKET_ID=$OPTARG;;
    s) SERVER=$OPTARG;;
    w) WORKDIR_BASE=$OPTARG;;
    k) TOKEN=$OPTARG;;
    I) ICV_ATLAS=$OPTARG;;
    g) TAG_T1=$OPTARG;;
    f) TAG_T2=$OPTARG;;
    R) SHIFT_LEFT=$OPTARG;;
    L) SHIFT_RIGHT=$OPTARG;;
    J) SHIFT_ICV=$OPTARG;;

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
T1_FILE=$(itksnap-wt -P -i $WSFILE -llf $TAG_T1)
if [[ $(echo $T1_FILE | wc -w) -ne 1 || ! -f $T1_FILE ]]; then
  fail_ticket $TICKET_ID "Missing tag '$TAG_T1' in ticket workspace"
fi

# Get the layer tagged T2
T2_FILE=$(itksnap-wt -P -i $WSFILE -llf $TAG_T2)
if [[ $(echo $T2_FILE | wc -w) -ne 1 || ! -f $T2_FILE ]]; then
  fail_ticket $TICKET_ID "Missing tag '$TAG_T2' in ticket workspace"
fi

# Provide callback info for ASHS to update progress and send log messages
export ASHS_ROOT
export ASHS_HOOK_SCRIPT=$(dirname $(readlink -m $0))/ashs_alfabis_hook.sh

# The hood data depends on whether we are doing ICV as part of the script
if [[ $ICV_ATLAS ]]; then
  export ASHS_HOOK_DATA="$TICKET_ID,ASHS,0.0,0.5"
else
  export ASHS_HOOK_DATA=$TICKET_ID
fi

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
upload_logs $TICKET_ID $WORKDIR/ashs ASHS

# Check the error code
if [[ $ASHS_RC -ne 0 ]]; then
  # TODO: we need to supply some debugging information, this is not enough
  # ASHS crashed - report the error
  fail_ticket $TICKET_ID "ASHS execution failed"
fi

# TODO: package up the results into a mergeable workspace (?)
for what in heur corr_usegray corr_nogray; do
  $ASHS_ROOT/ext/$(uname)/bin/c3d \
    $WORKDIR/ashs/final/${IDSTRING}_left_lfseg_${what}.nii.gz \
    -shift $SHIFT_LEFT -replace $SHIFT_LEFT 0 \
    $WORKDIR/ashs/final/${IDSTRING}_right_lfseg_${what}.nii.gz \
    -shift $SHIFT_RIGHT -replace $SHIFT_RIGHT 0 -add \
    -type uchar -o $WORKDIR/${IDSTRING}_lfseg_${what}.nii.gz
done

# Create a new workspace
itksnap-wt -i $WSFILE \
  -las $WORKDIR/${IDSTRING}_lfseg_corr_usegray.nii.gz -psn "JLF/CL result" \
  -las $WORKDIR/${IDSTRING}_lfseg_corr_nogray.nii.gz -psn "JLF/CL-lite result" \
  -las $WORKDIR/${IDSTRING}_lfseg_heur.nii.gz -psn "JLF result" \
  -labels-clear \
  -labels-add $ASHS_ATLAS/snap/snaplabels.txt $SHIFT_LEFT "Left %s" \
  -labels-add $ASHS_ATLAS/snap/snaplabels.txt $SHIFT_RIGHT "Right %s" \
  -o $WORKDIR/${IDSTRING}_results.itksnap

if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to create a result workspace"
fi

# If requeting ICV, perform the similar processing
if [[ $ICV_ATLAS ]]; then

  export ASHS_HOOK_DATA="$TICKET_ID,ICV,0.5,0.5"

  # Ready to roll!
  $ASHS_ROOT/bin/ashs_main.sh \
    -a $ICV_ATLAS \
    -g $T1_FILE -f $T1_FILE \
    -w $WORKDIR/ashs_icv \
    -I $IDSTRING \
    -H -P -B

  # Return code
  ASHS_RC=$?

  # Upload the logs
  upload_logs $TICKET_ID $WORKDIR/ashs_icv ASHS-ICV

  # Check the error code
  if [[ $ASHS_RC -ne 0 ]]; then
    # TODO: we need to supply some debugging information, this is not enough
    # ASHS crashed - report the error
    fail_ticket $TICKET_ID "ASHS-ICV execution failed"
  fi

  # Add the ICV image to the project
  $ASHS_ROOT/ext/$(uname)/bin/c3d \
    $WORKDIR/ashs_icv/final/${IDSTRING}_left_lfseg_corr_nogray.nii.gz \
    -shift $SHIFT_ICV -replace $SHIFT_ICV 0 \
    -type uchar -o $WORKDIR/${IDSTRING}_icv.nii.gz

  itksnap-wt -i $WORKDIR/${IDSTRING}_results.itksnap \
    -las $WORKDIR/${IDSTRING}_icv.nii.gz -psn "ICV" \
    -labels-add $ICV_ATLAS/snap/snaplabels.txt $SHIFT_ICV "%s" \
    -o $WORKDIR/${IDSTRING}_results.itksnap

  if [[ $? -ne 0 ]]; then
    fail_ticket $TICKET_ID "Failed to create a result workspace"
  fi

fi

# Upload the ticket
itksnap-wt -i $WORKDIR/${IDSTRING}_results.itksnap -dssp-tickets-upload $TICKET_ID

if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to upload ticket"
fi

# Set the log (ticket uploaded)
itksnap-wt -dssp-tickets-log $TICKET_ID info "Uploaded result workspace"

# Set the result to success
itksnap-wt -dssp-tickets-success $TICKET_ID
