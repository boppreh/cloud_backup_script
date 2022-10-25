#!/usr/bin/env bash

# update_cloud_backup.sh
#
# Uploads local files to a cloud backup.
# 
# Intended for immutable files like photos and videos, and therefore can give better warnings when those are corrupted.
# Assumes a remote host capable of running sha256sum and df (tested on Hetzner Storage Box's FreeBSD and restricted hsh shell).
# Pings are sent to healthchecks.io on start and end, so that alerts are sent if the script fails or doesn't execute often enough.
#
# Scenarios covered:
# - There's a new local file. Copy it to the cloud backup.
# - The cloud backup has a file that doesn't exist locally. Warn.
# - The checksum of a local or a remote file has changed from a previous run (ransomware, bit rot, etc). Warn.
# - The script hasn't run in X days. Warn (via healthchecks.io).
# - The script is taking too long and executions are overlapping. Don't run.
# - The script is taking too long but there's been no progress in checksums or rsync logs over 10 hours. Run normally.
# - Any of the main steps printed anything to stderr. Warn.
#
# Note that the script never changes or deletes any files, locally or in the cloud backup, preferring instead to warn of a possible issue.

###
# Default variables (please override them on vars.sh, not here)
###

# The commented-out variables below must be declared in vars.sh, so that they are not exposed in Git and updates to the script won't overwrite their values.
# The other variables provide default values, unless overridden by vars.sh later on.

# Username and hostname of the remote machine to store the backups.
# Highly recommended to set up SSH public key authentication, so that the script can run unattended without interaction.
#REMOTE=u12345-sub1@u12345.your-storagebox.de

# SSH port, 23 for Hetzner Storage Box, 22 for most others.
#SSH_OPTS=-p23

# Your Healthecks.io URL for reporting statuses. This is critical to get alerts!
# Create a free account at https://healthchecks.io/ and configure the expected schedule (e.g. daily pings, with alerts after 3 days).
#HEALTHCHECKS_IO_URL='https://hc-ping.com/GUID'

# The base location, all further paths will be relative to this.
#BASE_DIR="/d"
# The directory to be uploaded, relative to $BASE_DIR. The same structure will copied to the cloud backup,
# so that "media/camera/" is backed up as $REMOTE:~/media/camera, regardless of $BASE_DIR.
#RELATIVE_DIR_TO_BACKUP="media/camera/"

# On every run the oldest $N_CHECKSUM_PER_RUN files from $CHECKSUMS will be hashed both locally and remotely to verify integrity.
N_CHECKSUM_PER_RUN=100
CHECKSUMS=checksums.txt

# Warn if the remote storage is over 80% capacity.
MAX_CAPACITY_PERCENT=80

# Temporary files deleted at the end of the run.
LOCKFILE=.update_in_progress
LOCAL_FILES_LIST=local_files.txt

# Logging. $ERRORS is expected to be empty on a normal run.
mkdir -p logs
ERRORS="logs/$(date +%F)_ERRORS.txt"
RSYNC_LOGS="logs/$(date +%F)_rsync_logs.txt"
STDOUT_LOGS="logs/$(date +%F)_script_stdout.txt"


###
# SETUP
###

if ! test -f vars.sh;
    then echo "Please create vars.sh with the required values. See README.md for more instructions. Exiting..."
    exit 1
fi

# Load the preferred vars with higher priority. This might overwrite the values seen above.
source vars.sh

# The /./ is required by rsync to set the relative path on the remote side.
DIR_TO_BACKUP="$BASE_DIR/./$RELATIVE_DIR_TO_BACKUP"

if ! test -d "$DIR_TO_BACKUP";
    then echo "'$BASE_DIR/$RELATIVE_DIR_TO_BACKUP' is not a valid directory. Exiting..."
    exit 1
fi

if test -z "$REMOTE" || test -z "$SSH_OPTS" || test -z "$HEALTHCHECKS_IO_URL" || test -z "$DIR_TO_BACKUP"; then
    echo "The file vars.sh doesn't contain all the required variables set. See README.md for more instructions. Exiting..."
    exit 1
fi

set -o nounset

# Don't run if the lockfile exists.
if test -f "$LOCKFILE" ; then
    echo "A cloud backup update is already in progress. Exiting..." | tee >(curl --retry 3 -d @- "$HEALTHCHECKS_IO_URL/1" >/dev/null)
    exit 1
fi
touch "$LOCKFILE"
touch "$ERRORS"
touch "$STDOUT_LOGS"
touch "$RSYNC_LOGS"


###
# Run
###

curl --retry 3 "$HEALTHCHECKS_IO_URL/start" >/dev/null

(

    echo "###"
    echo "Uploading any new files"
    echo "###"
    # List all local files by syncing to an empty dir. Yes, really.
    rsync --dry-run --relative --recursive --itemize-changes --exclude='*.nomedia' "$DIR_TO_BACKUP" "$(mktemp -d --dry-run)" | grep -F '>f+++++++++' | cut -d" " -f 2- | sort --unique > "$LOCAL_FILES_LIST"
    # Some characters are too much trouble to handle in filenames, just refuse to run. Note that they are all invalid under Windows anyway.
    grep -E $'[\\\"*>$]' "$LOCAL_FILES_LIST" >&2 && exit

    # Upload any new files without modifying or deleting existing ones.
    rsync --files-from="$LOCAL_FILES_LIST" --stats --info=progress2 --archive --relative --max-delete=-1 --ignore-existing --partial-dir=.rsync-partial --rsh "ssh $SSH_OPTS" --log-file="$RSYNC_LOGS" "$BASE_DIR" "$REMOTE":
    # TODO: remove write permission on remote files after upload.
    echo

    echo "###"
    echo "Checking for missing local files"
    echo "###"
    # Dry-run of a restore, catches any missing local files or files that have timestamp/size changed (which were skipped by --ignore-existing on the previous run).
    rsync --dry-run --itemize-changes --archive --no-perms --relative --max-delete=-1 --exclude={'*.nomedia','.hsh_history','.ssh/'} --rsh "ssh $SSH_OPTS" --log-file="$RSYNC_LOGS" "$REMOTE": "$BASE_DIR" | grep -E '^[.><]f' 1>&2
    echo

    echo "###"
    echo "Computing checksums for any new local files"
    echo "###"
    # List all files not present in the checksums list, and compute their checksums.
    # `tr` is used to remove the asterisk from sha256sum output for FreeBSD (Hetzner Storage Box) compatibility.
    brand_new_checksums=$(grep -oFf "$LOCAL_FILES_LIST" "$CHECKSUMS" | grep -vFf - "$LOCAL_FILES_LIST" | (cd "$BASE_DIR" || exit; xargs --no-run-if-empty --delimiter='\n' sha256sum) | tr -d '*')
    echo "$brand_new_checksums"
    echo

    echo "###"
    echo "Protecting new files in remote host"
    echo "###"
    # Mark the new files as read-only on remote host.
    awk '{print "chmod -w " "\"" $0 "\""}' "$LOCAL_FILES_LIST" | ssh -T "$SSH_OPTS" "$REMOTE"
    echo

    echo "###"
    echo "Checking integrity of $N_CHECKSUM_PER_RUN old files"
    echo "###"
    # Pick the $N_CHECKSUM_PER_RUN oldest (top of the list) files to check integrity by recomputing the checksum.
    old_checksums=$(head -n "$N_CHECKSUM_PER_RUN" "$CHECKSUMS")

    # Compute new checksums (FreeBSD's sha256sum doesn't append a * before each file, so we manually remove it that from local results).
    new_local_checksums=$(echo "$old_checksums" | cut -d" " -f 2- | (cd "$BASE_DIR" || exit; xargs --no-run-if-empty --delimiter='\n' sha256sum) | tr -d '*')
    new_cloud_checksums=$(echo "$old_checksums" | cut -d" " -f 2- | awk '{print "sha256sum " "\"" $0 "\""}' | ssh -T "$SSH_OPTS" "$REMOTE" | tr -d '*')

    # Any difference is considered an error.
    diff <(echo "$old_checksums") <(echo "$new_local_checksums") 1>&2
    diff <(echo "$old_checksums") <(echo "$new_cloud_checksums") 1>&2

    # Print the checksums to prove we did something.
    echo "$new_local_checksums"

    # Rotate old checksums and add the ones for new files. Note that we use don't use $new_local_checksums, in case the files got corrupted.
    # Other solutions with `tee -a "$CHECKSUMS"`` failed because an empty line would sneak-in somehow.
    full_checksums=$(cat <(echo "$brand_new_checksums") <(sed 1,"$N_CHECKSUM_PER_RUN"d "$CHECKSUMS") <(echo "$old_checksums"))
    echo "$full_checksums" | grep '\S' > "$CHECKSUMS"
    echo

    echo "###"
    echo "Downloading a random file"
    echo "###"
    random_file=$(shuf -n1 "$LOCAL_FILES_LIST")
    checksum=$(ssh "$SSH_OPTS" "$REMOTE" "cat \"$random_file\"" | sha256sum -b | cut -d" " -f 1)
    grep -F "$checksum $random_file" "$CHECKSUMS" >/dev/null || echo "Incorrect hash $checksum for downloaded sample file $random_file" >&2
    echo

    # Only remove the file if the subshell didn't die.
    rm "$LOCAL_FILES_LIST"

) 2> >(tee -a "$ERRORS" >&2) 1> >(tee -a "$STDOUT_LOGS")

capacity=$(ssh "$SSH_OPTS" "$REMOTE" "df -h ." | grep -oP '[0-9]+(?=%)')
if test "$capacity" -ge "$MAX_CAPACITY_PERCENT"; then
    echo "LOW SPACE: remote capacity $capacity% is greater than $MAX_CAPACITY_PERCENT%" >> "$ERRORS"
fi

n_errors=$(wc -l < "$ERRORS")

echo "Cloud storage at $capacity% capacity after uploading $DIR_TO_BACKUP in $SECONDS seconds. $n_errors lines in errors file. Last rsync log line: $(tail -n 1 "$RSYNC_LOGS")" \
| tee -a "$STDOUT_LOGS" >(curl --retry 3 -d @- "$HEALTHCHECKS_IO_URL/$n_errors" >/dev/null)


###
# Cleanup
###

rm "$LOCKFILE"
exit "$n_errors"
