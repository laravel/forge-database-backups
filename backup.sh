#!/bin/sh

set -e

BACKUP_STATUS=0
BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_ARCHIVES=()

echo "Streaming backups to storage..."

for DATABASE in $BACKUP_DATABASES; do
    BACKUP_ARCHIVE_NAME="$DATABASE.sql.gz"
    BACKUP_ARCHIVE_PATH="$BACKUP_FULL_STORAGE_PATH$BACKUP_TIMESTAMP/$BACKUP_ARCHIVE_NAME"

    if [[ $SERVER_DATABASE_DRIVER == 'mysql' ]]
    then
        STATUS=$(mysqldump \
            --user=root \
            --password=$SERVER_DATABASE_PASSWORD \
            --single-transaction \
            -B \
            $DATABASE | \
            gzip -c | \
            aws s3 cp - $BACKUP_ARCHIVE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT})
    elif [[ $SERVER_DATABASE_DRIVER == 'pgsql' ]]
    then
        # The postgres user cannot access /root/.backups, so switch to /tmp

        cd /tmp

        STATUS=$(sudo -u postgres pg_dump --clean --create -F p $DATABASE | \
        gzip -c | \
        aws s3 cp - $BACKUP_ARCHIVE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT})
    fi

    # Check Exit Code Of Backup

    if [[ $STATUS -gt 0 ]];
    then
        BACKUP_STATUS=1

        echo "There was a problem during the backup process."

        continue
    fi

    # Get The Size Of This File And Store It

    BACKUP_ARCHIVE_SIZE=$(aws s3 ls $BACKUP_ARCHIVE_PATH \
        --profile=$BACKUP_AWS_PROFILE_NAME \
        ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT} | \
        awk '{print $3}')

    # Check Exit Code Of Listing

    if [[ $? -gt 0 ]];
    then
        BACKUP_STATUS=1

        echo "There was a problem during the backup process, when fetching the archive size."

        continue
    fi

    BACKUP_ARCHIVES+=($BACKUP_ARCHIVE_NAME $BACKUP_ARCHIVE_SIZE)
done

BACKUP_ARCHIVES_JSON=$(echo "[$(printf '{\"%s\": %d},' ${BACKUP_ARCHIVES[@]} | sed '$s/,$//')]")

curl -s --request POST \
    --url "$FORGE_PING_CALLBACK" \
    --data-urlencode "type=backup" \
    --data-urlencode "backup_token=$BACKUP_TOKEN" \
    --data-urlencode "streamed=true" \
    --data-urlencode "status=$BACKUP_STATUS" \
    --data-urlencode "backup_configuration_id=$BACKUP_ID" \
    --data-urlencode "archives=$BACKUP_ARCHIVES_JSON" \
    --data-urlencode "archive_path=$BACKUP_FULL_STORAGE_PATH$BACKUP_TIMESTAMP" \
    --data-urlencode "started_at=$SCRIPT_STARTED_AT" \
    --data-urlencode "uuid=$BACKUP_UUID"

exit $BACKUP_STATUS
