#!/bin/bash
#
# Proxmox Auto-Update (Debian 13 base)
# ---------------------------------------------------------------
# • Prevents concurrent runs via a lock file
# • Installs needrestart if missing
# • Runs apt update / full-upgrade / autoremove / clean
# • Checks reboot requirement in two ways:
#      – needs-restarting -r  (only reported when a reboot is needed)
#      – /var/run/reboot-required  (used for the e‑mail subject)
# • Logs everything and sends an e‑mail (no automatic reboot)
# ---------------------------------------------------------------

set -euo pipefail                     # abort on errors / undefined vars

# ------------------- Configuration -------------------
HOSTNAME="$(hostname -f)"               # Fully qualified host name
LOCKFILE="/var/run/proxmox-auto-update.lock"
LOGFILE="/var/log/proxmox-auto-update.log"
MAIL_TO="root@localhost"               # Change to your preferred recipient
APTCMD="/usr/bin/apt-get"              # Absolute path to apt-get
NEEDRESTART_PKG="needrestart"
NEEDRESTART_CMD="/usr/sbin/needs-restarting"
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
    echo "Proxmox Auto-Update started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Node: ${HOSTNAME}"
    echo "Lock file: ${LOCKFILE}"
    echo "Log file: ${LOGFILE}"
    echo "--------------------------------------------------------------------"
} >> "${LOGFILE}"

# ------------------- Error handler -------------------
error_handler() {
    {
        echo "ERROR: The update script terminated on ${HOSTNAME}."
        echo "Please inspect the log file above for details."
    } >> "${LOGFILE}"
    mail -s "[PROXMOX][${HOSTNAME}] Auto-Update failed" "${MAIL_TO}" < "${LOGFILE}"
}
trap error_handler ERR

# ------------------- Step 1: ensure needrestart is installed -------------------
{
    echo "[$(date '+%H:%M:%S')] Checking for ${NEEDRESTART_PKG} …"
    if ! dpkg -s "${NEEDRESTART_PKG}" >/dev/null 2>&1; then
        echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} missing – installing …"
        ${APTCMD} update -qq                # quiet update of package lists
        ${APTCMD} install -y -qq "${NEEDRESTART_PKG}"
        echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} installed successfully."
    else
        echo "[$(date '+%H:%M:%S')] ${NEEDRESTART_PKG} already present."
    fi
} >> "${LOGFILE}" 2>&1

# ------------------- Step 2: system updates -------------------
{
    echo "[$(date '+%H:%M:%S')] apt update …"
    ${APTCMD} update -qq

    echo "[$(date '+%H:%M:%S')] apt full-upgrade -y …"
    ${APTCMD} full-upgrade -y -qq

    echo "[$(date '+%H:%M:%S')] apt autoremove -y …"
    ${APTCMD} autoremove -y -qq

    echo "[$(date '+%H:%M:%S')] apt clean …"
    ${APTCMD} clean -qq
} >> "${LOGFILE}" 2>&1

# ------------------- Step 3: Reboot checks -------------------
# 1. needs-restarting (only report when a reboot is required)
if ${NEEDRESTART_CMD} -r >/dev/null 2>&1; then
    RESTART_NEEDRESTART="⚠️  needs-restarting: reboot required"
else
    RESTART_NEEDRESTART=""   # suppress the “no reboot needed” line
fi

# 2. Debian's /var/run/reboot-required flag (used for subject)
if [ -f /var/run/reboot-required ]; then
    RESTART_DEBIAN="⚠️  /var/run/reboot-required exists → reboot required"
    SUBJECT_REBOOT_STATUS="Reboot required"
else
    RESTART_DEBIAN="✅  /var/run/reboot-required absent → no reboot needed"
    SUBJECT_REBOOT_STATUS="No reboot needed"
fi

# Build combined summary (skip empty parts)
if [[ -n "${RESTART_NEEDRESTART}" ]]; then
    REBOOT_SUMMARY="${RESTART_NEEDRESTART}\n${RESTART_DEBIAN}"
else
    REBOOT_SUMMARY="${RESTART_DEBIAN}"
fi

# ------------------- Log footer & e‑mail -------------------
{
    echo "--------------------------------------------------------------------"
    echo "Proxmox Auto-Update finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Node: ${HOSTNAME}"
    echo -e "${REBOOT_SUMMARY}"
    echo "===================================================================="
    echo ""
} >> "${LOGFILE}"

# ----- SEND E‑MAIL (subject now clean, ASCII only) -----
mail -s "[PROXMOX][${HOSTNAME}] Auto-Update completed - ${SUBJECT_REBOOT_STATUS}" "${MAIL_TO}" <<EOF
The scheduled Proxmox update finished successfully on **${HOSTNAME}**.

Reboot status:
$(echo -e "${REBOOT_SUMMARY}")

For full details, see the log file at ${LOGFILE}.
EOF

exit 0
