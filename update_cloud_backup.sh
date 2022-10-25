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

set -o nounset

# Because these values are sensitive, these are only examples. Copy the lines below that you want to edit and place them in `vars.sh`.
REMOTE=u12345@u12345.your-storagebox.de # https://www.hetzner.com/storage/storage-box
SSH_OPTS=-p23
HEALTHCHECKS_IO_URL='https://hc-ping.com/GUID' # https://healthchecks.io/

# Location of local directories to be uploaded.
BASE_PATH="/d"
RELATIVE_DIR_TO_BACKUP="media/camera/" # Must be relative to $BASE_PATH. Will define the remote structure, e.g. $REMOTE:~/media/camera .

DIRS_TO_BACKUP="$BASE_PATH/./$RELATIVE_DIR_TO_BACKUP" # The "/./" defines the relative paths for rsync.

# On every run the oldest $N_CHECKSUM_PER_RUN files from $CHECKSUMS will be hashed both locally and remotely to verify consistency.
N_CHECKSUM_PER_RUN=100
CHECKSUMS=checksums.txt

# Temporary files deleted at the end of the run.
LOCKFILE=.update_in_progress
LOCAL_FILES=local_files.txt

# Logging. $ERRORS is expected to be empty on a normal run.
mkdir -p logs
ERRORS="logs/$(date +%F)_ERRORS.txt"
RSYNC_LOGS="logs/$(date +%F)_rsync_logs.txt"
STDOUT_LOGS="logs/$(date +%F)_script_stdout.txt"

# Load the preferred vars with higher priority.
source vars.sh

#############

# Don't run if the lockfile exists and the log or hash files have been updated in over ten hours. The second check is to prevent a stray lock file from stopping all future backups.
if test -f "$LOCKFILE" && test "$(find "$CHECKSUMS" "$LOCAL_FILES" "$RSYNC_LOGS" -mmin -600 2> /dev/null)"; then
    echo "A cloud backup update is already in progress. Exiting..."
    exit 1
fi
touch "$LOCKFILE"
touch "$ERRORS"
touch "$STDOUT_LOGS"
touch "$RSYNC_LOGS"

curl --retry 3 "$HEALTHCHECKS_IO_URL/start" > /dev/null

(

    echo "###"
    echo "Listing local files"
    echo "###"
    rsync --dry-run --relative --recursive --itemize-changes --exclude='*.nomedia' "$DIRS_TO_BACKUP" "$(mktemp -d --dry-run)" | grep -F '>f+++++++++' | cut -d" " -f 2- | sort --unique > "$LOCAL_FILES"
    echo

    echo "###"
    echo "Uploading new files"
    echo "###"
    rsync --files-from="$LOCAL_FILES" --stats --progress --info=progress2 --archive --relative --max-delete=-1 --ignore-existing --partial-dir=.rsync-partial --rsh "ssh $SSH_OPTS" --log-file="$RSYNC_LOGS" "$BASE_PATH" "$REMOTE":
    echo

    echo "###"
    echo "Checking for missing local files"
    echo "###"
    rsync --dry-run --itemize-changes --archive --relative --max-delete=-1 --ignore-existing --exclude={'*.nomedia','.hsh_history','.ssh/'} --rsh "ssh $SSH_OPTS" --log-file="$RSYNC_LOGS" "$REMOTE": "$BASE_PATH" | grep -F '>f+++++++++' 1>&2
    echo

    echo "###"
    echo "Computing checksums for any new local files"
    echo "###"
    brand_new_checksums=$(grep -oFf "$LOCAL_FILES" "$CHECKSUMS" | grep -vFf - "$LOCAL_FILES" | (cd "$BASE_PATH" || exit; xargs --no-run-if-empty --delimiter='\n' sha256sum) | tr -d '*')
    echo

    echo "###"
    echo "Checking consistency of $N_CHECKSUM_PER_RUN old files"
    echo "###"
    # Pick the $N_CHECKSUM_PER_RUN oldest (top of the file) files to check consistency by recomputing the checksum.
    old_checksums=$(head -n "$N_CHECKSUM_PER_RUN" "$CHECKSUMS")

    # Compute new checksums (FreeBSD's sha256sum doesn't append a * before each file, so we manually remove it that from local results).
    new_local_checksums=$(echo "$old_checksums" | cut -d" " -f 2- | (cd $BASE_PATH || exit; xargs --no-run-if-empty --delimiter='\n' sha256sum) | tr -d '*')
    new_cloud_checksums=$(echo "$old_checksums" | cut -d" " -f 2- | awk '{print "sha256sum " "\"" $0 "\""}' | ssh -T "$SSH_OPTS" "$REMOTE" | tr -d '*')

    # Any difference is considered an error.
    diff <(echo "$old_checksums") <(echo "$new_local_checksums") 1>&2
    diff <(echo "$old_checksums") <(echo "$new_cloud_checksums") 1>&2

    # Print the checksums to prove we did something.
    echo "$new_local_checksums"

    # Remove old checksums and append new. Other solutions with `tee -a "$CHECKSUMS"`` failed because an empty line would sneak-in somehow.
    full_checksums=$(cat <(echo "$brand_new_checksums") <(sed 1,"$N_CHECKSUM_PER_RUN"d "$CHECKSUMS") <(echo "$new_local_checksums"))
    echo "$full_checksums" | grep '\S' > "$CHECKSUMS"
    echo

) 2> >(tee -a "$ERRORS" >&2) 1> >(tee -a "$STDOUT_LOGS")

n_errors=$(wc -l < "$ERRORS")
capacity=$(ssh "$SSH_OPTS" "$REMOTE" "df -h ." | awk 'FNR==2{print $5}')

echo "Cloud storage at $capacity capacity after uploading $DIRS_TO_BACKUP in $SECONDS seconds. $n_errors lines in errors file. Last rsync log line: $(tail -n 1 "$RSYNC_LOGS")" \
| tee -a "$STDOUT_LOGS" >(curl --retry 3 -d @- "$HEALTHCHECKS_IO_URL/$n_errors")

rm "$LOCAL_FILES"
rm "$LOCKFILE"
exit "$n_errors"
