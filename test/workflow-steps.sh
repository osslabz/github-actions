#!/usr/bin/env bash
#
# Helpers for the tests that run a workflow's shell steps the way the runner does.

# Prints the `run: |` block of the step with the given id in the given workflow without its
# indentation, which is the script the runner writes for that step.
step_script() {
    awk -v id="$2" '
        in_run && $0 != "" && index($0, indent) != 1 { exit }
        in_run { print substr($0, length(indent) + 1); next }
        in_step && /^ *run: \|$/ {
            match($0, /^ */)
            indent = ""
            for (i = 0; i < RLENGTH + 2; i++) indent = indent " "
            in_run = 1
            next
        }
        $0 ~ "^ *id: " id "$" { in_step = 1 }
    ' "$1"
}
