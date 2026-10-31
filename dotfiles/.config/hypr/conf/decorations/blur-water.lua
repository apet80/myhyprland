-- -----------------------------------------------------
-- General window decoration
-- name: "Blur Water"
-- Water surface that reacts to the pointer.
-- Requires Hyprland >= 0.57
-- -----------------------------------------------------

hl.config({
    decoration = {
        rounding = 10,
        active_opacity = 0.9,
        inactive_opacity = 0.6,
        fullscreen_opacity = 0.9,

        blur = {
            enabled = true,
            size = 3,
            passes = 4,
            new_optimizations = true,
            ignore_opacity = true,
            xray = true,
            variant = 4, -- water
            water = {
                strength = 32,
                radius = 20,
                speed = 0.76,
                damping = 0.95,
                duration = 12,
            },
        },

        shadow = {
            enabled = true,
            range = 30,
            render_power = 3,
            color = "0x66000000",
        },
    }
})

hl.layer_rule({ match = { namespace = "waybar" }, blur = true })

-- Keep the focused window free of the blur effect: no blur, fully opaque
hl.window_rule({
    name    = "blur-variant-focused-window",
    match   = { focus = true },
    no_blur = true,
    opaque  = true,
})
