#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

ENV_FILE="./logs.env"
LOCK_FILE="/tmp/disk_cleanup.lock"
DRY_RUN=${DRY_RUN:-true}

if [ "$EUID" -eq 0 ]; then
    LOG_FILE="/var/log/disk_cleanup.log"
else
    LOG_FILE="$HOME/cleanup/disk_cleanup.log"
fi

mkdir -p "$(dirname "$LOG_FILE")"

TOTAL_FREED=0
FILES_REMOVED=0
JOURNALS_REMOVED=0
TOTAL_FILES_REMOVED=0
DIR_DETAILS=""
JOURNAL_DETAILS=""
ESTIMATED_FREED=0
TOTAL_SPACE_GAIN=0
INODE_USAGE=0
DISK_USAGE=0

########################################
# Check dependency
########################################

check_dependencies() {

  for cmd in journalctl curl msmtp df awk find du wall; do
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
    if [ "$LOG_TO_SCREEN" = true ]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
    else
        show_startup
        exec >> "$LOG_FILE" 2>&1
    fi
    show_startup 
}

########################################
# Show Startup
########################################

show_startup() {
    echo "-------------------------------------------------"
    echo "Disk Cleanup Started: $(date)"
    echo "Host: $(hostname)"
    echo "Mode: DRY_RUN=$DRY_RUN"
    echo "-------------------------------------------------"
}

########################################
# Disk Usage Check
########################################

check_disk_usage() {

    DISK_USAGE=$(df -P / | awk 'NR==2 {print $5}' | tr -d '%')
    echo "Current Disk Usage: ${DISK_USAGE}%"

    if [ "$DISK_USAGE" -ge 90 ]; then
      echo "[WARNING] Disk usage is above 90%."
      # wall "[WARNING] Disk usage is above 90%."
    fi
}

########################################
# Inode Check
########################################

check_inode_usage() {

    INODE_USAGE=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')
    echo "Current Inode Usage: ${INODE_USAGE}%"

    if [ "$INODE_USAGE" -ge 90 ]; then
      echo "[WARNING] Inode usage exceeded 90%"
      # wall "[WARNING] Inode usage exceeded 90%"
    fi
}

########################################
# Journal Cleanup
########################################

journal_cleanup() {

    # journal directory may not exist
    [ -d /var/log/journal/ ] || return

    JOURNAL_BEFORE=$(journalctl --disk-usage | awk '{print $7}')

    if [ "$DRY_RUN" = true ]; then

        echo "Calculating journal cleanup impact..."

        JOURNAL_FILES=$(find /var/log/journal/ -type f -mtime +$JOURNAL_LOG_DAYS 2>/dev/null)

        for FILE in $JOURNAL_FILES
        do
            SIZE=$(du -m "$FILE" | awk '{print $1}')
            ESTIMATED_FREED=$((ESTIMATED_FREED + SIZE))
            JOURNALS_REMOVED=$((JOURNALS_REMOVED + 1))
            JOURNAL_DETAILS+="$FILE (${SIZE}MB)\n"
        done

        JOURNAL_AFTER="${ESTIMATED_FREED}"

    else

        echo "Executing journal cleanup..."

        [ "$JOURNAL_LOG_DAYS" != "0" ] && execute "journalctl --vacuum-time=${JOURNAL_LOG_DAYS}d"
        [ "$JOURNAL_LOG_SIZE" != "0" ] && execute "journalctl --vacuum-size=${JOURNAL_LOG_SIZE}M"
        [ "$JOURNAL_LOG_FILE_LIMIT" != "0" ] && execute "journalctl --vacuum-files=${JOURNAL_LOG_FILE_LIMIT}"

        ESTIMATED_FREED="N/A (journalctl managed)"
        JOURNALS_REMOVED="N/A (not exposed)"
        JOURNAL_DETAILS="N/A (Managed by journalctl)"
        JOURNAL_AFTER=$(journalctl --disk-usage | awk '{print $7}')
    fi
}

########################################
# Directory Cleanup
########################################

directory_cleanup() {

    echo "Calculating directory cleanup impact..."

    for DIR in "${LOG_DIR[@]}"; do

        [ ! -d "$DIR" ] && continue

        echo "Scanning directory: $DIR"

        while IFS= read -r FILE; do     # using Input Field Separator (IFS)

            SIZE=$(du -m "$FILE" | awk '{print $1}')

            TOTAL_FREED=$((TOTAL_FREED + SIZE))
            FILES_REMOVED=$((FILES_REMOVED + 1))

            DIR_DETAILS+="$FILE (${SIZE}MB)\n"

            execute "rm -f '$FILE'"
        
        done < <(
            find "$DIR" -type f \
            ! -path "/var/log/journal/*" \
            \( -mtime +"$DIR_LOG_DAYS" -o -size +"${DIR_LOG_SIZE}M" \) \
            2>/dev/null
        )
    done
}

########################################
# Execute Wrapper (handles DRY_RUN)
########################################

execute() {
    if [ "$DRY_RUN" = false ]; then
          "$@"
      # eval "$@"
    fi
}

########################################
# Cleanup Summary
########################################

print_summary() {

    echo ""
    echo "================ CLEANUP SUMMARY ================"
    if [ "$DRY_RUN" = true ]; then
        echo "Journal Logs: (DRY RUN)"
        echo "Before Cleanup: $JOURNAL_BEFORE"
        echo "Journals to be removed : $JOURNALS_REMOVED"
        echo "Space to be Freed : $JOURNAL_AFTER MB"
        echo ""
        echo "Journals to be removed:"
        echo -e "$JOURNAL_DETAILS"
        echo "-------------------------------------------------"
        echo "Directory Logs: (DRY RUN)"
        echo "Files to be Removed: $FILES_REMOVED"
        echo "Space to be Freed : ${TOTAL_FREED} MB"
        echo ""
        echo "directories to be removed:"
        echo -e "$DIR_DETAILS"
    else
        echo "Journal Logs:"
        echo "Before Cleanup: $JOURNAL_BEFORE"
        echo "Journals to be removed : $JOURNALS_REMOVED"
        echo "Space to be Freed : $JOURNAL_AFTER MB"
        echo ""
        echo "Journals to be removed:"
        echo -e "$JOURNAL_DETAILS"
        echo "-------------------------------------------------"
        echo "Directory Logs"
        echo "Files Removed: $FILES_REMOVED"
        echo "Space Freed : ${TOTAL_FREED} MB"
        echo ""
        echo "directories to be removed:"
        echo -e "$DIR_DETAILS"
    fi
}

########################################
# Cleanup Effectiveness
########################################

check_cleanup_effectiveness() {

    TOTAL_SPACE_GAIN=$((TOTAL_FREED + JOURNAL_AFTER))

    if [ "$TOTAL_SPACE_GAIN" -lt 100 ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "cleanup would free <100MB"
        else
            echo "CRITICAL: cleanup freed <100MB on $(hostname). Manual investigation required."
            # wall "CRITICAL: cleanup freed <100MB on $(hostname). Manual investigation required."
        fi
    fi
}

########################################
# Cron Automation
########################################

setup_cron() {
    
    # SCRIPT_PATH=$(realpath "$0")
    SCRIPT_PATH=$(realpath "${BASH_SOURCE[0]}")

    if [ "$CRON_JOB" = "true" ]; then
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || true; echo "$CRON_SCHEDULE $SCRIPT_PATH") | crontab -
        echo "Cron job added: $CRON_SCHEDULE"
    else
        # crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || true) | crontab -
        echo "Cron job removed"
    fi
}

########################################
# Notifications
########################################

send_notifications() {
    
    if [ "$DRY_RUN" = true ]; then
      TOTAL_FILES_REMOVED=$((FILES_REMOVED + JOURNALS_REMOVED))
    else
      TOTAL_FILES_REMOVED="${TOTAL_FILES_REMOVED} + Journals"
    fi
    
    MESSAGE="Log cleanup completed on $(hostname)

    Files Removed: $TOTAL_FILES_REMOVED
    Space Freed: ${TOTAL_SPACE_GAIN} MB
    Disk Usage: ${DISK_USAGE} %
    Inode usage: ${INODE_USAGE} %
    Mode: DRY_RUN=$DRY_RUN
    Time: $(date)"
    
    
    ########################################
    # Slack Notification
    ########################################
    
    #If $SLACK_WEBHOOK is empty, curl will fail.
    # [ -z "$SLACK_WEBHOOK" ] && return
    
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
       send_slack_message "$MESSAGE"
    else
      echo "slack not configured or web-hook missing"
      echo "slack notification failed"
    fi
    
    ########################################
    # Email Notification (msmtp)
    ########################################

    # if command -v msmtp >/dev/null 2>&1 && [ -n "${EMAIL_ADDRESS:-}" ]; then
    if [[ -n "${EMAIL_FROM:-}" && -n "${EMAIL_TO:-}" ]]; then
      send_my_mail "$EMAIL_TO" "$EMAIL_FROM" "$MESSAGE"
    else
      echo "msmtp not configured or EMAIL variables missing"
      echo "email notification failed"
    fi
}

########################################
# Slack Notification
########################################

send_slack_message() {
    MSG="$1"
    curl -s -o /dev/null -X POST -H 'Content-type: application/json' \
    --data "$(printf '{"text":"%s"}' "$MSG")" \
    "$SLACK_WEBHOOK"
    
    echo "Slack Notification Sent"
}

########################################
# Email Notification (msmtp)
########################################

send_my_mail() {
    local TO="$1"
    local FROM="$2"
    local BODY="$3"
    {
        printf "To: %s\n" "$TO"
        printf "From: %s\n" "$FROM"
        printf "Subject: Log Cleanup Report\n"
        printf "\n"   # ← VERY IMPORTANT (separates headers from body)
        printf "%s\n" "$BODY"
    } | msmtp -t
    
    echo "Email Notification Sent"
}

########################################
# Main
########################################

main() {

    check_dependencies
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
    
    echo ""
    echo "-------------------------------------------------"
    echo "Disk Cleanup Finished"
    echo "-------------------------------------------------"
    echo ""
}

main