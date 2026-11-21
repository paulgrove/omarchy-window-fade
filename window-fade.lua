local function class_match(excluded_apps)
  local classes = {"steam_proton"}
  for _, app in ipairs(excluded_apps) do
    classes[#classes + 1] = app:gsub("[\\.^$|?*+(){}%[%]]", "\\%0")
  end
  return "negative:^(?:" .. table.concat(classes, "|") .. ")$"
end

local function create_rules(screen, class, shader)
  local match = {
    class = class,
    tag = "negative:window-fade-exclude-" .. screen,
    workspace = "m[" .. screen .. "]",
  }
  local prefix = "window-fade-profile-" .. screen
  return {
    hl.window_rule({
      name = prefix .. "-inactive",
      match = match,
      tag = "+shader_inactive:" .. shader,
      no_dim = true,
    }),
    hl.window_rule({
      name = prefix .. "-unfocus",
      match = match,
      tag = "+shader_unfocus:" .. shader,
    }),
    -- Use the transition in place of the resting shader to avoid double dimming.
    hl.window_rule({
      name = prefix .. "-replace",
      match = match,
      tag = "+shader_replace:1",
    }),
  }
end

local function set_enabled(rules, enabled)
  for _, rule in ipairs(rules) do
    if rule:is_enabled() ~= enabled then
      rule:set_enabled(enabled)
    end
  end
end

return function(shader_dir, active_screens)
  -- Hyprland discards these handles on config reload.
  _G.omarchy_window_fade_profiles = _G.omarchy_window_fade_profiles or {}
  local by_screen = _G.omarchy_window_fade_profiles
  for screen, current in pairs(by_screen) do
    if not active_screens[screen] then
      set_enabled(current.rules, false)
    end
  end

  for screen, profile in pairs(active_screens) do
    local class = class_match(profile.excluded_apps)
    local shader = shader_dir .. "/monitor-" .. screen .. ".glsl"
    hl.plugin.HyprWindowShade.setwindowfadeopacity(shader, profile.opacity, profile.seconds)
    local current = by_screen[screen]
    if not current or current.class ~= class then
      by_screen[screen] = {class = class, rules = create_rules(screen, class, shader)}
    else
      set_enabled(current.rules, true)
    end
  end
end
