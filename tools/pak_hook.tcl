#!/usr/bin/env tclsh
# tools/pak_hook.tcl — Claude Code PostToolUse hook for automatic Pak validation.
#
# Claude Code runs this after every Write or Edit, passing the tool input as
# JSON on stdin. It:
#
#   1. Reads the tool input JSON from stdin.
#   2. Extracts the file path, and exits silently for non-.pk64 files.
#   3. Runs `pak check` on the file.
#   4. On errors, prints them and exits 2, which surfaces the output to Claude.
#   5. When clean, runs `pak explain` and prints the generated C (minus the
#      boilerplate preamble) so the semantics can be eyeballed, then exits 0.
#
# Exit codes:
#   0 — file is valid, or not a .pk64 file
#   2 — `pak check` failed; the errors are on stdout for Claude to read
#
# Environment:
#   PAK_HOOK_NO_EXPLAIN=1  — skip the explain step (faster, less output)

set HERE [file dirname [file normalize [info script]]]
set REPO [file dirname $HERE]
set PAK [file join $REPO bin pak]

# Pull one string value out of a flat JSON object without a JSON parser: the
# hook payload only ever needs "file_path"/"path", and dragging in a package
# dependency for that would make the hook fragile.
proc json_string {json key} {
    set pat "\"$key\"\\s*:\\s*\"((?:\\\\.|\[^\"\\\\\])*)\""
    if {![regexp $pat $json -> raw]} { return "" }
    return [subst -nocommands -novariables \
        [string map {\\/ / \\" \" \\\\ \\\\ \\n \\n \\t \\t \\r \\r} $raw]]
}

# Strip the standard runtime preamble so only the user's code is shown. The
# preamble ends with the pak_arena_reset inline definition.
proc user_code {c} {
    set idx [string first "pak_arena_reset" $c]
    if {$idx < 0} { return $c }
    set nl [string first "\n" $c $idx]
    if {$nl < 0} { return "" }
    return [string range $c [expr {$nl + 1}] end]
}

set raw [read stdin]
if {[string trim $raw] eq ""} { exit 0 }

set path [json_string $raw file_path]
if {$path eq ""} { set path [json_string $raw path] }
if {$path eq "" || [file extension $path] ne ".pk64"} { exit 0 }

if {![file executable $PAK]} {
    puts "WARNING: $PAK not found or not executable — cannot validate."
    exit 0
}

# A non-zero exit makes `exec` append "child process exited abnormally" to the
# captured output; the diagnostics themselves are what matters here.
set rc [catch {exec $PAK check $path 2>@1} out]
if {$rc} {
    set out [string map {"child process exited abnormally" ""} $out]
    puts [string repeat = 60]
    puts "PAK VALIDATION FAILED: $path"
    puts [string repeat = 60]
    if {[string trim $out] ne ""} { puts [string trim $out] }
    puts ""
    puts "Fix the errors above before proceeding."
    puts "Reference LANGUAGE.md and NOT_SUPPORTED.md."
    puts [string repeat = 60]
    exit 2
}

if {[info exists ::env(PAK_HOOK_NO_EXPLAIN)] && $::env(PAK_HOOK_NO_EXPLAIN) eq "1"} {
    exit 0
}

if {[catch {exec $PAK explain $path} c]} { exit 0 }
set body [string trim [user_code $c]]
if {$body ne ""} {
    puts [string repeat = 60]
    puts "PAK EXPLAIN (user code): $path"
    puts [string repeat = 60]
    puts $body
    puts [string repeat = 60]
    puts "Generated C above is your code only (preamble omitted)."
    puts "If the output does not match intent, fix the .pk64 source."
    puts [string repeat = 60]
}
exit 0
