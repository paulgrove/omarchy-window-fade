#!/usr/bin/env bash
set -euo pipefail

project_dir=$(dirname -- "$(dirname -- "$(realpath -- "$0")")")
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$UID}/omarchy-window-fade"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
config_file="$config_dir/shell.json"
profiles_file="$config_dir/window-fade-profiles.json"
engine="$project_dir/HyprWindowShade.so"
engine_version=window-fade-delay-3
id=pgrove.window-fade

if [[ ${1:-} == --settle ]]; then
  sleep 0.25
fi

mkdir -p -m 700 -- "$runtime_dir"
exec 9>"$runtime_dir/sync.lock"
flock -w 5 9

apply_rules() {
  local lua_file lua_shader_dir result
  lua_file=$(jq -n --arg path "$project_dir/window-fade.lua" '$path')
  lua_shader_dir=$(jq -n --arg path "$runtime_dir" '$path')
  result=$(hyprctl eval "dofile($lua_file)($lua_shader_dir, {$1})")
  if [[ "$result" != ok ]]; then
    printf '%s\n' "$result" >&2
    return 1
  fi
}

if [[ ${1:-} == --stop ]]; then
  apply_rules ""
  plugins=$(hyprctl plugin list)
  if [[ "$plugins" == *"Plugin HyprWindowShade by "* && "$plugins" == *"Version: $engine_version"* ]]; then
    result=$(hyprctl plugin unload "$engine")
    if [[ "$result" != ok ]]; then
      printf '%s\n' "$result" >&2
      exit 1
    fi
  fi
  exit 0
fi

monitors=$(hyprctl -j monitors | jq -ec '[.[].name | select(test("^[A-Za-z0-9._-]+$"))]')
overrides='{}'
if [[ -f "$profiles_file" ]]; then
  overrides=$(jq -ec 'select(type == "object")' "$profiles_file")
fi
config='{}'
if [[ -f "$config_file" ]]; then
  config=$(jq -ec 'select(type == "object")' "$config_file")
fi
settings=$(jq -ec --arg id "$id" --argjson monitors "$monitors" --argjson overrides "$overrides" '
  def bounded($lower; $upper; $fallback; $step):
    (if type == "number" then ((. / $step | round) * $step) else $fallback end) as $value
    | if $value < $lower then $lower elif $value > $upper then $upper else $value end;
  def profile($available):
    {enabled: ($available and .fadeEnabled != false),
     excludedApps: (.excludedApps | if type == "array" then
       map(select(type == "string" and length > 0 and length <= 256 and (test("[[:cntrl:]]") | not))) | unique
       else [] end),
     delayMs: (.delayMs | bounded(0; 300000; 1000; 250)),
     fadeMs: (.fadeMs | bounded(0; 5000; 2000; 250)),
     saturation: (.saturation | bounded(0; 100; 60; 1)),
     brightness: (.brightness | bounded(0; 100; 75; 1)),
     transparency: (.transparency | bounded(0; 100; 0; 1))};
  ([.bar.layout[]?[]?, .plugins[]?]
    | map(if type == "string" then {id: .} else . end)
    | map(select(type == "object" and .id == $id))
    | first // null) as $entry
  | ($entry != null and ((.disabledPlugins // []) | index($id) | not)) as $available
  | ($entry // {}) as $defaults
  | ((if ($defaults.screenProfiles | type) == "object" then $defaults.screenProfiles else {} end)
     * $overrides) as $saved
  | [$monitors[] as $name | {key: $name, value:
      ($defaults + ($saved[$name] | if type == "object" then with_entries(select(.value != null)) else {} end)
       | profile($available))}]
  | {enabled: any(.[]; .value.enabled), screens: from_entries}' <<< "$config")

if jq -e .enabled >/dev/null <<< "$settings"; then
  supported_commit=$(<"$project_dir/engine/hyprland-commit")
  commit=$(hyprctl -j version | jq -er .commit)
  if [[ "$commit" != "$supported_commit" ]]; then
    printf '%s\n' "Window Fade requires Hyprland commit $supported_commit." >&2
    exit 78
  fi
  plugins=$(hyprctl plugin list)
  if [[ "$plugins" != *"Plugin HyprWindowShade by "* ]]; then
    if [[ ! -r "$engine" ]]; then
      printf '%s\n' 'Window Fade engine is missing. Run build-engine.sh before enabling the plugin.' >&2
      exit 69
    fi
    result=$(hyprctl plugin load "$engine")
    if [[ "$result" != ok ]]; then
      printf '%s\n' "$result" >&2
      exit 1
    fi
    hyprctl plugin load "$engine" >/dev/null
    plugins=$(hyprctl plugin list)
  fi
  if [[ "$plugins" != *"Version: $engine_version"* ]]; then
    printf '%s\n' 'Window Fade requires its own HyprWindowShade build. Disable any other HyprWindowShade build first.' >&2
    exit 1
  fi
fi

write_shader() (
  screen="$1" delay_ms="$2" fade_ms="$3" saturation="$4" brightness="$5"
  shader="$runtime_dir/monitor-$screen.glsl"
  staged_shader=$(mktemp "$runtime_dir/shader.XXXXXX")
  trap 'rm -f -- "$staged_shader"' EXIT
  LC_ALL=C awk -v delay="$delay_ms" -v duration="$fade_ms" -v saturation="$saturation" -v brightness="$brightness" '
    /^\/\/ @duration / { printf "// @duration %.3f\n", (duration > 0 ? duration / 1000 : 0.001); next }
    /^\/\/ @unfocus_delay / { printf "// @unfocus_delay %.3f\n", delay / 1000; next }
    /^const float restingSaturation =/ { printf "const float restingSaturation = %.2f;\n", saturation / 100; next }
    /^const float restingBrightness =/ { printf "const float restingBrightness = %.2f;\n", brightness / 100; next }
    { print }
  ' "$project_dir/window-fade.glsl" > "$staged_shader"
  if ! cmp -s -- "$shader" "$staged_shader"; then
    if [[ -f "$shader" ]]; then
      # The shader engine checks modification times at whole-second resolution.
      previous_mtime=$(stat -c %Y -- "$shader")
      staged_mtime=$(stat -c %Y -- "$staged_shader")
      if (( staged_mtime <= previous_mtime )); then
        touch -m -d "@$((previous_mtime + 1))" -- "$staged_shader"
      fi
    fi
    mv -f -- "$staged_shader" "$shader"
  fi
)

while IFS=$'\t' read -r screen delay_ms fade_ms saturation brightness; do
  write_shader "$screen" "$delay_ms" "$fade_ms" "$saturation" "$brightness"
done < <(jq -r '.screens | to_entries[] | select(.value.enabled)
  | [.key, .value.delayMs, .value.fadeMs, .value.saturation, .value.brightness] | @tsv' <<< "$settings")

active_screens=$(jq -r '.screens | to_entries
  | map(select(.value.enabled) | (.value) as $profile
      | "[\(.key | @json)]={excluded_apps={\($profile.excludedApps | map(@json) | join(","))},opacity=\(1 - $profile.transparency / 100),seconds=\($profile.fadeMs / 1000)}")
  | join(",")' <<< "$settings")
apply_rules "$active_screens"
printf '%s\n' "$settings"
