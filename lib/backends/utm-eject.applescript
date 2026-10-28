-- Detach every removable drive (the install and config discs) from a stopped
-- winserver VM in UTM. Called by lib/backends/utm.sh:
--
--   osascript utm-eject.applescript NAME

on run argv
	tell application "UTM"
		set vm to first virtual machine whose name is (item 1 of argv)
		set config to configuration of vm

		set kept to {}
		repeat with d in (drives of config)
			if not (removable of d) then set end of kept to (contents of d)
		end repeat
		set drives of config to kept

		-- UTM 5.0 reads back its port forwards with a protocol it then refuses
		-- to take in: give them back without it (TCP is the default).
		set nets to {}
		repeat with n in (network interfaces of config)
			set n to contents of n
			set forwards to {}
			repeat with f in (port forwards of n)
				set end of forwards to {host address:(host address of f), host port:(host port of f), ¬
					guest address:(guest address of f), guest port:(guest port of f)}
			end repeat
			set port forwards of n to forwards
			set end of nets to n
		end repeat
		set network interfaces of config to nets

		update configuration of vm with config
	end tell
end run
