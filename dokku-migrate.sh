#!/bin/bash
set -e

# dokku-migrate.sh
# A command-line tool to backup and restore Dokku apps and databases.
#
# Configuration is read from a JSON file at ~/.dokku-migrate/config.json.
#
# Example config.json:
# {
#   "backup_directory": "~/dokku",
#   "servers": {
#     "server1": {
#       "host": "dokku1.example.com",
#       "user": "root",
#       "ssh_key": "~/.ssh/id_rsa"
#     },
#     "server2": {
#       "host": "dokku2.example.com",
#       "user": "ubuntu",
#       "ssh_key": "~/.ssh/id_rsa"
#     }
#   }
# }
#
# Usage:
#   ./dokku-migrate.sh backup <servername> [appname]
#     - If appname is provided, backs up only that app; otherwise, backs up every app from the server.
#
#   ./dokku-migrate.sh restore <servername> [appname]
#     - Restores backup(s) for the given server.
#
#   ./dokku-migrate.sh list <servername>
#     - Lists remote apps on the given server.
#
#   ./dokku-migrate.sh backup-db <dbtype> <servername> <dbname>
#     - Backs up a database. dbtype is either "postgres" or "mongo".
#
#   ./dokku-migrate.sh restore-db <dbtype> <servername> <dbname>
#     - Restores a database dump to the remote server.
#
# Requirements: jq must be installed.

# Configuration file location
CONFIG_FILE="${HOME}/.dokku-migrate/config.json"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Configuration file ${CONFIG_FILE} not found!"
  exit 1
fi

# Function to print usage
usage() {
  cat <<EOF
Usage:
  dokku-migrate backup <servername> [appname]
         Backup all apps (or a single app if provided) from the specified server.
  dokku-migrate restore <servername> [appname]
         Restore all apps (or a single app if provided) to the specified server.
  dokku-migrate list <servername>
         List apps on the specified remote server.
  dokku-migrate backup-db <dbtype> <servername> <dbname>
         Backup a database (dbtype: postgres or mongo) from the specified server.
  dokku-migrate restore-db <dbtype> <servername> <dbname>
         Restore a database (dbtype: postgres or mongo) to the specified server.
EOF
  exit 1
}

# Ensure we have at least 2 arguments.
if [ "$#" -lt 2 ]; then
  usage
fi

# Read parameters
ACTION="$1"
SERVERNAME="$2"
TARGET_NAME="$3"
DBTYPE="$2"   # For backup-db and restore-db, dbtype is the second parameter
# For backup-db/restore-db, we adjust later.

# Function to load server config from CONFIG_FILE using jq.
load_server_config() {
  local srv="$1"
  REMOTE_USER=$(jq -r ".servers.\"${srv}\".user" "${CONFIG_FILE}")
  REMOTE_HOST=$(jq -r ".servers.\"${srv}\".host" "${CONFIG_FILE}")
  SSH_KEY=$(jq -r ".servers.\"${srv}\".ssh_key" "${CONFIG_FILE}")
  # Expand tilde if present:
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
  BACKUP_DIR=$(jq -r ".backup_directory" "${CONFIG_FILE}")
  # Expand tilde if present in backup_directory
  BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"
}

# Backup an individual app (configuration, persistent storage)
backup_app() {
  local app="$1"
  local local_app_dir="$2/apps/${app}"
  mkdir -p "${local_app_dir}"
  echo "Backing up app ${app}..."

  # Backup VHOST and ENV files
  ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "cat /home/dokku/${app}/VHOST" > "${local_app_dir}/VHOST" 2>/dev/null || echo "# No VHOST file" > "${local_app_dir}/VHOST"
  ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "cat /home/dokku/${app}/ENV" > "${local_app_dir}/ENV" 2>/dev/null || echo "# No ENV file" > "${local_app_dir}/ENV"

  # Backup persistent storage if exists
  echo "Checking persistent storage for ${app}..."
  ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "if [ -d /var/lib/dokku/data/storage/${app} ]; then tar -czf /tmp/${app}_storage.tar.gz -C /var/lib/dokku/data/storage/${app} .; fi"
  if scp -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/${app}_storage.tar.gz" "${local_app_dir}/storage.tar.gz" 2>/dev/null; then
    echo "Persistent storage for ${app} backed up."
    # Optionally, clean up remote temp file:
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "rm -f /tmp/${app}_storage.tar.gz"
  else
    echo "No persistent storage found for ${app}."
  fi

  # Write metadata file
  cat <<EOF > "${local_app_dir}/metadata.json"
{
  "app": "${app}",
  "server": "${SERVERNAME}",
  "backup_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# Restore an individual app using the local backup
restore_app() {
  local app="$1"
  local local_app_dir="$2/apps/${app}"
  echo "Restoring app ${app}..."

  # Create the app on the remote server
  ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku apps:create ${app}"

  # Restore VHOST and ENV (configure domains and environment variables)
  if [ -f "${local_app_dir}/VHOST" ]; then
    VHOST=$(cat "${local_app_dir}/VHOST")
    if [ -n "$VHOST" ]; then
      ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku domains:add ${app} ${VHOST}"
    fi
  fi
  if [ -f "${local_app_dir}/ENV" ]; then
    ENV_VARS=$(cat "${local_app_dir}/ENV")
    if [ -n "$ENV_VARS" ]; then
      ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku config:set ${app} ${ENV_VARS}"
      ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku config:unset ${app} GIT_REV"
    fi
  fi

  # Restore persistent storage if backup exists
  if [ -f "${local_app_dir}/storage.tar.gz" ]; then
    echo "Restoring persistent storage for ${app}..."
    scp -i "${SSH_KEY}" "${local_app_dir}/storage.tar.gz" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/${app}_storage.tar.gz"
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p /var/lib/dokku/data/storage/${app} && tar -xzf /tmp/${app}_storage.tar.gz -C /var/lib/dokku/data/storage/${app} && sudo chown -R nobody:nogroup /var/lib/dokku/data/storage/${app} && rm -f /tmp/${app}_storage.tar.gz"
  fi
}

# Backup a database (Postgres or Mongo). dbtype should be either 'postgres' or 'mongo'
backup_db() {
  local dbtype="$1"
  local dbname="$2"
  local local_db_dir="$3/${dbtype}"
  mkdir -p "${local_db_dir}"
  echo "Backing up ${dbtype} database ${dbname} from server ${SERVERNAME}..."
  local remote_backup_file="/tmp/${dbname}_${dbtype}_backup"
  local local_backup_file
  if [ "$dbtype" == "postgres" ]; then
    remote_backup_file="${remote_backup_file}.sql"
    local_backup_file="${local_db_dir}/${dbname}_backup.sql"
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku postgres:export ${dbname} > ${remote_backup_file}"
  elif [ "$dbtype" == "mongo" ]; then
    remote_backup_file="${remote_backup_file}.archive"
    local_backup_file="${local_db_dir}/${dbname}_backup.archive"
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku mongo:export ${dbname} > ${remote_backup_file}"
  else
    echo "Unsupported dbtype: ${dbtype}"
    exit 1
  fi
  scp -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}:${remote_backup_file}" "${local_backup_file}"
  ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "rm -f ${remote_backup_file}"
  echo "${dbtype} backup for ${dbname} saved as ${local_backup_file}"
}

# Restore a database (Postgres or Mongo). dbtype should be either 'postgres' or 'mongo'
restore_db() {
  local dbtype="$1"
  local dbname="$2"
  local local_db_dir="$3/${dbtype}"
  local local_backup_file
  if [ "$dbtype" == "postgres" ]; then
    local_backup_file="${local_db_dir}/${dbname}_backup.sql"
  elif [ "$dbtype" == "mongo" ]; then
    local_backup_file="${local_db_dir}/${dbname}_backup.archive"
  else
    echo "Unsupported dbtype: ${dbtype}"
    exit 1
  fi
  if [ ! -f "${local_backup_file}" ]; then
    echo "Backup file ${local_backup_file} not found!"
    exit 1
  fi
  echo "Restoring ${dbtype} database ${dbname} to server ${SERVERNAME}..."
  scp -i "${SSH_KEY}" "${local_backup_file}" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/"
  if [ "$dbtype" == "postgres" ]; then
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku postgres:import ${dbname} < /tmp/$(basename ${local_backup_file}) && rm -f /tmp/$(basename ${local_backup_file})"
  elif [ "$dbtype" == "mongo" ]; then
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku mongo:import ${dbname} < /tmp/$(basename ${local_backup_file}) && rm -f /tmp/$(basename ${local_backup_file})"
  fi
}

# Main command logic
case "$ACTION" in
  backup)
    load_server_config "$SERVERNAME"
    LOCAL_SERVER_DIR="${BACKUP_DIR}/${SERVERNAME}"
    mkdir -p "${LOCAL_SERVER_DIR}/apps"
    if [ -z "$TARGET_NAME" ]; then
      echo "Fetching app list from ${REMOTE_HOST}..."
      APP_LIST=$(ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku apps:list" | tr -d '\r')
      for app in $APP_LIST; do
        backup_app "$app" "${LOCAL_SERVER_DIR}"
      done
    else
      backup_app "$TARGET_NAME" "${LOCAL_SERVER_DIR}"
    fi
    ;;
  restore)
    load_server_config "$SERVERNAME"
    LOCAL_SERVER_DIR="${BACKUP_DIR}/${SERVERNAME}"
    if [ -z "$TARGET_NAME" ]; then
      echo "Restoring all apps from ${LOCAL_SERVER_DIR}/apps..."
      for app_dir in "${LOCAL_SERVER_DIR}/apps/"*; do
        [ -d "$app_dir" ] || continue
        app=$(basename "$app_dir")
        restore_app "$app" "${LOCAL_SERVER_DIR}"
      done
    else
      restore_app "$TARGET_NAME" "${LOCAL_SERVER_DIR}"
    fi
    ;;
  list)
    load_server_config "$SERVERNAME"
    ssh -i "${SSH_KEY}" "${REMOTE_USER}@${REMOTE_HOST}" "dokku apps:list"
    ;;
  backup-db)
    # Usage: dokku-migrate.sh backup-db <dbtype> <servername> <dbname>
    if [ "$#" -ne 4 ]; then usage; fi
    DBTYPE="$1"
    SERVERNAME="$2"
    DBNAME="$3"
    load_server_config "$SERVERNAME"
    LOCAL_SERVER_DIR="${BACKUP_DIR}/${SERVERNAME}"
    backup_db "$DBTYPE" "$DBNAME" "${LOCAL_SERVER_DIR}"
    ;;
  restore-db)
    # Usage: dokku-migrate.sh restore-db <dbtype> <servername> <dbname>
    if [ "$#" -ne 4 ]; then usage; fi
    DBTYPE="$1"
    SERVERNAME="$2"
    DBNAME="$3"
    load_server_config "$SERVERNAME"
    LOCAL_SERVER_DIR="${BACKUP_DIR}/${SERVERNAME}"
    restore_db "$DBTYPE" "$DBNAME" "${LOCAL_SERVER_DIR}"
    ;;
  *)
    usage
    ;;
esac

echo "Operation completed."
