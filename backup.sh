#!/bin/sh

BACKUP_STATUS=0

# Change To Tmp Directory

cd /tmp

# Run The Correct Backup Script For Each Database Driver

if [[ $SERVER_DATABASE_DRIVER == 'mysql' ]]
then

    for DATABASE in $DATABASES; do
        mysqldump \
            --user root \
            --password $SERVER_DATABASE_PASSWORD \
            --single-transaction \
            $DATABASE > $DATABASE.sql
    done

elif [[ $SERVER_DATABASE_DRIVER == 'pgsql' ]]
then
    for DATABASE in $DATABASES; do
        sudo -u postgres pg_dump --clean -F p $DATABASE > $DATABASE.sql
    done
fi

# Add SQL Dumps To Archive And Remove Them Afterwards

find . -name "*.sql" | tar -czvf $BACKUP_ARCHIVE --remove-files -T -

# Upload The Archived File

if [ -f $BACKUP_ARCHIVE ]
then
    echo "Uploading backup archive..."

    aws s3 cp /tmp/$BACKUP_ARCHIVE $BACKUP_FULL_STORAGE_PATH \
        --profile=$BACKUP_AWS_PROFILE_NAME \
        ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT}

    if [ $? -ne 0 ]
    then
        echo "There was an error uploading the backup archive..."
    else
        # Set Successful Status

        BACKUP_STATUS=1
    fi

    # Remove Backup Archive

    rm -f $BACKUP_ARCHIVE
else
    echo "Backup archive could not be created..."
fi

# Prune Old Backups

if [ $BACKUP_STATUS -eq 1 ]
then
    echo "Pruning backups..."

    CURRENT_BACKUPS=$(
        aws s3 ls $BACKUP_FULL_STORAGE_PATH \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT} \
            | awk '{print $4}'
    )

    BACKUPS_TO_PRUNE=$(printf '%s' "$CURRENT_BACKUPS" | head -n -$BACKUP_RETENTION)

    for BACKUP in $BACKUPS_TO_PRUNE; do
        aws s3 rm "${BACKUP_FULL_STORAGE_PATH}${BACKUP}" \
            --profile=$BACKUP_AWS_PROFILE_NAME \
            ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT}
    done
fi

exit $BACKUP_STATUS
