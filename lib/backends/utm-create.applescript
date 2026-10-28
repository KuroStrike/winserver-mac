-- Create a winserver VM in UTM and print its id. Called by lib/backends/utm.sh:
--
--   osascript utm-create.applescript NAME ARCH MEMORY_MIB CPUS HYPERVISOR DISK_MIB NIC DISPLAY
--                                    RDP_PORT SSH_PORT WINRM_PORT ISO [ISO...]
--
-- ARCH is aarch64 or x86_64, HYPERVISOR true or false. Each ISO becomes a CD drive.

on run argv
	set {vmName, arch, memMiB, cpus, hv, diskMiB, nic, disp, rdpPort, sshPort, winrmPort} to items 1 thru 11 of argv
	-- File references are made here: inside the tell block, UTM would be asked for them.
	set isos to {}
	repeat with i from 12 to count of argv
		set end of isos to POSIX file (item i of argv)
	end repeat

	tell application "UTM"
		-- The disk comes first: once Setup has written Windows to it, the
		-- firmware boots it instead of the install disc at the first reboot.
		set theDrives to {{interface:NVMe, guest size:(diskMiB as integer)}}
		repeat with iso in isos
			if arch is "aarch64" then
				set end of theDrives to {removable:true, interface:USB, source:(contents of iso)}
			else
				set end of theDrives to {removable:true, interface:IDE, source:(contents of iso)}
			end if
		end repeat

		-- No "protocol" key: UTM 5.0 cannot read TCP from a script, and TCP is the default.
		set forwards to {{host address:"127.0.0.1", host port:(rdpPort as integer), guest port:3389}, ¬
			{host address:"127.0.0.1", host port:(sshPort as integer), guest port:22}, ¬
			{host address:"127.0.0.1", host port:(winrmPort as integer), guest port:5985}}

		set config to {name:vmName, architecture:arch, memory:(memMiB as integer), cpu cores:(cpus as integer), ¬
			hypervisor:(hv is "true"), uefi:true, drives:theDrives, ¬
			network interfaces:{{hardware:nic, mode:emulated, port forwards:forwards}}, displays:{{hardware:disp}}}
		if arch is "x86_64" then set config to config & {machine:"q35"}

		set vm to make new virtual machine with properties {backend:qemu, configuration:config}
		return id of vm
	end tell
end run
