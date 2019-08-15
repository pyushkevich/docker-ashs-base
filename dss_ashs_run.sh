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
    itksnap-wt -dssp-tickets-attach $ticket_id "ASHS execution log" $html "text/html"
    itksnap-wt -dssp-tickets-log $ticket_id info "ASHS execution logs uploaded"
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

# Provide callback info for ASHS to update progress and send log messages
export ASHS_ROOT
export ASHS_HOOK_SCRIPT=$(dirname $(readlink -m $0))/ashs_alfabis_hook.sh
export ASHS_HOOK_DATA=$TICKET_ID

# The 8-digit ticket id string
IDSTRING=$(printf %08d $TICKET_ID)

# Check the resolution of the T1w MRI
# if the resolution of LR and UI directions are smaller than 0.7, skip the SR stage
DIM=($(c3d $T1_FILE -swapdim RPI -info-full | grep 'Spacing' | sed -e "s/.*\[//g" -e "s/,/ /g" -e "s/\].*//g"))
DIMX=${DIM[0]}
DIMY=${DIM[1]}
DIMZ=${DIM[2]}
echo "Image Dimensions: $DIMX, $DIMY, $DIMZ"

if [[ $(echo "$DIMX <= 0.7 && $DIMZ <= 0.7" | bc) == 1 ]]; then
  ASHS_CONFIG=ashs_user_config_noSR.sh
else
  ASHS_CONFIG=ashs_user_config.sh
fi


# Ready to roll!
$ASHS_ROOT/bin/ashs_main.sh \
  -a $ASHS_ATLAS \
  -C $ASHS_ATLAS/$ASHS_CONFIG \
  -g $T1_FILE -f $T1_FILE \
  -w $WORKDIR/ashs \
  -I $IDSTRING \
  -H -P \
	-m identity.mat -M

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

if [[ $(echo "$DIMX <= 0.7 && $DIMZ <= 0.7" | bc) == 1 ]]; then

  itksnap-wt -i $WSFILE \
    -layers-set-main $T1_FILE -psn "Original T1 scan" \
    -las $WORKDIR/${IDSTRING}_lfseg_heur.nii.gz -psn "JLF result" \
    -labels-clear \
    -labels-add $ASHS_ATLAS/snap/snaplabels.txt 0 "Left %s" \
    -labels-add $ASHS_ATLAS/snap/snaplabels.txt 100 "Right %s" \
		-o $WORKDIR/${IDSTRING}_results.itksnap \
		-dssp-tickets-upload $TICKET_ID 

else

  itksnap-wt -i $WSFILE \
    -layers-set-main $WORKDIR/ashs/tse.nii.gz -psn "Super-resolution upsampled T1 scan" \
    -layers-add-anat $T1_FILE -psn "Original T1 scan" \
    -las $WORKDIR/${IDSTRING}_lfseg_heur.nii.gz -psn "JLF result" \
    -labels-clear \
    -labels-add $ASHS_ATLAS/snap/snaplabels.txt 0 "Left %s" \
    -labels-add $ASHS_ATLAS/snap/snaplabels.txt 100 "Right %s" \
		-o $WORKDIR/${IDSTRING}_results.itksnap \
		-dssp-tickets-upload $TICKET_ID 

fi

if [[ $? -ne 0 ]]; then
  fail_ticket $TICKET_ID "Failed to upload ticket"
fi

# Set the log (ticket uploaded)
itksnap-wt -dssp-tickets-log $TICKET_ID info "Uploaded result workspace"

# Set the result to success
itksnap-wt -dssp-tickets-success $TICKET_ID
