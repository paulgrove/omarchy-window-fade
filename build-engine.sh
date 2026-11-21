#!/usr/bin/env bash
set -euo pipefail

project_dir=$(dirname -- "$(realpath -- "$0")")
supported_commit=$(<"$project_dir/engine/hyprland-commit")
installed_version=$(Hyprland --version)
if [[ "$installed_version" != *" at commit $supported_commit "* ]] || ! pkg-config --exact-version=0.57.2 hyprland; then
  printf '%s\n' "Window Fade requires Hyprland 0.57.2 ($supported_commit) and its matching development headers." >&2
  exit 1
fi

# Stage on the same filesystem so replacing the build is atomic, even if the
# compositor still has an older copy mapped.
build_dir=$(mktemp -d "$project_dir/.build-engine.XXXXXX")
trap 'rm -f -- "$build_dir/HyprWindowShade.so"; rmdir -- "$build_dir"' EXIT
make -C "$project_dir/engine" TARGET="$build_dir/HyprWindowShade.so"
mv -f -- "$build_dir/HyprWindowShade.so" "$project_dir/HyprWindowShade.so"
printf '%s\n' "Built $project_dir/HyprWindowShade.so"
