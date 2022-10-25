# update_cloud_backup.sh

A bash script that uploads local files to a cloud backup. Minimal dependencies, maximum data-integrity paranoia, and good performance. Intended for files that don't change, like photos and videos, and therefore should be safer than solutions that try to merge changes.

Uses rsync and other common Linux tools (available on Windows via [Git Bash](https://gitforwindows.org/)), and connects to the remote machine with simple SSH commands suitable for restricted shells (tested on [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box)).

Runs are reported to [healthchecks.io](https://healthchecks.io), so that you get email alerts if any errors happen or if the script doesn't run on schedule.

## Design

This is a tool for **backup**, not *synchronization* or *cloud storage*.

- *Cloud storage* guarantees only one copy of your files, in the cloud. The vendor might still lose it, or lock you out.
- *Synchronization* propagates changes to remote copies. Even when the changes are undesirable, like ransomware encryption or accidental deletions.
- **Backup** is a redundant copy of your files, to be restored in case of data loss.

This tool is specialized in protecting large, important files that don't change (like photos and videos) against accidental deletion, bit-rot, and ransomware. My guiding principles for this solution are:

- One way transfers with no overwrites or deletion.
    - No changes are ever made to the local copies.
    - Remote files are never modified or deleted after being created, and are made read-only to help enforce this.
- Detect corruption by bit-rot, ransomware, and accidental deletion.
    - Any difference in file content is assumed to be bad and will generate alerts.
    - Missing local files also generate alerts. **It's not a backup if there's only one good copy.**
- Reliable alerts.
    - For any error, any discrepancy in the files, or when the tool hasn't run in a while.
    - Sent to your email by an external service, not an entry in a random log file somewhere.
- Integrity is regularly checked.
    - Checksums are computed locally and remotely, then both are compared to expected values.
    - This takes long on HDDs, so only a certain number of old files are checked per run.
- Availability is regularly checked.
    - Once per run a random local file is selected, and the remote copy is downloaded for verification.
- No automated recovery.
    - This tool only detects and reports problems, and never tries to fix anything by itself.
    - Data loss means something went seriously wrong. Recovery must be done carefully, under supervision.
- But recovery must still be simple.
    - The backup is stored as normal files in the same structure as the local files.
    - Recovery can be as simple as `scp -r $remote:* .`, or by mounting a (preferably read-only) Samba share.
- Reliability trumps everything.
    - Encryption is too risky for my backups.
        - The keys would either be stored locally, and also be lost in most disasters, or in a hard-to-find-and-easy-to-lose offsite shoebox.
        - Encrypted files are completely lost if a single bit is flipped. Unencrypted photos and videos are often salvageable.
        - Bugs in the tool become deadly.
        - All recovery must be done through the tool.
        - I can enhance my security in non-destructive ways by using 2FA, random passwords, SSH keys, and tightening down user permissions.
    - Versioning is too risky for my backups.
        - Recovery of old versions (presumably the good ones) must be done through the tool.
        - Makes performance and storage use less predictable.
        - Unnecessary for my types of files, and often already available at lower layers, like ZFS snapshots.
- General tool safety.
    - Alerts when the remote storage is over capacity (80% by default).
    - Any stderr messages are treated as errors and will generate alerts.
    - Uses a lockfile to detect and avoid overlapping runs.
        - And if that happens? You guessed it, alert.
        - I joke, but minimizing false positives is also important. If you get an email, it means there's something you should do.
    - Logs and errors are diligently dated and stored under `logs/` (a few KB per run).

The script was created in Bash in hopes of being a very short one by leveraging rsync. It's not short anymore, but I find it's still barely within my acceptable limits for Bash script complexity, and has been well behaved. Future versions will be in a proper programming language if any new features are necessary, or if any footguns are triggered. It does have the advantage of relying only on common tools like rsync and curl.

I don't intend for this to be a fully general backup tool for global use, so suggestions and bug reports are welcome, as long as they don't stray too much away from the current use case.

## Disclaimer

This is my personal backup script and has only been tested with my setup (Git Bash on Windows + Hetzner Storage Box, 300 GB of data in 30k files). Absolutely no warranty given or implied. I'm writing these docs for future me, but if it helps you, great!

That being said, since the transfer is one way and it never updates or deletes any remote files, it should be fairly safe. I'd be surprised if it did anything worse than spitting a bunch of errors or temporarily saturating your I/O, even in the most broken setups.

## Instructions

0. Make sure you have a remote machine to store the backup, and you can SSH into it non-interactively.
1. Sign up for [healthchecks.io](https://healthchecks.io) and create a project. The free plan includes 20 monitoring jobs, of which this script will use only one.
2. Create a `vars.sh` file per example below.
3. Download and run `update_cloud_backup.sh` manually once to verify it's working.
4. Schedule a task to run `update_cloud_backup.sh` daily or weekly. I use the Windows built-in Task Scheduler and `git-bash` to run the script.

```bash
###
# Required vars
###

# Username and hostname of the remote machine to store the backups.
# Highly recommended to set up SSH public key authentication, so that the script can run unattended without interaction.
REMOTE=u12345-sub1@u12345.your-storagebox.de

# SSH port, 23 for Hetzner Storage Box, 22 for most others.
SSH_OPTS=-p23

# Your Healthecks.io URL for reporting statuses. This is critical to get alerts!
# Create a free account at https://healthchecks.io/ and configure the expected schedule (e.g. daily pings, with alerts after 3 days).
HEALTHCHECKS_IO_URL='https://hc-ping.com/GUID'

# The base location, all further paths will be relative to this.
BASE_DIR="/d"
# The directory to be uploaded, relative to $BASE_DIR. The same structure will copied to the cloud backup,
# so that "media/camera/" is backed up as $REMOTE:~/media/camera, regardless of $BASE_DIR.
RELATIVE_DIR_TO_BACKUP="media/camera/"


###
# Optional vars
###

# On every run the oldest $N_CHECKSUM_PER_RUN files from $CHECKSUMS will be hashed both locally and remotely to verify integrity.
# Adjust depending on how many files you have, how often you run the script, and how often you want the integrity checked.
#N_CHECKSUM_PER_RUN=100

# Warn if the remote storage is over 80% capacity.
#MAX_CAPACITY_PERCENT=80
```