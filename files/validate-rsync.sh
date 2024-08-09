#!/bin/bash

# This script is intended to be used as a forced command for SSH connections
# with rsync. It is used to allow only rsync commands to be executed via SSH.

# The script should be placed in the /home/[user]/.ssh directory and the following
# line should be added to the authorized_keys file for the user that will be
# running the rsync command:
#
# command="/home/[user]/.ssh/validate-rsync.sh",no-port-forwarding,no-X11-forwarding,no-pty ssh-rsa [public key] [comment]
#
# The script should be owned by [user] and have read and execute permissions for that user only:
#
# chown [user] /home/[user]/.ssh/validate-rsync.sh
# chmod 500 /home/[user]/.ssh/validate-rsync.sh
#
# The script is inspired by the following article: https://troy.jdmz.net/rsync/index.html


DEBUG=0

# Function to extract the server path from an rsync command 
# and check if it is a path within the user's home folder
check_rsync_command() {
    local input="$1"
    
    # Extract the last argument from the input
    local path=$(echo "$input" | awk '{print $NF}')

    # Check if the path contains a colon
    if [[ "$path" == *:* ]]; then
        # Extract the path after the last colon
        path="${path##*:}"
    fi

    # Check if the path is absolute or relative
    local full_path
    if [[ "$path" == /* ]]; then
        # Absolute path
        full_path="$path"
    else
        # Relative path, assume this is relative to the user's home folder
        full_path="$HOME/$path"
    fi

    # Resolve the absolute path
    local resolved_path
    resolved_path=$(realpath "$full_path")

    if [ $DEBUG -eq 1 ]; then
        echo "Input path: $path"
        echo "Full path: $resolved_path"
    fi

    # Check if the resolved path is within the user's home directory
    if [[ "$resolved_path" == "$HOME"* ]]; then
        if [ $DEBUG -eq 1 ]; then
            echo "Path is within the user's home folder"
        fi
        return 0  # The path is within the user's home folder
    else
        if [ $DEBUG -eq 1 ]; then
            echo "Path is outside the user's home folder"
        fi
        return 1  # The path is outside the user's home folder
    fi
}

# Inject SSH_ORIGINAL_COMMAND for testing
# SSH_ORIGINAL_COMMAND="rsync --server -avz -e \"ssh -i ~/.ssh/ssh_test_key\" ~/upload foo@127.0.0.1:/tmp"

if [ $DEBUG -eq 1 ]; then
    echo "SSH_ORIGINAL_COMMAND: $SSH_ORIGINAL_COMMAND"
fi

case "$SSH_ORIGINAL_COMMAND" in 
    *\&* | *\(* | *\{* | *\;* | *\<* | *\`* | *\|* )
        # Reject commands that look like user is trying to issue several commands
        # in one line. Could be hostile, trying to issue first a short rsync
        # followed by hostile command...
        #echo `date +"%Y-%m-%d %H:%M:%S UTC%:z"` " - SSH connection rejected: " "$SSH_ORIGINAL_COMMAND"
        ;;
    rsync\ --server* )
        # Allow all connections containing just the rsync command with arguments

        # Check if the rsync command is trying to access a directory in the user's home folder
        if check_rsync_command "$SSH_ORIGINAL_COMMAND"; then
            # Execute the rsync command only if the destination path is a directory in the user's home folder
            if [ $DEBUG -eq 1 ]; then
                echo "Command is allowed"
            fi
            eval $SSH_ORIGINAL_COMMAND
        else
            # Reject the rsync command if the destination path is outside the user's home folder
            if [ $DEBUG -eq 1 ]; then
                echo "Command is not allowed"
            fi
        fi
        ;;
    * )
        # Reject everything else.
        #echo `date +"%Y-%m-%d %H:%M:%S UTC%:z"` " - SSH connection rejected: " "$SSH_ORIGINAL_COMMAND"
        ;;
esac
