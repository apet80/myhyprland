-- -----------------------------------------------------
-- General window decoration
-- name: "Blur Aurora"
-- Aurora curtains over the blurred backdrop.
-- Animated: speed > 0 increases GPU usage (0 = frozen).
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
            variant = 9, -- aurora
            aurora = {
                speed = 1,
                intensity = 0.35,
                color1 = "rgba(29f0a0ff)",
                color2 = "rgba(7a4dffff)",
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
