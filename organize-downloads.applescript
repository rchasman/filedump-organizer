-- Folder Action to organize Downloads folder
-- Triggered when files are added to Downloads

on adding folder items to this_folder after receiving added_items
	-- Wait 5 seconds to allow downloads to complete
	delay 5

	-- Run the organize script
	do shell script "~/Downloads/.organize/ai-organize.sh true 5"
end adding folder items to
