# Linux Baseline OS & Kernel Hardening with Ansible

[![Ansible CI & Security Lint](https://github.com/romanmgaranzuay/ansible-linux-hardening/actions/workflows/lint.yml/badge.svg)](https://github.com/romanmgaranzuay/ansible-linux-hardening/actions/workflows/lint.yml)

Automated, idempotent Linux system hardening pipeline targeting Center for Internet Security (CIS) benchmarks for Ubuntu Server (ARM64 / x86_64).

---

## 📊 Security Audit & Compliance Validation (Lynis)

Security posture improvements are benchmarked using Lynis system audits across sequential hardening milestones:

| Hardening Phase | Lynis Index | Focus Areas | Status |
| :--- | :---: | :--- | :--- |
| **Baseline** | `61` | Stock Ubuntu Server 24.04 LTS installation | Initial State |
| **OS Hardening** | `71` | Kernel (`sysctl`), SSH Daemon (`ssh`), Filesystem mounts (`filesystem`) | Completed |
| **Auditing & Detection (Local VM)** | `80` | Kernel Auditing (`auditd`), Intrusion Prevention (`fail2ban`), FIM (`aide`), Rootkits (`rkhunter`) | **Completed** |
| **AWS Cloud Hardening & SSM Baseline** | `79` | UFW Firewall, Process Accounting Daemons (`acct`, `sysstat`), Zero-Ingress Security Group | **Completed** |

<p align="center">
  <img src="docs/images/os-hardening-audit-71.png" alt="Lynis Security Audit Score - 71" width="45%" />
  <img src="docs/images/auditing-and-ids-audit-80.png" alt="Lynis Security Audit Score - 80" width="45%" />
</p>

---

## 🏗️ Architecture: Zero-Ingress Cloud Deployment

The pipeline deploys and hardens instances without exposing administrative network interfaces to the public internet:

```text
[ Developer Workstation ] (macOS / Python venv)
         │
         │  Ansible Playbook via community.aws.aws_ssm transport
         ▼
[ AWS Systems Manager / S3 Staging Bucket ]
         │
         │  Encrypted Agent Channel (Outbound HTTPS 443 Only)
         ▼
[ AWS Custom VPC (10.0.0.0/16) ]
    └── [ Public Subnet (10.0.0.0/24) ]
            └── [ EC2 t4g.micro (ARM64 / Ubuntu 24.04 LTS) ]
                     ├── Security Group: 0 Inbound Rules (Port 22 Closed)
                     ├── Host Firewall: UFW Default-Deny Ingress
                     ├── Auditing Subsystems: auditd + AIDE + fail2ban
                     └── Output Artifact: Hardened Golden AMI (ami-0bbf26689dd6f40b6)
```
* **No Open SSH Port**: Admin access is managed out-of-band via AWS Systems Manager Session Manager, removing SSH brute-force attack vectors.
* **Ephemeral Staging**: Playbooks and payload files are staged in a private S3 bucket and led down dynamically by AWS SSM Agent. 
* **Immutable Snapshot**: Compliant image captured as reusable Golden AMI before destroying EC2 instance. 

## 🛡️ Implemented Security Controls

### 1. Kernel & Network Stack Defense (`tasks/sysctl.yml`)
* **ASLR Enforcement:** Configures `kernel.randomize_va_space = 2` to mitigate memory corruption and buffer overflow exploits.
* **Kernel Pointer & Buffer Restraints:** Enforces `kernel.kptr_restrict = 2` and `kernel.dmesg_restrict = 1` to hide sensitive kernel memory addresses from unprivileged users.
* **Network Defense-in-Depth:**
  * Mitigates SYN flood denial-of-service via `net.ipv4.tcp_syncookies = 1`.
  * Drops spoofed packets via Reverse Path Filtering (`rp_filter = 1`).
  * Disables ICMP redirect acceptance and packet routing forwarding.
  * Enables martian packet logging for source-route anomaly detection.

### 2. SSH Daemon Lockdown (`tasks/ssh.yml`)
* Disables remote root login (`PermitRootLogin no`) and blank passwords (`PermitEmptyPasswords no`).
* Enforces key-based authentication exclusively (`PasswordAuthentication no`).
* Implements connection rate limiting (`MaxAuthTries 3`) and idle session termination (`ClientAliveInterval 300`, `ClientAliveCountMax 2`).
* Disables X11 graphical forwarding (`X11Forwarding no`).
* Utilizes configuration validation hooks (`validate: /usr/sbin/sshd -t -f %s`) to prevent service lockout on syntax errors.

### 3. Attack Surface & Filesystem Hardening (`tasks/filesystem.yml`)
* **Legacy Filesystem Blacklisting:** Disables obsolete filesystems (`cramfs`, `freevxfs`, `jffs2`, `hfs`, `hfsplus`, `udf`) via `/etc/modprobe.d/` overrides to minimize kernel attack surfaces.
* **Shared Memory Isolation:** Restricts `/dev/shm` mounts in `/etc/fstab` with `nodev`, `nosuid`, and `noexec` flags.

### 4. User Authentication & PAM Governance (`tasks/pam.yml`)
* Enforces password entropy via `libpam-pwquality` (minimum 14 characters, character class diversity, history restrictions).
* Establishes password aging thresholds (`PASS_MAX_DAYS 90`, `PASS_MIN_DAYS 1`) and restrictive default umasks (`UMASK 027`) in `/etc/login.defs`.

### 5. Kernel Auditing & System Accounting (`tasks/auditd.yml`)
* Deploys `auditd` and `audispd-plugins` with persistent buffer management.
* Configures immutable (`-e 2`) kernel audit rules monitoring modifications to authentication databases (`/etc/passwd`, `/etc/shadow`), sudoers privileges, and system network configurations.
* Enables process accounting daemons `sysstat` and `acct`.

### 6. Dynamic Intrusion Prevention & Firewall
* Integrates `fail2ban` with the `systemd` journal backend.
* Configures `ufw` with default-deny ingress policy behind AWS Security Groups.

### 7. File Integrity Monitoring & Toolchain Lockdown (`tasks/integrity.yml`)
* Deploys **AIDE** (Advanced Intrusion Detection Environment) for cryptographic file integrity monitoring.
* Configures **RKHunter** for automated rootkit, backdoor, and exploit pattern analysis.
* Audits core package authenticity against upstream cryptographic hashes via `debsums`.
* Restricts compiler access (`gcc`, `as`, `g++`) to root execution only.

### 8. Legal Compliance Warning Banners (`tasks/banners.yml`)
* Deploys authorized access legal notices to `/etc/issue` (local console) and `/etc/issue.net` (remote SSH sessions).

---

## ⚙️ Shift-Left CI/CD Pipeline

All Ansible tasks, playbooks, and configuration files are validated continuously on pull requests via GitHub Actions:
* **YAML Linting:** Validates formatting and syntax consistency via `yamllint`.
* **Playbook Syntax Check:** Runs `ansible-playbook --syntax-check` prior to staging.
* **Security & Best Practice Linting:** Enforces modern Ansible standards and catches execution antipatterns using `ansible-lint`.

---

## 📁 Project Structure

```text
ansible-hardening/
├── .github/
│   └── workflows/
│       └── lint.yml           # CI workflow for syntax & security linting
├── terraform/                 # AWS Infrastructure as Code definitions
│   ├── main.tf                # VPC, IAM Instance Profile, S3 Staging Bucket, EC2
│   └── .terraform.lock.hcl    # Deterministic provider version locks
├── ansible.cfg                # Execution settings & privilege escalation
├── inventory.ini              # Target host definitions (SSM transport configuration)
├── site.yml                   # Master orchestration playbook
├── docs/
│   └── images/                # Audit scan evidence and validation metrics
└── roles/
    └── security/
        ├── handlers/
        │   └── main.yml       # Service notification handlers (e.g., sshd reload)
        └── tasks/
            ├── main.yml       # Primary task execution entry point
            ├── sysctl.yml     # Kernel tuning and network defense
            ├── ssh.yml        # SSH daemon hardening & privilege separation
            ├── filesystem.yml # Filesystem restrictions and module blacklisting
            ├── pam.yml        # PAM policies and password aging
            ├── auditd.yml     # Linux audit subsystem rules
            ├── fail2ban.yml   # Dynamic IP banning rules
            ├── integrity.yml  # AIDE FIM, RKHunter, and compiler restrictions
            └── banners.yml    # Compliance login notices
```

## Takeaways and Tradeoffs 
* **Local vs Cloud Score Differences (Lynis 80 vs 79)**: Local machine hardening scores (**80**) rely on dedicated disk partitioning. On cloud architectures, the multi-partition scheme adds unnecessary overhead for disk expansion and can break application runtimes. Achieving a **79** is ideal for CIS compliance while maintaining cloud operability.

* **Zero-Ingress Transport**: Running Ansible over SSM and not SSH requires standardizing on `ansible_user=ssm-user` and routing execution staging through S3 bucket with restrictive IAM access.

* **Preserving Hardened Configs During Upgrades**: Automated package upgrades (apt-get dist-upgrade) trigger maintainer file overwrite prompts. CIS-managed templates (such as /etc/ssh/sshd_config) need to be retained to maintain configuration baseline integrity.

* **Idempotency in Automation**: Designing tasks with validation checks ensures repeated playbook runs enforce baseline state without service interruptions or configuration drift.


## Try it yourself

### Prerequisites
* Target Host: Ubuntu Server 24.04+ (ARM64 / x86_64)
* Local Workstation: Python 3.10+ in a virtual environment (`.venv`), Terraform 1.5+, AWS CLI configured with appropriate admin permissions. 
* Required Collections: `ansible-galaxy collection install amazon.aws community.aws ansible.posix`

### Execution Steps:

1. **Clone the repository:**
   ```bash
   git clone https://github.com/<your-username>/ansible-hardening.git
   cd ansible-hardening
   ```
2. **Configure your inventory:**
   ```text
   Update inventory.ini with your target host connection settings (or use local execution).
   ```
   ```ini
   [aws_hardening_targets]
   i-037ff79be19ce2ed8

   [aws_hardening_targets:vars]
   ansible_connection=community.aws.aws_ssm
   ansible_aws_ssm_region=us-east-1
   ansible_aws_ssm_bucket_name=ansible-ssm-staging-your-bucket-id
   ansible_user=ssm-user
   ansible_become=true
   ansible_python_interpreter=/usr/bin/python3
   ```

3. **Execute the playbook:**
   ```bash
   export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES # If running Python under macOS Apple Silicon...resolves POSIX fork() constraints
   ansible-playbook -i inventory.ini site.yml
   ```
4. **Initialize Integrity Baselines and Audit via SSM**
   ```bash
   aws ssm start-session --target <INSTANCE_ID>

   # Inside SSM Session:
   sudo aideinit && sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   sudo rkhunter --propupd
   sudo lynis audit system --quick
   exit
   ```
5. **Bake Golden AMI and Destroy**
   ```bash
   # Bake AMI (From local workstation)
   aws ec2 create-image \
      --instance-id <INSTANCE_ID> \
      --name "ubuntu-24.04-arm64-hardened-cis-$(date +%Y%m%d)" \
      --description "Ubuntu 24.04 ARM64 CIS hardened image" \
      --no-reboot

   # Wait for availability
   aws ec2 wait image-available --image-ids <NEW_IMAGE_ID>

   # Tear down compute infrastructure to stop billing
   cd terraform
   terraform destroy -auto-approve
   ```
