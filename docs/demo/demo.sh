#!/bin/bash
# Plays the README demo: each command is "typed", then really run.
# Run it from anywhere; it works in the repository root (build first with make).
#
# To regenerate docs/demo.gif (asciinema 3 and agg, both single binaries from
# github.com/asciinema/asciinema and github.com/asciinema/agg releases):
#   asciinema rec --overwrite --headless --window-size 100x32 -c docs/demo/demo.sh docs/demo/demo.cast
#   agg --font-size 16 --theme monokai --idle-time-limit 2 --fps-cap 12 --speed 1.2 docs/demo/demo.cast docs/demo.gif

cd "$(dirname "$0")/../.." || exit 1

# Print a prompt and type the command, then run it. Output lines are shown
# with a short delay so the token and rule stream is readable in the GIF.
run() {
    printf '\033[1;32m$\033[0m '
    local i
    for ((i = 0; i < ${#1}; i++)); do
        printf '%s' "${1:i:1}"
        sleep 0.03
    done
    sleep 0.4
    echo
    bash -c "$1" 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        sleep "${2:-0}"
    done
    sleep 1.5
}

clear
run "cat docs/demo/demo.c"
run "./compiler -v docs/demo/demo.c 2>&1 | grep -E 'Processing token|Expanding rule'" 0.08
run "cat output.ll" 0.05
run "lli output.ll; echo \$?"
run "make test | tail -1"
sleep 2
