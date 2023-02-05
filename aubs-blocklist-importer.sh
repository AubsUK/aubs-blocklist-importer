#!/bin/bash

############################################################
############################################################
### V0.2.0 Import Blocklist Files to IPTables
### https://github.com/AubsUK/aubs-blocklist-importer
### Changes
##	v0.1.0 - 2022-07-24 Initial Release
##	v0.1.1 - 2022-07-24 minor aesthetic changes
##			Removed header information from this file and added to README
##			Added $CHAINNAME to success email
##			Reformatted failure email
##	v0.1.2 - 2022-07-24 Override files change
##			Changed the way overrides are processed if the file doesn't exist.
##	v0.1.3 - 2022-07-25 Changed logfile location
##	v0.2.0 - 2022-07-25 Added a check to make sure it's all worked
##			After importing, check download and live lists match;
##			  If check fails, try and restore the previously loaded list, check again
##			Modified final email notification to include success/failure if restoring
##			Changed logfile name
##			Moved clear/check/create IPTables configuration
##	v0.2.1 - 2022-11-21 Fixed checking for packages used where the package doesn't exist
##	v0.2.2 - 2022-12-10 Added MIN_COUNT for the minimum count in downloaded file to prevent failed downloads
##	v0.2.3 - 2022-12-11 Added Email Success/Failure switches
##			Allows failures to be alerted without the constant bombardment of successes
##			Also allows an override to send one Success/Failure after the opposite is received, even
##			  if it shouldn't email on those days.
##
############################################################
############################################################

START_FROM_SCRATCH=false
DELETE_ALL_FILES_ON_COMPLETION=true


## Basic Settings
DOWNLOAD_FILE="http://lists.blocklist.de/lists/all.txt" 	# The text file that contains all the IPs to use


CHAINNAME="blocklist-de"							# The Chain name to import the IPs into
ACTION="REJECT" # Can be DROP or REJECT				# The action to assign to the IPs for this Chain
MIN_COUNT="100"										# If the downloaded file contains less than this number of rows, consider it failed

## Base defaults - Set the base path and filename here
PathOfScript="$(dirname "$(realpath "$0")")/"
BASE_PATH="$PathOfScript"							# The base path for all files
BLOCKLIST_BASE_FILE="ip-blocklist"					# The base filename for all files related to the blocklist


## E-Mail variables
SENDER_NAME="Notifications"							# Display name for the sending email address
SENDER_EMAIL="notifications@$(hostname -f)"			# Sending email address ('hostname -f' puts the FQDN)
RECIPIENT_EMAIL="servers@$(hostname -d)"			# Comma separated recipient addresses ('hostname -d' puts domain name)
SUBJECT="$(hostname -f) - IP blocklist update - "	# Subject start for the email.
EMAIL_SUCCESS_DAYS=1,4								# Days SUCCESS emails should be sent [1=Monday, 7=Sunday] (1,=Mon,Thu)
EMAIL_SUCCESS_TYPE="FIRST"							# When to send success emails (if run multiple times a day) [NONE, FIRST, ALL] (only on the days in SUCCESS_DAYS)
EMAIL_FAILURE_DAYS=1,2,3,4,5,6,7					# Days FAILURE emails should be sent [1=Monday, 7=Sunday] (1,3,6=Mon,Wed,Sat)
EMAIL_FAILURE_TYPE="FIRST"							# When to send failure emails (if run multiple times a day) [NONE, FIRST, ALL]
EMAIL_FAILURE_SUCCESS_OVERRIDE=true					# For multi-day runs, as long as the FAILURE_DAYS is 1-7 and FAILURE_TYPE isn't NONE, when a FAILURE
													#   is received after a SUCCESS, an email will be sent (last run=success, this run=failure).
													#   The same will happen for SUCCESS if SUCCESS_DAYS is 1-7 and SUCCESS_TYPE isn't NONE, that after a
													#   FAILURE, a SUCCESS email will be received.
													#   On the other hand, as FAILUREs will be sent, a SUCCESS might not to confirm it has been restored
													#   until the next SUCCESS_DAY when a SUCCESS can be received.  Set this to true and a FAILURE/SUCCESS
													#   email will be sent the first time the new status changes, but no other times unless scheduled.


## Permanent Files
OVERRIDE_ALLOWLIST_PATH=$BASE_PATH					# Path for the override allow-list (default is the same as the base path)
OVERRIDE_ALLOWLIST_FILE="override-allowlist.txt"	# Override allow-list filename
OVERRIDE_BLOCKLIST_PATH=$BASE_PATH					# Path for the override block-list (default is the same as the base path)
OVERRIDE_BLOCKLIST_FILE="override-blocklist.txt"	# Override block-list filename
LOGFILE_PATH="/var/log/aubs-blocklist-importer/"	# Path for the log file.  Should not contain the filename.
LOGFILE_FILE="aubs-blocklist-importer.log"			# Filename for the logging.
LAST_RUN_PATH=$BASE_PATH							# Status of the last run (includes the day number for use in email allowed days)
LAST_RUN_FILE="Last_Run_Status.txt"					# Status of the last run (includes the day number for use in email allowed days)

## Packages used - If needed, set these manually to the required path (e.g. IPTABLES_PATH="/sbin/iptables")
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
BLOCKLIST_FILE=$BLOCKLIST_BASE_FILEPATH.download							# Main file that the download list is imported into and processed
BLOCKLIST_EXISTING=$BLOCKLIST_BASE_FILEPATH.existing						# List of existing IPs from the current IP chain
BLOCKLIST_EXISTING_CHECK1=$BLOCKLIST_BASE_FILEPATH.existing.check1			# List of IPs to confirm successful import
BLOCKLIST_EXISTING_VALIDATE1=$BLOCKLIST_BASE_FILEPATH.existing.validate1	# List of IPs remaining after checking
BLOCKLIST_EXISTING_CHECK2=$BLOCKLIST_BASE_FILEPATH.existing.check2			# List of IPs to confirm successful import
BLOCKLIST_EXISTING_VALIDATE2=$BLOCKLIST_BASE_FILEPATH.existing.validate2	# List of IPs remaining after checking
BLOCKLIST_ORIGINAL=$BLOCKLIST_FILE.Original									# Copy of the original download file
BLOCKLIST_IPV4=$BLOCKLIST_FILE.IPv4											# Downloaded file processed with only IPv4 addresses
BLOCKLIST_OVERRIDE_ALLOWLIST=$BLOCKLIST_FILE.OverrideAllow					# Downloaded file processed with override allow-list addresses removed
BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP=$BLOCKLIST_FILE.OverrideAllowTEMP			# Temporary override allow-list files sorted and deduped
BLOCKLIST_OVERRIDE_BLOCKLIST=$BLOCKLIST_FILE.OverrideBlock					# Downloaded file processed with override block-list addresses added
BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP=$BLOCKLIST_FILE.OverrideBlockTEMP			# Temporary override block-list files sorted and deduped
BLOCKLIST_DEDUPE=$BLOCKLIST_FILE.Dedupe										# Downloaded file processed with duplicates removed
BLOCKLIST_COMPARE=$BLOCKLIST_FILE.compare									# Comparison between processed download file and existing list
BLOCKLIST_COMPARE_ADD=$BLOCKLIST_FILE.compare.add							# Items processed that aren't in the existing (to be added)
BLOCKLIST_COMPARE_REM=$BLOCKLIST_FILE.compare.rem							# Existing items that aren't in the processed (to be removed)
LAST_RUN_STATUS=$LAST_RUN_PATH$LAST_RUN_FILE								# Last run file, contains SUCCESS or FAILURE and a number for the day last run

## If the logfile path doesn't exist, make it, then touch the file to create it if needed
mkdir -p $LOGFILE_PATH
touch $LOGFILE_LOCATION

#If the last run status path doesn't exist, make it, then touch the file to create it if needed
mkdir -p $LAST_RUN_PATH
touch $LAST_RUN_STATUS


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
	SEND_TODAY=true
	CURRENT_STATUS=$1
	SUBJECT=$2
	BODY=$3

	DOW=$(date +%u)
	DOW=$(($DOW-0))

#CURRENT_STATUS="SUCCESS"

	LAST_STATUS_READ="`head -1 $LAST_RUN_STATUS`"
	if [ $LAST_STATUS_READ ]
	then
		LAST_DAY="${LAST_STATUS_READ:7}"
		LAST_STATUS="${LAST_STATUS_READ::-1}"
	fi
#Overwrite the LAST_RUN_STATUS file
	LogThis "Writing last status of [$CURRENT_STATUS$DOW] to $LAST_RUN_STATUS"
	echo "$CURRENT_STATUS$DOW" > $LAST_RUN_STATUS

echo "CURRENT_STATUS: $CURRENT_STATUS"
echo "EMAIL_SUCCESS_DAYS: $EMAIL_SUCCESS_DAYS"
echo "EMAIL_SUCCESS_TYPE: $EMAIL_SUCCESS_TYPE"
echo "EMAIL_FAILURE_DAYS: $EMAIL_FAILURE_DAYS"
echo "EMAIL_FAILURE_TYPE: $EMAIL_FAILURE_TYPE"
echo "LAST_DAY: $LAST_DAY"
echo "LAST_STATUS: $LAST_STATUS"
echo "EMAIL_FAILURE_SUCCESS_OVERRIDE: $EMAIL_FAILURE_SUCCESS_OVERRIDE"

echo "----------"
if [[ $EMAIL_FAILURE_DAYS == *$DOW* ]]; then echo "EMAIL_FAILURE_DAYS matches today"; else echo "EMAIL_FAILURE_DAYS NOT matches today"; fi
if [[ "$EMAIL_FAILURE_TYPE" == "ALL" ]]; then echo "EMAIL_FAILURE_TYPE matches ALL"; else echo "EMAIL_FAILURE_TYPE NOT matches ALL"; fi
if [[ $LAST_DAY -ne $DOW ]]; then echo "LAST_DAY NOT matches current day"; else echo "LAST_DAY matches current day"; fi
if [[ "$EMAIL_FAILURE_TYPE" == "FIRST" ]]; then echo "EMAIL_FAILURE_TYPE matches FIRST"; else echo "EMAIL_FAILURE_TYPE NOT matches FIRST"; fi
if [[ "$LAST_STATUS" == "SUCCESS" ]]; then echo "LAST_STATUS matches SUCCESS"; else echo "LAST_STATUS NOT matches SUCCESS"; fi
if [[ "$EMAIL_FAILURE_SUCCESS_OVERRIDE" == true ]]; then echo "EMAIL_FAILURE_SUCCESS_OVERIDE matches TRUE"; else echo "EMAIL_FAILURE_SUCCESS_OVERIDE NOT matches TRUE "; fi
echo "----------"


	if [ $CURRENT_STATUS == "SUCCESS" ]
	then
		echo "Success"
		# If today is one of the success days AND
		#   If TYPE is ALL
		#     OR
		#   If the last run day is not today and Type is FIRST
		#   OR
		# LAST_STATUS was failure, now success, and override is true

		if [[ ( ( $EMAIL_SUCCESS_DAYS == *$DOW* ) && ( ( "$EMAIL_SUCCESS_TYPE" == "ALL" ) || ( $LAST_DAY -ne $DOW && "$EMAIL_SUCCESS_TYPE" == "FIRST" ) ) ) || ( ( "$LAST_STATUS" == "FAILURE" && "$EMAIL_FAILURE_SUCCESS_OVERRIDE" == true ) ) ]]
		then :
		else
			echo "NOT sending success email"
			SEND_TODAY=false
		fi
	else
		echo "Failure"
		# If today is one of the failure days AND
		#   If TYPE is ALL
		#     OR
		#   If the last run day is not today and Type is FIRST
		#     OR
		#   LAST_STATUS was success, now failure, and override is true

		if [[ ( ( $EMAIL_FAILURE_DAYS == *$DOW* ) && ( ( "$EMAIL_FAILURE_TYPE" == "ALL" ) || ( $LAST_DAY -ne $DOW && "$EMAIL_FAILURE_TYPE" == "FIRST" ) ) ) || ( ( "$LAST_STATUS" == "SUCCESS" && "$EMAIL_FAILURE_SUCCESS_OVERRIDE" == true ) ) ]]
		then :
		else
			echo "NOT sending failure email"
			SEND_TODAY=false
		fi
	fi


if [[ $SEND_TODAY == true ]]
then
	LogThis "Sending $CURRENT_STATUS email"
	$SENDMAIL_PATH -F $SENDER_NAME -f $SENDER_EMAIL -it <<-END_MESSAGE
		To: $RECIPIENT_EMAIL
		Subject: $SUBJECT
		Content-Type: text/html
		MIME-Version: 1.0
		$BODY
		END_MESSAGE
else
	LogThis "NOT sending $CURRENT_STATUS email"
fi

}




## Function to delete all files relating to the 'base' file name in the 'base' path
DeleteAllFiles()
{
	## Delete existing blocklist files (if any)
	LogThis "Deleting any existing blocklist files. ($BLOCKLIST_BASE_FILEPATH.*)"
	rm -f "$BLOCKLIST_BASE_FILEPATH".*
}




## Function to clear the IPTables configuration for this $CHAINNAME
ResetChain()
{
	if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -gt 0 ]; 
		then $IPTABLES_PATH --flush $CHAINNAME 2>&1; LogThis "    Flushed IPTable Chain"; 
		else LogThis "    No IPTable Chain to flush"; fi
	if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -gt 0 ]; 
		then $IPSET_PATH flush $CHAINNAME 2>&1; LogThis "    Flushed IPSet Chain"; 
		else LogThis "    No IPSet Chain to flush"; fi;
	if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -gt 0 ]; 
		then $IPSET_PATH destroy $CHAINNAME 2>&1; LogThis "    Destroyed IPSet Chain"; 
		else LogThis "    No IPSet to destroy"; fi;
	if [ `$IPTABLES_PATH -L INPUT | $GREP_PATH $CHAINNAME | wc -l` -gt 0 ]; 
		then $IPTABLES_PATH -D INPUT -j $CHAINNAME; LogThis "    Deleted IPTable INPUT Join"; 
		else LogThis "    No IPTable INPUT Join to delete"; fi;
	if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -gt 0 ]; 
		then $IPTABLES_PATH -X $CHAINNAME; LogThis "    Deleted IPTable Chain"; 
		else LogThis "    No IPTable Chain to delete"; fi;
}




## Function to check the IPTables config and create where required
CheckConfig()
{
	# Checking the IPSet configuration
	if [ `$IPSET_PATH list | $GREP_PATH "Name: $CHAINNAME" | wc -l` -eq 0 ];
		then $IPSET_PATH create $CHAINNAME hash:ip maxelem 16777216 2>&1; LogThis "    New IP set created";
		else LogThis "    IP set already exists"; fi;
	# Checking the IPTables configuration
	if [ `$IPTABLES_PATH -L -n | $GREP_PATH "Chain $CHAINNAME" | wc -l` -eq 0 ];
		then $IPTABLES_PATH --new-chain $CHAINNAME 2>&1; LogThis "    New chain created";
		else LogThis "    Chain already exists"; fi;
	# Checking the chain exists in the IPTables INPUT and insert the rule if needed
	if [ `$IPTABLES_PATH -L INPUT | $GREP_PATH $CHAINNAME | wc -l` -eq 0 ];
		then $IPTABLES_PATH -I INPUT -j $CHAINNAME 2>&1; LogThis "    Chain added to INPUT";
		else LogThis "    Chain already in INPUT"; fi;
	# Checking a firewall rule exists in the chain
	if [ `$IPTABLES_PATH -L $CHAINNAME | $GREP_PATH $ACTION | wc -l` -eq 0 ];
		then $IPTABLES_PATH -I $CHAINNAME -m set --match-set $CHAINNAME src -j $ACTION 2>&1; LogThis "    Firewall rule created";
		else LogThis "    Firewall rule already exists in the chain"; fi;
}




LogThis "================================================================================"
LogThis ""

## Check that the base path is correctly set up, otherwise we might run into issues
if [ "$BASE_PATH" != "" ] && [ "${BASE_PATH:0:1}" == "/" ] && [ -d "$BASE_PATH" ]; then LogThis "Using Base Path [ $BASE_PATH ]"; fi;

## Check the commands used are valid, otherwise we might run into ussues
if [[ `command -v $IPTABLES_PATH` == "" ]]; then LogThis "Cannot find [ IPTABLES_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $IPSET_PATH` == "" ]]; then LogThis "Cannot find [ IPSET_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $SORT_PATH` == "" ]]; then LogThis "Cannot find [ SORT_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $SENDMAIL_PATH` == "" ]]; then LogThis "Cannot find [ SENDMAIL_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $GREP_PATH` == "" ]]; then LogThis "Cannot find [ GREP_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $WGET_PATH` == "" ]]; then LogThis "Cannot find [ WGET_PATH ]. Is it installed? Exiting"; exit 1; fi;
if [[ `command -v $PERL_PATH` == "" ]]; then LogThis "Cannot find [ PERL_PATH ]. Is it installed? Exiting"; exit 1; fi;

## ========== ========== ========== ========== ========== ##

# Before running anything, delete all previously used blocklist files if any exist
DeleteAllFiles

## ========== ========== ========== ========== ========== ##

LogThis -s "Downloading the most recent IP list from $DOWNLOAD_FILE..."
wgetOK=$($WGET_PATH -qO - $DOWNLOAD_FILE > $BLOCKLIST_FILE) 2>&1
if [ $? -ne 0 ]
then
	BodyResponse="IP blocklist could not be downloaded from '$DOWNLOAD_FILE' ($0)"
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
	SendEmailNow "FAILURE" "$SUBJECT" "$BODY"
	exit 1
else
	## Check the count, if it is 0, we shouldn't continue

	if [ $(wc -l < $BLOCKLIST_FILE) -lt $MIN_COUNT ]
	then
		BodyResponse="IP blocklist could not be downloaded from '$DOWNLOAD_FILE' [ Downloaded $(wc -l < $BLOCKLIST_FILE), below minimum of $MIN_COUNT]"
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
		SendEmailNow "FAILURE" "$SUBJECT" "$BODY"
		exit 1
	else
		## Download didn't fail, so should be successful
		LogThis -e "Successful [$(wc -l < $BLOCKLIST_FILE)]"
	fi
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

LogThis -s "Removing Override allow-list IPs"

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
	LogThis "Start-From-Scratch enabled.  Resetting IPTable and IPSet for '$CHAINNAME'..."
	## Call the ResetChain function to clear the IPTables configuration for this chain
	ResetChain
fi

## ========== ========== ========== ========== ========== ##

## Call the CheckConfig function to check the IPTables config and create where required
LogThis ""
LogThis "Checking the configuration for '$CHAINNAME'..."
CheckConfig

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

LogThis ""
LogThis -s "Checking imported '$CHAINNAME' matches downloaded list..."

#sed -i '1,5d' $BLOCKLIST_FILE #TESTING1 == REMOVE THE FIRST FIVE LINES FROM THE FILTERED ORIGINAL FILE

## Get the existing list of blacklisted IPs
$IPSET_PATH list $CHAINNAME >> $BLOCKLIST_EXISTING_CHECK1
## Remove lines that begin with a letter (a-z or A-Z) - the first 8 lines - from the existing list
sed -i '/^[a-z,A-Z]/d' $BLOCKLIST_EXISTING_CHECK1
## Remove blank lines
sed -i '/^$/d' $BLOCKLIST_EXISTING_CHECK1
## Sort the Existing list (the new list has already been sorted)
$SORT_PATH -u $BLOCKLIST_EXISTING_CHECK1 -o $BLOCKLIST_EXISTING_CHECK1
LogThis -m "Filtered Download [$(wc -l < $BLOCKLIST_FILE)] - Filtered Existing [$(wc -l < $BLOCKLIST_EXISTING_CHECK1)]..."
## Use COMM to filter the items:
# -1 = exclude column 1 (lines unique to FILE1)
# -2 = exclude column 2 (lines unique to FILE2)
# -3 = exclude column 3 (lines that appear in both files)
## Include only lines unique to FILE1 and FILE2 [i.e. anything that isn't in both] - This should be 0
comm -3 $BLOCKLIST_FILE $BLOCKLIST_EXISTING_CHECK1 >> $BLOCKLIST_EXISTING_VALIDATE1
if [ $(wc -l < $BLOCKLIST_EXISTING_VALIDATE1) -eq 0 ]
then
	LogThis -e "Validated"
	## All validated correctly
	#    set the subject
	#    no failure message
	#    show the Validation Check 1 rows
	#    don't show Validation Check 2 rows
	VALIDATION_STATUS="SUCCESS - Updated with the newest IP list"
	VALIDATION_MESSAGE="<p>IP Blocklist script successfully updated the IP set with the newest IP list</p>"
	VALIDATION_CHECK1=""
	VALIDATION_CHECK2="display:none;"
	## Validation 2 files won't exist, so will cause an error later, let's touch them now to create them blank
	touch $BLOCKLIST_EXISTING_CHECK2
	touch $BLOCKLIST_EXISTING_VALIDATE2
else
	LogThis -e "ERROR !!! - They don't match"
	LogThis "An error occurred with importing the download"
	## Call the ResetChain function to clear the IPTables configuration for this chain
	LogThis ""
	LogThis "Resetting the chain"
	ResetChain
	## Call the CheckConfig function to create new configuration
	LogThis "Creating a new chain"
	CheckConfig
	LogThis ""
	LogThis -s "Importing the previous existing list..."
	for i in $( cat $BLOCKLIST_EXISTING ); do $IPSET_PATH add $CHAINNAME $i 2>&1; done
	LogThis -e "Done"
#	sed -i '1,5d' $BLOCKLIST_EXISTING #TESTING2 == REMOVE THE FIRST FIVE LINES FROM THE ORIGINAL EXISTING FILE
	#### Re-check
	LogThis -s "Re-checking restored '$CHAINNAME' version matches original existing..."
	$IPSET_PATH list $CHAINNAME >> $BLOCKLIST_EXISTING_CHECK2
	sed -i '/^[a-z,A-Z]/d' $BLOCKLIST_EXISTING_CHECK2
	sed -i '/^$/d' $BLOCKLIST_EXISTING_CHECK2
	$SORT_PATH -u $BLOCKLIST_EXISTING_CHECK2 -o $BLOCKLIST_EXISTING_CHECK2
	LogThis -m "Original [$(wc -l < $BLOCKLIST_EXISTING)] - Current [$(wc -l < $BLOCKLIST_EXISTING_CHECK2)]..."
	comm -3 $BLOCKLIST_EXISTING $BLOCKLIST_EXISTING_CHECK2 >> $BLOCKLIST_EXISTING_VALIDATE2
	if [ $(wc -l < $BLOCKLIST_EXISTING_VALIDATE2) -eq 0 ]
	then
		LogThis -e "Validated"
		## Restoring the previous list worked
		#    set the subject
		#    Set the failure message
		#    show the Validation Check 1 rows in red
		#    show the Validation Check 2 rows in black
		VALIDATION_STATUS="ERROR - Newest IP list update Faulure"
		VALIDATION_MESSAGE="<p style="color:red"><strong>VALIDATION FAILED - Reverted to previous known good list</strong></p>"
		VALIDATION_CHECK1="color:red;"
		VALIDATION_CHECK2=""
	else
		LogThis -e "ERROR !!! - Still an issue"
		## Restoring the previous list failed too
		#    set the subject
		#    Set the failure message
		#    show the Validation Check 1 rows in red
		#    show the Validation Check 2 rows in red
		VALIDATION_STATUS="ERROR - CRITICAL FAILURE"
		VALIDATION_MESSAGE="<p style="color:red"><strong>VALIDATION FAILED - UNABLE TO REVERT TO PREVIOUS KNOWN GOOD LIST</strong></p>"
		VALIDATION_CHECK1="color:red;"
		VALIDATION_CHECK2="color:red;"
	fi
fi

## ========== ========== ========== ========== ========== ##

TIME_DIFF=$(($(date +"%s")-${TIME_START}))
LogThis ""
LogThis "Process finished in $((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds."

SUBJECT+="$VALIDATION_STATUS"
BODY="
<html>
	<head></head>
	<body>
		$VALIDATION_MESSAGE
		<!-- <br/><br/> -->
		<table>
			<tr><td><b>DETAILS</b></td><td>&nbsp;</td></tr>
			<tr><td>Start From Scratch</td><td>$START_FROM_SCRATCH</td></tr>
			<tr><td>Chain Name</td><td>$CHAINNAME</td></tr>
			<tr><td>Originally Loaded</td><td>$(wc -l < $BLOCKLIST_EXISTING)</td></tr>
			<tr><td>Downloaded</td><td>$(wc -l < $BLOCKLIST_ORIGINAL)</td></tr>
			<tr><td>Override Allow (original)</td><td>$(wc -l < $OVERRIDE_ALLOWLIST)</td></tr>
			<tr><td>Override Allow (unique)</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_ALLOWLIST_TEMP)</td></tr>
			<tr><td>Override Block (original)</td><td>$(wc -l < $OVERRIDE_BLOCKLIST)</td></tr>
			<tr><td>Override Block (unique)</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_BLOCKLIST_TEMP)</td></tr>
			<tr><td><b>PROCESSING</b></td><td>&nbsp;</td></tr>
			<tr><td>IPv4 Filtered</td><td>$(wc -l < $BLOCKLIST_IPV4)</td></tr>
			<tr><td>Dedupe Filtered</td><td>$(wc -l < $BLOCKLIST_DEDUPE)</td></tr>
			<tr><td>Override Allow Filtered</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_ALLOWLIST)</td></tr>
			<tr><td>Override Block Filtered</td><td>$(wc -l < $BLOCKLIST_OVERRIDE_BLOCKLIST)</td></tr>
			<tr><td>Total Blocked</td><td>$(wc -l < $BLOCKLIST_FILE)</td></tr>
			<tr><td>Added</td><td>$(wc -l < $BLOCKLIST_COMPARE_ADD)</td></tr>
			<tr><td>Removed</td><td>$(wc -l < $BLOCKLIST_COMPARE_REM)</td></tr>
			<tr><td><b>VALIDATION</b></td><td>&nbsp;</td></tr>
			<tr style=\"$VALIDATION_CHECK1\"><td>Check (should match 'Total Blocked')</td><td>$(wc -l < $BLOCKLIST_EXISTING_CHECK1)</td></tr>
			<tr style=\"$VALIDATION_CHECK1\"><td>Validation Difference (should be zero)</td><td>$(wc -l < $BLOCKLIST_EXISTING_VALIDATE1)</td></tr>
			<tr style=\"$VALIDATION_CHECK2\"><td>Restore Check (should match 'Originally Loaded')</td><td>$(wc -l < $BLOCKLIST_EXISTING_CHECK2)</td></tr>
			<tr style=\"$VALIDATION_CHECK2\"><td>Restore Validation Difference (should be zero)</td><td>$(wc -l < $BLOCKLIST_EXISTING_VALIDATE2)</td></tr>
			<tr><td><b>SUMMARY</b></td><td>&nbsp;</td></tr>
			<tr><td>Duration</td><td>$((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds.</td></tr>
			<tr><td>Date</td><td>$(date "+%F %T (%Z)")</td></tr>
			<tr><td>Server</td><td>`uname -a`</td></tr>
		</table>
	</body>
</html>
"
SendEmailNow "SUCCESS" "$SUBJECT" "$BODY"

## If DELETE_ALL_FILES_ON_COMPLETION is set, delete all files on completion.
if [ $DELETE_ALL_FILES_ON_COMPLETION = true ]
then
	DeleteAllFiles
fi

LogThis ""
LogThis "================================================================================"
