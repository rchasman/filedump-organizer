-- Folder Action to organize Downloads folder
-- Triggered when files are added to Downloads
-- After editing: recompile with
--   osacompile -o ~/Library/Scripts/Folder\ Action\ Scripts/organize-downloads.scpt organize-downloads.applescript

on adding folder items to this_folder after receiving added_items
	-- Wait 5 seconds to allow downloads to complete
	delay 5

	-- Heuristics/fast moves always run; this limit is Gemini budget for ambiguous leftovers.
	-- Bulk dumps: run manually with a higher limit, e.g. ./ai-organize.sh 50
	do shell script "~/Downloads/.organize/ai-organize.sh 15"
end adding folder items to
