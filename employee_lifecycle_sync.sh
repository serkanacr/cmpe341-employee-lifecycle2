#!/bin/bash

CURRENT_FILE="employees.csv"
SNAPSHOT_FILE="./output/last_employees.csv"
ARCHIVE_DIR="./output/archives"
LOG_DIR="./output/logs"
REPORTS_DIR="./output/reports"


# Controls directory, if any file does not exist, you should create.
#employee-lifecycle/
#├── output/
#│   ├── archives/
#│   ├── logs/
#│   ├── reports/
#│   └── last_employees.csv
#├── employee_lifecycle_sync.sh
#├── employees.csv
#
# Commands: mkdir -p
setup_environment() {
    mkdir -p "$ARCHIVE_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$REPORTS_DIR"

    if [ ! -f "$LOG_DIR/lifecycle_sync.log" ]; then
        touch "$LOG_DIR/lifecycle_sync.log"
    fi

    log_message "INFO" "Environment setup complete. Directories are ready."
}

# The log file records the operation along with its timestamp.
# YYYY-MM-DD HH:MM:SS | [LEVEL] | Message
# Commands: date, echo >>
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_file="$LOG_DIR/lifecycle_sync.log"

    # Format: YYYY-MM-DD HH:MM:SS | [LEVEL] | Message
    local formatted_log="$timestamp | [$level] | $message"

    echo "$formatted_log"
    echo "$formatted_log" >> "$log_file"
}

# Sort employees.csv and last_employees.csv files. 
# Use 2 temp files that name are sorted_current.txt and sorted_last.txt
read_and_normalize_csv() {

    awk -F',' 'NR>1 {print $2}' "$CURRENT_FILE" | tr -d '\r ' | sort > sorted_current.txt

    if [ -f "$SNAPSHOT_FILE" ]; then
        awk -F',' 'NR>1 {print $2}' "$SNAPSHOT_FILE" | tr -d '\r ' | sort > sorted_last.txt
    else
        touch sorted_last.txt
    fi

    log_message "INFO" "CSV files sorted."
}

# Detect changes as added, removed or status check.
# If it detects adding, call add_user otherwise call remove_user function.
# Commands: comm -13 (Only exists on new file), comm =23 (Only exists on old file)
detect_changes() {
 comm -13 sorted_last.txt sorted_current.txt > temp_added_users.txt
    > added_list.txt

    while read -r username; do

        username=$(echo "$username" | tr -d '[:space:]')

        if [ -n "$username" ]; then
            line=$(grep -m 1 ",$username," "$CURRENT_FILE")
            id=$(echo "$line" | awk -F',' '{print $1}' | tr -d '[:space:]')
            name=$(echo "$line" | awk -F',' '{print $3}' | xargs)
            dept=$(echo "$line" | awk -F',' '{print $4}' | tr -d '[:space:]')
            status=$(echo "$line" | awk -F',' '{print $5}' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

            add_user "$id" "$username" "$name" "$dept" "$status"

            if [ "$status" == "active" ]; then
                echo "$username, $dept" >> added_list.txt
            fi
        fi
    done < temp_added_users.txt

    comm -23 sorted_last.txt sorted_current.txt > temp_removed_users.txt
    > removed_list.txt
    while read -r username; do
        username=$(echo "$username" | tr -d '[:space:]')
        if [ -n "$username" ]; then
            dept=$(grep -m 1 ",$username," "$SNAPSHOT_FILE" | awk -F',' '{print $4}' | tr -d '[:space:]')

            remove_user "$username"

            echo "$username, ${dept:-unknown}" >> removed_list.txt
        fi
    done < temp_removed_users.txt

    > terminated_list.txt

    grep -i "terminated" "$CURRENT_FILE" | awk -F',' '{print $2}' | tr -d '[:space:]' > temp_terminated_users.txt
    while read -r username; do
        username=$(echo "$username" | tr -d '[:space:]')

        if ! grep -q "$username" temp_removed_users.txt; then

            dept=$(grep -m 1 ",$username," "$CURRENT_FILE" | awk -F',' '{print $4}' | tr -d '[:space:]')
            remove_user "$username"
            echo "$username, $dept" >> terminated_list.txt
        fi
    done < temp_terminated_users.txt

    log_message "INFO" "Change detection was completed."
}

# If status == active, add user.
# If deparment does not exist, you should add.
# Do not forget logging with log_message function.
# Commands: getent group (control department exists or not), groupadd (add departmant), useradd -m (add user), usermod -aG (add group)
add_user() {
    local employee_id=$1
    local username=$2
    local name_surname=$3
    local department=$4
    local status=$5

    if [ "$status" != "active" ]; then
        log_message "INFO" "Skipping user $username (Status: $status)"
        return
    fi

    if ! getent group "$department" >/dev/null; then
        groupadd "$department"
        if [ $? -eq 0 ]; then
            log_message "INFO" "Group '$department' created."
        else
            log_message "ERROR" "Failed to create group '$department'."
            return
        fi
    fi

    if id "$username" >/dev/null 2>&1; then
        log_message "WARN" "User $username already exists. Updating groups..."
        usermod -aG "$department" "$username"
    else
        useradd -m -s /bin/bash -c "$name_surname" -G "$department" "$username"
        if [ $? -eq 0 ]; then
            log_message "SUCCESS" "User $username added to system and group $department."
        else
            log_message "ERROR" "Failed to add user $username."
        fi
    fi
}

# Find user. (getent passwd)
# Backup the directory. (tar -czf)
# Lock the account. (usermod -L)
# Do not forget logging with log_message function.
remove_user() {
    local username=$1

    username=$(echo "$username" | tr -d '[:space:]')

    if ! id "$username" >/dev/null 2>&1; then
        log_message "WARN" "User $username does not exist. Skipping removal."
        return
    fi

    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)

    local timestamp
    timestamp=$(date "+%Y%m%d_%H%M%S")

    local archive_name="${username}_home_${timestamp}.tar.gz"

    if [ -d "$home_dir" ]; then
        tar -czf "$ARCHIVE_DIR/$archive_name" "$home_dir" 2>/dev/null
        if [ $? -eq 0 ]; then
             log_message "INFO" "Home directory archived: $archive_name"
        else
             log_message "ERROR" "Failed to archive home directory for $username."
        fi
    else
        log_message "WARN" "Home directory not found for $username. Skipping backup."
    fi

    usermod -L "$username"
    if [ $? -eq 0 ]; then
        log_message "SUCCESS" "User $username account locked."
    else
        log_message "ERROR" "Failed to lock account for $username."
    fi
}

# Generate repot that includes date, statistics.
generate_report() {

    local timestamp_file=$(date "+%Y%m%d_%H%M%S")
    local pretty_date=$(date "+%Y-%m-%d %H:%M:%S")
    local report_file="$REPORTS_DIR/manager_update_${timestamp_file}.txt"

    LATEST_REPORT="$report_file"

    local added_count=0
    local removed_count=0
    local terminated_count=0

    if [ -f "added_list.txt" ]; then
        added_count=$(wc -l < "added_list.txt")
    fi

    if [ -f "removed_list.txt" ]; then
        removed_count=$(wc -l < "removed_list.txt")
    fi

    if [ -f "terminated_list.txt" ]; then
        terminated_count=$(wc -l < "terminated_list.txt")
    fi

    {
        echo "Manager Employee Update"
        echo "======================="
        echo "Timestamp: $pretty_date"
        echo "Mode: LIVE"
        echo ""
        echo "Summary"
        echo "-------"
        echo "Added employees          : $added_count"
        echo "Removed employees        : $removed_count"
        echo "Offboarded by status     : $terminated_count"
        echo ""
        echo "Details"
        echo "-------"
        echo "Added (username, department):"
        if [ -f "added_list.txt" ] && [ $added_count -gt 0 ]; then
            cat "added_list.txt"
        else
            echo "None"
        fi
        echo ""

        echo "Removed (username, department):"
        if [ -f "removed_list.txt" ] && [ $removed_count -gt 0 ]; then
             cat "removed_list.txt"
        else
            echo "None"
        fi
        echo ""

        echo "Terminated processed (username, department):"
        if [ -f "terminated_list.txt" ] && [ $terminated_count -gt 0 ]; then
             cat "terminated_list.txt"
        else
            echo "None"
        fi

        echo ""
        echo "Artifacts"
        echo "---------"
        echo "Archives folder : $ARCHIVE_DIR"
        echo "Snapshot file   : $SNAPSHOT_FILE"
        echo "Log file        : $LOG_DIR/lifecycle_sync.log"

    } > "$report_file"

    log_message "INFO" "Manager report generated: $report_file"
}

# Send mail
# Command: mail -s "Subject" manager@email.com < report.txt.
send_email_report() {

    local recipient="oguzhanaydin@stu.khas.edu.tr"
    local subject="Employee Lifecycle Update - $(date +%Y-%m-%d)"

    if [ -n "$LATEST_REPORT" ] && [ -f "$LATEST_REPORT" ]; then

        mail -s "$subject" "$recipient" < "$LATEST_REPORT" 2>/dev/null

        if [ $? -eq 0 ]; then
            log_message "INFO" "Report emailed successfully to $recipient"
        else
            log_message "ERROR" "Failed to send email. Ensure 'mailutils' is installed."
        fi

    else
        log_message "ERROR" "Report file not found (LATEST_REPORT is empty). Email skipped."
    fi
}

# Save the employee.csv file as last_employees.csv. You can use copy.
update_snapshot() {
if [ -f "$CURRENT_FILE" ]; then

        cp "$CURRENT_FILE" "$SNAPSHOT_FILE"

        log_message "INFO" "Snapshot updated: $SNAPSHOT_FILE"
    else
        log_message "ERROR" "Could not update snapshot. Source file $CURRENT_FILE not found."
    fi
}

# Delete all temp files.
clean_temp_files() {
    rm -f sorted_current.txt sorted_last.txt
    rm -f added_list.txt removed_list.txt terminated_list.txt
    rm -f temp_added_users.txt temp_removed_users.txt temp_terminated_users.txt

    log_message "INFO" "Temporary files cleaned up."
}

main() {

    setup_environment

    # If last_exmployees.csv does not exist, create a new csv file.
    if [ ! -f "$SNAPSHOT_FILE" ]; then
        touch "$SNAPSHOT_FILE"
    fi

    # If employees.csv does not exist, terminate the program because we need current data.
    if [ ! -f "$CURRENT_FILE" ]; then
    echo "$CURRENT_FILE is not found!"
    exit 1
    fi

    read_and_normalize_csv
    detect_changes

    generate_report
    send_email_report
    update_snapshot
    clean_temp_files
}

main
