#!/bin/bash

# Variable to store the PID of the current curl process
CURL_PID=""

# Function to cleanly terminate the current curl process (if running)
cleanup_curl() {
    # Check if CURL_PID is set and the process is still alive
    if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then
        kill "$CURL_PID"                     # Send SIGTERM to stop curl
        wait "$CURL_PID" 2>/dev/null         # Wait for the process to terminate (avoid zombies)
        CURL_PID=""                          # Clear the PID
    fi
}

# Trap SIGINT (Ctrl+C) and SIGTERM to ensure cleanup on exit
trap 'cleanup_curl; exit' INT TERM

# Main loop: run indefinitely
while true; do
    # Terminate the previous curl instance if it's still running
    cleanup_curl

    echo "start watch model-instance"
    # Start a new curl in the background (output discarded)
    curl "http://localhost/v2/model-instances?watch=true" > /dev/null 2>&1 &
    CURL_PID=$!  # Save the PID of the background curl process

    # Wait for 2 seconds before the next iteration
    sleep 2
done
