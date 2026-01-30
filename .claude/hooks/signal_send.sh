#!/bin/bash
# Send a Signal message to the primary collaborator
# Usage: ./signal_send.sh "message"
# Requires SIGNAL_TO env var to be set

RECIPIENT="${SIGNAL_TO:-}"
MESSAGE="$1"

if [ -z "$MESSAGE" ]; then
    echo "Usage: ./signal_send.sh \"message\""
    exit 1
fi

# Send the message
signal-cli send -m "$MESSAGE" "$RECIPIENT"

if [ $? -eq 0 ]; then
    echo "Message sent"
else
    echo "Failed to send message"
    exit 1
fi
