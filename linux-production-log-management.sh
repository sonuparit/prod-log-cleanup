#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

LOG_FILE="/var/log/disk_cleanup.log"
exec >> "$LOG_FILE" 2>&1

ENV_FILE="./logs.env"
LOCK_FILE="/tmp/disk_cleanup.lock"
DRY_RUN=${DRY_RUN:-true}

TOTAL_FREED=0
FILES_REMOVED=0
DIR_DETAILS=""
ESTIMATED_FREED=0

########################################
# Check dependency
########################################

#bash
#coreutils
#util-linux
#systemd (journalctl)
#cron
#curl
#mailx / mailutils

check_dependencies() {

for cmd in journalctl curl mail df awk find du wall; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        exit 1
    fi
done

}

########################################
# Locking
########################################

lock_script() {
    if [ -f "$LOCK_FILE" ]; then
        echo "Another cleanup process is already running."
        exit 1
    fi

    touch "$LOCK_FILE"
    trap "rm -f $LOCK_FILE" EXIT
}

########################################
# Load Config
########################################

load_config() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "logs.env file not found!"
        exit 1
    fi

    source "$ENV_FILE"
}

########################################
# Execute Wrapper (handles DRY_RUN)
########################################

execute() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] $*"
    else eval "$@" fi
}

########################################
# Disk Usage Check
########################################

check_disk_usage() {

    DISK_USAGE=$(df -P / | awk 'NR==2 {print $5}' | tr -d '%')
    echo "Current Disk Usage: ${DISK_USAGE}%"

    if [ "$DISK_USAGE" -lt 90 ]; then
        echo "Disk usage below threshold. Exiting."
        exit 0
    fi

}

########################################
# Inode Check
########################################

check_inode_usage() {

    INODE_USAGE=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')
    echo "Current Inode Usage: ${INODE_USAGE}%"

    if [ "$INODE_USAGE" -ge 90 ]; then

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] wall Inode usage exceeded 90%"
        else
            wall "WARNING: Inode usage exceeded 90% on $(hostname)"
        fi

    fi

}

########################################
# Journal Cleanup
########################################

journal_cleanup() {

    # journal directory may not exist
    [ -d /var/log/journal ] || return

    JOURNAL_BEFORE=$(journalctl --disk-usage | awk '{print $7}')

    if [ "$DRY_RUN" = true ]; then

        echo "Calculating journal cleanup impact..."

        JOURNAL_FILES=$(find /var/log/journal -type f -mtime +$JOURNAL_LOG_DAYS 2>/dev/null)

        for FILE in $JOURNAL_FILES
        do
            SIZE=$(du -m "$FILE" | awk '{print $1}')
            ESTIMATED_FREED=$((ESTIMATED_FREED + SIZE))
        done

        JOURNAL_AFTER="${ESTIMATED_FREED} MB"

    else

        echo "Executing journal cleanup..."

        [ "$JOURNAL_LOG_DAYS" != "0" ] && execute "journalctl --vacuum-time=${JOURNAL_LOG_DAYS}d"
        [ "$JOURNAL_LOG_SIZE" != "0" ] && execute "journalctl --vacuum-size=${JOURNAL_LOG_SIZE}M"
        [ "$JOURNAL_LOG_FILE_LIMIT" != "0" ] && execute "journalctl --vacuum-files=${JOURNAL_LOG_FILE_LIMIT}"

        JOURNAL_AFTER=$(journalctl --disk-usage | awk '{print $7}')

    fi

}

########################################
# Directory Cleanup
########################################

directory_cleanup() {

    for DIR in "${LOG_DIR[@]}"; do

        [ ! -d "$DIR" ] && continue

        echo "Scanning directory: $DIR"

        while IFS= read -r FILE; do

            SIZE=$(du -m "$FILE" | awk '{print $1}')

            if [ "$SIZE" -ge "$DIR_LOG_SIZE" ]; then

                TOTAL_FREED=$((TOTAL_FREED + SIZE))
                FILES_REMOVED=$((FILES_REMOVED + 1))

                DIR_DETAILS+="$FILE (${SIZE}MB)\n"

                execute "rm -f '$FILE'"

            fi

        done < <(find "$DIR" -type f -mtime +"$DIR_LOG_DAYS" 2>/dev/null)

    done

}

########################################
# Cleanup Summary
########################################

print_summary() {

    echo ""
    echo "================ CLEANUP SUMMARY ================"
    echo ""

    echo "Journal Logs:"
    echo "Before Cleanup: $JOURNAL_BEFORE"
    echo "After Cleanup : $JOURNAL_AFTER"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "Directory Logs (DRY RUN)"
        echo "Files to be Removed: $FILES_REMOVED"
        echo "Space to be Freed : ${TOTAL_FREED} MB"
    else
        echo "Directory Logs"
        echo "Files Removed: $FILES_REMOVED"
        echo "Space Freed : ${TOTAL_FREED} MB"
    fi

    echo -e "$DIR_DETAILS"

}

########################################
# Alert
########################################

check_cleanup_effectiveness() {

    if [ "$TOTAL_FREED" -lt 100 ]; then

        if [ "$DRY_RUN" = true ]; then
            echo "CRITICAL: cleanup would free <100MB"
        else
            wall "CRITICAL: cleanup freed <100MB on $(hostname). Manual investigation required."
        fi

    fi

}

########################################
# Cron Automation
########################################

setup_cron() {

    SCRIPT_PATH=$(realpath "$0")

    if [ "$CRON_JOB" = "TRUE" ]; then

        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$VALUE $SCRIPT_PATH") | crontab -

        echo "Cron job added: $VALUE"

    else

        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -

        echo "Cron job removed"

    fi

}

########################################
# Notifications
########################################

send_notifications() {

    #If $SLACK_WEBHOOK is empty, curl will fail.
    [ -z "$SLACK_WEBHOOK" ] && return

    curl -X POST -H 'Content-type: application/json' \
    --data '{"text":"Log cleanup completed successfully"}' \
    "$SLACK_WEBHOOK"

    echo "Log cleanup completed on $(date)" \
    | mail -s "Log Cleanup Report" $EMAIL_ADDRESS

}

########################################
# Main
########################################

main() {

    check_dependencies

    echo "-------------------------------------"
    echo "Disk Cleanup Started: $(date)"
    echo "Host: $(hostname)"
    echo "Mode: DRY_RUN=$DRY_RUN"
    echo "-------------------------------------"

    lock_script
    load_config
    check_disk_usage
    check_inode_usage
    journal_cleanup
    directory_cleanup
    print_summary
    check_cleanup_effectiveness

    if [ "$DRY_RUN" = false ]; then
        setup_cron
        send_notifications
    fi

    echo "Cleanup process finished."
}

main