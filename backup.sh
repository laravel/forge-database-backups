#!/bin/sh

set -e

BACKUP_STATUS=0

# Change To Tmp Directory

cd /tmp

# Run The Correct Backup Script For Each Database Driver

if [[ $SERVER_DATABASE_DRIVER == 'mysql' ]]
then

    for DATABASE in $BACKUP_DATABASES; do
        mysqldump \
            --user=root \
            --password=$SERVER_DATABASE_PASSWORD \
            --single-transaction \
            $DATABASE > $DATABASE.sql
    done

elif [[ $SERVER_DATABASE_DRIVER == 'pgsql' ]]
then
    for DATABASE in $BACKUP_DATABASES; do
        sudo -u postgres pg_dump --clean -F p $DATABASE > $DATABASE.sql
    done
fi

# Add SQL Dump To Archive And Remove It Afterwards

tar -czvf $BACKUP_ARCHIVE --remove-files --exclude=$BACKUP_DATABASES.sql $BACKUP_DATABASES.sql

# Upload The Archived File

if [ -f $BACKUP_ARCHIVE ]
then
    echo "Uploading backup archive..."

    aws s3 cp /tmp/$BACKUP_ARCHIVE $BACKUP_FULL_STORAGE_PATH \
        --profile=$BACKUP_AWS_PROFILE_NAME \
        ${BACKUP_AWS_ENDPOINT:+ --endpoint=$BACKUP_AWS_ENDPOINT}

    # Set A Failed Status

    if [ $? -ne 0 ]
    then
        echo "There was an error uploading the backup archive..."
        BACKUP_STATUS=1
    fi

    # Remove Backup Archive

    rm -f $BACKUP_ARCHIVE
else
    echo "Backup archive could not be created..."
fi

exit $BACKUP_STATUS
