#!/bin/sh

set -eo pipefail

BACKUP_STATUS=0
BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_ARCHIVE_PATH=""
BACKUP_ARCHIVES=()
BACKUP_ARCHIVES_JSON=""

trap 'cleanup $? $LINENO' EXIT

cleanup()
{
    echo "Cleaning up backup."

    # Handle Errors

    if [ $1 != 0 ]; then
        echo "Exit code $1 occurred on line $2"
        BACKUP_STATUS=1
    fi

    if [[ ${#BACKUP_ARCHIVES[@]} -gt 0 ]];
    then
        BACKUP_ARCHIVES_JSON=$(echo "[$(printf '{\"%s\": %d},' ${BACKUP_ARCHIVES[@]} | sed '$s/,$//')]")
    fi

    curl -s --request POST \
        --url "$FORGE_PING_CALLBACK" \
        --data-urlencode "type=backup" \
        --data-urlencode "backup_token=$BACKUP_TOKEN" \
        --data-urlencode "streamed=true" \
        --data-urlencode "status=$BACKUP_STATUS" \
        --data-urlencode "backup_configuration_id=$BACKUP_ID" \
        --data-urlencode "archives=$BACKUP_ARCHIVES_JSON" \
        --data-urlencode "archive_path=$BACKUP_FULL_STORAGE_PATH$BACKUP_TIMESTAMP$BACKUP_NAME" \
        --data-urlencode "started_at=$SCRIPT_STARTED_AT" \
        --data-urlencode "uuid=$BACKUP_UUID"
}

echo "Streaming backups to storage..."

for DATABASE in $BACKUP_DATABASES; do
    BACKUP_ARCHIVE_NAME="$DATABASE.sql.gz"
    BACKUP_ARCHIVE_PATH="$BACKUP_FULL_STORAGE_PATH$BACKUP_TIMESTAMP$BACKUP_NAME/$BACKUP_ARCHIVE_NAME"

    if [[ $SERVER_DATABASE_DRIVER == 'mysql' ]]
    then
        mysqldump \
            --user=root \
            --password=$SERVER_DATABASE_PASSWORD \
            --single-transaction \
            --skip-lock-tables \
            -B \
            $DATABASE | \
            gzip -c | aws s3 cp - $BACKUP_ARCHIVE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url=$BACKUP_AWS_ENDPOINT}

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}
    elif [[ $SERVER_DATABASE_DRIVER == 'pgsql' ]]
    then
        # The postgres user cannot access /root/.backups, so switch to /tmp

        cd /tmp

        sudo -u postgres pg_dump --clean --create -F p $DATABASE | \
            gzip -c | aws s3 cp - $BACKUP_ARCHIVE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url=$BACKUP_AWS_ENDPOINT}

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}
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

        BACKUP_ARCHIVE_SIZE=$(aws s3 ls $BACKUP_ARCHIVE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT} \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint-url=$BACKUP_AWS_ENDPOINT} | \
            awk '{print $3}')

        RC=( "${PIPESTATUS[@]}" )
        STATUS=${RC[0]}
    fi

    BACKUP_ARCHIVES+=($BACKUP_ARCHIVE_NAME $BACKUP_ARCHIVE_SIZE)
done

exit $BACKUP_STATUS
