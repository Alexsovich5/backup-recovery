#!/bin/bash
#
# Automated Backup Script - Bacula Integration
# IT Administrator - Etech Eritrea PLC (2013-2014)
#

set -e

# Configuration
BACULA_DIR="/etc/bacula"
LOG_FILE="/var/log/backup-automation.log"
CONFIG_FILE="/etc/backup-config.conf"

# Source configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Validate arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <client> <backup_type>"
    echo "Backup types: full, incremental, differential"
    exit 1
fi

CLIENT="$1"
BACKUP_TYPE="$2"

log_message "Starting $BACKUP_TYPE backup for client: $CLIENT"

# Check Bacula services
if ! systemctl is-active bacula-dir >/dev/null 2>&1; then
    log_message "ERROR: Bacula Director not running"
    exit 1
fi

# Pre-backup checks
log_message "Performing pre-backup checks..."

# Check available space
AVAILABLE_SPACE=$(df /backup | awk 'NR==2 {print $4}')
if [ "$AVAILABLE_SPACE" -lt 1000000 ]; then  # Less than 1GB
    log_message "WARNING: Low disk space on backup volume"
fi

# Execute backup job
JOB_NAME="${CLIENT}-${BACKUP_TYPE}"
log_message "Executing Bacula job: $JOB_NAME"

# Create bconsole script
BCONSOLE_SCRIPT="/tmp/backup_${CLIENT}_${BACKUP_TYPE}.bconsole"
cat > "$BCONSOLE_SCRIPT" << EOF
run job="$JOB_NAME" yes
quit
EOF

# Run backup
if bconsole < "$BCONSOLE_SCRIPT"; then
    log_message "Backup job completed successfully: $JOB_NAME"
    
    # Post-backup verification
    log_message "Running backup verification..."
    
    # Create verification script
    cat > "/tmp/verify_${CLIENT}.bconsole" << EOF
run job="Verify-${CLIENT}" yes
quit
EOF
    
    if bconsole < "/tmp/verify_${CLIENT}.bconsole"; then
        log_message "Backup verification completed successfully"
    else
        log_message "WARNING: Backup verification failed"
    fi
    
else
    log_message "ERROR: Backup job failed for $JOB_NAME"
    exit 1
fi

# Cleanup
rm -f "$BCONSOLE_SCRIPT" "/tmp/verify_${CLIENT}.bconsole"

# Send notification
if command -v mail >/dev/null 2>&1; then
    echo "Backup completed for $CLIENT ($BACKUP_TYPE)" | mail -s "Backup Report" admin@etech.com.er
fi

log_message "Backup process completed for $CLIENT"