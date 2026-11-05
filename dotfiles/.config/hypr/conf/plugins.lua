-- Hyprland plugins (installed and loaded via hyprpm, see conf/autostart.lua)

-- hypr-dynamic-cursors: https://github.com/VirtCode/hypr-dynamic-cursors
-- Guarded so the config stays valid when the plugin isn't loaded.
if hl.plugin.dynamic_cursors then
	hl.config({
		plugin = {
			dynamic_cursors = {
				enabled = true,

				-- tilt | rotate | stretch | none
				mode = "rotate",
				threshold = 2,

				rotate = {
					-- length in px of the simulated stick used to rotate the cursor
					-- most realistic if this is your actual cursor size
					length = 20,

					-- clockwise offset applied to the angle in degrees
					-- this will apply to ALL shapes
					offset = 0.0,
				},
				-- shake to find: magnify the cursor when it's shaken
				shake = {
					enabled = true,
					threshold = 6.0,
					base = 4.0,
					speed = 4.0,
					timeout = 2000,
				},

				hyprcursor = {
					enabled = true,
					nearest = 1,
					resolution = -1,
					fallback = "clientside",
				},
			},
		},
	})
end
