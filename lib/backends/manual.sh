# shellcheck shell=bash
# "manual" backend: winserver prepares the media, you create the VM in
# whatever hypervisor you like (UTM, Hyper-V, Proxmox, VMware Workstation…).

be_manual_available() { return 0; }
be_manual_describe() { printf 'any hypervisor (you attach the discs)'; }
be_manual_needs_noprompt() { return 1; }
be_manual_tools_iso() { :; }
be_manual_require() { :; }
be_manual_create() { :; }
be_manual_running() { return 1; }
be_manual_start() { die "'$NAME' is a manual VM: start it in your hypervisor (see 'winserver info $NAME')"; }
be_manual_stop() { :; }
be_manual_eject() { :; }
be_manual_destroy() { :; }
be_manual_address() { :; }
be_manual_port() { case "$1" in rdp) echo 3389 ;; ssh) echo 22 ;; winrm) echo 5985 ;; esac; }
