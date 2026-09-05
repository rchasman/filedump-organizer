-- Folder Action to organize Downloads folder
-- Triggered when files are added to Downloads
-- After editing: recompile with
--   osacompile -o ~/Library/Scripts/Folder\ Action\ Scripts/organize-downloads.scpt organize-downloads.applescript

on adding folder items to this_folder after receiving added_items
	-- Wait 5 seconds to allow downloads to complete
	delay 5

	-- Thin Bun CLI: anydoc → gateway (nova-2-lite) → dedupe → move
	-- Budget = max gateway classify calls for this Folder Action run
	do shell script "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.bun/bin:$PATH\"; cd \"$HOME/Downloads/.organize\" && bun run organize 15"
end adding folder items to
