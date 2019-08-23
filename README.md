Script to automate backing up ZFS datasets to AWS

The script uses ZFS send on a dataset and the aws cli to transfer the data. The idea is that it'll make periodic full backups, and incremental ones in between.

Metadata is stored with each S3 object that allows the script to decide the course of action, and nothing is known locally about what has already been backed up.

Each dataset has independently configurable options, as can be seen in the supplied example config file

Requirements:
- aws cli installed and configured
- non-standard packages: jq, pv 

Recommendations:
- specific aws user
- retention policy to move datasets to glacier

ToDo:
- Delete old backups automatically
- Date based rules for creating new full backups (rather than just absolute number)
