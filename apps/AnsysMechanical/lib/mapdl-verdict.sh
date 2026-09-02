#!/bin/bash
# =============================================================================
# MAPDL solve-verdict helpers
# =============================================================================
# Sourced by AnsysMechanical.sbatch and exercised directly by
# tests/test-mapdl-verdict.sh (needs neither Slurm nor a licensed solver).
#
# Why this exists: MAPDL's exit status alone cannot decide success.
#   * Several official benchmark decks are configured to stop at a fixed
#     iteration count. MAPDL then prints an "*** ERROR ***" block reporting the
#     user-requested termination and exits NON-ZERO after a run that completed
#     exactly as intended.
#   * Conversely, a truncated or killed run can leave a ZERO exit status.
# The verdict therefore comes from the solver OUTPUT, and a non-zero exit status
# is normalised to success only when that exact benign termination explains it.
#
# Design rules enforced here:
#   1. Error detection is indentation-insensitive and classifies COMPLETE error
#      blocks, never individual context lines. Removing a matching detail line
#      must not leave its header behind to be counted as a failure.
#   2. Exactly one benign signature is whitelisted; everything else is a failure.
#   3. A verified solve needs "RUN COMPLETED" *and* a positive elapsed time *and*
#      zero unexpected error blocks.
#   4. An UNVERIFIED run never reports scheduler success, even when MAPDL
#      returned 0.
# =============================================================================

# The single known-benign signature: a deliberate stop at the configured
# iteration/substep limit.
#
# ANCHORED AT BOTH ENDS ON PURPOSE. A substring match would accept a block that
# contains the expected phrases *plus* a second, genuine failure, e.g.
#
#   *** ERROR ***
#   The number of iterations exceeds 25 and the run was terminated at the
#   user's request.
#   The results database also failed to write and output is incomplete.
#
# The whole block must consist of nothing but the expected termination text, so
# any extra sentence makes it unexpected and fails the run. Two observed wording
# variants are accepted; whitespace is already squeezed and trimmed by
# mapdl_error_blocks.
#
# The possessive is matched LITERALLY as an apostrophe. Do not write `user.?s`:
# in ERE `.?` is any single character, so it also accepts malformed text like
# `userXs`. Both the ASCII apostrophe and the U+2019 right single quote are
# allowed, because only the character encoding varies - never the wording.
# Double-quoted so the ASCII apostrophe can appear literally.
MAPDL_BENIGN_ERROR_RE="^ERR: The number of (iterations|substeps) exceeds [0-9]+(\. The run is terminated| and the run was terminated) at the user('|’)s request\.?\$"

# Exit statuses that a benign fixed-iteration termination is allowed to produce.
# Grounded in the recorded campaign: across 87 V26 Cluster runs the deliberate
# fixed-iteration stop (V26direct-5/-6) exited 1 (17x) and 255 (8x), while runs
# that reached their own end exited 0 (62x). Restricting normalisation to this set
# is what stops an ARBITRARY failure status from being masked by a benign-looking
# block: rc=42 alongside a benign block stays 42.
MAPDL_BENIGN_EXIT_STATUSES=" 0 1 255 "

# Declared up front so a caller running with `set -u` can reference them safely
# before the first mapdl_solve_verdict call.
MAPDL_SOLVE_OK=0
MAPDL_FINAL_RC=3
MAPDL_ELAPSED=""
MAPDL_COMPLETED=0
MAPDL_BENIGN=0
MAPDL_UNEXPECTED=0

# mapdl_error_blocks <file>
# Emit one "ERR: <body>" line per "*** ERROR ***" block, body joined and
# whitespace-squeezed. The marker is matched anywhere on the line, so a
# column-zero error is classified exactly like an indented one. A block ends at
# a blank line, at the next ERROR/WARNING/NOTE marker, or at a box-rule line.
# The "ERR: " prefix is what makes the count reliable: a block with an EMPTY
# body must still be counted (an unclassifiable error is a failure, not a pass).
mapdl_error_blocks() {
    local f="$1"
    [ -n "$f" ] && [ -r "$f" ] || return 0
    awk '
      # Normalisation must be IDENTICAL to the copy in
      # dynamodb/record-benchmark.sh, or the same solver output gets classified
      # one way live and another way on replay. Squeeze runs of whitespace to a
      # single space, then trim BOTH ends - MAPDL pads its output lines with
      # trailing spaces, and an untrimmed trailing space defeats the anchored
      # benign pattern and rejects a perfectly good run.
      function flush() {
          if (inblk) {
              gsub(/[[:space:]]+/, " ", buf)
              sub(/^[[:space:]]+/, "", buf); sub(/[[:space:]]+$/, "", buf)
              print "ERR: " buf
          }
          inblk = 0; buf = ""
      }
      /\*\*\* ERROR \*\*\*/                   { flush(); inblk = 1; next }
      inblk && /^[[:space:]]*$/               { flush(); next }
      inblk && /\*\*\* (WARNING|NOTE) \*\*\*/ { flush(); next }
      inblk && /^[[:space:]]*\*-|^[[:space:]]*\|-/ { flush(); next }
      inblk                                   { buf = buf " " $0; next }
      END                                     { flush() }
    ' "$f"
}

# mapdl_count_error_blocks <file> -> "<total> <benign> <unexpected>"
mapdl_count_error_blocks() {
    local f="$1" blocks total=0 benign=0
    blocks="$(mapdl_error_blocks "$f")"
    if [ -n "$blocks" ]; then
        total="$(printf '%s\n' "$blocks" | grep -c '^ERR: ' || true)"
        # The pattern carries its own ^/$ anchors - do NOT wrap it in '.*'.
        benign="$(printf '%s\n' "$blocks" | grep -cE "${MAPDL_BENIGN_ERROR_RE}" || true)"
    fi
    : "${total:=0}" "${benign:=0}"
    printf '%s %s %s\n' "$total" "$benign" "$(( total - benign ))"
}

# mapdl_elapsed_seconds <file>
# Print the final "Elapsed Time (sec) = <value>" ONLY when it parses as a finite
# number strictly greater than zero; print nothing otherwise.
# NB: parse the value right after the '=' — the summary line ends with a Date
# field, so taking the last number on the line yields the year, not seconds.
mapdl_elapsed_seconds() {
    local f="$1" v
    [ -n "$f" ] && [ -r "$f" ] || return 0
    v="$(grep -hE 'Elapsed [Tt]ime *\(sec\)' "$f" 2>/dev/null | tail -1 \
         | sed -E 's/.*[Ee]lapsed [Tt]ime *\(sec\) *= *(-?[0-9]+(\.[0-9]+)?).*/\1/')"
    case "$v" in ''|*[!0-9.-]*|*.*.*) return 0 ;; esac
    awk -v x="$v" 'BEGIN { if (x + 0 > 0) print x }'
}

# mapdl_stage_out <src_file> <dest_dir>
# Copy the solver output to durable shared storage and VERIFY it landed intact.
# Returns 0 ONLY when the destination exists, is non-empty and matches the
# source byte count — the caller must never reclaim node-local scratch on a
# non-zero return, or a failed shared filesystem silently destroys the only
# copy of the solver log.
mapdl_stage_out() {
    local src="$1" dest_dir="$2" dest src_bytes dest_bytes
    if [ -z "$src" ] || [ ! -r "$src" ]; then
        echo "ERROR: stage-out source '${src:-<unset>}' is missing or unreadable." >&2
        return 1
    fi
    if [ -z "$dest_dir" ]; then
        echo "ERROR: stage-out destination directory is unset." >&2
        return 1
    fi
    dest="${dest_dir%/}/$(basename "$src")"
    if [ "$(readlink -m "$src")" = "$(readlink -m "$dest")" ]; then
        # Already on the shared filesystem (SCRATCH_MODE=shared): nothing to copy.
        [ -s "$src" ] && return 0
        echo "ERROR: '$src' already lives on shared storage but is empty." >&2
        return 1
    fi
    mkdir -p "$dest_dir" 2>/dev/null
    if ! cp -f "$src" "$dest" 2>/dev/null; then
        echo "ERROR: copying '$src' to '$dest_dir' failed (filesystem full, read-only or unavailable?)." >&2
        return 1
    fi
    src_bytes="$(wc -c < "$src" 2>/dev/null | tr -d '[:space:]')"
    dest_bytes="$(wc -c < "$dest" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$dest_bytes" ] || [ "$dest_bytes" = "0" ] || [ "$dest_bytes" != "$src_bytes" ]; then
        echo "ERROR: staged copy '$dest' is empty or truncated (${dest_bytes:-0}/${src_bytes:-?} bytes)." >&2
        return 1
    fi
    return 0
}

# mapdl_memory_mode <file> -> InCore | OutOfCore | unknown
mapdl_memory_mode() {
    local f="$1"
    if   grep -qi 'Out-of-Core'      "$f" 2>/dev/null; then echo OutOfCore
    elif grep -qiE 'In-Core|InCore'  "$f" 2>/dev/null; then echo InCore
    else echo unknown; fi
}

# mapdl_solve_verdict <output_file> <solver_rc>
#
# Sets MAPDL_SOLVE_OK / MAPDL_FINAL_RC / MAPDL_ELAPSED / MAPDL_BENIGN /
# MAPDL_UNEXPECTED / MAPDL_COMPLETED in the CALLING shell and prints nothing.
# Call it directly — never inside $(...), which would run it in a subshell and
# discard the results. Use mapdl_verdict_summary to render the one-line summary.
#
# MAPDL_SOLVE_OK=1 requires: "RUN COMPLETED" + elapsed > 0 + no unexpected blocks.
# MAPDL_FINAL_RC:
#   verified,   rc == 0                                          -> 0
#   verified,   rc != 0, benign block AND rc in benign status set -> 0
#   verified,   rc != 0, benign block but rc NOT in that set      -> rc
#   verified,   rc != 0, no benign block                          -> rc
#   unverified, rc != 0                                           -> rc
#   unverified, rc == 0                                           -> 3 (synthesised)
#
# The status-set condition matters: without it any arbitrary failure status is
# masked to success whenever a benign-looking block happens to be present.
mapdl_solve_verdict() {
    local f="$1" rc="${2:-0}" counts rest
    counts="$(mapdl_count_error_blocks "$f")"
    rest="${counts#* }"
    MAPDL_BENIGN="${rest%% *}"
    MAPDL_UNEXPECTED="${counts##* }"
    MAPDL_ELAPSED="$(mapdl_elapsed_seconds "$f")"
    MAPDL_COMPLETED=0
    if [ -n "$f" ] && [ -r "$f" ] && grep -q 'RUN COMPLETED' "$f" 2>/dev/null; then
        MAPDL_COMPLETED=1
    fi

    case "$rc" in ''|*[!0-9-]*) rc=1 ;; esac

    MAPDL_SOLVE_OK=0
    if [ "$MAPDL_COMPLETED" -eq 1 ] && [ -n "$MAPDL_ELAPSED" ] && [ "$MAPDL_UNEXPECTED" -eq 0 ]; then
        MAPDL_SOLVE_OK=1
    fi

    if [ "$MAPDL_SOLVE_OK" -eq 1 ]; then
        if [ "$rc" -eq 0 ]; then
            MAPDL_FINAL_RC=0
        elif [ "$MAPDL_BENIGN" -gt 0 ] \
             && [ "${MAPDL_BENIGN_EXIT_STATUSES#* "$rc" }" != "$MAPDL_BENIGN_EXIT_STATUSES" ]; then
            MAPDL_FINAL_RC=0
        else
            MAPDL_FINAL_RC="$rc"
        fi
    else
        if [ "$rc" -ne 0 ]; then MAPDL_FINAL_RC="$rc"; else MAPDL_FINAL_RC=3; fi
    fi

    # An accepted run means BOTH: output verified AND a final status of zero. The
    # launcher gates benchmark recording on this, so a job that exits non-zero can
    # never contribute a row to the dataset.
    [ "$MAPDL_FINAL_RC" -eq 0 ] || MAPDL_SOLVE_OK=0
}

# One-line, log-friendly rendering of the last mapdl_solve_verdict call.
mapdl_verdict_summary() {
    printf 'solve_ok=%s final_rc=%s elapsed=%s completed=%s benign_errors=%s unexpected_errors=%s\n' \
        "${MAPDL_SOLVE_OK}" "${MAPDL_FINAL_RC}" "${MAPDL_ELAPSED:-none}" \
        "${MAPDL_COMPLETED}" "${MAPDL_BENIGN}" "${MAPDL_UNEXPECTED}"
}
