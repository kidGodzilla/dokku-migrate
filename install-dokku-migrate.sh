#!/bin/bash
# install-dokku-migrate.sh
# This installer script does the following:
#   1. Checks for required dependencies (jq).
#   2. Creates a default config file at ~/.dokku-migrate/config.json if it does not exist.
#   3. Installs the dokku-migrate.sh script to a location in your PATH.
#      (It installs to $HOME/.local/bin if available; you can modify this as needed.)
#
# Usage: 
#   ./install-dokku-migrate.sh

set -e

# --- 1. Check for Dependencies ---
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed."
    echo "Please install jq and re-run this script."
    echo "For Ubuntu: sudo apt-get install jq"
    echo "For macOS (with Homebrew): brew install jq"
    exit 1
fi

# --- 2. Set up Configuration File ---
CONFIG_DIR="$HOME/.dokku-migrate"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Creating config directory at $CONFIG_DIR..."
    mkdir -p "$CONFIG_DIR"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating default configuration file at $CONFIG_FILE..."
    cat << 'EOF' > "$CONFIG_FILE"
{
  "backup_directory": "~/dokku",
  "servers": {
    "server1": {
      "host": "dokku1.example.com",
      "user": "root",
      "ssh_key": "~/.ssh/id_rsa"
    },
    "server2": {
      "host": "dokku2.example.com",
      "user": "ubuntu",
      "ssh_key": "~/.ssh/id_rsa"
    }
  }
}
EOF
    echo "Default config created. Edit $CONFIG_FILE to customize your servers and backup_directory."
fi

# --- 3. Install the dokku-migrate Script ---
# Assume that dokku-migrate.sh is in the same directory as this installer.
SOURCE_SCRIPT="$(dirname "$0")/dokku-migrate.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "Error: Could not find dokku-migrate.sh in the current directory."
    exit 1
fi

# Determine a target installation directory.
# If $HOME/.local/bin exists (common on Ubuntu/macOS), we'll use that.
TARGET_DIR="$HOME/.local/bin"
if [ ! -d "$TARGET_DIR" ]; then
    echo "Creating directory $TARGET_DIR..."
    mkdir -p "$TARGET_DIR"
fi

TARGET_SCRIPT="$TARGET_DIR/dokku-migrate"

echo "Installing dokku-migrate script to $TARGET_SCRIPT..."
cp "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"

# --- 4. Check if the installation directory is in PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -q "^$TARGET_DIR\$"; then
    echo "WARNING: $TARGET_DIR is not in your PATH."
    echo "You can add it by appending the following line to your ~/.bashrc or ~/.zshrc file:"
    echo "  export PATH=\"\$PATH:$TARGET_DIR\""
    echo "After updating, reload your shell or source the file."
fi

echo "Installation complete! You can now run 'dokku-migrate' from your terminal."
