#!/bin/bash

############################################################
############################################################
SCRIPT_VERSION="Aubs-Blocklist-Importer v0.4.0"
### https://github.com/AubsUK/aubs-blocklist-importer
### Changes
##    v0.1.0 - 2022-07-24 Initial Release
##    v0.1.1 - 2022-07-24 Minor aesthetic changes
##                        Removed header information from this file and added to README
##                        Added $CHAINNAME to success email
##                        Reformatted failure email
##    v0.1.2 - 2022-07-24 Override files change
##                        Changed the way overrides are processed if the file doesn't exist.
##    v0.1.3 - 2022-07-25 Changed logfile location
##    v0.2.0 - 2022-07-25 Added a check to make sure it's all worked
##                        After importing, check download and live lists match;
##                        If check fails, try and restore the previously loaded list, check again
##                        Modified final email notification to include success/failure if restoring
##                        Changed logfile name
##                        Moved clear/check/create IPTables configuration
##    v0.2.1 - 2022-11-21 Fixed checking for packages used where the package doesn't exist
##    v0.2.2 - 2022-12-10 Added MIN_COUNT for the minimum count in downloaded file to prevent failed downloads
##    v0.2.3 - 2022-12-11 Added Email Success/Failure switches
##                        Allows failures to be alerted without the constant bombardment of successes
##                        Also allows an override to send one Success/Failure after the opposite is received, even
##                          if it shouldn't email on those days.
##    v0.3.0 - 2025-10-11 Added netfilter-persistent to maintain the list after a reboot
##                        Removed irrelevant reference to ruby
##    v0.4.0 - 2026-03-31 Major structural, performance, and reliability rewrite to enable multiple blocklists from one script:
##                          Switched from 'hash:ip' to 'hash:net' for full CIDR notation support.
##                          Switched from 'filter/INPUT' to 'raw/PREROUTING' to drop packets before connection tracking.
##                          Added an 'Aubs-Blocklists' parent chain to manage multiple lists.
##                          Moved Override processing from modifying blocklists to having their own rules.
##                          Excluded the local loopback interface (! -i lo) to prevent self-blocking.
##                          Excluded Fail2Ban rules when saving persistent firewall state.
##                          Replaced 'for' loops with 'ipset -! restore' to improve performance and reliability.
##                          Added an inline Python 3 function to normalise CIDR boundaries and validate IPs.
##                          Added command-line arguments (--listname, --url, --globalreset, --overrides, etc.).
##                          Added '--legacy-cleanup' to safely remove v0.3.0 firewall objects.
##                          Runtime logs are now captured dynamically and injected directly into HTML emails.
##                          Added 'flock' to prevent cron jobs from overlapping and corrupting data.
##                          Added 'AbortWithFailure' for a fail-fast exit.
##                          Enforced 'LC_ALL=C' grep, sorting, and comm to guarantee accurate comparisons across different locales.
##                          Added 'umask 027', wget timeouts, and root/sudo checks.
##                          Relocated temporary files into subdirectories to isolate from the script.
##                          Replaced deprecated 'which' with POSIX-compliant 'command -v'.
##                          Added warning mechanism for missing 'ipset-persistent' plugins.
##
############################################################
############################################################


## ========== ========== ========== ========== ========== ##
## User Customisable Configuration                        ##
## ========== ========== ========== ========== ========== ##


START_FROM_SCRATCH=false
GLOBAL_RESET=false
LEGACY_CLEANUP=false
SYNC_OVERRIDES_ONLY=false
REMOVE_LIST=false
DELETE_ALL_FILES_ON_COMPLETION=true

## Basic Settings (Defaults if no List/URL and MinCount provided via arguments)
DOWNLOAD_FILE="http://lists.blocklist.de/lists/all.txt"    # The text file that contains all the IPs to use
LISTNAME="blocklist-de"                                    # The list name to import the IPs into
MIN_COUNT="100"                                            # If the downloaded file contains less than this number of rows, consider it failed

## Naming & Routing Configuration
PARENT_CHAIN_NAME="Aubs-Blocklists"                        # The name of the main iptables chain
OVERRIDE_ALLOWLIST_NAME="aubs-override-allowlist"          # The name of the override allowlist IPSet
OVERRIDE_BLOCKLIST_NAME="aubs-override-blocklist"          # The name of the override blocklist IPSet
IPSET_PREFIX="Aubs-"                                       # Prefix added to IPSet lists to ensure firewall namespace uniqueness

## Default: Table="raw", RoutingChain="PREROUTING", ActionBlock="DROP".  Raw table only allows DROP!
## If changing to the filter/INPUT, use: Table="filter", RoutingChain="INPUT", ActionBlock="DROP"or"REJECT"
IPTABLES_TABLE="raw"                                       # The iptables table to work in (raw provides best performance)
IPTABLES_ROUTING_CHAIN="PREROUTING"                        # The routing chain to link the parent chain into
ACTION_ALLOW="RETURN"                                      # The action to perform for allowed IPs
ACTION_BLOCK="DROP"                                        # The action to perform for blocked IPs


## ========== ========== ========== ========== ========== ##
## System Variables & Paths                               ##
## ========== ========== ========== ========== ========== ##


PATH_OF_SCRIPT="$(dirname "$(realpath "$0")")/"     # The path of the script - The default will automatically identify the path so shouldn't need changing.
BASE_PATH="$PATH_OF_SCRIPT"                         # The base path for all files (if different from the PATH_OF_SCRIPT, must include trailing slash).
APP_DIR_NAME="ip-blocklist"                         # The name of the main working directory created within the base path.

## Override File Paths
OVERRIDE_PATH="$BASE_PATH"                              # Path where override files are stored (must include trailing slash).
OVERRIDE_ALLOWLIST_FILENAME="override-allowlist.txt"    # Override allowlist filename.
OVERRIDE_BLOCKLIST_FILENAME="override-blocklist.txt"    # Override blocklist filename.

LOGFILE_PATH="/var/log/aubs-blocklist-importer/"    # Path for the log file.  Should not contain the filename, but needs a trailing slash.
LOGFILE_FILE="aubs-blocklist-importer.log"          # Filename for the logging.

## Packages used
IPTABLES_PATH="$(command -v iptables)"
IPSET_PATH="$(command -v ipset)"
SORT_PATH="$(command -v sort)"
SENDMAIL_PATH="$(command -v sendmail)"
GREP_PATH="$(command -v grep)"
WGET_PATH="$(command -v wget)"
PYTHON3_PATH="$(command -v python3)"
NETFILTER_PERSISTENT_PATH="$(command -v netfilter-persistent)"

## E-Mail variables
SENDER_NAME="Notifications"                                         # Display name for the sending email address.
SENDER_EMAIL="notifications@$(hostname -f)"                         # Sending email address ('hostname -f' puts the FQDN) [e.g. notifications@server01.example.com].
RECIPIENT_EMAIL="servers@$(hostname -d)"                            # Comma separated (no spaces) recipient addresses. Can be left blank to disable all emails.
SUBJECT="$(hostname -f) - IP blocklist"                             # Subject prefix for all emails.

# NOTE: Alerts generating a "WARNING" (Global Reset) or "CRITICAL" (restore failure) will ALWAYS send an email immediately, bypassing the schedules below.
EMAIL_SUCCESS_DAYS=1,4                                              # Days SUCCESS emails should be sent [1=Monday, 7=Sunday] (1,4=Mon,Thu).
EMAIL_SUCCESS_TYPE="FIRST"                                          # Scheduled SUCCESS sending type [NONE, FIRST, ALL].
                                                                    #    NONE  = Never send SUCCESS emails.
                                                                    #    FIRST = Send an email only on the very first run on each day in the allowed day(s).
                                                                    #    ALL   = Send an email for every single run on each day in the allowed days.
EMAIL_FAILURE_DAYS=1,2,3,4,5,6,7                                    # Days FAILURE emails should be sent [1=Monday, 7=Sunday] (1,3,6=Mon,Wed,Sat).
EMAIL_FAILURE_TYPE="FIRST"                                          # Scheduled FAILURE sending type [NONE, FIRST, ALL]. (same rules as SUCCESS).
EMAIL_FAILURE_SUCCESS_OVERRIDE=true                                 # State-change emergency override (true/false).
                                                                    #    If true, When the status flips (e.g. from SUCCESS to FAILURE), it sends an
                                                                    #    immediate email regardless of the allowed days schedule (providing the TYPE is not 'NONE').


##################################################
##################################################
########## NOTHING TO EDIT BEYOND HERE. ##########
##################################################
##################################################


## ========== ========== ========== ========== ========== ##
## Functions                                              ##
## ========== ========== ========== ========== ========== ##


## Function to log to the log file and output to the screen if run manually
LogThis() {
    ## USAGE: LogThis [OPTIONS] [String]
    #        -s [Start] of the multi-line
    #        -m [Middle] of the multi-line
    #        -e [End] of the multi-line
    #
    # e.g.    LogThis ""
    #        LogThis "This is a string to log"
    #        LogThis -s "This is the first part of a multi-line string to log"
    #        LogThis -m "This is the middle part of a multi-line string to log"
    #        LogThis -e "This is the end part of a multi-line string to log"
    #
    # We could just set the response var and append to it when the next section of the script runs and output it all in one go,
    #   but doing it this way means we get something in the log even it if fails at the next step.

    # '[ -t 1 ]' checks if file descriptor 1 (standard output) is currently attached to an interactive terminal (TTY)
    # Success means the script is being run manually, so echo to screen, otherwise it is via cron, so just log it to file

    ## Sets the log date ready to enter at the start of a line
    local LOG_START
    LOG_START="$(date '+%a %b %e %T.%3N %Z %Y') [${LISTNAME}]: "

    if [ "$1" = "-s" ]; then
        if [ -t 1 ]; then echo -n "$LOG_START $2"; fi
        echo -n "$LOG_START $2" >> "$LOGFILE_LOCATION" 2>/dev/null
        echo -n "$LOG_START $2" >> "$CURRENT_RUN_LOG" 2>/dev/null
    elif [ "$1" = "-m" ]; then
        if [ -t 1 ]; then echo -n "$2"; fi
        echo -n "$2" >> "$LOGFILE_LOCATION" 2>/dev/null
        echo -n "$2" >> "$CURRENT_RUN_LOG" 2>/dev/null
    elif [ "$1" = "-e" ]; then
        if [ -t 1 ]; then echo "$2"; fi
        echo "$2" >> "$LOGFILE_LOCATION" 2>/dev/null
        echo "$2" >> "$CURRENT_RUN_LOG" 2>/dev/null
    elif [ -z "$1" ]; then
        # If the input is completely blank, remove the trailing space from LOG_START so nothing follows the colon
        if [ -t 1 ]; then echo "${LOG_START% }"; fi
        echo "${LOG_START% }" >> "$LOGFILE_LOCATION" 2>/dev/null
        echo "${LOG_START% }" >> "$CURRENT_RUN_LOG" 2>/dev/null
    else
        # Standard log entry without flags
        if [ -t 1 ]; then echo "$LOG_START $1"; fi
        echo "$LOG_START $1" >> "$LOGFILE_LOCATION" 2>/dev/null
        echo "$LOG_START $1" >> "$CURRENT_RUN_LOG" 2>/dev/null
    fi
}


## Function to add a log file divider when exiting the script
EndLogAndExit() {
    local EXIT_ERROR="$1"
    if [ -z "$EXIT_ERROR" ]; then EXIT_ERROR=0; fi
    LogThis ""
    LogThis "================================================================================"
    rm -f "$CURRENT_RUN_LOG" 2>/dev/null
    exit "$EXIT_ERROR"
}


## Function to extract and sanitise the log content for HTML emails
CaptureLogContent() {
    CAPTURED_LOG_CONTENT="Log extraction unavailable."
    if [ -f "$CURRENT_RUN_LOG" ]; then
        CAPTURED_LOG_CONTENT=$(sed -e "1!{ \$!s/^[^[]*\[$LISTNAME\]:/[$LISTNAME]:/; }" -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' < "$CURRENT_RUN_LOG" 2>/dev/null)
    fi
}


## Provides help on the use of the switches
show_help() {
    if [ ! -t 1 ]; then LogThis "Help called, but not running in terminal. Exiting."; EndLogAndExit "1"; fi
    local script_name; script_name=$(basename "$0");
    local start_from_scratch_default_message="off"; if [ "$START_FROM_SCRATCH_DEFAULT" = true ]; then start_from_scratch_default_message="on"; fi;
    local global_reset_default_message="off"; if [ "$GLOBAL_RESET_DEFAULT" = true ]; then global_reset_default_message="on"; fi;
    local cleanup_default_message="."; if [ "$DELETE_ALL_FILES_ON_COMPLETION_DEFAULT" = true ]; then cleanup_default_message=" (Default)."; fi;
    local no_cleanup_default_message="."; if [ "$DELETE_ALL_FILES_ON_COMPLETION_DEFAULT" != true ]; then no_cleanup_default_message=" (Default)."; fi;
    echo "$SCRIPT_VERSION"
    echo "A fast multi-blocklist IP importer using IPSet and the IPTables raw table."
    echo ""
    echo "Usage: $script_name [--listname <name>] [--url <url>] [--mincount <number>]"
    echo "Usage: $script_name [--listname <name>] [--remove]"
    echo "Usage: $script_name [--overrides]"
    echo "Usage: $script_name [--overrides] [--remove]"
    echo "Usage: $script_name [--globalreset]"
    echo ""
    echo "Options:"
    echo "  -l, --listname <name>    Target specific list name (default: '$LISTNAME_DEFAULT')."
    echo "  -u, --url <url>          URL to download the blocklist from (default: '$DOWNLOAD_FILE_DEFAULT')."
    echo "  -m, --mincount <number>  Minimum line count required to accept the download (default: '$MIN_COUNT_DEFAULT')."
    echo "  -s, --scratch            Reset the IPTables and IPSet rules for this list before processing (default: $start_from_scratch_default_message)."
    echo "  -r, --remove             Remove the overrides or specified list's firewall rules and status, then exit."
    echo "  -o, --overrides          Synchronise the override lists and exit."
    echo "  -g, --globalreset        Completely remove the parent chain, all lists, and override sets (default: $global_reset_default_message)."
    echo "  -x, --legacy-cleanup     Remove legacy v0.3.0 (and below) firewall rules and IPSets."
    echo "  -c, --cleanup            Delete all temporary files on completion$cleanup_default_message"
    echo "  -n, --no-cleanup         Keep temporary files on completion for debugging$no_cleanup_default_message"
    echo "  -h, --help               Show this message."
    echo ""
}


## Function to send a failure email and gracefully abort
AbortWithFailure() {
    local ERROR_MESSAGE="$1"
    local ERROR_MESSAGE_SAFE
    ERROR_MESSAGE_SAFE=$(echo "$ERROR_MESSAGE" | sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    LogThis -e " $ERROR_MESSAGE"
    local ERROR_SUBJECT="${SUBJECT}ERROR - Processing Failure"

    CaptureLogContent

    local ERROR_BODY="
        <html>
            <head></head>
            <body>
                <b>IP Blocklist script update FAILED:</b>
                <br/><br/>
                <table>
                    <tr><td>List Name</td><td>$LISTNAME</td></tr>
                    <tr><td>Error</td><td>$ERROR_MESSAGE_SAFE</td></tr>
                    <tr><td>Date</td><td>$(date "+%F %T (%Z)")</td></tr>
                </table>
                <br/><br/><b>Execution Log:</b><br/>
                <pre style=\"background-color: #f4f4f4; padding: 10px; font-size: 12px; overflow-x: auto;\">$CAPTURED_LOG_CONTENT</pre>
            </body>
        </html>
    "
    SendEmailNow "FAILURE" "$ERROR_SUBJECT" "$ERROR_BODY"
    if [ "$DELETE_ALL_FILES_ON_COMPLETION" = true ]; then
        DeleteAllFiles
    fi
    EndLogAndExit "1"
}


## Function to strip comments, normalise CIDR boundaries, and extract valid IPs
ExtractValidIPs() {
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local TEMP_SED_FILE="${OUTPUT_FILE}.sed"

    ## Remove all comments from the file
    if ! SED_OUTPUT=$( { sed 's/#.*//' "$INPUT_FILE" > "$TEMP_SED_FILE"; } 2>&1 ); then
        AbortWithFailure "ERROR: Sed failed while processing $INPUT_FILE. Details: $SED_OUTPUT"
    fi

    ## Extract, normalise, and filter IPs using inline Python 3 function
    local PYTHON_OUTPUT
    PYTHON_OUTPUT=$($PYTHON3_PATH - "$TEMP_SED_FILE" "$OUTPUT_FILE" << 'EOF'
import sys, ipaddress

try:
    temp_file = sys.argv[1]
    out_file = sys.argv[2]

    with open(temp_file, 'r') as f_in, open(out_file, 'w') as f_out:
        for line in f_in:
            line = line.strip()
            if not line: continue

            # If the line contains spaces, take only the first segment to handle messy lists
            ip_str = line.split()[0]

            try:
                # strict=False mathematically normalises the network (e.g. 192.168.1.5/24 becomes 192.168.1.0/24)
                net = ipaddress.ip_network(ip_str, strict=False)

                # Exclude IPv6 for v0.4.0 (IPSet hash:net cannot mix IPv4 and IPv6 in the same list)
                if net.version != 4:
                    continue

                # Exclude default routing blocks to prevent network isolation
                if net.network_address.exploded == '0.0.0.0':
                    continue

                # Format output: Strip the /32 (IPv4) or /128 (IPv6) mask to perfectly match 'ipset save' defaults
                if net.prefixlen == net.max_prefixlen:
                    f_out.write(str(net.network_address) + '\n')
                else:
                    f_out.write(str(net) + '\n')

            except ValueError:
                pass # Silently drop any line that is not a valid IP or CIDR boundary

except Exception as e:
    print('Python Exception:', str(e))
    sys.exit(1)
EOF
2>&1)

    local PYTHON_EXIT_CODE=$?
    if [ $PYTHON_EXIT_CODE -ne 0 ]; then
        AbortWithFailure "ERROR: Python normalisation failed while processing $INPUT_FILE. Details: $PYTHON_OUTPUT"
    fi

    ## Clean up temporary file
    rm -f "$TEMP_SED_FILE"
}


## Function to extract and sort the active IPs from an IPSet list
DumpIPSetToFile() {
    local SET_NAME="$1"
    local OUTPUT_FILE="$2"
    local IPSET_ERR_FILE="${OUTPUT_FILE}.err"

    # Use pipefail for this one command to ensure the pipe sequence doesn't fail silently if ipset save fails
    if ! ( set -o pipefail; $IPSET_PATH save "$SET_NAME" 2>"$IPSET_ERR_FILE" | awk -v set="$SET_NAME" '$1=="add" && $2==set {print $3}' > "$OUTPUT_FILE" ); then
        AbortWithFailure "ERROR: Failed to read/write IPSet $SET_NAME for validation. Details: $(cat "$IPSET_ERR_FILE" 2>/dev/null)"
    fi

    rm -f "$IPSET_ERR_FILE" 2>/dev/null

    if ! SORT_OUTPUT=$(LC_ALL=C $SORT_PATH -u "$OUTPUT_FILE" -o "$OUTPUT_FILE" 2>&1); then
        AbortWithFailure "ERROR: Failed to sort IPSet extract file. Details: $SORT_OUTPUT"
    fi
}


## Function to synchronise a file containing IPs with an IPSet list using comm
SyncIPSetList() {
    local TARGET_FILE="$1"
    local SET_NAME="$2"
    local BASE_TEMP="$3"

    ## Enforce sorted input to guarantee 'comm' accuracy
    # (Reminder : both files being checked with 'comm' must be sorted with an identical locale. Use "LC_ALL=C" for POSIX/C to override all other language/region settings.)
    if ! SORT_OUTPUT=$(LC_ALL=C $SORT_PATH -u "$TARGET_FILE" -o "$TARGET_FILE" 2>&1); then
        AbortWithFailure "ERROR: Failed to sort target file for synchronisation. Details: $SORT_OUTPUT"
    fi

    ## Extract the current active list from IPSet safely to prevent silent corruption
    DumpIPSetToFile "$SET_NAME" "${BASE_TEMP}existing"

    ## Generate Additions and Removals
    ## Use COMM to filter the items:
    # -1 = exclude column 1 (lines unique to FILE1)
    # -2 = exclude column 2 (lines unique to FILE2)
    # -3 = exclude column 3 (lines that appear in both files)

    ## Exclude anything from FILE1 (-1) and anything in FILE1 and FILE2 (-3) - So only lines that are unique to FILE2
    ## [Include anything in the existing file that isn't in the new] (was blocked but now shouldn't be)
    if ! COMM_REM_OUTPUT=$( { LC_ALL=C comm -13 "$TARGET_FILE" "${BASE_TEMP}existing" > "${BASE_TEMP}rem"; } 2>&1 ); then
        AbortWithFailure "ERROR: Failed to generate removals list. Details: $COMM_REM_OUTPUT"
    fi

    ## Exclude anything from FILE2 (-2) and anything in FILE1 and FILE2 (-3) - So only lines that are unique to FILE1
    ## [Include anything in the new file that isn't already in the existing] (new blocks)
    if ! COMM_ADD_OUTPUT=$( { LC_ALL=C comm -23 "$TARGET_FILE" "${BASE_TEMP}existing" > "${BASE_TEMP}add"; } 2>&1 ); then
        AbortWithFailure "ERROR: Failed to generate additions list. Details: $COMM_ADD_OUTPUT"
    fi

    ## REM before ADD - This order attempts to prevent the set from briefly exceeding maxelem limits
    ## Read all IPs from the REM list and remove them from the ipset first. The -! flag ignores "does not exist" errors
    if ! RESTORE_OUTPUT=$(sed "s/^/del $SET_NAME /" "${BASE_TEMP}rem" | $IPSET_PATH -! restore 2>&1); then
        LogThis "    WARNING: ipset restore (delete) encountered an issue for $SET_NAME: $RESTORE_OUTPUT"
    fi

    ## Read all IPs from the ADD list and add them to the ipset - The -! flag ignores "already exists" errors.
    if ! RESTORE_OUTPUT=$(sed "s/^/add $SET_NAME /" "${BASE_TEMP}add" | $IPSET_PATH -! restore 2>&1); then
        LogThis "    WARNING: ipset restore (add) encountered an issue for $SET_NAME: $RESTORE_OUTPUT"
    fi

    local COUNT_REM
    local COUNT_ADD
    COUNT_REM=$([ -f "${BASE_TEMP}rem" ] && wc -l < "${BASE_TEMP}rem" || echo 0)
    COUNT_ADD=$([ -f "${BASE_TEMP}add" ] && wc -l < "${BASE_TEMP}add" || echo 0)
    LogThis -e " Done [$COUNT_REM Removed, $COUNT_ADD Added]"
}


## Function to Destroy a list
DestroyList() {
    local LIST_TO_DELETE="$1"
    local destroy_output
    if $IPSET_PATH list "$LIST_TO_DELETE" -n >/dev/null 2>&1; then
        $IPSET_PATH flush "$LIST_TO_DELETE" 2>/dev/null
        if destroy_output=$($IPSET_PATH destroy "$LIST_TO_DELETE" 2>&1); then
            LogThis "    Destroyed IPSet list: $LIST_TO_DELETE"
        else
            LogThis "    WARNING: Could not destroy IPSet list $LIST_TO_DELETE. It may still be referenced by an active iptables rule. Error: $destroy_output"
        fi
    else
        LogThis "    IPSet $LIST_TO_DELETE does not exist."
    fi
}


## Function to handle the scheduling and sending of emails
SendEmailNow() {
    local SEND_TODAY=false
    local CURRENT_STATUS="$1"
    local EMAIL_SUBJECT="$2"
    local BODY="$3"

    local DOW
    DOW=$(date +%u)
    local LAST_STATUS_READ
    local LAST_DAY=""
    local LAST_STATUS=""
    local CONF_DAYS
    local CONF_TYPE
    local IS_SCHEDULED_DAY=false
    local STATUS_CHANGED=false

    ## Extract the previous run's day and status, and suppress any errors if the file is new or empty
    LAST_STATUS_READ=$(head -n 1 "$LAST_RUN_STATUS" 2>/dev/null)
    if [[ "$LAST_STATUS_READ" =~ ^(SUCCESS|FAILURE|WARNING|CRITICAL)[1-7]$ ]]; then
        # Get the last character (the day)
        LAST_DAY="${LAST_STATUS_READ: -1}"
        # Get everything *except* the last character (the status)
        LAST_STATUS="${LAST_STATUS_READ:0:-1}"
    fi

    # Always trigger an immediate email for WARNING (Global Reset, Legacy Cleanup, List Removed) or CRITICAL (restore failure)
    if [ "$CURRENT_STATUS" = "WARNING" ] || [ "$CURRENT_STATUS" = "CRITICAL" ]; then
        SEND_TODAY=true
    else
        # Identify which schedule variables to use based on the current run status
        if [ "$CURRENT_STATUS" = "SUCCESS" ]; then
            CONF_DAYS="$EMAIL_SUCCESS_DAYS"
            CONF_TYPE="$EMAIL_SUCCESS_TYPE"
        else
            CONF_DAYS="$EMAIL_FAILURE_DAYS"
            CONF_TYPE="$EMAIL_FAILURE_TYPE"
        fi

        # Identify if today is an allowed day in the chosen schedule
        if [[ ",$CONF_DAYS," == *",$DOW,"* ]]; then IS_SCHEDULED_DAY=true; fi

        # Identify if the status has changed since the script last executed
        if [ -n "$LAST_STATUS" ] && [ "$LAST_STATUS" != "$CURRENT_STATUS" ]; then STATUS_CHANGED=true; fi

        # Identify if an email should be sent
        if [ "$CONF_TYPE" != "NONE" ]; then
            # An override is active and the state has changed - send an immediate alert regardless of the day schedule
            if [ "$EMAIL_FAILURE_SUCCESS_OVERRIDE" = true ] && [ "$STATUS_CHANGED" = true ]; then SEND_TODAY=true
            # Identify if we are on a scheduled day to send this type of email
            elif [ "$IS_SCHEDULED_DAY" = true ]; then
                # Identify if every run on this scheduled day should generate an email
                if [ "$CONF_TYPE" = "ALL" ]; then SEND_TODAY=true
                # Identify if the first run on this scheduled day should generate an email
                elif [ "$CONF_TYPE" = "FIRST" ]; then
                    # Identify if this is the first alert for this day
                    if [ "$LAST_DAY" != "$DOW" ]; then SEND_TODAY=true
                    else LogThis "Status remains '$CURRENT_STATUS' and not first run today.  Not sending notification."
                    fi
                else
                    LogThis "Invalid 'Type' set for '$CURRENT_STATUS' status."
                fi
            else
                LogThis "Sending '$CURRENT_STATUS' notifications is not configured for today."
            fi
        else
            LogThis "Sending '$CURRENT_STATUS' notifications is disabled"
        fi
    fi

    # Overwrite the LAST_RUN_STATUS file
    if [ "$GLOBAL_RESET" = false ] && [ "$LEGACY_CLEANUP" = false ]; then
        LogThis "Writing last status of [${CURRENT_STATUS}${DOW}] to $LAST_RUN_STATUS"
        if ! STATUS_WRITE_OUTPUT=$( { echo "${CURRENT_STATUS}${DOW}" > "$LAST_RUN_STATUS"; } 2>&1 ); then
            LogThis "WARNING: Failed to write to Last Run Status file. Details: $STATUS_WRITE_OUTPUT"
        fi
    fi

    if [ "$SEND_TODAY" = true ]; then
        if [ -z "$RECIPIENT_EMAIL" ]; then
            LogThis "NOT sending $CURRENT_STATUS email - Recipient address is blank"
        elif [[ ! "$RECIPIENT_EMAIL" =~ ^([^@,[:space:]]+@[^@,[:space:]]+\.[^@,[:space:]]+)(,[^@,[:space:]]+@[^@,[:space:]]+\.[^@,[:space:]]+)*$ ]]; then
            LogThis "NOT sending $CURRENT_STATUS email - Recipient address format appears to be invalid: '$RECIPIENT_EMAIL'"
        else
            LogThis "Sending $CURRENT_STATUS email"
            $SENDMAIL_PATH -F "$SENDER_NAME" -f "$SENDER_EMAIL" -it <<-END_MESSAGE
			To: $RECIPIENT_EMAIL
			Subject: $EMAIL_SUBJECT
			Content-Type: text/html
			MIME-Version: 1.0
			$BODY
			END_MESSAGE
            if [ $? -ne 0 ]; then
                LogThis "WARNING: Failed to send $CURRENT_STATUS email notification."
            fi
        fi
    else
        LogThis "NOT sending $CURRENT_STATUS email based on current configuration schedule"
    fi
}


## Function to delete the temporary list directory to clean up files
DeleteAllFiles() {
    ## Delete existing blocklist temp files (if any)
    LogThis -s "Cleaning up temporary blocklist files... "

    local REAL_LIST_DIR
    local REAL_WORKING_DIR
    REAL_LIST_DIR=$(realpath -m "$LIST_DIR" 2>/dev/null)
    REAL_WORKING_DIR=$(realpath -m "$WORKING_DIR" 2>/dev/null)

    if [[ -n "$REAL_LIST_DIR" && "$REAL_LIST_DIR" == "$REAL_WORKING_DIR"* ]]; then
        if ! RM_OUTPUT=$(rm -rf "$LIST_DIR" 2>&1); then
            LogThis -e "WARNING: Failed to cleanly delete list directory. Details: $RM_OUTPUT"
        else
            LogThis -e "Done."
        fi
    else
        DELETE_ALL_FILES_ON_COMPLETION=false
        AbortWithFailure "Unsafe or altered file deletion path detected ($LIST_DIR). Aborting."
    fi
}


## Function to completely clear the Override IPTables and IPSets
ResetOverrides() {
    # Check if the allow list with the allow action exists in the parent chain in the table
    if $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_ALLOWLIST_NAME" src -j "$ACTION_ALLOW" 2>/dev/null; then
        if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_ALLOWLIST_NAME" src -j "$ACTION_ALLOW" 2>&1); then
            LogThis "    WARNING: Failed to delete IPTable rule for $OVERRIDE_ALLOWLIST_NAME. IPSet destruction may fail. Details: $DEL_OUTPUT"
        else
            LogThis "    Deleted IPTable rule for $OVERRIDE_ALLOWLIST_NAME from $PARENT_CHAIN_NAME parent chain"
        fi
    else
        LogThis "    No IPTable allowlist rule to delete for $OVERRIDE_ALLOWLIST_NAME in $PARENT_CHAIN_NAME parent chain"
    fi

    # Check if the block list with the block action exists in the parent chain in the table
    if $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_BLOCKLIST_NAME" src -j "$ACTION_BLOCK" 2>/dev/null; then
        if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_BLOCKLIST_NAME" src -j "$ACTION_BLOCK" 2>&1); then
            LogThis "    WARNING: Failed to delete IPTable rule for $OVERRIDE_BLOCKLIST_NAME. IPSet destruction may fail. Details: $DEL_OUTPUT"
        else
            LogThis "    Deleted IPTable rule for $OVERRIDE_BLOCKLIST_NAME from $PARENT_CHAIN_NAME parent chain"
        fi
    else
        LogThis "    No IPTable blocklist rule to delete for $OVERRIDE_BLOCKLIST_NAME in $PARENT_CHAIN_NAME parent chain"
    fi

    # Check, flush and destroy the allow list if it exists in IPSet
    DestroyList "$OVERRIDE_ALLOWLIST_NAME"

    # Check, flush and destroy the block list if it exists in IPSet
    DestroyList "$OVERRIDE_BLOCKLIST_NAME"
}


## Function to clear the IPTables configuration for this list
ResetList() {
    # Check if the specific list with the block action exists in the parent chain in the table
    if $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$IPSET_TARGET_NAME" src -j "$ACTION_BLOCK" 2>/dev/null; then
        if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$PARENT_CHAIN_NAME" -m set --match-set "$IPSET_TARGET_NAME" src -j "$ACTION_BLOCK" 2>&1); then
            LogThis "    WARNING: Failed to delete IPTable rule for $IPSET_TARGET_NAME. IPSet destruction may fail. Details: $DEL_OUTPUT"
        else
            LogThis "    Deleted IPTable rule for $IPSET_TARGET_NAME from $PARENT_CHAIN_NAME parent chain"
        fi
    else
        LogThis "    No IPTable rule to delete for $IPSET_TARGET_NAME in $PARENT_CHAIN_NAME parent chain"
    fi

    # Check, flush and destroy the specific list if it exists in IPSet
    DestroyList "$IPSET_TARGET_NAME"
}


## Function to check the Parent Chain config and create where required
CheckConfigParentChain() {
    # Check if the parent chain exists in the table
    if ! $IPTABLES_PATH -t "$IPTABLES_TABLE" -L "$PARENT_CHAIN_NAME" -n >/dev/null 2>&1; then
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -N "$PARENT_CHAIN_NAME" 2>&1
        LogThis "    New parent $PARENT_CHAIN_NAME chain created in $IPTABLES_TABLE table"
    else
        LogThis "    Parent chain already exists"
    fi

    # Enforce the parent chain is linked at position 1 in the requested routing chain, excluding loopback traffic
    local CURRENT_ROUTING_RULE_POSITION
    CURRENT_ROUTING_RULE_POSITION=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -S "$IPTABLES_ROUTING_CHAIN" 2>/dev/null | $GREP_PATH -E '^-[AI]' | sed -n '1p')
    if [[ "$CURRENT_ROUTING_RULE_POSITION" != *"! -i lo -j $PARENT_CHAIN_NAME"* ]]; then
        # Remove any existing misaligned links first
        while $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$IPTABLES_ROUTING_CHAIN" ! -i lo -j "$PARENT_CHAIN_NAME" >/dev/null 2>&1; do
            if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$IPTABLES_ROUTING_CHAIN" ! -i lo -j "$PARENT_CHAIN_NAME" 2>&1); then
                AbortWithFailure "ERROR: Failed to delete misaligned parent chain link. Firewall state is unpredictable. Details: $DEL_OUTPUT"
            fi
        done
        # Re-insert at position 1, ensuring the loopback interface is bypassed
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -I "$IPTABLES_ROUTING_CHAIN" 1 ! -i lo -j "$PARENT_CHAIN_NAME" 2>&1
        LogThis "    Parent chain forced to position 1 in $IPTABLES_ROUTING_CHAIN (Excluding loopback)"
    else
        LogThis "    Parent chain already at position 1 in $IPTABLES_ROUTING_CHAIN (Excluding loopback)"
    fi
}


## Function to check the Override IPTables config and create where required
CheckConfigOverrides() {
    # Checking the override allowlist IPSet
    if ! $IPSET_PATH list "$OVERRIDE_ALLOWLIST_NAME" -n >/dev/null 2>&1; then
        $IPSET_PATH create "$OVERRIDE_ALLOWLIST_NAME" hash:net maxelem 16777216 -exist 2>&1
        LogThis "    New override allowlist IPSet created"
    else
        LogThis "    Override allowlist IPSet already exists"
    fi

    # Checking the override blocklist IPSet
    if ! $IPSET_PATH list "$OVERRIDE_BLOCKLIST_NAME" -n >/dev/null 2>&1; then
        $IPSET_PATH create "$OVERRIDE_BLOCKLIST_NAME" hash:net maxelem 16777216 -exist 2>&1
        LogThis "    New override blocklist IPSet created"
    else
        LogThis "    Override blocklist IPSet already exists"
    fi

    # Enforce override allowlist rule at the TOP of the parent chain (position 1)
    local CURRENT_ALLOW_RULE_POSITION
    CURRENT_ALLOW_RULE_POSITION=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -S "$PARENT_CHAIN_NAME" 2>/dev/null | $GREP_PATH -E '^-[AI]' | sed -n '1p')
    if [[ "$CURRENT_ALLOW_RULE_POSITION" != *"$OVERRIDE_ALLOWLIST_NAME"* ]]; then
        while $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_ALLOWLIST_NAME" src -j "$ACTION_ALLOW" >/dev/null 2>&1; do
            if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_ALLOWLIST_NAME" src -j "$ACTION_ALLOW" 2>&1); then
                AbortWithFailure "ERROR: Failed to delete misaligned allowlist rule. Firewall state is unpredictable. Details: $DEL_OUTPUT"
            fi
        done
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -I "$PARENT_CHAIN_NAME" 1 -m set --match-set "$OVERRIDE_ALLOWLIST_NAME" src -j "$ACTION_ALLOW" 2>&1
        LogThis "    Override allowlist rule forced to position 1 of the parent chain"
    else
        LogThis "    Override allowlist rule already at position 1 of the parent chain"
    fi

    # Enforce override blocklist rule immediately after the allowlist (position 2)
    local CURRENT_BLOCK_RULE_POSITION
    CURRENT_BLOCK_RULE_POSITION=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -S "$PARENT_CHAIN_NAME" 2>/dev/null | $GREP_PATH -E '^-[AI]' | sed -n '2p')
    if [[ "$CURRENT_BLOCK_RULE_POSITION" != *"$OVERRIDE_BLOCKLIST_NAME"* ]]; then
        while $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_BLOCKLIST_NAME" src -j "$ACTION_BLOCK" >/dev/null 2>&1; do
            if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$PARENT_CHAIN_NAME" -m set --match-set "$OVERRIDE_BLOCKLIST_NAME" src -j "$ACTION_BLOCK" 2>&1); then
                AbortWithFailure "ERROR: Failed to delete misaligned blocklist rule. Firewall state is unpredictable. Details: $DEL_OUTPUT"
            fi
        done
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -I "$PARENT_CHAIN_NAME" 2 -m set --match-set "$OVERRIDE_BLOCKLIST_NAME" src -j "$ACTION_BLOCK" 2>&1
        LogThis "    Override blocklist rule forced to position 2 of the parent chain"
    else
        LogThis "    Override blocklist rule already at position 2 of the parent chain"
    fi
}


## Function to check the IPTables config and create where required for the Specific List
CheckConfigList() {
    # Checking the IPSet configuration for the specific blocklist
    if ! $IPSET_PATH list "$IPSET_TARGET_NAME" -n >/dev/null 2>&1; then
        $IPSET_PATH create "$IPSET_TARGET_NAME" hash:net maxelem 16777216 -exist 2>&1
        LogThis "    New blocklist IPSet created ($IPSET_TARGET_NAME)"
    else
        LogThis "    Blocklist IPSet already exists ($IPSET_TARGET_NAME)"
    fi

    # Append the specific blocklist rule to the parent chain (does not need to be in any particular order)
    if ! $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$PARENT_CHAIN_NAME" -m set --match-set "$IPSET_TARGET_NAME" src -j "$ACTION_BLOCK" >/dev/null 2>&1; then
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -A "$PARENT_CHAIN_NAME" -m set --match-set "$IPSET_TARGET_NAME" src -j "$ACTION_BLOCK" 2>&1
        LogThis "    Specific blocklist firewall rule appended to the parent chain"
    else
        LogThis "    Specific blocklist firewall rule already exists in the parent chain"
    fi
}


## Function to save persistent firewall rules while excluding temporary Fail2Ban chains
SavePersistentFirewall() {
    if [ -x "$NETFILTER_PERSISTENT_PATH" ]; then
        LogThis -s "Saving persistent firewall rules (excluding Fail2Ban)..."
        "$NETFILTER_PERSISTENT_PATH" save >/dev/null 2>&1

        # Post-process the saved IPv4 rules to strip out active Fail2Ban chains
        if [ -f /etc/iptables/rules.v4 ]; then
            if ! SED_V4_OUTPUT=$(sed -i '/f2b-/d' /etc/iptables/rules.v4 2>&1); then
                LogThis "    WARNING: Failed to process rules.v4. Details: $SED_V4_OUTPUT"
            fi
        fi

        # Post-process the saved IPv6 rules to strip out active Fail2Ban chains
        if [ -f /etc/iptables/rules.v6 ]; then
            if ! SED_V6_OUTPUT=$(sed -i '/f2b-/d' /etc/iptables/rules.v6 2>&1); then
                LogThis "    WARNING: Failed to process rules.v6. Details: $SED_V6_OUTPUT"
            fi
        fi

        LogThis -e " Done"
    else
        LogThis "    WARNING: 'netfilter-persistent' not found.  New rules will not be retained after a reboot."
    fi
}


## ========== ========== ========== ========== ========== ##
## Initial Config, Checks and Argument Parsing            ##
## ========== ========== ========== ========== ========== ##


## Enforce permissions for all files created by this script (Owner: RW, Group: R, Other: None)
umask 027

## Extract the defaults in case the originals are modified during argument parsing
LISTNAME_DEFAULT="$LISTNAME"
DOWNLOAD_FILE_DEFAULT="$DOWNLOAD_FILE"
MIN_COUNT_DEFAULT="$MIN_COUNT"
START_FROM_SCRATCH_DEFAULT="$START_FROM_SCRATCH"
GLOBAL_RESET_DEFAULT="$GLOBAL_RESET"
DELETE_ALL_FILES_ON_COMPLETION_DEFAULT="$DELETE_ALL_FILES_ON_COMPLETION"

## Tracking variables to ensure --listname and --url dependency
ARG_PROVIDED_LISTNAME=false
ARG_PROVIDED_URL=false

## Tracking variables to capture early run requirements
ARG_HELP=false
ARG_UNKNOWN=false
UNKNOWN_PARAMETER=""

## Other used variables
LAST_RUN_PREFIX="Last_Run_Status"

## Extract the arguments provided by any switches if present
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -l|--listname) LISTNAME="$2"; ARG_PROVIDED_LISTNAME=true; shift ;;
        -m|--mincount) MIN_COUNT="$2"; shift ;;
        -u|--url) DOWNLOAD_FILE="$2"; ARG_PROVIDED_URL=true; shift ;;
        -s|--scratch) START_FROM_SCRATCH=true ;;
        -r|--remove) REMOVE_LIST=true ;;
        -c|--cleanup) DELETE_ALL_FILES_ON_COMPLETION=true ;;
        -n|--no-cleanup) DELETE_ALL_FILES_ON_COMPLETION=false ;;
        -o|--overrides) SYNC_OVERRIDES_ONLY=true ;;
        -g|--globalreset) GLOBAL_RESET=true ;;
        -x|--legacy-cleanup) LEGACY_CLEANUP=true ;;
        -h|--help) ARG_HELP=true ;;
        *) ARG_UNKNOWN=true; UNKNOWN_PARAMETER="$1"; break ;;
    esac
    shift
done

## Enforce precedence of the LISTNAME variable if multiple primary modes (--listname and --url or --sync-overrides or --globalreset) are triggered in the same command
## Order: Global Reset > Legacy Cleanup > Overrides > List
if [ "$GLOBAL_RESET" = true ]; then LISTNAME="Global-Reset"
elif [ "$LEGACY_CLEANUP" = true ]; then LISTNAME="Legacy-Cleanup"
elif [ "$SYNC_OVERRIDES_ONLY" = true ]; then LISTNAME="Overrides"
fi

## Set up the main logging directory
mkdir -p "$LOGFILE_PATH" 2>/dev/null
LOGFILE_LOCATION="$LOGFILE_PATH$LOGFILE_FILE"

## Create a background log to capture the live run for the email output using mktemp to prevent symlink attacks
if ! CURRENT_RUN_LOG=$(mktemp /tmp/aubs-blocklist-run-XXXXXX.log 2>/dev/null); then
    # This shouldn't happen unless something is seriously wrong with the server.
    # Attempt to write to screen, live log and main log if possible.
    LogThis "FATAL ERROR: Could not create secure temporary log file via mktemp. Exiting to prevent symlink attacks." >&2
    # Send an immediate warning email.
    SUBJECT+="Live Log File Error"
    BODY="<p><b>FATAL ERROR</b>: Could not create secure temporary log file via mktemp. This could indicate a serious issue.</p>"
    SendEmailNow "WARNING" "$SUBJECT" "$BODY"
    exit 1
fi
chmod 600 "$CURRENT_RUN_LOG" 2>/dev/null

LogThis "================================================================================"
LogThis ""
LogThis "Created temporary log file [ $CURRENT_RUN_LOG ]."

## Try and touch the main log to ensure writability and create it if needed. If it fails, it will echo to the temporary log.
if ! TOUCH_LOG_OUTPUT=$( { touch "$LOGFILE_LOCATION"; } 2>&1 ); then
    LogThis "WARNING: Failed to create or write to log file at '$LOGFILE_LOCATION'. Details: $TOUCH_LOG_OUTPUT"
fi


## ========== ========== ========== ========== ========== ##
## Concurrency Control (File Locking)                     ##
## ========== ========== ========== ========== ========== ##


## Create a lock file in /var/run/ (or similar, as a temporary file) to prevent multiple overlapping cron jobs for the same list from corrupting temporary files
# The flock command ties the lock to the script's active running process via file descriptor 200.  Once the process dies, the lock is removed automatically.
LOCK_FILE="/var/run/aubs-blocklist-importer-${LISTNAME}.lock"
if ! exec 200>"$LOCK_FILE" 2>/dev/null; then
    LogThis "ERROR: Cannot write to lock file '$LOCK_FILE'. Exiting to prevent corruption."
    EndLogAndExit "1"
fi
if ! flock -n 200; then
    LogThis "Another instance of aubs-blocklist-importer is already running for list '${LISTNAME}'. Exiting to prevent corruption."
    EndLogAndExit "1"
fi


## ========== ========== ========== ========== ========== ##
## Validations and Dependency Checks                      ##
## ========== ========== ========== ========== ========== ##


if [ "$ARG_UNKNOWN" = true ]; then LogThis "ERROR: Unknown parameter passed: $UNKNOWN_PARAMETER" >&2; show_help; EndLogAndExit "1"; fi
if [ "$ARG_HELP" = true ]; then show_help; EndLogAndExit "0"; fi

if ! [[ "$MIN_COUNT" =~ ^[0-9]+$ ]]; then
    LogThis "ERROR: --mincount must be a positive integer."
    EndLogAndExit "1"
fi

## Enforce root privileges check
if [ "$(id -u)" -ne 0 ]; then
    LogThis "CRITICAL ERROR: This script must be run as root (or via sudo) to modify firewall rules." >&2
    EndLogAndExit "1"
fi

## Enforce that --listname and --url must be used together (unless removing a list)
if [ "$REMOVE_LIST" = false ]; then
    if [ "$ARG_PROVIDED_LISTNAME" = true ] && [ "$ARG_PROVIDED_URL" = false ]; then
        LogThis "ERROR: The --listname switch requires the --url switch to also be provided."
        LogThis ""
        show_help
        EndLogAndExit "1"
    elif [ "$ARG_PROVIDED_URL" = true ] && [ "$ARG_PROVIDED_LISTNAME" = false ]; then
        LogThis "ERROR: The --url switch requires the --listname switch to also be provided."
        LogThis ""
        show_help
        EndLogAndExit "1"
    fi
## Enforce that --remove cannot be used with both --overrides or --listname.
elif [ "$REMOVE_LIST" = true ] && [ "$SYNC_OVERRIDES_ONLY" = true ] && [ "$ARG_PROVIDED_LISTNAME" = true ]; then
    LogThis "ERROR: The --remove switch cannot be used with both --overrides and --listname switches."
    LogThis ""
    show_help
    EndLogAndExit "1"
## Enforce that --remove cannot be used without --overrides or --listname.
elif [ "$REMOVE_LIST" = true ] && [ "$SYNC_OVERRIDES_ONLY" = false ] && [ "$ARG_PROVIDED_LISTNAME" = false ]; then
    LogThis "ERROR: The --remove switch requires either the --overrides or --listname switch to also be provided."
    LogThis ""
    show_help
    EndLogAndExit "1"
fi

## Validate the LISTNAME to prevent directory traversal or IPSet naming errors
## IPSet names can only contain alphanumeric characters, dots, underscores, and hyphens.
if [[ "$LISTNAME" =~ [^a-zA-Z0-9._-] ]]; then
    LogThis "ERROR: The provided list name '$LISTNAME' contains invalid characters.  Only alphanumeric characters, dots, underscores, and hyphens are permitted."
    LogThis ""
    show_help
    EndLogAndExit "1"
fi

## Add the prefix for the specific IPSet name to ensure uniqueness
if [ "$LISTNAME" != "Global-Reset" ] && [ "$LISTNAME" != "Legacy-Cleanup" ] && [ "$LISTNAME" != "Overrides" ]; then
    IPSET_TARGET_NAME="${IPSET_PREFIX}${LISTNAME#$IPSET_PREFIX}"

    ## Prevent completely blank or purely punctuation-based list names after prefix stripping
    if [[ ! "${LISTNAME#$IPSET_PREFIX}" =~ [a-zA-Z0-9] ]]; then
        LogThis "ERROR: The core list name must contain at least one alphanumeric character."
        LogThis ""
        show_help
        EndLogAndExit "1"
    fi
else
    IPSET_TARGET_NAME="$LISTNAME"
fi

## Enforce the strict IPSet 31-character length limit
if [ "${#IPSET_TARGET_NAME}" -gt 31 ]; then
    LogThis "ERROR: The resulting IPSet name '$IPSET_TARGET_NAME' exceeds the 31-character limit (${#IPSET_TARGET_NAME} characters)."
    LogThis "       Please choose a shorter list name."
    LogThis ""
    show_help
    EndLogAndExit "1"
fi

## Add the LISTNAME to the subject of emails (needs to be here in case it was updated by any arguments)
SUBJECT+=" [${LISTNAME}] - "

TIME_START=$(date +"%s%3N")

## Structured Directories
WORKING_DIR="${BASE_PATH}${APP_DIR_NAME}/"
LIST_DIR="${WORKING_DIR}${LISTNAME}/"

LAST_RUN_STATUS="${WORKING_DIR}${LAST_RUN_PREFIX}-${LISTNAME}.txt"            # Last run file, contains SUCCESS or FAILURE and a number for the day last run

OVERRIDE_ALLOWLIST_FILEPATH="${OVERRIDE_PATH}${OVERRIDE_ALLOWLIST_FILENAME}"  # Full path to the override allowlist
OVERRIDE_BLOCKLIST_FILEPATH="${OVERRIDE_PATH}${OVERRIDE_BLOCKLIST_FILENAME}"  # Full path to the override blocklist

## Ensure the main working directory exists (but not if runing a Legacy Cleanup)
if [ ! "$LEGACY_CLEANUP" = true ]; then
    if ! MKDIR_WORK_OUTPUT=$(mkdir -p "$WORKING_DIR" 2>&1); then
        AbortWithFailure "ERROR: Failed to create main working directory. Details: $MKDIR_WORK_OUTPUT"
    fi
fi

## Default status for override validations
VALIDATION_ALLOW_TEXT="N/A"
VALIDATION_BLOCK_TEXT="N/A"
EMAIL_ALERT_TYPE="SUCCESS"


## Check that the base path is correctly set up
if [ -n "$BASE_PATH" ] && [ "${BASE_PATH:0:1}" = "/" ] && [ -d "$BASE_PATH" ]; then
    LogThis "Using Base Path [ $BASE_PATH ]"
else
    AbortWithFailure "ERROR: Invalid Base Path [ $BASE_PATH ]. Exiting."
fi

## Check the commands used are valid, otherwise we might run into issues (some don't entirely matter, so they have a warning instead)
if [ ! -x "$IPTABLES_PATH" ]; then AbortWithFailure "Cannot find [ iptables ] via command -v. Is it installed? Exiting"; fi;
if [ ! -x "$IPSET_PATH" ]; then AbortWithFailure "Cannot find [ ipset ] via command -v. Is it installed? Exiting"; fi;
if [ ! -x "$SORT_PATH" ]; then AbortWithFailure "Cannot find [ sort ] via command -v. Is it installed? Exiting"; fi;
if [ ! -x "$GREP_PATH" ]; then AbortWithFailure "Cannot find [ grep ] via command -v. Is it installed? Exiting"; fi;
if [ ! -x "$WGET_PATH" ]; then AbortWithFailure "Cannot find [ wget ] via command -v. Is it installed? Exiting"; fi;
if [ ! -x "$PYTHON3_PATH" ]; then AbortWithFailure "Cannot find [ python3 ] via command -v. Is it installed? Exiting"; fi;

if [ ! -x "$SENDMAIL_PATH" ]; then 
    if [ -n "$RECIPIENT_EMAIL" ]; then
        AbortWithFailure "Cannot find [ sendmail ] via command -v. Is it installed? Exiting"
    else
        LogThis "WARNING: Cannot find [ sendmail ] via command -v. Email notifications will be disabled."
    fi
fi

if [ ! -x "$NETFILTER_PERSISTENT_PATH" ]; then
    LogThis "WARNING: Cannot find [ netfilter-persistent ] via command -v. Rules modified in this run will not survive a reboot."
else
    # Check if IPSet plugins exist for netfilter-persistent
    if [ ! -f "/usr/share/netfilter-persistent/plugins.d/10-ipset" ] || [ ! -f "/usr/share/netfilter-persistent/plugins.d/40-ipset" ]; then
        LogThis "WARNING: 'ipset-persistent' plugins [ 10-ipset ] and/or [ 40-ipset ] not found. IPSet lists may not restore on reboot."
    fi
fi


## ========== ========== ========== ========== ========== ##
## Global Reset                                           ##
## ========== ========== ========== ========== ========== ##


## Perform Global Reset if requested
if [ "$GLOBAL_RESET" = true ]; then
    LogThis ""
    LogThis "Performing Global Reset..."

    # Unlink the parent chain from the routing chain
    if $IPTABLES_PATH -t "$IPTABLES_TABLE" -C "$IPTABLES_ROUTING_CHAIN" ! -i lo -j "$PARENT_CHAIN_NAME" 2>/dev/null; then
        if ! DEL_OUTPUT=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -D "$IPTABLES_ROUTING_CHAIN" ! -i lo -j "$PARENT_CHAIN_NAME" 2>&1); then
            LogThis "    WARNING: Failed to unlink $PARENT_CHAIN_NAME from $IPTABLES_ROUTING_CHAIN. Details: $DEL_OUTPUT"
        else
            LogThis "    Unlinked $PARENT_CHAIN_NAME from $IPTABLES_ROUTING_CHAIN."
        fi
    else
        LogThis "    $PARENT_CHAIN_NAME not linked in $IPTABLES_ROUTING_CHAIN."
    fi

    # Identify and delete all sets attached to the parent chain
    if $IPTABLES_PATH -t "$IPTABLES_TABLE" -L "$PARENT_CHAIN_NAME" -n >/dev/null 2>&1; then

        # Extract the names of all IPSets currently linked to the parent chain (through each column in the iptables output)
        ATTACHED_SETS=$($IPTABLES_PATH -t "$IPTABLES_TABLE" -S "$PARENT_CHAIN_NAME" | awk '/--match-set/ {for(i=1;i<=NF;i++) if($i=="--match-set") print $(i+1)}')

        # Flush the parent chain to release the active IPSet links
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -F "$PARENT_CHAIN_NAME" 2>/dev/null
        LogThis "    Flushed parent chain $PARENT_CHAIN_NAME."

        # Delete the parent chain
        $IPTABLES_PATH -t "$IPTABLES_TABLE" -X "$PARENT_CHAIN_NAME" 2>/dev/null
        LogThis "    Deleted parent chain $PARENT_CHAIN_NAME."

        # Loop through and destroy each list attached to the chain
        while read -r set; do
            if [ -n "$set" ] && [[ "$set" != "$OVERRIDE_ALLOWLIST_NAME" && "$set" != "$OVERRIDE_BLOCKLIST_NAME" ]]; then
                DestroyList "$set"
            fi
        done <<< "$ATTACHED_SETS"
    fi

    # Check, flush and destroy the allow list if it exists in IPSet
    DestroyList "$OVERRIDE_ALLOWLIST_NAME"

    # Check, flush and destroy the block list if it exists in IPSet
    DestroyList "$OVERRIDE_BLOCKLIST_NAME"

    # Clear up all relevant files
    LogThis -s "    Deleting all related temporary files... "
    if [[ -n "$WORKING_DIR" && "$WORKING_DIR" == "$BASE_PATH"* ]]; then
        if ! RM_OUTPUT=$(rm -rf "$WORKING_DIR" 2>&1); then
            LogThis -e "WARNING: Failed to cleanly delete working directory. Details: $RM_OUTPUT"
        else
            LogThis -e "Deleted."
        fi
    else
        LogThis -e "Unsafe or altered file deletion path detected ($WORKING_DIR)."
    fi


    LogThis "Sending notification email."

    CaptureLogContent

    # Send an immediate warning email that the server has no blocklists.
    SUBJECT+="Firewall Blocklists Cleared"
    BODY="<p>A global reset was performed on the server.  All blocklist chains, IPSets, and temporary files for this script have been deleted.</p><p><b>NOTE:</b> Manually delete the log folder:<br/>[ $LOGFILE_PATH ]</p><br/><br/><b>Execution Log:</b><br/><pre style=\"background-color: #f4f4f4; padding: 10px; font-size: 12px; overflow-x: auto;\">$CAPTURED_LOG_CONTENT</pre>"
    SendEmailNow "WARNING" "$SUBJECT" "$BODY"

    LogThis "Global Reset complete.  Exiting."
    EndLogAndExit "0"
fi


## ========== ========== ========== ========== ========== ##
## Legacy Cleanup                                         ##
## ========== ========== ========== ========== ========== ##


if [ "$LEGACY_CLEANUP" = true ]; then
    LogThis ""
    LogThis "Performing Legacy (v0.3.0 and below) Cleanup..."

    if [ ! -t 1 ]; then
        LogThis " Legacy Cleanup can only run interactively. Exiting"
        EndLogAndExit "1"
    else
        # Look for rules in the INPUT chain of the filter table
        INPUT_RULES=$($IPTABLES_PATH -t filter -S INPUT 2>/dev/null | $GREP_PATH -E '^-A INPUT -j ')

        LEGACY_FOUND=false

        if [ -n "$INPUT_RULES" ]; then
            # Temporarily change the Internal Field Separator to a newline so the loop reads line-by-line
            OLD_IFS="$IFS"
            IFS=$'\n'
            for rule in $INPUT_RULES; do
                # Extract the target chain name
                TARGET_CHAIN=$(echo "$rule" | awk '{print $4}')

                # Skip if it's empty, standard target, or fail2ban
                if [ -z "$TARGET_CHAIN" ] || [[ "$TARGET_CHAIN" == "ACCEPT" || "$TARGET_CHAIN" == "DROP" || "$TARGET_CHAIN" == "REJECT" || "$TARGET_CHAIN" == "RETURN" || "$TARGET_CHAIN" == f2b-* ]]; then
                    continue
                fi

                # Check if this target is actually a custom chain with an IPSet of the same name (standard v0.3.0 and below format)
                if $IPTABLES_PATH -t filter -L "$TARGET_CHAIN" -n >/dev/null 2>&1; then
                    if $IPSET_PATH list "$TARGET_CHAIN" -n >/dev/null 2>&1; then
                        LEGACY_FOUND=true
                        LogThis "    Found legacy object: '$TARGET_CHAIN'"

                        # Print directly to the terminal and read from it to bypass any stdin/stderr quirks in older Bash versions
                        printf "    Delete legacy chain and IPSet '%s'? [y/N]: " "$TARGET_CHAIN" > /dev/tty
                        read -r CONFIRM_DELETE < /dev/tty

                        if [[ ! "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
                            LogThis "    Skipping deletion of '$TARGET_CHAIN'."
                            continue
                        fi

                        # Delete the jump from INPUT
                        if ! DEL_INPUT_OUTPUT=$($IPTABLES_PATH -t filter -D INPUT -j "$TARGET_CHAIN" 2>&1); then
                            LogThis "        WARNING: Failed to delete INPUT rule for $TARGET_CHAIN. Details: $DEL_INPUT_OUTPUT"
                        else
                            LogThis "        Deleted INPUT rule for $TARGET_CHAIN."
                        fi

                        # Flush and delete the custom chain
                        $IPTABLES_PATH -t filter -F "$TARGET_CHAIN" 2>/dev/null
                        if ! DEL_CHAIN_OUTPUT=$($IPTABLES_PATH -t filter -X "$TARGET_CHAIN" 2>&1); then
                            LogThis "        WARNING: Failed to delete filter chain $TARGET_CHAIN. Details: $DEL_CHAIN_OUTPUT"
                        else
                            LogThis "        Flushed and deleted filter chain $TARGET_CHAIN."
                        fi

                        # Flush and destroy the IPSet
                        $IPSET_PATH flush "$TARGET_CHAIN" 2>/dev/null
                        if ! DEL_IPSET_OUTPUT=$($IPSET_PATH destroy "$TARGET_CHAIN" 2>&1); then
                            LogThis "        WARNING: Failed to destroy IPSet $TARGET_CHAIN. Details: $DEL_IPSET_OUTPUT"
                        else
                            LogThis "        Flushed and destroyed IPSet $TARGET_CHAIN."
                        fi
                    fi
                fi
            done
            IFS="$OLD_IFS"
        fi

        # Clear up all relevant files
        LogThis -s "    Deleting Last Run Status file [ ${BASE_PATH}Last_Run_Status.txt ]... "
        if [[ -f "${BASE_PATH}Last_Run_Status.txt" ]]; then
            if ! RM_OUTPUT=$(rm -f "${BASE_PATH}Last_Run_Status.txt" 2>&1); then
                LogThis -e "WARNING: Failed to cleanly delete Legacy Last Run Status. Details: $RM_OUTPUT"
            else
                LogThis -e "Deleted."
            fi
        else
            LogThis -e "Not found."
        fi

        if [ "$LEGACY_FOUND" = false ]; then
            LogThis "    No legacy v0.3.0 objects found."
        else
            # Save the new firewall state, ignore Fail2Ban rules, and make it persistent
            SavePersistentFirewall

            LogThis "Sending notification email."

            CaptureLogContent

            # Send an immediate warning email that the server has no blocklists.
            SUBJECT+="Legacy Firewall Blocklist Cleared"
            BODY="<p>A Legacy Cleanup was performed on the server.  All blocklist chains, IPSets, and temporary files for this script have been deleted.</p><p><b>NOTE:</b> Manually delete the log folder:<br/>[ $LOGFILE_PATH ]</p><br/><br/><b>Execution Log:</b><br/><pre style=\"background-color: #f4f4f4; padding: 10px; font-size: 12px; overflow-x: auto;\">$CAPTURED_LOG_CONTENT</pre>"
            SendEmailNow "WARNING" "$SUBJECT" "$BODY"
        fi

        LogThis "Legacy cleanup complete.  Exiting."
        EndLogAndExit "0"
    fi
fi


## ========== ========== ========== ========== ========== ##
## Preparation & Initialization                           ##
## ========== ========== ========== ========== ========== ##


    LogThis ""
    LogThis "Running aubs-blocklist-importer for $LISTNAME"
    LogThis ""

## Before running anything, delete all previously used blocklist files for this List (if any exist) then create this list's directory
DeleteAllFiles

if [ "$REMOVE_LIST" = true ]; then
    LogThis ""
    LogThis "Removing list '$LISTNAME'..."

    if [ "$SYNC_OVERRIDES_ONLY" = true ]; then
        ResetOverrides
    elif [ "$ARG_PROVIDED_LISTNAME" = true ]; then
        ResetList
    fi

    LogThis -s "    Deleting Last Run Status file [ $LAST_RUN_STATUS ]... "
    if [[ -f "$LAST_RUN_STATUS" ]]; then
        if ! RM_OUTPUT=$(rm -f "$LAST_RUN_STATUS" 2>&1); then
            LogThis -e "WARNING: Failed to cleanly delete Last Run Status. Details: $RM_OUTPUT"
        else
            LogThis -e "Deleted."
        fi
    else
        LogThis -e "Not found."
    fi
    SavePersistentFirewall
    CaptureLogContent

    # Send an immediate warning email that the server has no blocklists.
    SUBJECT+="Firewall Blocklist Cleared"
    BODY="<p>A reset was performed on the list [ $LISTNAME ].  The IPSet for this list has been removed from the firewall, and temporary files for this list have been deleted.</p><br/><br/><b>Execution Log:</b><br/><pre style=\"background-color: #f4f4f4; padding: 10px; font-size: 12px; overflow-x: auto;\">$CAPTURED_LOG_CONTENT</pre>"
    SendEmailNow "WARNING" "$SUBJECT" "$BODY"
    LogThis "Removal complete.  Exiting."
    EndLogAndExit "0"
fi

if ! MKDIR_LIST_OUTPUT=$(mkdir -p "$LIST_DIR" 2>&1); then
    AbortWithFailure "ERROR: Failed to create list directory. Details: $MKDIR_LIST_OUTPUT"
fi

## TEST1 - This line is for testing the checking system works.  Uncomment to process
#rm -r "$LIST_DIR" #TESTING1 ==> REMOVE THE DIRECTORY THE SCRIPT WILL USE FOR STORING TEMPORARY FILES

## The START_FROM_SCRATCH variable determines if the LISTNAME and Overrides should be deleted from IPTable and IPSet before proceeding
if [ "$START_FROM_SCRATCH" = true ]; then
    LogThis ""
    LogThis "Start-From-Scratch enabled.  Resetting IPTable and IPSets..."

    if [ "$SYNC_OVERRIDES_ONLY" = true ]; then
        ResetOverrides
    else
        ResetList
    fi
fi


## ========== ========== ========== ========== ========== ##
## Parent Chain Configuration                             ##
## ========== ========== ========== ========== ========== ##


LogThis ""
LogThis "Checking the configuration for Parent Chain '$PARENT_CHAIN_NAME'..."
CheckConfigParentChain


## ========== ========== ========== ========== ========== ##
## Main Process - Overrides or Blocklist                  ##
## ========== ========== ========== ========== ========== ##


if [ "$SYNC_OVERRIDES_ONLY" = true ]; then

    LogThis ""
    LogThis "Checking the configuration for Overrides..."
    CheckConfigOverrides

    ## Synchronise Override Allowlist
    if [ ! -r "$OVERRIDE_ALLOWLIST_FILEPATH" ]; then
        LogThis -s "Override allowlist file doesn't exist.  Creating it..."
        # Because the OVERRIDE_ALLOWLIST file doesn't exist, create it and add the header info
        if ! CREATE_ALLOW_OUTPUT=$( { printf "# Add IP addresses to this list, one on each line, to make sure they are never blocked\n# IPs can be in normal or CIDR format (e.g. 1.2.3.4 or 1.2.3.4/24)\n\n" >> "$OVERRIDE_ALLOWLIST_FILEPATH"; } 2>&1 ); then
            AbortWithFailure "ERROR: Failed to create the override allowlist file. Details: $CREATE_ALLOW_OUTPUT"
        else
            LogThis -e " Done"
        fi
    fi

    LogThis -s "Synchronising Override allowlist IPs..."
    ExtractValidIPs "$OVERRIDE_ALLOWLIST_FILEPATH" "${LIST_DIR}allow.temp"

    ## Sort the extracted IPs, removing any duplicates
    if ! SORT_ALLOW_OUTPUT=$(LC_ALL=C $SORT_PATH -u "${LIST_DIR}allow.temp" -o "${LIST_DIR}allow.temp" 2>&1); then
        AbortWithFailure "ERROR: Failed to sort override allowlist. Details: $SORT_ALLOW_OUTPUT"
    fi

    ## Process the override allowlist comparison and sync
    SyncIPSetList "${LIST_DIR}allow.temp" "$OVERRIDE_ALLOWLIST_NAME" "${LIST_DIR}allow."

    LogThis -s "Validating Override allowlist sync..."
    DumpIPSetToFile "$OVERRIDE_ALLOWLIST_NAME" "${LIST_DIR}allow.check"

    ## Exclude anything in both files (-3) - So only lines that are unique to FILE1 or FILE2
    ## [Include the differences between the new and existing] (if it loaded properly, this should be 0)
    if ! COMM_ALLOW_OUTPUT=$( { LC_ALL=C comm -3 "${LIST_DIR}allow.temp" "${LIST_DIR}allow.check" > "${LIST_DIR}allow.validate"; } 2>&1 ); then
        AbortWithFailure "ERROR: Allowlist comm validation failed. Details: $COMM_ALLOW_OUTPUT"
    fi

    COUNT_VALIDATE_ALLOW=$([ -f "${LIST_DIR}allow.validate" ] && wc -l < "${LIST_DIR}allow.validate" || echo 0)
    if [ "$COUNT_VALIDATE_ALLOW" -eq 0 ]; then
        LogThis -e " Validated successfully"
        VALIDATION_ALLOW_TEXT="OK"
    else
        LogThis -e " ERROR !!! - Sync failed"
        VALIDATION_ALLOW_TEXT="<span style=\"color:red; font-weight:bold;\">FAILED</span>"
        EMAIL_ALERT_TYPE="FAILURE"
    fi

    ## Synchronise Override Blocklist
    if [ ! -r "$OVERRIDE_BLOCKLIST_FILEPATH" ]; then
        LogThis -s "Override blocklist file doesn't exist.  Creating it..."
        # Because the OVERRIDE_BLOCKLIST_FILEPATH file doesn't exist, create it and add the header info
        if ! CREATE_BLOCK_OUTPUT=$( { touch "$OVERRIDE_BLOCKLIST_FILEPATH" && printf "# Add IP addresses to this list, one on each line, to make sure they are always blocked\n# IPs can be in normal or CIDR format (e.g. 1.2.3.4 or 1.2.3.4/24)\n\n" >> "$OVERRIDE_BLOCKLIST_FILEPATH"; } 2>&1 ); then
            AbortWithFailure "ERROR: Failed to create the override blocklist file. Details: $CREATE_BLOCK_OUTPUT"
        else
            LogThis -e " Done"
        fi
    fi

    LogThis -s "Synchronising Override blocklist IPs... "
    ExtractValidIPs "$OVERRIDE_BLOCKLIST_FILEPATH" "${LIST_DIR}block.temp"

    ## Sort the extracted IPs, removing any duplicates
    if ! SORT_BLOCK_OUTPUT=$(LC_ALL=C $SORT_PATH -u "${LIST_DIR}block.temp" -o "${LIST_DIR}block.temp" 2>&1); then
        AbortWithFailure "ERROR: Failed to sort override blocklist. Details: $SORT_BLOCK_OUTPUT"
    fi

    ## Process the override blocklist comparison and sync
    SyncIPSetList "${LIST_DIR}block.temp" "$OVERRIDE_BLOCKLIST_NAME" "${LIST_DIR}block."

    LogThis -s "Validating Override blocklist sync..."
    DumpIPSetToFile "$OVERRIDE_BLOCKLIST_NAME" "${LIST_DIR}block.check"

    ## Exclude anything in both files (-3) - So only lines that are unique to FILE1 or FILE2
    ## [Include the differences between the new and existing] (if it loaded properly, this should be 0)
    if ! COMM_BLOCK_OUTPUT=$( { LC_ALL=C comm -3 "${LIST_DIR}block.temp" "${LIST_DIR}block.check" > "${LIST_DIR}block.validate"; } 2>&1 ); then
        AbortWithFailure "ERROR: Blocklist comm validation failed. Details: $COMM_BLOCK_OUTPUT"
    fi

    COUNT_VALIDATE_BLOCK=$([ -f "${LIST_DIR}block.validate" ] && wc -l < "${LIST_DIR}block.validate" || echo 0)
    if [ "$COUNT_VALIDATE_BLOCK" -eq 0 ]; then
        LogThis -e " Validated successfully"
        VALIDATION_BLOCK_TEXT="OK"
    else
        LogThis -e " ERROR !!! - Sync failed"
        VALIDATION_BLOCK_TEXT="<span style=\"color:red; font-weight:bold;\">FAILED</span>"
        EMAIL_ALERT_TYPE="FAILURE"
    fi

    ## Set email validation status messages for Override run
    if [ "$EMAIL_ALERT_TYPE" = "FAILURE" ]; then
        VALIDATION_STATUS="WARNING - Override sync FAILED"
        VALIDATION_MESSAGE="<p style=\"color:red\"><strong>One or more Overrides failed to synchronise!</strong></p>"
    else
        VALIDATION_STATUS="SUCCESS - Overrides synchronised"
        VALIDATION_MESSAGE="<p>Override lists were successfully synchronised.</p>"
    fi

else

    LogThis ""
    LogThis -s "Downloading the most recent IP list from '$DOWNLOAD_FILE' ..."
    if ! WGET_OUTPUT=$($WGET_PATH --timeout=30 --tries=3 -nv -O "${LIST_DIR}download.staging" "$DOWNLOAD_FILE" 2>&1); then
        AbortWithFailure "IP blocklist could not be downloaded from '$DOWNLOAD_FILE'. Details: $WGET_OUTPUT"
    else
        ## Check the count against the temporary file before confirming success
        TMP_COUNT=$([ -f "${LIST_DIR}download.staging" ] && wc -l < "${LIST_DIR}download.staging" || echo 0)
        if [ "$TMP_COUNT" -lt "$MIN_COUNT" ]; then
            AbortWithFailure "IP blocklist download from '$DOWNLOAD_FILE' failed validation [ Downloaded $TMP_COUNT, below minimum of $MIN_COUNT]"
        else
            ## Download appears to have completely successful, rename the temporary file
            if ! MV_OUTPUT=$(mv "${LIST_DIR}download.staging" "${LIST_DIR}download" 2>&1); then
                AbortWithFailure "ERROR: Failed to move temporary download file to working directory. Details: $MV_OUTPUT"
            fi
            LogThis -e " Successful [$TMP_COUNT]"
        fi
    fi

    ## Take a copy of the original download
    if ! CP_ORIG_OUTPUT=$(cp -f "${LIST_DIR}download" "${LIST_DIR}download.original" 2>&1); then
        AbortWithFailure "ERROR: Failed to create backup copy of original download. Details: $CP_ORIG_OUTPUT"
    fi

    LogThis ""
    LogThis -s "Normalise IPs and filter out invalid/default network paths"
    ExtractValidIPs "${LIST_DIR}download" "${LIST_DIR}download.IPv4"

    ## Copy the IPv4 list to the main file
    if ! CP_IPV4_OUTPUT=$(cp -f "${LIST_DIR}download.IPv4" "${LIST_DIR}download" 2>&1); then
        AbortWithFailure "ERROR: Failed to copy IPv4 filtered list to working file. Details: $CP_IPV4_OUTPUT"
    fi

    COUNT_IPV4=$([ -f "${LIST_DIR}download" ] && wc -l < "${LIST_DIR}download" || echo 0)
    LogThis -e " [$COUNT_IPV4]"

    LogThis -s "Removing duplicate IPs"
    if ! SORT_DEDUPE_OUTPUT=$(LC_ALL=C $SORT_PATH -u "${LIST_DIR}download" -o "${LIST_DIR}download.Dedupe" 2>&1); then
        AbortWithFailure "ERROR: Failed to deduplicate download list. Details: $SORT_DEDUPE_OUTPUT"
    fi

    ## Copy the dedupe output to the main file
    if ! CP_DEDUPE_OUTPUT=$(cp -f "${LIST_DIR}download.Dedupe" "${LIST_DIR}download" 2>&1); then
        AbortWithFailure "ERROR: Failed to copy deduplicated list to working file. Details: $CP_DEDUPE_OUTPUT"
    fi

    COUNT_DEDUPE=$([ -f "${LIST_DIR}download" ] && wc -l < "${LIST_DIR}download" || echo 0)
    LogThis -e " [$COUNT_DEDUPE]"

    LogThis ""
    LogThis "Checking the configuration for '$LISTNAME'..."
    CheckConfigList

    LogThis ""
    LogThis -s "Comparing the New and Existing lists..."

    ## Process the downloaded blocklist comparison and sync
    SyncIPSetList "${LIST_DIR}download" "$IPSET_TARGET_NAME" "${LIST_DIR}"


    ## ========== ========== ========== ========== ========== ##
    ## Validate Blocklist Import                              ##
    ## ========== ========== ========== ========== ========== ##


    LogThis ""
    LogThis -s "Checking imported '$LISTNAME' matches downloaded list..."

    ## Touch validation files so they exist when needed.  Check2 and Validate2 files would not normally exist if Check1 is successful
    if ! TOUCH_OUTPUT=$( { touch "${LIST_DIR}existing.check2" "${LIST_DIR}existing.validate2"; } 2>&1 ); then
        LogThis "    WARNING: Failed to create validation files. Details: $TOUCH_OUTPUT"
    fi

    ## Extract the updated existing list of blacklisted IPs for validation
    DumpIPSetToFile "$IPSET_TARGET_NAME" "${LIST_DIR}existing.check1"

    ## TEST2 - This line is for testing the checking system works.  Uncomment to process
    #sed -i '1,5d' "${LIST_DIR}existing.check1" #TESTING2 ==> REMOVE THE FIRST FIVE LINES FROM THE EXTRACTED LIST FROM THE FIREWALL

    COUNT_EXISTING_CHECK1=$([ -f "${LIST_DIR}existing.check1" ] && wc -l < "${LIST_DIR}existing.check1" || echo 0)
    COUNT_CURRENT_DOWNLOAD=$([ -f "${LIST_DIR}download" ] && wc -l < "${LIST_DIR}download" || echo 0)
    LogThis -m " Filtered Download [$COUNT_CURRENT_DOWNLOAD] ... Filtered Existing [$COUNT_EXISTING_CHECK1] ..."

    ## Use COMM to filter the items:
    ## Exclude anything in both files (-3) - So only lines that are unique to FILE1 or FILE2
    ## [Include the differences between the new and existing] (if it loaded properly, this should be 0)
    if ! COMM_VAL1_OUTPUT=$( { LC_ALL=C comm -3 "${LIST_DIR}download" "${LIST_DIR}existing.check1" > "${LIST_DIR}existing.validate1"; } 2>&1 ); then
        AbortWithFailure "ERROR: Comm validation 1 failed. Details: $COMM_VAL1_OUTPUT"
    fi

    COUNT_VALIDATE1=$([ -f "${LIST_DIR}existing.validate1" ] && wc -l < "${LIST_DIR}existing.validate1" || echo 0)

    if [ "$COUNT_VALIDATE1" -eq 0 ]; then
        LogThis -e " Validated"
        ## All validated correctly
        VALIDATION_STATUS="SUCCESS - Updated with the newest IP list"
        VALIDATION_MESSAGE="<p>IP Blocklist script successfully updated the IP set with the newest IP list</p>"
        VALIDATION_CHECK1=""
        VALIDATION_CHECK2="display:none;"
    else
        LogThis -e " ERROR !!! - They don't match"
        EMAIL_ALERT_TYPE="FAILURE"
        LogThis "An error occurred with importing the download"
        ## Call the ResetList function to clear the IPTables configuration for this list
        LogThis ""
        LogThis "Resetting the chain"
        ResetList
        ## Call the CheckConfigList function to create new configuration
        LogThis "Creating a new chain"
        CheckConfigList
        LogThis ""
        LogThis -s "Importing the previous existing list..."
        if ! RESTORE_OUTPUT=$(sed "s/^/add $IPSET_TARGET_NAME /" "${LIST_DIR}existing" | $IPSET_PATH -! restore 2>&1); then
            AbortWithFailure "ERROR: ipset restore (restore previous) encountered an issue for $IPSET_TARGET_NAME: $RESTORE_OUTPUT. Firewall state may be inconsistent."
        fi
        LogThis -e " Done"

        #### Re-check
        LogThis -s "Re-checking restored '$LISTNAME' version matches original existing..."
        DumpIPSetToFile "$IPSET_TARGET_NAME" "${LIST_DIR}existing.check2"

        ## TEST3 - This line is for testing the checking system works.  Uncomment to process
        #sed -i '1,5d' "${LIST_DIR}existing.check2" #TESTING3 ==> REMOVE THE FIRST FIVE LINES FROM THE ORIGINAL REIMPORT FROM THE FIREWALL

        COUNT_EXISTING_CHECK2=$([ -f "${LIST_DIR}existing.check2" ] && wc -l < "${LIST_DIR}existing.check2" || echo 0)
        COUNT_ORIGINAL_EXISTING=$([ -f "${LIST_DIR}existing" ] && wc -l < "${LIST_DIR}existing" || echo 0)
        LogThis -m " Original [$COUNT_ORIGINAL_EXISTING] - Current [$COUNT_EXISTING_CHECK2] ..."

        ## Use COMM to filter the items:
        ## Exclude anything in both files (-3) - So only lines that are unique to FILE1 or FILE2
        ## [Include the differences between the original existing and restored existing] (if it loaded properly, this should be 0)
        if ! COMM_VAL2_OUTPUT=$( { LC_ALL=C comm -3 "${LIST_DIR}existing" "${LIST_DIR}existing.check2" > "${LIST_DIR}existing.validate2"; } 2>&1 ); then
            AbortWithFailure "ERROR: Comm validation 2 failed. Details: $COMM_VAL2_OUTPUT"
        fi

        COUNT_VALIDATE2=$([ -f "${LIST_DIR}existing.validate2" ] && wc -l < "${LIST_DIR}existing.validate2" || echo 0)

        if [ "$COUNT_VALIDATE2" -eq 0 ]; then
            LogThis -e " Validated"
            ## Restoring the previous list worked
            VALIDATION_STATUS="ERROR - Newest IP list update Failure"
            VALIDATION_MESSAGE="<p style=\"color:red; font-weight:bold;\">VALIDATION FAILED - Reverted to previous known good list</p>"
            VALIDATION_CHECK1="color:red; font-weight:bold;"
            VALIDATION_CHECK2=""
        else
            LogThis -e " ERROR !!! - Still an issue"
            ## Restoring the previous list failed too
            VALIDATION_STATUS="ERROR - CRITICAL FAILURE"
            VALIDATION_MESSAGE="<p style=\"color:red; font-weight:bold;\">VALIDATION FAILED - UNABLE TO REVERT TO PREVIOUS KNOWN GOOD LIST</p>"
            VALIDATION_CHECK1="color:red; font-weight:bold;"
            VALIDATION_CHECK2="color:red; font-weight:bold;"
            EMAIL_ALERT_TYPE="CRITICAL"
        fi
    fi
fi


## ========== ========== ========== ========== ========== ##
## Finalise & Save                                        ##
## ========== ========== ========== ========== ========== ##


# Save the new firewall state, ignore Fail2Ban rules, and make it persistent
SavePersistentFirewall

TIME_DIFF=$(($(date +"%s%3N")-${TIME_START}))
LogThis ""
LogThis "Process finished in ${TIME_DIFF} Milliseconds."

SUBJECT+="$VALIDATION_STATUS"

## Build the HTML email table based on the execution type
if [ "$SYNC_OVERRIDES_ONLY" = true ]; then
    WC_OVERRIDE_ALLOW_ORIG=$([ -f "$OVERRIDE_ALLOWLIST_FILEPATH" ] && wc -l < "$OVERRIDE_ALLOWLIST_FILEPATH" || echo "-")
    WC_OVERRIDE_ALLOW_ADD=$([ -f "${LIST_DIR}allow.add" ] && wc -l < "${LIST_DIR}allow.add" || echo "-")
    WC_OVERRIDE_ALLOW_REM=$([ -f "${LIST_DIR}allow.rem" ] && wc -l < "${LIST_DIR}allow.rem" || echo "-")
    WC_OVERRIDE_BLOCK_ORIG=$([ -f "$OVERRIDE_BLOCKLIST_FILEPATH" ] && wc -l < "$OVERRIDE_BLOCKLIST_FILEPATH" || echo "-")
    WC_OVERRIDE_BLOCK_ADD=$([ -f "${LIST_DIR}block.add" ] && wc -l < "${LIST_DIR}block.add" || echo "-")
    WC_OVERRIDE_BLOCK_REM=$([ -f "${LIST_DIR}block.rem" ] && wc -l < "${LIST_DIR}block.rem" || echo "-")

    TABLE_ROWS="
            <tr><td><b>OVERRIDE DETAILS</b></td><td>&nbsp;</td></tr>
            <tr><td>Override Allowlist Status</td><td>$VALIDATION_ALLOW_TEXT</td></tr>
            <tr><td>Override Allow (original)</td><td>$WC_OVERRIDE_ALLOW_ORIG</td></tr>
            <tr><td>Override Allowlist Additions</td><td>$WC_OVERRIDE_ALLOW_ADD</td></tr>
            <tr><td>Override Allowlist Removals</td><td>$WC_OVERRIDE_ALLOW_REM</td></tr>
            <tr><td>Override Blocklist Status</td><td>$VALIDATION_BLOCK_TEXT</td></tr>
            <tr><td>Override Block (original)</td><td>$WC_OVERRIDE_BLOCK_ORIG</td></tr>
            <tr><td>Override Blocklist Additions</td><td>$WC_OVERRIDE_BLOCK_ADD</td></tr>
            <tr><td>Override Blocklist Removals</td><td>$WC_OVERRIDE_BLOCK_REM</td></tr>
    "
else
    WC_EXISTING=$([ -f "${LIST_DIR}existing" ] && wc -l < "${LIST_DIR}existing" || echo "-")
    WC_ORIGINAL=$([ -f "${LIST_DIR}download.original" ] && wc -l < "${LIST_DIR}download.original" || echo "-")
    WC_IPV4=$([ -f "${LIST_DIR}download.IPv4" ] && wc -l < "${LIST_DIR}download.IPv4" || echo "-")
    WC_DEDUPE=$([ -f "${LIST_DIR}download.Dedupe" ] && wc -l < "${LIST_DIR}download.Dedupe" || echo "-")
    WC_FILE=$([ -f "${LIST_DIR}download" ] && wc -l < "${LIST_DIR}download" || echo "-")
    WC_ADD=$([ -f "${LIST_DIR}add" ] && wc -l < "${LIST_DIR}add" || echo "-")
    WC_REM=$([ -f "${LIST_DIR}rem" ] && wc -l < "${LIST_DIR}rem" || echo "-")
    WC_CHECK1=$([ -f "${LIST_DIR}existing.check1" ] && wc -l < "${LIST_DIR}existing.check1" || echo "-")
    WC_VALIDATE1=$([ -f "${LIST_DIR}existing.validate1" ] && wc -l < "${LIST_DIR}existing.validate1" || echo "-")
    WC_CHECK2=$([ -f "${LIST_DIR}existing.check2" ] && wc -l < "${LIST_DIR}existing.check2" || echo "-")
    WC_VALIDATE2=$([ -f "${LIST_DIR}existing.validate2" ] && wc -l < "${LIST_DIR}existing.validate2" || echo "-")

    TABLE_ROWS="
            <tr><td><b>DETAILS</b></td><td>&nbsp;</td></tr>
            <tr><td>Originally Loaded</td><td>$WC_EXISTING</td></tr>
            <tr><td>Downloaded</td><td>$WC_ORIGINAL</td></tr>
            <tr><td><b>PROCESSING</b></td><td>&nbsp;</td></tr>
            <tr><td>IPv4 Filtered</td><td>$WC_IPV4</td></tr>
            <tr><td>Dedupe Filtered</td><td>$WC_DEDUPE</td></tr>
            <tr><td>Total Download Blocked</td><td>$WC_FILE</td></tr>
            <tr><td>Added</td><td>$WC_ADD</td></tr>
            <tr><td>Removed</td><td>$WC_REM</td></tr>
            <tr><td><b>VALIDATION</b></td><td>&nbsp;</td></tr>
            <tr style=\"$VALIDATION_CHECK1\"><td>Check (should match 'Total Download Blocked')</td><td>$WC_CHECK1</td></tr>
            <tr style=\"$VALIDATION_CHECK1\"><td>Validation Difference (should be zero)</td><td>$WC_VALIDATE1</td></tr>
            <tr style=\"$VALIDATION_CHECK2\"><td>Restore Check (should match 'Originally Loaded')</td><td>$WC_CHECK2</td></tr>
            <tr style=\"$VALIDATION_CHECK2\"><td>Restore Validation Difference (should be zero)</td><td>$WC_VALIDATE2</td></tr>
    "
fi

CaptureLogContent

BODY="
<html>
    <head></head>
    <body>
        $VALIDATION_MESSAGE
        <!-- <br/><br/> -->
        <table>
            <tr><td><b>SETUP</b></td><td>&nbsp;</td></tr>
            <tr><td>Start From Scratch</td><td>$START_FROM_SCRATCH</td></tr>
            <tr><td>List Name</td><td>$LISTNAME</td></tr>
            $TABLE_ROWS
            <tr><td><b>SUMMARY</b></td><td>&nbsp;</td></tr>
            <tr><td>Duration</td><td>${TIME_DIFF} Milliseconds.</td></tr>
            <tr><td>Date</td><td>$(date "+%F %T.%3N (%Z)")</td></tr>
        </table>
        <br/><br/><b>Execution Log:</b><br/>
        <pre style=\"background-color: #f4f4f4; padding: 10px; font-size: 12px; overflow-x: auto;\">$CAPTURED_LOG_CONTENT</pre>
    </body>
</html>
"

SendEmailNow "$EMAIL_ALERT_TYPE" "$SUBJECT" "$BODY"

## If DELETE_ALL_FILES_ON_COMPLETION is set, delete all files on completion.
if [ "$DELETE_ALL_FILES_ON_COMPLETION" = true ]; then DeleteAllFiles; fi

EndLogAndExit "0"