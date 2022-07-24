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
Edit ```override-allowlist.txt``` and ```override-blocklist.txt``` to include IPs to never block (e.g. your own servers) and always block (servers who frequently attack you)

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
