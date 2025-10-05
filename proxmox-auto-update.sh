#!/bin/bash
#
# Proxmox Cluster Auto-Update (Debian 13 base)
# ---------------------------------------------------------------
# • Updates all nodes in the Proxmox cluster sequentially
# • Automatically sets up SSH keys if needed
# • Prevents concurrent runs via a lock file
# • Installs needrestart if missing
# • Runs apt update / full-upgrade / autoremove / clean
# • Checks reboot requirement in two ways:
#      – needs-restarting -r  (only reported when a reboot is needed)
#      – /var/run/reboot-required  (used for the e‑mail subject)
# • Logs everything and sends an e‑mail (no automatic reboot)
# Written by Nico Schmidt (baGStube_Nico)
# E-Mail: nico.schmidt@ns-tech.cloud
# Follow my Socials: https://linktr.ee/bagstube_nico
# ---------------------------------------------------------------

set -euo pipefail                     # abort on errors / undefined vars

# ------------------- Configuration -------------------
HOSTNAME="$(hostname -f)"               # Fully qualified host name
LOCKFILE="/var/run/proxmox-auto-update.lock"
LOGFILE="/var/log/proxmox-cluster-auto-update.log"
MAIL_TO="root@localhost"               # Change to your preferred recipient
APTCMD="/usr/bin/apt-get"              # Absolute path to apt-get
NEEDRESTART_PKG="needrestart"
NEEDRESTART_CMD="/usr/sbin/needs-restarting"
REMOTE_SCRIPT="/tmp/proxmox-remote-update.sh"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH_KEY="/root/.ssh/id_ed25519"
SSH_PASSWORD=""                        # Set SSH password here if all nodes use the same password
                                       # Example: SSH_PASSWORD="your_password_here"
                                       # Leave empty to skip automatic SSH setup

# Manual node list (if no cluster is configured)
# Add all nodes you want to update here
MANUAL_NODES=""                        # Example: MANUAL_NODES="examplehost.com"
# -----------------------------------------------------

# ----------- Acquire lock (prevent double run) ----------
exec 200>"${LOCKFILE}"
flock -n 200 || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : another instance is already running on ${HOSTNAME}" \
        >> "${LOGFILE}"
    exit 1
}

# ------------------- Log header -------------------
{
    echo "===================================================================="
    echo "Proxmox Cluster Auto-Update started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Coordinating Node: ${HOSTNAME}"
    echo "Lock file: ${LOCKFILE}"
    echo "Log file: ${LOGFILE}"
    echo "--------------------------------------------------------------------"
} >> "${LOGFILE}"

# ------------------- Error handler -------------------
error_handler() {
    {
        echo "ERROR: The cluster update script terminated on ${HOSTNAME}."
        echo "Please inspect the log file above for details."
    } >> "${LOGFILE}"
    mail -s "[PROXMOX CLUSTER][${HOSTNAME}] Auto-Update failed" "${MAIL_TO}" < "${LOGFILE}"
}
trap error_handler ERR

# ------------------- Install sshpass if needed -------------------
install_sshpass() {
    if [[ -n "${SSH_PASSWORD}" ]] && ! command -v sshpass &> /dev/null; then
        {
            echo "[$(date '+%H:%M:%S')] sshpass not found – installing …"
            ${APTCMD} update -qq
            ${APTCMD} install -y -qq sshpass
            echo "[$(date '+%H:%M:%S')] sshpass installed successfully."
        } >> "${LOGFILE}" 2>&1
    fi
}

# ------------------- Setup SSH key -------------------
setup_ssh_key() {
    {
        echo "[$(date '+%H:%M:%S')] Checking SSH key setup …"
        
        # Generate SSH key if it doesn't exist
        if [[ ! -f "${SSH_KEY}" ]]; then
            echo "[$(date '+%H:%M:%S')] Generating SSH key …"
            ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "proxmox-auto-update@${HOSTNAME}"
            echo "[$(date '+%H:%M:%S')] SSH key generated: ${SSH_KEY}"
        else
            echo "[$(date '+%H:%M:%S')] SSH key already exists: ${SSH_KEY}"
        fi
    } >> "${LOGFILE}" 2>&1
}

# ------------------- Copy SSH key to remote node -------------------
copy_ssh_key_to_node() {
    local node=$1
    
    {
        echo "[$(date '+%H:%M:%S')] Checking SSH access to ${node} …"
        
        # Test if SSH key already works
        if ssh ${SSH_OPTS} -o BatchMode=yes -o PasswordAuthentication=no "root@${node}" "exit" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] SSH key authentication already working for ${node}"
            return 0
        fi
        
        # If password is set, try to copy the key
        if [[ -n "${SSH_PASSWORD}" ]]; then
            echo "[$(date '+%H:%M:%S')] SSH key not set up for ${node}, attempting to copy …"
            
            if ! command -v sshpass &> /dev/null; then
                echo "ERROR: sshpass not installed but SSH_PASSWORD is set"
                return 1
            fi
            
            # Copy SSH key using password
            if sshpass -p "${SSH_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=no -i "${SSH_KEY}.pub" "root@${node}" 2>&1; then
                echo "[$(date '+%H:%M:%S')] SSH key successfully copied to ${node}"
                
                # Verify it works
                if ssh ${SSH_OPTS} -o BatchMode=yes -o PasswordAuthentication=no "root@${node}" "exit" 2>/dev/null; then
                    echo "[$(date '+%H:%M:%S')] SSH key authentication verified for ${node}"
                    return 0
                else
                    echo "WARNING: SSH key copied but authentication still not working for ${node}"
                    return 1
                fi
            else
                echo "ERROR: Failed to copy SSH key to ${node}"
                return 1
            fi
        else
            echo "WARNING: SSH key not set up for ${node} and no SSH_PASSWORD configured"
            echo "Please either:"
            echo "  1. Set SSH_PASSWORD in the script configuration"
            echo "  2. Manually run: ssh-copy-id root@${node}"
            return 1
        fi
    } >> "${LOGFILE}" 2>&1
}

# ------------------- Get cluster nodes -------------------
get_cluster_nodes() {
    local nodes=""
    
    {
        echo "[$(date '+%H:%M:%S')] Detecting cluster nodes …"
        
        # Method 1: Try pvecm (Proxmox cluster manager)
        if command -v pvecm &> /dev/null; then
            echo "[$(date '+%H:%M:%S')] Checking pvecm nodes …"
            if pvecm status &> /dev/null 2>&1; then
                # Parse pvecm nodes output
                # Format: Nodeid Votes Name
                #              1     1 nodename (local)
                local current_short=$(hostname -s)
                while read -r line; do
                    # Skip header lines
                    if echo "$line" | grep -qE "Nodeid|Membership|---"; then
                        continue
                    fi
                    
                    # Extract node name (last field, remove (local) marker if present)
                    local nodename=$(echo "$line" | awk '{print $NF}' | sed 's/(local)//')
                    
                    # Skip empty lines, current hostname (both FQDN and short)
                    if [[ -n "$nodename" ]] && \
                       [[ "$nodename" != "${HOSTNAME}" ]] && \
                       [[ "$nodename" != "${current_short}" ]]; then
                        nodes="${nodes} ${nodename}"
                        echo "[$(date '+%H:%M:%S')] Found cluster node: ${nodename}"
                    fi
                done < <(pvecm nodes 2>/dev/null | grep -E "^[[:space:]]*[0-9]")
                
                if [[ -n "${nodes}" ]]; then
                    echo "[$(date '+%H:%M:%S')] Found nodes via pvecm: ${nodes}"
                fi
            else
                echo "[$(date '+%H:%M:%S')] pvecm status failed - not in a cluster"
            fi
        fi
        
        # Method 2: Check /etc/pve/nodes directory (fallback)
        if [[ -z "${nodes}" ]] && [[ -d /etc/pve/nodes ]]; then
            echo "[$(date '+%H:%M:%S')] Checking /etc/pve/nodes directory …"
            local pve_nodes
            pve_nodes=$(ls -1 /etc/pve/nodes 2>/dev/null | grep -v "^$(hostname -s)\$" || true)
            if [[ -n "${pve_nodes}" ]]; then
                echo "[$(date '+%H:%M:%S')] Found nodes in /etc/pve/nodes: ${pve_nodes}"
                # Convert short names to FQDN if possible
                local fqdn_nodes=""
                for node in ${pve_nodes}; do
                    # Try to get FQDN
                    local node_fqdn=$(getent hosts "${node}" 2>/dev/null | awk '{print $2}' | head -1 || echo "${node}")
                    fqdn_nodes="${fqdn_nodes} ${node_fqdn}"
                done
                nodes="${fqdn_nodes}"
            fi
        fi
        
        # Method 3: Use manual node list (fallback)
        if [[ -z "${nodes}" ]] && [[ -n "${MANUAL_NODES}" ]]; then
            echo "[$(date '+%H:%M:%S')] Using manual node list: ${MANUAL_NODES}"
            nodes="${MANUAL_NODES}"
        fi
        
        if [[ -z "${nodes}" ]]; then
            echo "[$(date '+%H:%M:%S')] No cluster nodes detected"
        else
            echo "[$(date '+%H:%M:%S')] Final node list: ${nodes}"
        fi
        
    } >> "${LOGFILE}" 2>&1
    
    echo "${nodes}" | xargs  # trim whitespace
}

# ------------------- Create remote update script -------------------
create_remote_script() {
    cat > "${REMOTE_SCRIPT}" << 'REMOTE_EOF'
#!/bin/bash
set -euo pipefail

HOSTNAME="$(hostname -f)"
APTCMD="/usr/bin/apt-get"
NEEDRESTART_PKG="needrestart"
NEEDRESTART_CMD="/usr/sbin/needs-restarting"

echo "[$(date '+%H:%M:%S')] ========== Update starting on ${HOSTNAME} =========="

# Step 1: ensure needrestart is installed
echo "[$(date '+%H:%M:%S')] Checking for ${NEEDRESTART_PKG} …"
if ! dpkg -s "${NEEDRESTART_PKG}" >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} missing – installing …"
    ${APTCMD} update -qq
    ${APTCMD} install -y -qq "${NEEDRESTART_PKG}"
    echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} installed successfully."
else
    echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} already present."
fi

# Step 2: system updates
echo "[$(date '+%H:%M:%S')] apt update …"
${APTCMD} update -qq

echo "[$(date '+%H:%M:%S')] apt full-upgrade -y …"
${APTCMD} full-upgrade -y -qq

echo "[$(date '+%H:%M:%S')] apt autoremove -y …"
${APTCMD} autoremove -y -qq

echo "[$(date '+%H:%M:%S')] apt clean …"
${APTCMD} clean -qq

# Step 3: Reboot checks
if ${NEEDRESTART_CMD} -r >/dev/null 2>&1; then
    RESTART_NEEDRESTART="⚠️  needs-restarting: reboot required"
else
    RESTART_NEEDRESTART=""
fi

if [ -f /var/run/reboot-required ]; then
    RESTART_DEBIAN="⚠️  /var/run/reboot-required exists → reboot required"
    SUBJECT_REBOOT_STATUS="Reboot required"
else
    RESTART_DEBIAN="✅  /var/run/reboot-required absent → no reboot needed"
    SUBJECT_REBOOT_STATUS="No reboot needed"
fi

if [[ -n "${RESTART_NEEDRESTART}" ]]; then
    REBOOT_SUMMARY="${RESTART_NEEDRESTART}\n${RESTART_DEBIAN}"
else
    REBOOT_SUMMARY="${RESTART_DEBIAN}"
fi

echo "[$(date '+%H:%M:%S')] ========== Update completed on ${HOSTNAME} =========="
echo -e "${REBOOT_SUMMARY}"
echo "REBOOT_STATUS:${SUBJECT_REBOOT_STATUS}"

exit 0
REMOTE_EOF
    chmod +x "${REMOTE_SCRIPT}"
}

# ------------------- Update local node -------------------
update_local_node() {
    {
        echo ""
        echo "===================================================================="
        echo "[$(date '+%H:%M:%S')] Updating LOCAL node: ${HOSTNAME}"
        echo "===================================================================="
        
        # Step 1: ensure needrestart is installed
        echo "[$(date '+%H:%M:%S')] Checking for ${NEEDRESTART_PKG} …"
        if ! dpkg -s "${NEEDRESTART_PKG}" >/dev/null 2>&1; then
            echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} missing – installing …"
            ${APTCMD} update -qq
            ${APTCMD} install -y -qq "${NEEDRESTART_PKG}"
            echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} installed successfully."
        else
            echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} already present."
        fi

        # Step 2: system updates
        echo "[$(date '+%H:%M:%S')] apt update …"
        ${APTCMD} update -qq

        echo "[$(date '+%H:%M:%S')] apt full-upgrade -y …"
        ${APTCMD} full-upgrade -y -qq

        echo "[$(date '+%H:%M:%S')] apt autoremove -y …"
        ${APTCMD} autoremove -y -qq

        echo "[$(date '+%H:%M:%S')] apt clean …"
        ${APTCMD} clean -qq

        # Step 3: Reboot checks
        if ${NEEDRESTART_CMD} -r >/dev/null 2>&1; then
            LOCAL_RESTART_NEEDRESTART="⚠️  needs-restarting: reboot required"
        else
            LOCAL_RESTART_NEEDRESTART=""
        fi

        if [ -f /var/run/reboot-required ]; then
            LOCAL_RESTART_DEBIAN="⚠️  /var/run/reboot-required exists → reboot required"
            LOCAL_REBOOT_STATUS="Reboot required"
        else
            LOCAL_RESTART_DEBIAN="✅  /var/run/reboot-required absent → no reboot needed"
            LOCAL_REBOOT_STATUS="No reboot needed"
        fi

        if [[ -n "${LOCAL_RESTART_NEEDRESTART}" ]]; then
            LOCAL_REBOOT_SUMMARY="${LOCAL_RESTART_NEEDRESTART}\n${LOCAL_RESTART_DEBIAN}"
        else
            LOCAL_REBOOT_SUMMARY="${LOCAL_RESTART_DEBIAN}"
        fi

        echo "[$(date '+%H:%M:%S')] Local node update completed"
        echo -e "${LOCAL_REBOOT_SUMMARY}"
        
    } >> "${LOGFILE}" 2>&1
}

# ------------------- Update remote node -------------------
update_remote_node() {
    local node=$1
    local result_file=$2
    local status="SUCCESS"
    local reboot_status="Unknown"
    
    {
        echo ""
        echo "===================================================================="
        echo "[$(date '+%H:%M:%S')] Updating REMOTE node: ${node}"
        echo "===================================================================="
        
        # Setup SSH key for this node if needed
        if ! copy_ssh_key_to_node "${node}"; then
            echo "ERROR: Cannot establish SSH connection to ${node}"
            status="FAILED - SSH Setup Failed"
            echo "${node}|${status}|${reboot_status}" >> "${result_file}"
            return 1
        fi
        
        # Copy script to remote node
        if ! scp ${SSH_OPTS} "${REMOTE_SCRIPT}" "root@${node}:${REMOTE_SCRIPT}" 2>&1; then
            echo "ERROR: Failed to copy update script to ${node}"
            status="FAILED - Script Transfer Failed"
            echo "${node}|${status}|${reboot_status}" >> "${result_file}"
            return 1
        fi
        
        # Execute script on remote node
        local output
        if output=$(ssh ${SSH_OPTS} "root@${node}" "bash ${REMOTE_SCRIPT}" 2>&1); then
            echo "${output}"
            # Extract reboot status from output
            reboot_status=$(echo "${output}" | grep "REBOOT_STATUS:" | cut -d: -f2 || echo "Unknown")
        else
            echo "ERROR: Failed to execute update script on ${node}"
            echo "${output}"
            status="FAILED - Script Execution Failed"
        fi
        
        # Cleanup remote script
        ssh ${SSH_OPTS} "root@${node}" "rm -f ${REMOTE_SCRIPT}" 2>&1 || true
        
        # Write result to file
        echo "${node}|${status}|${reboot_status}" >> "${result_file}"
        
    } >> "${LOGFILE}" 2>&1
}

# ------------------- Main execution -------------------
# Temporarily disable pipefail for the main section
set +e

{
    # Install sshpass if needed
    install_sshpass
    
    # Setup SSH key
    setup_ssh_key
    
    # Create remote update script
    create_remote_script
    
    # Update local node first
    update_local_node
    
    # Get cluster nodes
    CLUSTER_NODES=$(get_cluster_nodes)
    
    if [[ -z "${CLUSTER_NODES}" ]]; then
        echo ""
        echo "[$(date '+%H:%M:%S')] No other cluster nodes found or not in a cluster."
        echo "[$(date '+%H:%M:%S')] Only local node was updated."
        CLUSTER_SUMMARY="Only local node (${HOSTNAME}) was updated.\nReboot status: ${LOCAL_REBOOT_STATUS}"
    else
        echo ""
        echo "[$(date '+%H:%M:%S')] Found cluster nodes: ${CLUSTER_NODES}"
        echo "[$(date '+%H:%M:%S')] Starting updates on remote nodes..."
        
        # Initialize results storage
        RESULTS_FILE="/tmp/proxmox-update-results.$$"
        : > "${RESULTS_FILE}"
        
        # Store local node result
        echo "${HOSTNAME}|SUCCESS|${LOCAL_REBOOT_STATUS}" >> "${RESULTS_FILE}"
        
        # Update each remote node
        for node in ${CLUSTER_NODES}; do
            update_remote_node "${node}" "${RESULTS_FILE}"
        done
        
        # Build summary from results file
        CLUSTER_SUMMARY="Cluster Update Summary:\n\n"
        
        while IFS='|' read -r node status reboot; do
            CLUSTER_SUMMARY+="• ${node}: ${status} - ${reboot}\n"
        done < "${RESULTS_FILE}"
        
        rm -f "${RESULTS_FILE}"
    fi
    
    # Cleanup
    rm -f "${REMOTE_SCRIPT}"
    
} >> "${LOGFILE}" 2>&1

# Re-enable pipefail
set -e

# ------------------- Log footer & e‑mail -------------------
{
    echo "--------------------------------------------------------------------"
    echo "Proxmox Cluster Auto-Update finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Coordinating Node: ${HOSTNAME}"
    echo ""
    echo -e "${CLUSTER_SUMMARY}"
    echo "===================================================================="
    echo ""
} >> "${LOGFILE}"

# ----- SEND E‑MAIL -----
mail -s "[PROXMOX CLUSTER] Auto-Update completed on all nodes" "${MAIL_TO}" <<EOF
The scheduled Proxmox cluster update finished on all nodes.

$(echo -e "${CLUSTER_SUMMARY}")

For full details, see the log file at ${LOGFILE} on ${HOSTNAME}.

Please consider supporting this script development:
💖 Ko-fi: ko-fi.com/bagstube_nico"
🔗 Links: linktr.ee/bagstube_nico"
EOF

exit 0
