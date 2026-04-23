# 1. Define your components
MESSAGE="email from msmtp"
EMAIL="sonu.parit1@gmail.com"

# 2. Create the pre-string (use single quotes so variables don't expand yet)
# OR use double quotes if you want them expanded now.
STRING="echo \"$MESSAGE\" | msmtp $EMAIL"

# 3. To run it as a command:
eval "$STRING"

-----------------------------------------------
# Define the "pre-string" as a function
send_my_mail() {
    echo "$1" | msmtp "$2"
}

# Run it
send_my_mail "This is my message" "sonu.parit1@gmail.com"

-----------------------------------------------
send_my_mail() {
    local MSG="$1"
    local ADDR="$2"
    # Sending with a Subject header
    printf "Subject: Log Alert\n\n%s" "$MSG" | msmtp "$ADDR"
}

# Run it
send_my_mail "This is my message" "sonu.parit1@gmail.com"
------------------------------------------------

send_my_mail() {
    MSG="
    Subject: Log Cleanup Report
    To: $1
    From: $2
    $3"
    # Sending with a Subject header
    printf "$MSG" | msmtp "$ADDR"
}