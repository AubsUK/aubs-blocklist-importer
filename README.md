# aubs-blocklist-importer
Blocklist import script for IPTools/IPSet





## Quick Start
Clone the repository
```
git clone https://github.com/AubsUK/aubs-blocklist-importer
```
or just create the three files manually, and copy their contents

Make the script executable
```
cd aubs-blocklist-importer
chmod 700 aubs-blocklist-importer.sh
```
Edit ```override-allowlist.txt``` and ```override-blocklist.txt``` to include IPs to never block (e.g. your own servers) and always block (servers who frequently attack you)<br/>

Add an entry into Cron
```
sudo nano /etc/crontab
```
Add in:
```
# Blocklist Importer
30 1 * * * root /Path/To/aubs-blocklist-importer/aubs-blocklist-import.sh
```
**Note:** Make it as frequent as required (within reason, check the blocklist's website to confirm the maximum); You shouldn't use root, so will need to create a user account, allow it to edit the log files and run the script etc.)

## Basic settings

- ```START_FROM_SCRATCH=``` - Use this to clear out the IPTable and IPSet for the $CHAINNAME on each run.<br/>
- ```DELETE_ALL_FILES_ON_COMPLETION=```  - Use this to delete the temporary files on completion, useful for debugging if something is wrong with the block lists.

### Basic Settings
- ```DOWNLOAD_FILE=``` - The URL of the text file which contains all the IPs to use.<br/>
- ```CHAINNAME=``` - The name of the chain to import the IPs in to.<br/>
- ```ACTION=``` - The action you want the script to apply to the firewall rule, either ALLOW (for known IPs), BLOCK, or REJECT for this Chain.<br/>

### Base defaults
- ```BASE_PATH=``` - The /location/of/ where the temp files should be stored, this also applies to override files.  Default uses `$PathOfScript` which uses the location of the script file.<br/>
- ```BLOCKLIST_BASE_FILE=``` - The base filename for the temporary files created.  Default is `ip-blocklist`.

### E-Mail variables
- ```SENDER_NAME=``` - The display name of the sender for notifications email.  Default is `Notifications`.<br/>
- ```SENDER_EMAIL=``` - The sender email address for notification emails.  Default is automatically configured to `notifications@server.domain.co.uk` (where `server.domain.co.uk` is provided automatically from `hostname -f`).<br/>
- ```RECIPIENT_EMAIL=``` - The recipient email address, multuple recipients can be separated by commas.  Default is automatically configured to `servers@domain.co.uk` (where `domain.co.uk` is provided automatically from `hostname -d`).<br/>
- ```SUBJECT=``` - The start part of the subject for success and failure emails.  Default is `server.domain.co.uk - IP blocklist update - ` (where `server.domain.co.uk` is provided from `hostname -f`).<br/>

### Permanent Files
- ```OVERRIDE_ALLOWLIST_PATH=``` - This is the <u>location</u> of the override allow-list.  Default is the same as `$BASE_PATH`.<br/>
- ```OVERRIDE_ALLOWLIST_FILE=``` - This is the **filename** of the override allow-list.  Default is `override-allowlist.txt`.<br/>
- ```OVERRIDE_BLOCKLIST_PATH=``` - This is the **location** of the override block-list.  Default is the same as `$BASE_PATH`.<br/>
- ```OVERRIDE_BLOCKLIST_FILE=``` - This is the **filename** of the override allow-list.  Default is `override-blocklist.txt`.<br/>
- ```LOGFILE_PATH=``` - This is the **location** of the log file.  Default is a new directory in the `/var/log/` path `/var/log/aubs-blocklist-import/`.<br/>
- ```LOGFILE_FILE=``` - This is the **filename** of the log file.  Default is `aubs-blocklist.log`.


## Planned changes (in no particular order)
1. Allow cron to take the download file and chain name as variables
2. Incorporate IPv6 IP addresses
3. If a firewall rule exists in the chain, check if the ACTION is the same each time and change if it's different e.g. DROP to REJECT
4. Check if the path is a path or a file/path for all variables
```
  BASE_PATH_CheckPath=${BASE_PATH%/*}
  BASE_PATH_CheckFile=${BASE_PATH##*/}
  echo "PATH [ $BASE_PATH_CheckPath ]"
  echo "FILE [ $BASE_PATH_CheckFile ]"
```
5. Check if BASE_PATH is a valid and/or a 'bad' path like in /proc/ or something
6. --DONE-- ~~Change logging to give the option to enter additional test (e.g. 'done' at the end of the previous logged line~~
7. Consider removing the variables for the programs being used, I don't really think these are necessary because the ones being used are mostly 'standard' - Check if they are POSIX, or alternatives.  Most others being used are: date, touch, echo, if, exit, rm, mv, cp, wc, sed, comm, cat.
