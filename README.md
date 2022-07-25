  # aubs-blocklist-importer
  Blocklist import script for IPTools/IPSet
  https://github.com/AubsUK/aubs-blocklist-importer

# Information
This is a simple blocklist import script that works with single IPv4 addresses (no ranges or IPv6 support yet).
- Runs automatically (via Cron)
- Imports a list of IPs to block from a URL text file
- Strips out anything non-IPv4 related
- Removes duplicates
- Custom lists to override the importing blocklist
  - Allow list - Never block anything on this list even if it *is* in the download (e.g. your own or customer IPs)
  - Block list - Always block anything on this list even if it *isn't* in the download (e.g. IPs of frequent attackers or spammers)
- Checks for an existing chain and that everything is already set up, or creates them
- Compares the new import blocklist against the existing blocked list
  - only import new IPs
  - removes old IPs not on the new list
- Checks the new live list matches the filtered import list
  - If it doesn't, it clears the configuration and tries to re-import the previous (known-good) list
  - If then checks if the re-import of the known-good list is successful 
- Full logging
- Email notifications



  # Quick Start
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


  # Configurable Options

  <table>
  <tr><th>Variable</th><th>Description</th><th>Default</th></tr>
  <tr>
  <td colspan=3>

  ### General

  </td>
  </tr>
  <tr>
  <td>

  `START_FROM_SCRATCH`

  </td>
  <td>
  Clear out the IPTable and IPSet for the $CHAINNAME on each run
  </td>
  <td>
  false
  </td>
  </tr>
  <tr>
  <td>

  `DELETE_ALL_FILES_ON_COMPLETION`

  </td>
  <td>
  Delete the temporary files on completion, useful for debugging if something is wrong with the block lists
  </td>
  <td>
  true
  </td>
  </tr>
  <tr>
  <td colspan=3>

  ### Basic Settings

  </td>
  </tr>
  <tr>
  <td>

  `DOWNLOAD_FILE`

  </td>
  <td>
  URL of the text file which contains all the IPs to use
  </td>
  <td>
  http://lists.blocklist.de/lists/all.txt
  </td>
  </tr>
  <tr>
  <td>

  `CHAINNAME`

  </td>
  <td>
  Name of the chain to import the IPs in to
  </td>
  <td>
  blocklist-de
  </td>
  </tr>
  <tr>
  <td>

  `ACTION`

  </td>
  <td>
  The action script should apply to the firewall rule<br>Either ALLOW (for known IPs), BLOCK, or REJECT for this Chain
  </td>
  <td>
  REJECT
  </td>
  </tr>
  <tr>
  <td colspan=3>

  ### Base defaults

  </td>
  </tr>
  <tr>
  <td>

  `BASE_PATH`

  </td>
  <td>
  /path/to/ temp files location
  <td>

  Uses `$PathOfScript` which uses the location of the script file

  </td>
  </tr>
  <tr>
  <td>

  `BLOCKLIST_BASE_FILE`

  </td>
  <td>
  Base filename for the temporary files created
  </td>
  <td>
  ip-blocklist
  </td>
  </tr>
  <tr>
  <td colspan=3>

  ### E-Mailnotification variables

  </td>
  </tr>
  <tr>
  <td>

  `SENDER_NAME`

  </td>
  <td>
  Display name of the sender
  </td>
  <td>
  Notifications
  </td>
  </tr>
  <tr>
  <td>

  `SENDER_EMAIL`

  </td>
  <td>
  Senders email address
  </td>
  <td>

  Automatically configured to `notifications@server.domain.co.uk`<br/>(where server.domain.co.uk is provided automatically from `hostname -f`)

  </td>
  </tr>
  <tr>
  <td>

  `RECIPIENT_EMAIL`

  </td>
  <td>
  Recipient email address<br/>(multuple recipients separated by commas)
  </td>
  <td>

  Automatically configured to `servers@domain.co.uk`<br/>(where domain.co.uk is provided automatically from `hostname -d`)

  </td>
  </tr>
  <tr>
  <td>

  `SUBJECT`

  </td>
  <td>
  Start of the subject for success and failure emails
  </td>
  <td>

  `server.domain.co.uk - IP blocklist update - `<br/>(where server.domain.co.uk is provided from `hostname -f`)

  </td>
  </td>
  </tr>
  <tr>
  <td colspan=3>

  ### Permanent Files

  </td>
  </tr>
  <tr>
  <td>

  `OVERRIDE_ALLOWLIST_PATH`

  </td>
  <td>
  Location of the override allow-list
  </td>
  <td>

  The same as `$BASE_PATH`

  </td>
  </tr>
  <tr>
  <td>

  `OVERRIDE_ALLOWLIST_FILE`

  </td>
  <td>
  Filename of the override allow-list
  </td>
  <td>
  override-allowlist.txt
  </td>
  </tr>
  <tr>
  <td>

  `OVERRIDE_BLOCKLIST_PATH`

  </td>
  <td>
  Location of the override block-list
  </td>
  <td>

  The same as `$BASE_PATH`

  </td>
  </tr>
  <tr>
  <td>

  `OVERRIDE_BLOCKLIST_FILE`

  </td>
  <td>
  Filename of the override allow-list
  </td>
  <td>
  override-blocklist.txt
  </td>
  </tr>
  <tr>
  <td>

  `LOGFILE_PATH`

  </td>
  <td>
  Location of the log file
  </td>
  <td>

  A new directory in the /var/log/ path called `/var/log/aubs-blocklist-import/`

  </td>
  </tr>
  <tr>
  <td>

  `LOGFILE_FILE`

  </td>
  <td>
  Filename of the log file
  </td>
  <td>
  aubs-blocklist.log
  </td>
  </tr>
  </table>






# Planned changes (in no particular order)
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
8. Work with subnets, expand them to individual IPs or if IPSet allows them.
9. Enable/Disable email notifications, or set them to only send every X days.
10. Using the same chain with multiple blocklists (perhaps download all at once, then filter through before adding - Size limitations?).
11. --DONE-- ~~Check import was successful~~
12. Warn if any 'override allow' exist in the blocklist



# NOTES
This script was born through the need for a script to do exactly what I wanted.  I took a lot of inspiration from [Lexo.ch](https://www.lexo.ch/blog/2019/09/blocklist-de-iptables-ipset-update-script-how-to-automatically-update-your-firewall-with-the-ip-set-from-blocklist-de/), and lots of support from [Stack Overflow](https://stackoverflow.com/) and related sites, along with may other sites.
