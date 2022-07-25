#!/bin/bash

############################################################
############################################################
### V1.1.3 Import Blocklist Files to IPTables
### Changes
##    v0.1.0 - 2022-07-24 Initial Release
##    v0.1.1 - 2022-07-24 minor aesthetic changes
##		Removed header information from this file and added to README
##		Added $CHAINNAME to success email
##		Reformatted failure email
##    v0.1.2 - 2022-07-24 Override files change
##		Changed the way overrides are processed if the file doesn't exist.
##    v0.1.3 - 2022-07-25 Changed logfile location
##
############################################################
############################################################

START_FROM_SCRATCH=false
DELETE_ALL_FILES_ON_COMPLETION=true


## Basic Settings
DOWNLOAD_FILE="http://lists.blocklist.de/lists/all.txt"  # The text file that contains all the IPs to use
CHAINNAME="blocklist-de"                                 # The Chain name to import the IPs into
ACTION="REJECT" # Can be DROP or REJECT                  # The action to assign to the IPs for this Chain


## Base defaults - Set the base path and filename here
PathOfScript="$(dirname "$(realpath "$0")")/"
BASE_PATH="$PathOfScript"                                # The base path for all files
BLOCKLIST_BASE_FILE="ip-blocklist"                       # The base filename for all files related to the blocklist


## E-Mail variables
SENDER_NAME="Notifications"                              # Display name for the sending email address
SENDER_EMAIL="notifications@$(hostname -f)"              # Sending email address ('hostname -f' puts the FQDN)
RECIPIENT_EMAIL="servers@$(hostname -d)"                 # Comma separated recipient addresses ('hostname -d' puts domain name)
SUBJECT="$(hostname -f) - IP blocklist update - "        # Subject start for the email.


## Permanent Files
OVERRIDE_ALLOWLIST_PATH=$BASE_PATH                       # Path for the override allow-list (default is the same as the base path)
OVERRIDE_ALLOWLIST_FILE="override-allowlist.txt"         # Override allow-list filename
OVERRIDE_BLOCKLIST_PATH=$BASE_PATH                       # Path for the override block-list (default is the same as the base path)
OVERRIDE_BLOCKLIST_FILE="override-blocklist.txt"         # Override block-list filename
LOGFILE_PATH="/var/log/aubs-blocklist-importer/"         # Path for the log file.  Should not contain the filename.
LOGFILE_FILE="blocklist.log"                             # Filename for the logging.


## Programs used - If needed, set these manually to the required path (e.g. IPTABLES_PATH="/sbin/iptables")
IPTABLES_PATH="$(which iptables)"
IPSET_PATH="$(which ipset)"
SORT_PATH="$(which sort)"
SENDMAIL_PATH="$(which sendmail)"
GREP_PATH="$(which grep)"
WGET_PATH="$(which wget)"
PERL_PATH="$(which perl)"


##################################################
##################################################
########## NOTHING TO EDIT BEYOND HERE. ##########
##################################################
##################################################

TIME_START=$(date +"%s")

## Set the file locations
LOGFILE_LOCATION=$LOGFILE_PATH$LOGFILE_FILE
OVERRIDE_ALLOWLIST=$OVERRIDE_ALLOWLIST_PATH$OVERRIDE_ALLOWLIST_FILE
OVERRIDE_BLOCKLIST=$OVERRIDE_BLOCKLIST_PATH$OVERRIDE_BLOCKLIST_FILE

# Base file path including the file name, to be used for the temporary files
BLOCKLIST_BASE_FILEPATH=$BASE_PATH$BLOCKLIST_BASE_FILE

# Temporary files created based on the base file.  All related files will be created in the same location
BLOCKLIST_FILE=$BLOCKLIST_BASE_FILEPATH.download                     # Main file that the download list is imported into and processed
BLOCKLIST_EXISTING=$BLOCKLIST_BASE_FILEPATH.existing                 # List of existing IPs from the current IP chain
BLOCKLIST_ORIGINAL=$BLOCKLIST_FILE.Original                          # Copy of the original download file
BLOCKLIST_IPV4=$BLOCKLIST_FILE.IPv4                                  # Downloaded file processed with only IPv4 addresses
BLOCKLIST_OVERRIDE_ALLOWLIST=$BLOCKLIST_FILE.OverrideAllow           # Downloaded file processed with override allow-list addresses removed
BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP=$BLOCKLIST_FILE.OverrideAllowTEMP  # Temporary override allow-list files sorted and deduped
BLOCKLIST_OVERRIDE_BLOCKLIST=$BLOCKLIST_FILE.OverrideBlock           # Downloaded file processed with override block-list addresses added
BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP=$BLOCKLIST_FILE.OverrideBlockTEMP  # Temporary override block-list files sorted and deduped
BLOCKLIST_DEDUPE=$BLOCKLIST_FILE.Dedupe                              # Downloaded file processed with duplicates removed
BLOCKLIST_COMPARE=$BLOCKLIST_FILE.compare                            # Comparison between processed download file and existing list
BLOCKLIST_COMPARE_ADD=$BLOCKLIST_FILE.compare.add                    # Items processed that aren't in the existing (to be added)
BLOCKLIST_COMPARE_REM=$BLOCKLIST_FILE.compare.rem                    # Existing items that aren't in the processed (to be removed)


## If the logfile path doesn't exist, make it, then touch the file to create it if needed
mkdir -p $LOGFILE_PATH
touch $LOGFILE_LOCATION

## Function to log to the log file and output to the screen if run manually
LogThis() {
	## USAGE: LogThis [OPTIONS] [String]
	#        -s [Start] of the multi-line
	#        -m [Middle] of the multi-line
	#        -e [End] of the multi-line
	#
	# e.g.	LogThis ""
	#		LogThis "This is a string to log"
	#		LogThis -s "This is the first part of a multi-line string to log"
	#		LogThis -m "This is the middle part of a multi-line string to log"
	#		LogThis -e "This is the end part of a multi-line string to log"

	# We could just set the response var and append to it when the next section of the script runs and output it all in one go,
	#   but doing it this way means we get something in the log even it if fails at the next step.

	## Sets the log date ready to enter at the start of a line and sets the switch to none.
	LOG_START="$(date): "
	SWITCH=""

	## Runs through the options presented to the function, 'opt' is the variable to check and can be named anything.
	#   If the value is S or M, set the SWITCH to to no-new-line, if it's M or E, clear the date from LOG_START.
	#   If the value is S or there's no option, LOG_START contains the date.
	local OPTIND o # declare as local so it clears every run
	while getopts "sme" opt; do
		case $opt in
			s)
				SWITCH="-n "
				;;
			m)
				SWITCH="-n "
				LOG_START=""
				;;
			e)
				LOG_START=""
				;;
		esac
	done
	shift $((OPTIND-1))
	echo ${SWITCH} "$LOG_START $(printf "$1")" >> "$LOGFILE_LOCATION"
	echo ${SWITCH} "$LOG_START $(printf "$1")"
}


## Function to send an email
SendEmailNow()
{
	SUBJECT=$1
	BODY=$2
	$SENDMAIL_PATH -F $SENDER_NAME -f $SENDER_EMAIL -it <<-END_MESSAGE
		To: $RECIPIENT_EMAIL
		Subject: $SUBJECT
		Content-Type: text/html
		MIME-Version: 1.0
		$BODY
		END_MESSAGE
}


## Function to delete all files relating to the 'base' file name in the 'base' path
DeleteAllFiles()
{
	## Delete existing blocklist files (if any)
	LogThis "Deleting any existing blocklist files. ($BLOCKLIST_BASE_FILEPATH.*)"
	rm -f "$BLOCKLIST_BASE_FILEPATH".*
}


LogThis "================================================================================"
LogThis ""

## Check that the base path is correctly set up, otherwise we might run into issues
if [ "$BASE_PATH" != "" ] && [ "${BASE_PATH:0:1}" == "/" ] && [ -d "$BASE_PATH" ]; then LogThis "Using Base Path [ $BASE_PATH ]"; fi;

## Check the commands used are valid, otherwise we might run into ussues
if [ `command -v $IPTABLES_PATH` == "" ]; then LogThis "Cannot find [ $IPTABLES_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $IPSET_PATH` == "" ]; then LogThis "Cannot find [ $IPSET_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $SORT_PATH` == "" ]; then LogThis "Cannot find [ $SORT_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $SENDMAIL_PATH` == "" ]; then LogThis "Cannot find [ $SENDMAIL_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $GREP_PATH` == "" ]; then LogThis "Cannot find [ $GREP_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $WGET_PATH` == "" ]; then LogThis "Cannot find [ $WGET_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [ `command -v $PERL_PATH` == "" ]; then LogThis "Cannot find [ $PERL_PATH ]. Is it installed? Exiting"; exit 1; fi;

## ========== ========== ========== ========== ========== ##

# Before running anything, delete all previously used blocklist files if any exist
DeleteAllFiles

## ========== ========== ========== ========== ========== ##

LogThis -s "Downloading the most recent IP list from $DOWNLOAD_FILE..."
wgetOK=$($WGET_PATH -qO - $DOWNLOAD_FILE > $BLOCKLIST_FILE) 2>&1
if [ $? -ne 0 ]
then
	BodyResponse="IP blocklist could not be downloaded from '$DOWNLOAD_FILE' - The script calling this function: $0"
	LogThis -e " $BodyResponse"
	## Send warning e-mail and exit
	SUBJECT+="ERROR - Failed to download the new IP set"
	BODY="
		<html>
			<head></head>
			<body>
				<b>IP Blocklist script update FAILED:</b>
				<br/><br/>
				<table>
					<tr><td>URL</td><td>$BodyResponse</td></tr>
					<tr><td>Chain Name</td><td>$CHAINNAME</td></tr>
					<tr><td>Date</td><td>$(date "+%F %T (%Z)")</td></tr>
					<tr><td>Server</td><td>`uname -a`</td></tr>
				</table>
				
			</body>
		</html>
	"
	SendEmailNow "$SUBJECT" "$BODY"
	exit 1
else
	## Download didn't fail, so should be successful
	LogThis -e "Successful [$(wc -l < $BLOCKLIST_FILE)]"
fi

## Take a copy of the original download
cp -f $BLOCKLIST_FILE $BLOCKLIST_ORIGINAL


## ========== ========== ========== ========== ========== ##

LogThis ""
LogThis -s "Filter out anything not an IPv4 address"
## blocklist.de does not provide IPv6 and sometimes contains malformed information, only keep IPv4 addresses
$GREP_PATH -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" $BLOCKLIST_FILE > ${BLOCKLIST_IPV4}

## Copy the IPv4 list to the main file
cp -f $BLOCKLIST_IPV4 $BLOCKLIST_FILE

LogThis -e "[$(wc -l < $BLOCKLIST_FILE)]"

## ========== ========== ========== ========== ========== ##

LogThis -s "Removing duplicate IPs."
$SORT_PATH -u $BLOCKLIST_FILE -o $BLOCKLIST_DEDUPE 2>&1

## Copy the dedupe output to the main file
cp -f $BLOCKLIST_DEDUPE $BLOCKLIST_FILE

LogThis -e "[$(wc -l < $BLOCKLIST_FILE)]"


## ========== ========== ========== ========== ========== ##

if [ ! -r $OVERRIDE_ALLOWLIST ]
then
	LogThis -s "Override allow-list file doesn't exist.  Creating it..."
	#Because the OVERRIDE_ALLOWLIST file doesn't exist, we need to create it and add the header info
	echo -e "# Add IP addresses to this list, one on each line, to make sure they are never blocked" >> $OVERRIDE_ALLOWLIST
	if [ -r $OVERRIDE_ALLOWLIST ]
	then
		LogThis -e "Done"
	else
		LogThis -e "Failed"
		exit 1
	fi
fi

LogThis -s "Removing Override allow-list IPs..."

## Sort the Override allow-list IPs in a temp file, removing any duplicates
$SORT_PATH -u $OVERRIDE_ALLOWLIST -o $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP

## Remove lines that begin with a letter (a-z or A-Z) or # comments
sed -i '/^[a-z,A-Z,\#\]/d' $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP
## Remove blank lines
sed -i '/^$/d' $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP

LogThis -m "($(wc -l < $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP) unique)"

## Use COMM to filter the items:
# -1 = exclude column 1 (lines unique to FILE1)
# -2 = exclude column 2 (lines unique to FILE2)
# -3 = exclude column 3 (lines that appear in both files)
# Include only lines unique to FILE1 [exclude anything that is in the override allow-list]
comm -23 $BLOCKLIST_FILE $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP >> $BLOCKLIST_OVERRIDE_ALLOWLIST

## Copy the override allow-list cleaned output to the main file
cp -f $BLOCKLIST_OVERRIDE_ALLOWLIST $BLOCKLIST_FILE

LogThis -e "[$(wc -l < $BLOCKLIST_FILE)]"

## ========== ========== ========== ========== ========== ##

if [ ! -r $OVERRIDE_BLOCKLIST ]
then
	LogThis -s "Override block-list file doesn't exist.  Creating it..."
	#Because the OVERRIDE_BLOCKLIST file doesn't exist, we need to create it and add the header info
	touch $OVERRIDE_BLOCKLIST
	echo -e "# Add IP addresses to this list, one on each line, to make sure they are always blocked and never allowed" >> $OVERRIDE_BLOCKLIST
	if [ -r $OVERRIDE_BLOCKLIST ]
	then
		LogThis -e "Done"
	else
		LogThis -e "Failed"
		exit 1
	fi
fi

LogThis -s "Adding Override block-list IPs... "

## Sort the Override block-list IPs in a temp file, removing any duplicates
$SORT_PATH -u $OVERRIDE_BLOCKLIST -o $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP

## Remove lines that begin with a letter (a-z or A-Z) or # comments
sed -i '/^[a-z,A-Z,\#\]/d' $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP
## Remove blank lines
sed -i '/^$/d' $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP

LogThis -m "($(wc -l < $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP) unique)"

## Merge the blocklist file with the override block-list, removing duplicates
$SORT_PATH -u $BLOCKLIST_FILE $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP -o $BLOCKLIST_OVERRIDE_BLOCKLIST

## Copy the override block-list cleaned output to the main file
cp -f $BLOCKLIST_OVERRIDE_BLOCKLIST $BLOCKLIST_FILE

LogThis -e "[$(wc -l < $BLOCKLIST_FILE)]"

## ========== ========== ========== ========== ========== ##

## The START_FROM_SCRATCH variable dermines if the CHAINNAME should be deleted from IPTable and IPSet before proceeding
if [ "$START_FROM_SCRATCH" = true ]
then
	LogThis ""
	LogThis "Start-From-Scratch set.  Resetting IPTable and IPSet for '$CHAINNAME'..."

	if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -gt 0 ]; 
		then sudo $IPTABLES_PATH --flush $CHAINNAME 2>&1; LogThis "    Flushed IPTable Chain"; 
		else LogThis "    No IPTable Chain to flush"; fi
	if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -gt 0 ]; 
		then sudo $IPSET_PATH flush $CHAINNAME 2>&1; LogThis "    Flushed IPSet Chain"; 
		else LogThis "    No IPSet Chain to flush"; fi;
	if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -gt 0 ]; 
		then sudo $IPSET_PATH destroy $CHAINNAME 2>&1; LogThis "    Destroyed IPSet Chain"; 
		else LogThis "    No IPSet to destroy"; fi;
	if [ `$IPTABLES_PATH -L INPUT | $GREP_PATH $CHAINNAME | wc -l` -gt 0 ]; 
		then sudo $IPTABLES_PATH -D INPUT -j $CHAINNAME; LogThis "    Deleted IPTable INPUT Join"; 
		else LogThis "    No IPTable INPUT Join to delete"; fi;
	if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -gt 0 ]; 
		then sudo $IPTABLES_PATH -X $CHAINNAME; LogThis "    Deleted IPTable Chain"; 
		else LogThis "    No IPTable Chain to delete"; fi;
fi

## ========== ========== ========== ========== ========== ##

LogThis ""
LogThis -s "Checking the IPSet configuration for the '$CHAINNAME' IP set..."
if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -eq 0 ]
then
	# Create the new IPSET set
	$IPSET_PATH create $CHAINNAME hash:ip maxelem 16777216 2>&1
	LogThis -e " New IP set created"
else
	### An IPSET set already exists.
	LogThis -e " IP set already exists"
fi

## ========== ========== ========== ========== ========== ##

LogThis -s "Checking the IPTables configuration for the '$CHAINNAME' chain..."
if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -eq 0 ]
then
	# Create the iptables chain
	$IPTABLES_PATH --new-chain $CHAINNAME 2>&1
	LogThis -e " New chain created"
else
	### An IPTABLES chain already exists.
	LogThis -e " Chain already exists"
fi

## ========== ========== ========== ========== ========== ##

LogThis -s "Checking the chain '$CHAINNAME' exists in the IPTables INPUT..."
# Insert rule (if necesarry) into the INPUT chain so the chain above will also be used
if [ `$IPTABLES_PATH -L INPUT | $GREP_PATH $CHAINNAME | wc -l` -eq 0 ]
then
	# Insert the chain into the INPUT
	$IPTABLES_PATH -I INPUT -j $CHAINNAME 2>&1
	LogThis -e " Chain added to INPUT"
else
	### The chain already exsits in the IPTables INPUT
	LogThis -e " Chain already in INPUT"
fi

## ========== ========== ========== ========== ========== ##

LogThis -s "Checking a firewall rule exists in the '$CHAINNAME' chain..."
if [ `$IPTABLES_PATH -L $CHAINNAME | $GREP_PATH $ACTION | wc -l` -eq 0 ]
then
	# Create the one and only firewall rule
	$IPTABLES_PATH -I $CHAINNAME -m set --match-set $CHAINNAME src -j $ACTION 2>&1
	LogThis -e " Firewall rule created"
else
	### The firewall rule already exsits in the chain.
	LogThis -e " Firewall rule already exists in the chain"
fi

## ========== ========== ========== ========== ========== ##

LogThis ""
LogThis "Getting the existing list for the '$CHAINNAME' IP set"

## Get the existing list of blacklisted IPs
$IPSET_PATH list $CHAINNAME >> $BLOCKLIST_EXISTING

## Remove lines that begin with a letter (a-z or A-Z) - the first 8 lines - from the existing list
sed -i '/^[a-z,A-Z]/d' $BLOCKLIST_EXISTING
## Remove blank lines
sed -i '/^$/d' $BLOCKLIST_EXISTING

## Sort the Existing list (the new list has already been sorted)
$SORT_PATH -u $BLOCKLIST_EXISTING -o $BLOCKLIST_EXISTING

LogThis ""
LogThis "Comparing the New and Existing lists..."

## Use COMM to filter the items:
# -1 = exclude column 1 (lines unique to FILE1)
# -2 = exclude column 2 (lines unique to FILE2)
# -3 = exclude column 3 (lines that appear in both files)
## Include only lines unique to FILE1 [new items to add]
comm -23 $BLOCKLIST_FILE $BLOCKLIST_EXISTING >> $BLOCKLIST_COMPARE_ADD
## Include only lines unique to FILE2 [old items to remove]
comm -13 $BLOCKLIST_FILE $BLOCKLIST_EXISTING >> $BLOCKLIST_COMPARE_REM


## Read all IPs from the ADD list and add them to the ipset filter
LogThis -s "Adding [$(wc -l < $BLOCKLIST_COMPARE_ADD)] new IPs into the IP set..."
for i in $( cat $BLOCKLIST_COMPARE_ADD ); do $IPSET_PATH add $CHAINNAME $i 2>&1; done
LogThis -e "Done"

## Read all IPs from the REM list remove them from the ipset filter
LogThis -s "Removing [$(wc -l < $BLOCKLIST_COMPARE_REM)] old IPs from the IP set..."
for i in $( cat $BLOCKLIST_COMPARE_REM ); do $IPSET_PATH del $CHAINNAME $i 2>&1; done
LogThis -e "Done"

## ========== ========== ========== ========== ========== ##

TIME_DIFF=$(($(date +"%s")-${TIME_START}))
LogThis "Process finished in $((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds."


SUBJECT+="SUCCESS - Updated with the newest IP list"
BODY="
<html>
	<head></head>
	<body>
		<b>IP Blocklist script updated the IP set with the newest IP list:</b>
		<br/><br/>
		<table>
			<tr><td>Start From Scratch</td><td>$START_FROM_SCRATCH</td></tr>
			<tr><td>Chain Name</td><td>$CHAINNAME</td></tr>
			<tr><td>Originally Loaded</td><td>$(wc -l < $BLOCKLIST_EXISTING)</td></tr>
			<tr><td>Downloaded</td><td>$(wc -l < $BLOCKLIST_ORIGINAL)</td></tr>
			<tr><td>Override Allow (original)</td><td>$(wc -l < $OVERRIDE_ALLOWLIST)</td></tr>
			<tr><td>Override Allow (unique)</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP)</td></tr>
			<tr><td>Override Block (original)</td><td>$(wc -l < $OVERRIDE_BLOCKLIST)</td></tr>
			<tr><td>Override Block (unique)</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP)</td></tr>
			<tr><td><b>PROCESSING</b></td><td>&nbsp;</td></tr>
			<tr><td>IPv4 count</td><td>$(wc -l < $BLOCKLIST_IPV4)</td></tr>
			<tr><td>Deduped</td><td>$(wc -l < $BLOCKLIST_DEDUPE)</td></tr>
			<tr><td>Override Allow Cleared</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_ALLOWLIST)</td></tr>
			<tr><td>Override Block Cleared</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_BLOCKLIST)</td></tr>
			<tr><td>Added</td><td>$(wc -l < $BLOCKLIST_COMPARE_ADD)</td></tr>
			<tr><td>Removed</td><td>$(wc -l < $BLOCKLIST_COMPARE_REM)</td></tr>
			<tr><td>Duration</td><td>$((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds.</td></tr>
			<tr><td>Date</td><td>$(date "+%F %T (%Z)")</td></tr>
			<tr><td>Server</td><td>`uname -a`</td></tr>
		</table>
	</body>
</html>
"
SendEmailNow "$SUBJECT" "$BODY"

## If DELETE_ALL_FILES_ON_COMPLETION is set, delete all files on completion.
if [ $DELETE_ALL_FILES_ON_COMPLETION = true ]
then
	DeleteAllFiles
fi

LogThis ""
LogThis "================================================================================"
