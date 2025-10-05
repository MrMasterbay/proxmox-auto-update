# Proxmox Cluster Auto-Update Script

## 📋 Overview

This Bash script automates the update process for all nodes in a Proxmox cluster. It sequentially performs a complete system update on each node and sends an email notification with the status.

## ✨ Features

- ✅ Automatic sequential updates of all cluster nodes
- ✅ Automatic SSH key setup between nodes (optional with password)
- ✅ Lock mechanism prevents concurrent executions
- ✅ Automatic installation of `needrestart` if not present
- ✅ Complete system update: `apt update`, `full-upgrade`, `autoremove`, `clean`
- ✅ Reboot status check using two methods:
  - `needs-restarting -r` (needrestart package)
  - `/var/run/reboot-required` (Debian standard)
- ✅ Detailed logging of all actions
- ✅ Email notification with summary
- ✅ No automatic reboot - administrator maintains manual control

## 📦 Prerequisites

### On the coordinating node:

```bash
apt-get install -y flock mailutils
```

Optional (for automatic SSH key setup with password):
```bash
apt-get install -y sshpass
```

### All nodes:

- Proxmox VE installed (Postfix is already included)
- Root SSH access between nodes
- Debian-based system (tested with Debian 13)

## 🚀 Installation

### 1. Download the script

```bash
cd /root
wget https://example.com/proxmox-auto-update.sh
chmod +x proxmox-auto-update.sh
```

Or create manually:
```bash
nano /root/proxmox-auto-update.sh
# Paste script content
chmod +x /root/proxmox-auto-update.sh
```

### 2. Adjust configuration

Open the script and modify the variables in the configuration section:

```bash
nano /root/proxmox-auto-update.sh
```

**Important configuration options:**

```bash
# Email recipient
MAIL_TO="root@localhost"              # Change to your email

# SSH password (optional - only if SSH keys are not yet configured)
SSH_PASSWORD=""                        # Leave empty or enter password

# Manual node list (only if no cluster is configured)
MANUAL_NODES=""                        # Example: "node2.domain.com node3.domain.com"
```

### 3. Set up SSH keys (if not already configured)

**Option A: Automatic setup with password**

Set in the script:
```bash
SSH_PASSWORD="your_root_password"
```

The script will automatically set up SSH keys on first run.

**Option B: Manual setup**

```bash
# Generate SSH key (if not present)
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""

# Copy key to all other nodes
ssh-copy-id root@node2.domain.com
ssh-copy-id root@node3.domain.com
```

### 4. Test

Run the script manually:

```bash
/root/proxmox-auto-update.sh
```

Check the log:
```bash
cat /var/log/proxmox-cluster-auto-update.log
```

## ⏰ Automation with Cron

### Daily updates at 3:00 AM

```bash
crontab -e
```

Add:
```cron
0 3 * * * /root/proxmox-auto-update.sh
```

### Weekly updates (Sunday, 3:00 AM)

```cron
0 3 * * 0 /root/proxmox-auto-update.sh
```

### Monthly updates (1st of month, 3:00 AM)

```cron
0 3 1 * * /root/proxmox-auto-update.sh
```

## 📧 Email Configuration

### Postfix is pre-installed on Proxmox

Proxmox VE comes with Postfix pre-installed and configured. You only need to verify the configuration.

### Verify Postfix configuration

```bash
# Check Postfix status
systemctl status postfix

# View main configuration
postconf -n

# Test email delivery
echo "Test message" | mail -s "Test Mail" your@email.com
```

### Configure Postfix for external delivery

Edit the main configuration:
```bash
nano /etc/postfix/main.cf
```

For internet delivery, ensure these settings:
```
myhostname = node1.yourdomain.com
mydestination = $myhostname, localhost.$mydomain, localhost
relayhost = 
inet_interfaces = all
```

Restart Postfix:
```bash
systemctl restart postfix
```

### For external SMTP relay (e.g., Gmail, Office365)

If your ISP blocks port 25, use an SMTP relay:

```bash
nano /etc/postfix/main.cf
```

Add:
```
relayhost = [smtp.gmail.com]:587
smtp_use_tls = yes
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
```

Create credentials file:
```bash
nano /etc/postfix/sasl_passwd
```

Content:
```
[smtp.gmail.com]:587 your@gmail.com:your-app-password
```

Secure and activate:
```bash
chmod 600 /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
systemctl restart postfix
```

### Test email delivery

```bash
echo "Test from Proxmox" | mail -s "Test Subject" your@email.com

# Check mail logs
tail -f /var/log/mail.log

# Check mail queue
mailq
```

## 📊 Log Files

### Main log file

```bash
/var/log/proxmox-cluster-auto-update.log
```

Contains:
- Timestamps of all actions
- Update progress per node
- Errors and warnings
- Reboot status
- Summary

### View logs

```bash
# Full log
cat /var/log/proxmox-cluster-auto-update.log

# Last 50 lines
tail -n 50 /var/log/proxmox-cluster-auto-update.log

# Live view while script is running
tail -f /var/log/proxmox-cluster-auto-update.log

# Search for errors
grep -i error /var/log/proxmox-cluster-auto-update.log
```

### Set up log rotation

```bash
nano /etc/logrotate.d/proxmox-auto-update
```

Content:
```
/var/log/proxmox-cluster-auto-update.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
}
```

## 🔍 Cluster Detection

The script automatically detects cluster nodes using three methods:

### 1. Proxmox Cluster Manager (pvecm)
Preferred method for Proxmox clusters:
```bash
pvecm nodes
```

### 2. /etc/pve/nodes directory
Fallback method:
```bash
ls /etc/pve/nodes
```

### 3. Manual node list
For non-cluster setups or as override:
```bash
MANUAL_NODES="node2.domain.com node3.domain.com"
```

## 📝 Example Output

### Successful execution

```
====================================================================
Proxmox Cluster Auto-Update started: 2025-10-05 03:00:01
Coordinating Node: node1.domain.com
====================================================================

[03:00:01] Updating LOCAL node: node1.domain.com
[03:00:01] apt update …
[03:00:03] apt full-upgrade -y …
[03:00:25] apt autoremove -y …
[03:00:26] apt clean …
[03:00:26] Local node update completed
⚠️  /var/run/reboot-required exists → reboot required

[03:00:27] Found cluster nodes: node2.domain.com node3.domain.com
[03:00:27] Starting updates on remote nodes...

====================================================================
[03:00:27] Updating REMOTE node: node2.domain.com
====================================================================
[03:00:28] ========== Update starting on node2.domain.com ==========
[03:00:45] ========== Update completed on node2.domain.com ==========
✅  /var/run/reboot-required absent → no reboot needed

====================================================================
[03:01:15] Updating REMOTE node: node3.domain.com
====================================================================
[03:01:16] ========== Update starting on node3.domain.com ==========
[03:01:33] ========== Update completed on node3.domain.com ==========
⚠️  /var/run/reboot-required exists → reboot required

--------------------------------------------------------------------
Proxmox Cluster Auto-Update finished: 2025-10-05 03:01:35

Cluster Update Summary:

• node1.domain.com: SUCCESS - Reboot required
• node2.domain.com: SUCCESS - No reboot needed
• node3.domain.com: SUCCESS - Reboot required
====================================================================
```

### Email notification

**Subject:** `[PROXMOX CLUSTER] Auto-Update completed on all nodes`

**Content:**
```
The scheduled Proxmox cluster update finished on all nodes.

Cluster Update Summary:

• node1.domain.com: SUCCESS - Reboot required
• node2.domain.com: SUCCESS - No reboot needed
• node3.domain.com: SUCCESS - Reboot required

For full details, see the log file at /var/log/proxmox-cluster-auto-update.log on node1.domain.com.
```

## 🔧 Troubleshooting

### Problem: SSH connection fails

**Solution 1:** Set up SSH keys manually
```bash
ssh-copy-id root@node2.domain.com
```

**Solution 2:** Set SSH_PASSWORD in script
```bash
SSH_PASSWORD="your_password"
```

**Solution 3:** Test SSH connection
```bash
ssh -v root@node2.domain.com
```

### Problem: Script already running (lock file)

**Symptom:** Error message "another instance is already running"

**Solution:**
```bash
# Check if process is still running
ps aux | grep proxmox-cluster-auto-update

# If no process is running, remove lock file
rm /var/run/proxmox-auto-update.lock
```

### Problem: No email received

**Solution 1:** Test mail configuration
```bash
echo "Test" | mail -s "Test" your@email.com
tail -f /var/log/mail.log
```

**Solution 2:** Check Postfix status
```bash
systemctl status postfix
journalctl -u postfix -n 50
```

**Solution 3:** Check mail queue
```bash
mailq
postqueue -p
```

**Solution 4:** Check if emails are being blocked
```bash
# Check if port 25 is blocked by ISP
telnet smtp.gmail.com 25

# If blocked, configure SMTP relay (see Email Configuration section)
```

### Problem: Node not detected

**Symptom:** "No cluster nodes detected"

**Solution 1:** Check cluster status
```bash
pvecm status
pvecm nodes
```

**Solution 2:** Use manual node list
```bash
# Set in script:
MANUAL_NODES="node2.domain.com node3.domain.com"
```

### Problem: Update fails

**Symptom:** "apt full-upgrade" error

**Solution 1:** Check repository issues
```bash
apt-get update
cat /etc/apt/sources.list
```

**Solution 2:** Check disk space
```bash
df -h
apt-get clean
apt-get autoremove
```

**Solution 3:** Check held packages
```bash
apt-mark showhold
```

## 🔒 Security Considerations

1. **SSH Keys:** Use SSH keys instead of passwords when possible
2. **Password in script:** If `SSH_PASSWORD` is set, protect the script:
   ```bash
   chmod 700 /root/proxmox-auto-update.sh
   ```
3. **Log files:** Do not contain passwords, but do contain system information
4. **Root access:** Script must run as root
5. **Backups:** Make backups before major updates

## 🎯 Best Practices

### 1. Schedule maintenance windows
```bash
# Cron for Sunday 3:00 AM (low load)
0 3 * * 0 /root/proxmox-auto-update.sh
```

### 2. Set up monitoring
```bash
# Nagios/Icinga check
/usr/lib/nagios/plugins/check_file_age -f /var/log/proxmox-cluster-auto-update.log -w 86400 -c 172800
```

### 3. Test environment
Test updates in a test environment before applying to production.

### 4. Staged updates
For large clusters: Update nodes in groups
```bash
# Group 1: Mondays
MANUAL_NODES="node2 node3"

# Group 2: Wednesdays
MANUAL_NODES="node4 node5"
```

### 5. Backup before updates
```bash
# Proxmox backup before cron job
0 2 * * 0 vzdump --all --storage backup-storage
0 3 * * 0 /root/proxmox-auto-update.sh
```

## 📚 Advanced Configuration

### Update only specific nodes

```bash
# In script:
MANUAL_NODES="node2.domain.com node3.domain.com"

# Ignore nodes from pvecm - only use MANUAL_NODES
# Comment out pvecm detection (lines 165-190)
```

### Different update times per node

Create multiple script variants:

```bash
# Script 1: Only nodes 1+2
cp proxmox-auto-update.sh update-group1.sh
# Set: MANUAL_NODES="node1 node2"

# Script 2: Only nodes 3+4
cp proxmox-auto-update.sh update-group2.sh
# Set: MANUAL_NODES="node3 node4"

# Crontab:
0 3 * * 1 /root/update-group1.sh  # Monday
0 3 * * 3 /root/update-group2.sh  # Wednesday
```

### Custom APT options

Modify in script:

```bash
# Change line 31:
APTCMD="/usr/bin/apt-get -o Dpkg::Options::='--force-confold'"
```

### Pre/Post-update hooks

Add custom commands:

```bash
# Before update (line 330):
echo "[$(date '+%H:%M:%S')] Running pre-update hook …"
/root/pre-update-hook.sh

# After update (line 375):
echo "[$(date '+%H:%M:%S')] Running post-update hook …"
/root/post-update-hook.sh
```

## 📬 Email Troubleshooting Guide

### Check if Postfix is running
```bash
systemctl status postfix
systemctl enable postfix
systemctl start postfix
```

### Test local mail delivery
```bash
echo "Test local" | mail -s "Test" root
cat /var/mail/root
```

### Check Postfix configuration
```bash
postconf -n | grep -E 'myhostname|mydestination|relayhost'
```

### View mail logs in real-time
```bash
tail -f /var/log/mail.log
```

### Check mail queue and errors
```bash
mailq
postqueue -p
postcat -q QUEUE_ID  # Replace QUEUE_ID with actual ID from mailq
```

### Flush mail queue
```bash
postqueue -f
```

### Common Postfix fixes

**Fix 1: Set proper hostname**
```bash
hostnamectl set-hostname node1.yourdomain.com
postconf -e "myhostname = node1.yourdomain.com"
systemctl restart postfix
```

**Fix 2: Allow localhost relay**
```bash
postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128"
systemctl restart postfix
```

**Fix 3: Fix email aliases**
```bash
echo "root: your@email.com" >> /etc/aliases
newaliases
systemctl restart postfix
```

## 🆘 Support & Contact

- **Proxmox Forum:** https://forum.proxmox.com
- **Proxmox Documentation:** https://pve.proxmox.com/wiki/Main_Page
- **Debian Wiki:** https://wiki.debian.org

## 📄 License

This script is freely available and can be modified and used as desired.

## 🔄 Changelog

### Version 1.0 (2025-10-05)
- Initial version
- Automatic cluster node detection
- SSH key management
- Email notifications
- Detailed logging
- Reboot status detection

---

**⚠️ IMPORTANT:** This script does NOT perform automatic reboots. After updates requiring a reboot, you must manually restart the nodes!

```bash
# Check reboot status
cat /var/run/reboot-required

# Restart node
reboot
```
