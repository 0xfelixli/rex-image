-- Optional Rex fish tabs and splits. Install on the client Mac running the Rex app.
-- The target host must have fish at this path.
local FISH = "/opt/homebrew/bin/fish"

local function fish_options(ctx)
    local options = { shell = FISH }
    if ctx.block_id then
        local ok, process = pcall(function()
            return rex.block.call("com.superlogical.terminal", "process", {})
        end)
        if ok and process and process.foreground then
            options.cwd = process.foreground.cwd
        end
    end

    return options
end

local function fish_split(ctx, direction)
    local options = fish_options(ctx)
    local result, err = rex.session.new_split{
        anchor_id = ctx.block_id,
        direction = direction,
        side = "after",
        focus = true,
        layout = rex.layout.block{
            flavor = "com.superlogical.terminal.shell",
            options = options,
        },
    }
    if not result then error(err or "Failed to create fish split") end
    return result
end

rex.action{
    name = "fish_tab",
    title = "Fish: New Tab",
    run = function(ctx)
        local result, err = rex.session.new_window{
            layout = rex.layout.block{
                flavor = "com.superlogical.terminal.shell",
                options = fish_options(ctx),
            },
        }
        if not result then error(err or "Failed to create fish tab") end
        return result
    end,
}

rex.action{
    name = "fish_split_right",
    title = "Fish: Split Right",
    run = function(ctx) return fish_split(ctx, "horizontal") end,
}
rex.action{
    name = "fish_split_down",
    title = "Fish: Split Down",
    run = function(ctx) return fish_split(ctx, "vertical") end,
}

local function bind_fish(key, action)
    rex.unbind(key)
    rex.bind(key, action)
end
bind_fish("cmd+d", "fish_split_right")
bind_fish("cmd+[KeyD]", "fish_split_right")
bind_fish("cmd+shift+d", "fish_split_down")
bind_fish("cmd+shift+[KeyD]", "fish_split_down")

bind_fish("cmd+t", "fish_tab")
bind_fish("cmd+[KeyT]", "fish_tab")
