#!/bin/bash

set -o nounset
#set -o errexit
set -o pipefail

BUCKET='zfs.test'
AWS_REGION='eu-north-1'
BACKUP_PATH=$(hostname -f)
DATASETS_CONF='s3backup.conf'

SNAPSHOT_TYPES="zfs-auto-snap_frequent\|zfs-auto-snap_hourly\|zfs-auto-snap_daily\|zfs-auto-snap_weekly\|zfs-auto-snap_monthly"

MAX_INCREMENTAL_BACKUPS=100
INCREMENTAL_FROM_INCREMENTAL=1

VERBOSE=0

function check_set
{
    if [[ -z $2 ]]
    then
        echo $1
        exit 1
    fi  
}

function verbose_log
{
    if [[ $VERBOSE -eq 1 ]]
    then
        echo $1
    fi  
}

function echoerr
{
    cat <<< "$@" 1>&2
}

function check_aws_bucket
{
    check_set "Missing bucket name" $BUCKET
    local bucket_ls=$( aws s3 ls $BUCKET 2>&1 )
    if [[ $bucket_ls =~ 'An error occurred (AccessDenied)' ]]
    then
        echoerr "Access denied attempting to access bucket $BUCKET"
        exit
    elif [[ $bucket_ls =~ 'An error occurred (NoSuchBucket)' ]]
    then
        echo "Creating bucket $BUCKET in region $AWS_REGION"
        aws s3api create-bucket  --bucket $BUCKET --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION --acl private
        aws s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
    else
        verbose_log "Bucket: $BUCKET exists"
    fi
}

function check_aws_folder
{
    local backup_path=${1-NO_DATASET}
    local dir_list=$(aws s3 ls $BUCKET/$backup_path 2>&1)
    if [[ $dir_list =~ 'An error occurred (AccessDenied)' ]]
    then
        echoerr "Access denied atempting to access $backup_path"
        exit
    elif [[ $dir_list == '' ]]
    then
        verbose_log "Creating folder $backup_path"
        aws s3api put-object --bucket $BUCKET --key $backup_path/
    fi
}

function incremental_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}
    local last_full_snapshot=${4-}
    local last_full_snapshot_file=${5-}
    local increment_from=${6-}
    local increment_from_file=${7-}
    local backup_seq=${8-}

    echo "Performing incremental backup on $snapshot from $increment_from"

    /sbin/zfs send --raw -Dcpi $increment_from $snapshot | pv | aws s3 cp - s3://$BUCKET/$backup_path/$filename \
        --metadata=FullSnapshot=false,\
Snapshot=$snapshot,\
LastFullSnapshot=$last_full_snapshot,\
LastFullSnapshotFile=$last_full_snapshot_file,\
IncrementFrom=$increment_from,\
IncrementFromFile=$increment_from_file,\
BackupSeq=$backup_seq,\
Dedup=true,Lz4comp=true 
}

function full_backup
{
    local snapshot=${1-}
    local backup_path=${2-}
    local filename=${3-}

    echo "Performing full backup on $snapshot"

    /sbin/zfs send --raw -Dcp $snapshot | pv | aws s3 cp - s3://$BUCKET/$backup_path/$filename \
         --metadata=FullSnapshot=true,\
Snapshot=$snapshot,\
LastFullSnapshot=$snapshot,\
LastFullSnapshotFile=$filename,\
IncrementFrom=$snapshot,\
IncrementFromFile=$filename,\
BackupSeq=0,\
Dedup=true,Lz4comp=true 
}

function backup_dataset
{
    local dataset=${1-}
    check_set "Missing dataset name" $dataset
    local backup_path="$BACKUP_PATH/$dataset" 
    check_aws_folder $backup_path

    local latest_remote_file=$( aws s3 ls $BUCKET/$backup_path/ | grep -v \/\$ | sort  -r | head -1 | awk '{print $4}' )
    local latest_snapshot=$( /sbin/zfs list -Ht snap -o name,creation -p |grep "^$dataset@"| grep $SNAPSHOT_TYPES | sort -n -k2 | tail -1 | awk '{print $1}' )
    local remote_filename=$( echo $latest_snapshot | sed 's/\//./g' )

    if [[ -z $latest_snapshot ]]
    then
        echoerr "No snapshots found for $dataset"
    elif [[ -z $latest_remote_file ]]
    then
        full_backup $latest_snapshot $backup_path $remote_filename
    elif [[ $latest_remote_file == $remote_filename ]]
    then
        echo "Backup is already at current version"
    else
        local remote_meta=$( aws s3api head-object --bucket $BUCKET --key $backup_path/$latest_remote_file )
        local last_full=$(echo $remote_meta| jq -r ".Metadata.lastfullsnapshot")
        local last_full_filename=$(echo $remote_meta| jq -r ".Metadata.lastfullsnapshotfile")
        local backup_seq=$(( $(echo $remote_meta | jq -r ".Metadata.backupseq" ) + 1 ))

        if [[ $backup_seq -gt $MAX_INCREMENTAL_BACKUPS ]]
        then
            full_backup $latest_snapshot $backup_path $remote_filename
        elif [[ $INCREMENTAL_FROM_INCREMENTAL -eq 1  ]] 
        then
            local increment_from=$(echo $remote_meta | jq -r ".Metadata.snapshot")
            incremental_backup $latest_snapshot $backup_path $remote_filename $last_full $last_full_filename $increment_from $latest_remote_file $backup_seq
        else
            incremental_backup $latest_snapshot $backup_path $remote_filename $last_full $last_full_filename $last_full $last_full_filename $backup_seq
        fi
    fi 
}

check_aws_bucket

for dataset in $( IFS=$'\n' ; cat $DATASETS_CONF )
do
    if [[ -z $( /sbin/zfs list -Ho name | grep "^$dataset$" ) ]]
    then
        echo "Dataset $dataset does not exist"
    else
        echo "Processing dataset $dataset"
        backup_dataset $dataset
    fi
done

