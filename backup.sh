#!/bin/bash

set -euo pipefail

BACKUP_STATUS=0
BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_ARCHIVE_PATH=""
BACKUP_ARCHIVES=()
BACKUP_ARCHIVES_JSON=""
PGSQL_TMP=""

# Validate required environment variables

REQUIRED_VARS=(
    FORGE_PING_CALLBACK
    BACKUP_TOKEN
    BACKUP_ID
    BACKUP_UUID
    BACKUP_DATABASES
    BACKUP_FULL_STORAGE_PATH
    BACKUP_AWS_PROFILE_NAME
    SERVER_DATABASE_DRIVER
    SERVER_DATABASE_PASSWORD
    SCRIPT_STARTED_AT
)

for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "Error: Required environment variable $VAR is not set."
        exit 1
    fi
done

# Validate required tools

REQUIRED_TOOLS=(gzip aws curl)

if [[ "$SERVER_DATABASE_DRIVER" == 'mysql' ]]; then
    REQUIRED_TOOLS+=(mysqldump)
elif [[ "$SERVER_DATABASE_DRIVER" == 'mariadb' ]]; then
    REQUIRED_TOOLS+=(mariadb-dump)
elif [[ "$SERVER_DATABASE_DRIVER" == 'pgsql' ]]; then
    REQUIRED_TOOLS+=(pg_dump sudo)
fi

for TOOL in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$TOOL" &>/dev/null; then
        echo "Error: Required tool '$TOOL' is not installed or not in PATH."
        exit 1
    fi
done

trap 'cleanup $? $LINENO' EXIT

cleanup()
{
    echo "Cleaning up backup."

    # Clean up PostgreSQL temp directory if it was created
    if [[ -n "$PGSQL_TMP" && -d "$PGSQL_TMP" ]]; then
        rm -rf "$PGSQL_TMP"
    fi

    # Handle Errors

    if [[ $1 -ne 0 ]]; then
        echo "Exit code $1 occurred on line $2"
        BACKUP_STATUS=1
    fi

    if [[ ${#BACKUP_ARCHIVES[@]} -gt 0 ]];
    then
        # Build JSON array using loop-based construction
        BACKUP_ARCHIVES_JSON="["
        local first=true
        local i=0
        while [[ $i -lt ${#BACKUP_ARCHIVES[@]} ]]; do
            if [[ "$first" == true ]]; then
                first=false
            else
                BACKUP_ARCHIVES_JSON+=","
            fi
            BACKUP_ARCHIVES_JSON+="{\"${BACKUP_ARCHIVES[$i]}\": ${BACKUP_ARCHIVES[$((i+1))]}}"
            i=$((i + 2))
        done
        BACKUP_ARCHIVES_JSON+="]"
    fi

    if ! curl -s --request POST \
        --url "$FORGE_PING_CALLBACK" \
        --data-urlencode "type=backup" \
        --data-urlencode "backup_token=$BACKUP_TOKEN" \
        --data-urlencode "streamed=true" \
        --data-urlencode "status=$BACKUP_STATUS" \
        --data-urlencode "backup_configuration_id=$BACKUP_ID" \
        --data-urlencode "archives=$BACKUP_ARCHIVES_JSON" \
        --data-urlencode "archive_path=${BACKUP_FULL_STORAGE_PATH}${BACKUP_TIMESTAMP}" \
        --data-urlencode "started_at=$SCRIPT_STARTED_AT" \
        --data-urlencode "uuid=$BACKUP_UUID"; then
        echo "Warning: Failed to send backup callback to Forge."
    fi
}

echo "Streaming backups to storage..."

for DATABASE in $BACKUP_DATABASES; do
    BACKUP_ARCHIVE_NAME="$DATABASE.sql.gz"
    BACKUP_ARCHIVE_PATH="${BACKUP_FULL_STORAGE_PATH}${BACKUP_TIMESTAMP}/${BACKUP_ARCHIVE_NAME}"

    if [[ "$SERVER_DATABASE_DRIVER" == 'mysql' ]]
    then
        MYSQL_PWD="$SERVER_DATABASE_PASSWORD" mysqldump \
            --user=root \
            --single-transaction \
            --skip-lock-tables \
            --routines \
            --hex-blob \
            -B \
            "$DATABASE" | \
            gzip -c | aws s3 cp - "$BACKUP_ARCHIVE_PATH" \
            --profile="$BACKUP_AWS_PROFILE_NAME" \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint="$BACKUP_AWS_ENDPOINT"} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url="$BACKUP_AWS_ENDPOINT"}

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}
    elif [[ "$SERVER_DATABASE_DRIVER" == 'mariadb' ]]
    then
        MYSQL_PWD="$SERVER_DATABASE_PASSWORD" mariadb-dump \
            --user=root \
            --single-transaction \
            --skip-lock-tables \
            --routines \
            --hex-blob \
            -B \
            "$DATABASE" | \
            gzip -c | aws s3 cp - "$BACKUP_ARCHIVE_PATH" \
            --profile="$BACKUP_AWS_PROFILE_NAME" \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint="$BACKUP_AWS_ENDPOINT"} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url="$BACKUP_AWS_ENDPOINT"}

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}
    elif [[ "$SERVER_DATABASE_DRIVER" == 'pgsql' ]]
    then
        # The postgres user cannot access /root/.backups, so switch to a secure temp directory

        PGSQL_TMP=$(mktemp -d)
        cd "$PGSQL_TMP"

        sudo -u postgres pg_dump --clean --create -F p "$DATABASE" | \
            gzip -c | aws s3 cp - "$BACKUP_ARCHIVE_PATH" \
            --profile="$BACKUP_AWS_PROFILE_NAME" \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint="$BACKUP_AWS_ENDPOINT"} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url="$BACKUP_AWS_ENDPOINT"}

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}

        rm -rf "$PGSQL_TMP"
        PGSQL_TMP=""
    fi

    # Check Exit Code Of Backup

    if [[ $STATUS -gt 0 ]];
    then
        BACKUP_STATUS=1

        echo "There was a problem during the backup process. Exit code: $STATUS"

        continue
    fi

    if [[ $BACKUP_STATUS -eq 0 ]];
    then
        # Get The Size Of This File And Store It

        BACKUP_ARCHIVE_SIZE=$(aws s3 ls "$BACKUP_ARCHIVE_PATH" \
            --profile="$BACKUP_AWS_PROFILE_NAME" \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint="$BACKUP_AWS_ENDPOINT"} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url="$BACKUP_AWS_ENDPOINT"} | \
            awk '{print $3}')

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}

        if [[ $STATUS -gt 0 ]]; then
            echo "Warning: Failed to retrieve archive size for $BACKUP_ARCHIVE_NAME. Exit code: $STATUS"
            BACKUP_ARCHIVE_SIZE=0
        fi
    fi

    BACKUP_ARCHIVES+=("$BACKUP_ARCHIVE_NAME" "$BACKUP_ARCHIVE_SIZE")
done

exit $BACKUP_STATUS
