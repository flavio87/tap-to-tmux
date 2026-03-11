-- NTM Connect URL Handler
-- Writes the session name to a trigger file, which is picked up by
-- ntm-connect-watcher (a background process running in a proper terminal context
-- where Aerospace IPC works).
--
-- Build: osacompile -o ~/Applications/NTMConnect.app NTMConnect.applescript
-- Then edit ~/Applications/NTMConnect.app/Contents/Info.plist to add URL scheme.

on open location theURL
	-- Parse session name from ntm-connect://SESSION
	set sessionName to text 15 thru -1 of theURL
	if sessionName ends with "/" then set sessionName to text 1 thru -2 of sessionName

	-- Write session name to trigger file — the watcher will pick it up
	do shell script "echo " & quoted form of sessionName & " > /tmp/ntm-connect-trigger"
end open location
