#!/usr/bin/env bash

DEPENDENCIES=("psql" "pg_dump" "pg_isready")
cleanup=false # Define usage function

usage() {
    echo
    echo "Usage: bash $0 -h <host> -p <port> -u <username> -s <source_db> -d <destination_db> -c <schema> -t <table> [--cleanup]"
    echo 
    echo "Description: $0 script sets up logical replication for a specific table between two databases in the same PostgreSQL cluster."
    echo "The script excludes all foreign keys from the source table while restoring its dump in the destination table."
    echo 
    echo "Options:"
    echo "  -h <host>            Specify the host."
    echo "  -p <port>            Specify the port."
    echo "  -u <username>        Specify the superuser username."
    echo "  -s <source_db>       Specify the source database."
    echo "  -d <destination_db>  Specify the destination database."
    echo "  -c <schema>          Specify the schema name (used in both databases)."
    echo "  -t <table>           Specify the table name."
    echo "  --cleanup            (Optional) Perform cleanup actions before dump. Set to 'true' to enable cleanup. It will drop replication slot, publication and subscription, but not destination table, if it exists."
    echo "                       Default is false. If set to true, script will perfome cleanup actions and exit. Run again without --cleanup to perform main flow"
    echo "  --help               Show this help message."
}


# Check dependencies
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Command '$cmd' not found. Please make sure it is installed (postgresql-client package or similar)."
        exit 1
    fi
done

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h)
            op_host="$2"
            shift 2
            ;;
        -p)
            op_port="$2"
            shift 2
            ;;
        -u)
            username="$2"
            shift 2
            ;;
        -s)
            source_db="$2"
            shift 2
            ;;
        -d)
            destination_db="$2"
            shift 2
            ;;
        -c)
            schema="$2"
            shift 2
            ;;
        -t)
            table="$2"
            shift 2
            ;;
        --cleanup)
            if [[ "$2" == "true" ]]; then
                cleanup=true
            else
              usage 
              exit 1
            fi
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Invalid option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if required arguments are provided
if [[ -z $op_host || -z $op_port || -z $username || -z $source_db || -z $destination_db || -z $schema || -z $table ]]; then
    echo "Error: Missing required argument(s)."
    usage
    exit 1
fi

# Check host accessibility
if ! pg_isready -q -h "$op_host" -p "$op_port"; then
    echo "The specified host is not accessible on port $op_port."
    exit 1
fi

# Prompt for password securely
read -s -p "Enter the password: " op_password
echo

# Verify password using psql
if ! PGPASSWORD="$op_password" psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -c "SELECT 1" >/dev/null 2>&1; then
    echo "The provided password is incorrect."
    exit 1
fi

PGPASSWORD="$op_password"

# Use the provided arguments
echo "Going to set up logical replication for provided environment:"
echo "Host: $op_host"
echo "Port: $op_port"
echo "Source DB: $source_db"
echo "Destination DB: $destination_db"
echo "Schema: $schema"
echo "Table: $table"


# compose needed variables
publication_name="${schema}_${table}_publication"
subscription_name="${schema}_${table}_subscription"
op_slot_name="${source_db}_${table}_slot"
op_slot_name=$(echo "$op_slot_name" | tr '-' '_')

cleanup() {
    echo "Performing cleanup actions..."
    
    echo "Dropping publication '$publication_name' on source database..."
    PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -c "DROP PUBLICATION $publication_name;"
    
    echo "Dropping replication slot '$op_slot_name' on source database..."
    PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -c "SELECT pg_drop_replication_slot('$op_slot_name');"
    
    echo "Unattaching subscriber '$subscription_name' from slot in destination database..."
    PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -c "ALTER SUBSCRIPTION $subscription_name SET (slot_name = NONE);"
    
    echo "Dropping subscription '$subscription_name' on destination database..."
    PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -c "DROP SUBSCRIPTION $subscription_name;"
    
    echo "Cleanup actions completed."
    exit 1
}

if [[ $cleanup == true ]]; then
    cleanup
fi

handle_error() {
    local error_code=$?
    local error_command=$BASH_COMMAND
    echo "Error occurred: $error_command (exit code: $error_code)"
    exit 1
}

trap handle_error ERR

# Step 1: Create pg_dump of SOURCE database
echo "Dumping ${table} from source database..."
PGPASSWORD=$op_password pg_dump -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -t "$schema.$table" -Fc -f "$source_db.dump"

# Step 2: Restore the dump in DESTINATION database
table_check=$(PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -tAc "SELECT 1 FROM pg_tables WHERE tablename = '$table' AND schemaname = '$schema'")
if [[ $table_check == "1" ]]; then
    echo "The table '$schema.$table' already exists in the destination database."
    echo "You might want to drop it with command: "
    echo "psql -h $op_host -p $op_port -U $username -d $destination_db -c \"DROP TABLE $schema.$table;\""
    echo "Aborting restore."
    exit 1
fi
echo "Restoring dump in destination database..."
PGPASSWORD=$op_password pg_restore -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -Fc -j 4 -L <(pg_restore -l "$source_db.dump" | grep -Ev ' FK') "$source_db.dump"
rm "$source_db.dump"

# Step 3: Create publication in SOURCE database for the table
publication_check=$(PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -tAc "SELECT 1 FROM pg_publication WHERE pubname = '$publication_name'")
if [[ $publication_check == "1" ]]; then
    echo "Publication '$publication_name' already exists in the source database."
    echo "To delete the existing publication, use the following command:"
    echo "psql -h $op_host -p $op_port -U $username -d $source_db -c \"DROP PUBLICATION $publication_name;\""
    exit 1
fi
echo "Creating '${publication_name}' for ${table} in source databse..."
PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -c "CREATE PUBLICATION $publication_name FOR TABLE \"$schema\".\"$table\""

# Step 4: Create replication slot in SOURCE database
slot_check=$(PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name = '$op_slot_name'")
if [[ $slot_check == "1" ]]; then
    echo "Replication slot '$op_slot_name' already exists in the source database."
    echo "To delete the existing replication slot, use the following command:"
    echo "psql -h $op_host -p $op_port -U $username -d $source_db -c \"SELECT pg_drop_replication_slot('$op_slot_name');\""
    exit 1
fi
echo "Creating logical replication slot '${op_slot_name}' in source database "
PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$source_db" -c "SELECT pg_create_logical_replication_slot('$op_slot_name', 'pgoutput')"

# Step 5: Create subscription in DESTINATION database using the pre-created replication slot
subscription_check=$(PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -tAc "SELECT 1 FROM pg_subscription WHERE subname = '$subscription_name'")
if [[ $subscription_check == "1" ]]; then
    echo "Subscription '$subscription_name' already exists in the destination database."
    echo "To delete the existing subscription, use the following commands:"
    echo "psql -h $op_host -p $op_port -U $username -d $destination_db -c \"ALTER SUBSCRIPTION $subscription_name SET (slot_name = NONE);\""
    echo "psql -h $op_host -p $op_port -U $username -d $destination_db -c \"DROP SUBSCRIPTION $subscription_name;\""
    exit 1
fi
echo "Creating '${subscription_name}' in destination database..."
PGPASSWORD=$op_password psql -h "$op_host" -p "$op_port" -U "$username" -d "$destination_db" -c "CREATE SUBSCRIPTION $subscription_name CONNECTION 'host="$op_host" port="$op_port" dbname="$source_db" user="$username" password="$op_password"' PUBLICATION "$publication_name" WITH (slot_name = "$op_slot_name", create_slot = false)"



commands_file="replication_commands.txt"
echo "" > $commands_file
{
    echo "Useful commands:"
    echo "1. Check logical replication status on SOURCE database:"
    echo "   psql -h $op_host -p $op_port -U $username -d $source_db -c \"SELECT * FROM pg_stat_replication;\""
    echo ""
    echo "2. Check logical replication status on DESTINATION database:"
    echo "   psql -h $op_host -p $op_port -U $username -d $destination_db -c \"SELECT * FROM pg_stat_subscription;\""
    echo ""
    echo "3. Delete the publication in SOURCE database:"
    echo "   psql -h $op_host -p $op_port -U $username -d $source_db -c \"DROP PUBLICATION $publication_name;\""
    echo ""
    echo "4. Delete the subscription in DESTINATION database:"
    echo "   psql -h $op_host -p $op_port -U $username -d $destination_db -c \"ALTER SUBSCRIPTION $subscription_name SET (slot_name = NONE); DROP SUBSCRIPTION $subscription_name;\""
} | tee "$commands_file"

echo "This commands saved in $commands_file"

