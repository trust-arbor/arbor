#!/bin/bash
# Send a Signal message to the primary collaborator
# Usage: ./signal_send.sh "message"

PRIMARY_NUMBER="${SIGNAL_TO:-}"
MESSAGE="$1"

if [ -z "$MESSAGE" ]; then
    echo "Usage: ./signal_send.sh \"message\""
    exit 1
fi

# Send the message
signal-cli send -m "$MESSAGE" "$PRIMARY_NUMBER"

if [ $? -eq 0 ]; then
    echo "Message sent to the primary collaborator"
else
    echo "Failed to send message"
    exit 1
fi
