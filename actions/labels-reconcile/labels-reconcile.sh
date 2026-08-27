#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
else
  # Fixture tests source the pure functions and deliberately inspect failures.
  set -u
fi

# labels-reconcile.sh — the automation LABELS.md promises: state labels are
# written by machinery, never by hand. Every run derives each open PR's
# state:* from GitHub's own facts (draft flag, requested reviewers, submitted
# reviews) and converges the labels to it, so a killed run or a hand-moved
# label heals on the next pass. Stale is judged from real activity — commits,
# comments, reviews — never from label churn, or the sweep would un-stale its
# own mark every tick.
#
# The verdict contract (CONTRIBUTING.md): reviews end in approve or
# request-changes. Some live bots are comment-only and post agreement as a
# COMMENTED review — a non-verdict this machine refuses to guess about (body
# parsing is a heuristic, and a wrong guess promotes an unapproved PR). The
# judgment call belongs to the PR AUTHOR, who reads the round and escalates
# by requesting the human's review — an explicit request is a fact, and it is
# the one this machine trusts (see decide_state's top precedence). The
# machine auto-requests the human only in the no-judgment-needed case: every
# required verdict is a formal head-current approval. Any approval that counts
# must be bound to
# the CURRENT head SHA: GitHub keeps approvals alive across pushes, and a
# stale approval must never promote unreviewed code to the human.
#
# DRY_RUN=1 narrates every mutation instead of performing it (how this script
# is rehearsed against the live repo). BOOTSTRAP=yes also bootstraps the
# taxonomy (label create --force) — that heal is asked for, never inferred
# from the event that woke the sweep (#472); every other run tolerates a
# missing label rather than recreating it.
#
# The state machine below is pure (globals in, state out) and covered by
# fixture tests in test/labels-reconcile.test.sh.

HUMAN="${HUMAN_REVIEWER:-danmt}"
BOTS=()
# Per-author panels (#224): parallel arrays because the conf is tiny and an
# associative array buys nothing but a bash-4 dependency statement. One entry
# per panel[<login>]= row — PANEL_AUTHORS holds the login, PANEL_ROWS the
# space-joined reviewer set at the same index.
PANEL_AUTHORS=()
PANEL_ROWS=()
TRIAGE_ACTORS=()
REQUIRED_BOTS=()
STATES=(state:building state:bots-reviewing state:addressing state:needs-human)
BLOCKERS=(blocker:conflict blocker:ci-red blocker:unrequested)
# The PR's current labels, set per PR by the sweep. Initialized here because
# the script runs under `set -u` even when sourced, and the pure-function
# fixtures call decide_state — which now reads has_label — without ever
# setting it (#51). An empty default keeps has_label honest for every caller.
LABELS=""
# The PR's base-branch head, the release-shape guard's second ref (#130), set
# per PR by the sweep. Initialized here for LABELS' reason and one sharper: the
# guard's call site reads it under `set -u`, and until #501 the read sat inside
# a command substitution whose failure the enclosing call swallowed — every
# fixture driving reconcile_pr had been expanding an unbound name and getting
# away with it. Assigning the read to a local makes that status the assignment's
# own, so the empty default is now load-bearing rather than tidy.
BASE_SHA=""
# The head SHA named by the newest `rerun-owed` evidence comment on this PR;
# empty when the PR does not carry the label, no evidence names a head, or the
# comments could not be read. Read only on PRs carrying the label — one API
# call, paid by the few (#423).
RERUN_OWED_HEAD=""
# What that evidence comment opens with. A marker, not a prose match: the head
# it names is a fact the machine acts on, so it is written where a machine can
# read it, in the shape this repo's other head-scoped markers already use.
RERUN_OWED_MARKER='🔁 rerun owed at head '
# Labels this machine used to own and no longer does. Cleared on sight so a
# retirement heals the board instead of stranding a label nothing recomputes.
RETIRED=(state:needs-rebase)
STALE_AFTER=$((48 * 3600))
# How long the facts behind blocker:unrequested must have stood still before it
# is written (#236 D2). The operator's "more than 5 minutes", measured off the
# inputs' own timestamps rather than off sweep memory — this script is
# stateless per pass and stays that way. Overridable the way this file's other
# constants are, for a caller whose round cadence is slower or faster.
RECONCILE_UNREQUESTED_GRACE="${RECONCILE_UNREQUESTED_GRACE:-300}"
# The workflow whose runs checks_state must never grade — its own (#208).
# GITHUB_WORKFLOW is ambient in every Actions step and names the CALLER (the
# consumer's PR-facing workflow, since consumers name the caller), so this
# self-serves with no workflow-file change. The explicit override exists for
# two readers: the fixtures, and #209's detached sweep caller, which will
# need to point this at the PR-facing caller's name once reconcile no longer
# runs inside it. Empty means "filter nothing" — a caller outside Actions
# (a local rehearsal, an older pin) must not silently start dropping entries.
SELF_WORKFLOW="${SELF_WORKFLOW:-${GITHUB_WORKFLOW:-}}"
# Closed by default at the direct-script boundary as well as the reusable
# workflow and composite action boundaries (#459). #459 observed the verdict;
# #460 acts on it, at the end of reconcile_pr and through run().
AUTO_MERGE="${AUTO_MERGE-off}"
AUTO_MERGE_RELEASE="${AUTO_MERGE_RELEASE-off}"
# The taxonomy bootstrap's only gate (#472). `-` and not `:-`, exactly as
# above: unset is the default, and empty is a typo the run must die on rather
# than silently read as "do not bootstrap" — which is what made the defect
# this replaced survive, a gate answering a question nobody asked. The
# composite validates its own input first, so this bites the direct-script
# caller, where the value was otherwise unchecked.
BOOTSTRAP="${BOOTSTRAP-no}"
# What the success comment opens with (#460 D6). A marker in the shape this
# file's other machine comments use — but NOT an idempotency guard, and no
# ensure_comment reads it: the sweep enumerates OPEN pull requests only
# (main's `gh pr list --state open`), so a merged PR is never reconciled a
# second time and there is no repeat to suppress. It is here so a human, or a
# later machine, can find every auto-merge this toggle performed.
AUTO_MERGED_MARKER='<!-- ceremony:auto-merged -->'
# The mark on a human review request THIS machine made (#479). The reconciler
# asks the human when the round passes and could never take that ask back,
# because `requested "$HUMAN"` cannot tell its own request from a maintainer's
# — and the two mean opposite things to round_state, where a maintainer
# pulling a PR to themselves early is a deliberate act that outranks an
# unfinished round. A stale self-made request therefore read as that
# deliberate claim forever. The mark is the smallest thing that separates
# them, and it is what makes retraction safe: without it every retraction
# would also clear a maintainer's deliberate early claim, which is the case
# the precedence exists to protect.
#
# A comment marker and not a label: the taxonomy rejected markers-as-labels
# for other purposes, and this is the shape the ruling, attention and
# auto-merge markers already use (#479 D2).
HUMAN_REQUEST_MARKER='<!-- ceremony:human-requested -->'
# ...and the mark on its withdrawal. Two markers and not one, because the
# question is about the request standing NOW: after a retraction the machine's
# ask is gone, and a maintainer who asks next must not inherit the first
# mark's answer. The newest of the two wins, which is what makes the pair a
# state rather than a history.
HUMAN_REQUEST_WITHDRAWN_MARKER='<!-- ceremony:human-request-withdrawn -->'
# What those marks say about the request standing on THIS PR: MACHINE when the
# newest mark is this machine's own request, NONE otherwise. Initialized here
# for the reason LABELS is: the script runs under `set -u` even when sourced,
# and the pure fixtures call round_state without setting it.
#
# NONE is the safe default in BOTH directions, which is why one default
# serves. Nothing is withdrawn on it — an unread fact never takes a
# maintainer's deliberate act away — and round_state's MISSING branch reads it
# as the maintainer's request it has always read, so an unread fact invents no
# verdict either.
HUMAN_REQUEST_MARK=NONE
# The workflow to wake after a merge this sweep performed (#461). Empty means
# dispatch nothing, which is every consumer until one opts in, and empty is the
# default at all three boundaries the way `auto_merge`'s `off` is. The name is
# never validated here (D4): whether the workflow exists, declares
# `workflow_dispatch:` and is dispatchable by this token are three questions
# `gh workflow run` already answers by failing, and a second implementation of
# GitHub's own checks is a guess this script cannot keep current.
POST_MERGE_WORKFLOW="${POST_MERGE_WORKFLOW-}"
RELEASE_WORKFLOW="${RELEASE_WORKFLOW-}"

# The needs-ruling invariants (#52) — one implementation for both surfaces.
# shellcheck source=lib/ruling.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/ruling.sh"
# The attention target invariants (#232) — diagnosis only, both surfaces.
# shellcheck source=lib/attention.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/attention.sh"
# The guarded read and its reason line (#101) — one implementation for both
# surfaces. read_failure_reason lived here until the issue surface needed the
# identical rule (#247); a second copy of it is the failure lib/ruling.sh's
# own header was written to record.
# shellcheck source=lib/read.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/read.sh"
# The rollup classifier (#136, #139, #208) — one implementation for both
# reconcilers since #440, which gave the issue surface a second reader. Its
# SELF_WORKFLOW contract is the assignment above; the lib defaults nothing.
# shellcheck source=lib/checks.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/checks.sh"

log() { printf 'labels: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

blind_sweep_warning() { # $1 = unreadable PRs, $2 = all open PRs, $3 = sampled read-failure reason
  # Report, do not diagnose (#101 D5). The old text asserted the caller's
  # checks:/statuses: grants as THE cause — an inference #95 made from a
  # control case, and the merged consumer-side fix (incubator#48/PR #49)
  # left the symptom standing while the run emitting this warning held the
  # evidence that would have said so. Lead with what gh actually said this
  # sweep; the permissions hint stays, demoted to one named candidate.
  if [ "$2" -gt 0 ] && [ "$1" -eq "$2" ]; then
    local reason="${3:-}"
    if [ -n "$reason" ]; then
      echo "::warning::labels: every open PR was unreadable; sampled reason: $reason — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)"
    else
      echo "::warning::labels: every open PR was unreadable; no reason was captured — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)"
    fi
  fi
}

missing_core_labels_warning() { # $1 = declared rows, $2 = repo label names
  local rows="$1" repo_labels="$2" row name missing=""
  [ -n "$repo_labels" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="${row%%|*}"
    if ! grep -qxF "$name" <<<"$repo_labels"; then
      if [ -n "$missing" ]; then missing="$missing, $name"; else missing="$name"; fi
    fi
  done <<<"$rows"
  if [ -n "$missing" ]; then
    echo "::warning::labels: missing core label(s): $missing; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy"
  fi
}

load_config() { # $1 = consumer labels.conf; panel is mandatory, scopes optional
  local conf="$1" line panel_seen=false login
  local -a row=()
  [ -f "$conf" ] || {
    echo "labels: missing config: $conf (a panel= line is required)" >&2
    return 1
  }
  BOTS=()
  PANEL_AUTHORS=()
  PANEL_ROWS=()
  TRIAGE_ACTORS=()
  # shellcheck disable=SC2094 # parse_panel_author_row takes $conf for its
  # error messages only — nothing in this loop writes the file it reads
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # The panel[ prefix is matched QUOTED (#224 D7): in a case pattern an
    # unquoted panel[abc]=* is a bracket expression that matches panela=…,
    # panelb=…, panelc=… — silently rerouting ordinary settings. The
    # panela= tripwire in test/labels.test.sh goes red if this regresses.
    case "$line" in
      panel=*)
        [ "$panel_seen" = false ] || {
          echo "labels: duplicate panel line in $conf" >&2
          return 1
        }
        panel_seen=true
        read -r -a BOTS <<<"${line#panel=}"
        [ "${#BOTS[@]}" -gt 0 ] || {
          echo "labels: panel must name at least one reviewer in $conf" >&2
          return 1
        }
        ;;
      "panel["*) parse_panel_author_row "$line" "$conf" || return ;;
      triage-actors=*)
        read -r -a row <<<"${line#triage-actors=}"
        for login in ${row[@]+"${row[@]}"}; do
          case "$login" in
            "" | *[!A-Za-z0-9-]*)
              echo "::warning::labels: malformed triage-actors login '$login' in $conf — skipped" >&2
              ;;
            *) TRIAGE_ACTORS+=("$login") ;;
          esac
        done
        ;;
      *) parse_label_row "$line" >/dev/null || return ;;
    esac
  done <"$conf"
  [ "$panel_seen" = true ] || {
    echo "labels: missing panel= line in $conf" >&2
    return 1
  }
}

parse_panel_author_row() { # panel[<login>]=<space-separated logins> (#224)
  # Every failure here is a hard one that names the offending line (D3): a
  # conf error takes the whole board down, and the run log is the only place
  # the operator can read why. A malformed bracket is refused AS a bracket
  # (D4) — falling through to parse_label_row would report it as a
  # "malformed label row", the misleading diagnostic #224 was filed over.
  local line="$1" conf="$2" login rest existing
  case "$line" in
    "panel["*"]="*) ;;
    *)
      echo "labels: malformed panel[<login>]= row (expected panel[<login>]=<reviewers>): $line in $conf" >&2
      return 1
      ;;
  esac
  login="${line#panel[}"
  login="${login%%]=*}"
  [ -n "$login" ] || {
    echo "labels: empty login in panel row: $line in $conf" >&2
    return 1
  }
  # The login must be exactly one well-formed bracket pair of login
  # characters. Without this, panel[z]]=b parses: the case above only
  # establishes that SOME ]= occurs, ${login%%]=*} keeps the stray ] inside
  # the login (z]), and set_required_bots for the real z then silently falls
  # back to the base panel — the misroute D4 exists to refuse. GitHub logins
  # are [A-Za-z0-9-], per the #285 spec.
  case "$login" in
    *[!A-Za-z0-9-]*)
      echo "labels: malformed panel[<login>]= row (a login is [A-Za-z0-9-] only): $line in $conf" >&2
      return 1
      ;;
  esac
  for existing in ${PANEL_AUTHORS[@]+"${PANEL_AUTHORS[@]}"}; do
    [ "$existing" != "$login" ] || {
      echo "labels: duplicate panel[$login]= row in $conf: $line" >&2
      return 1
    }
  done
  local -a row=()
  rest="${line#*]=}"
  read -r -a row <<<"$rest"
  [ "${#row[@]}" -gt 0 ] || {
    echo "labels: panel[$login]= must name at least one reviewer in $conf: $line" >&2
    return 1
  }
  PANEL_AUTHORS+=("$login")
  PANEL_ROWS+=("${row[*]}")
}

parse_label_row() { # exact name|color|description; pipes in descriptions are refused
  local line="$1" name color desc extra
  IFS='|' read -r name color desc extra <<<"$line"
  if [ -z "$name" ] || [ -z "$color" ] || [ -z "$desc" ] || [ -n "${extra:-}" ]; then
    echo "labels: malformed label row: $line" >&2
    return 1
  fi
  printf '%s|%s|%s\n' "$name" "$color" "$desc"
}

configured_label_rows() { # validated scope rows, excluding the panel setting
  local conf="$1" line
  [ -f "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # "panel["* quoted for the same D7 reason as load_config's case; skipping
    # the bracketed rows (D5) keeps a dispatch bootstrap from trying to
    # create a label named panel[<login>].
    case "$line" in panel=* | "panel["* | triage-actors=*) continue ;; esac
    parse_label_row "$line" || return
  done <"$conf"
}

panel_for_author() { # $1 = author → the effective panel, space-joined (#224 D2)
  # THE resolution point: the author's panel[<login>]= row when the conf
  # defines one, the base panel= otherwise. Everything that computes a
  # required set goes through here, because two places computing the panel
  # is how the engine and the reconciler came to disagree in the first place.
  local author="$1" i
  for i in ${PANEL_AUTHORS[@]+"${!PANEL_AUTHORS[@]}"}; do
    if [ "${PANEL_AUTHORS[i]}" = "$author" ]; then
      printf '%s\n' "${PANEL_ROWS[i]}"
      return
    fi
  done
  printf '%s\n' "${BOTS[*]}"
}

is_fleet_login() { # $1 = login → membership in every roster-bearing conf row (#459)
  local login="$1" identity row_login
  [ -n "$login" ] || return 1
  for identity in ${BOTS[@]+"${BOTS[@]}"} \
    ${PANEL_AUTHORS[@]+"${PANEL_AUTHORS[@]}"} \
    ${TRIAGE_ACTORS[@]+"${TRIAGE_ACTORS[@]}"}; do
    [ "$identity" = "$login" ] && return 0
  done
  for identity in ${PANEL_ROWS[@]+"${PANEL_ROWS[@]}"}; do
    for row_login in $identity; do
      [ "$row_login" = "$login" ] && return 0
    done
  done
  return 1
}

auto_merge_method() { # release is a selector: every PR belongs to one toggle (#468 D2)
  if has_label release; then
    printf '%s\n' "$AUTO_MERGE_RELEASE"
  else
    printf '%s\n' "$AUTO_MERGE"
  fi
}

auto_merge_verdict() { # $1 = this pass's decide_state conclusion (#459, #468)
  local method
  method="$(auto_merge_method)"
  [ "$method" != off ] || { echo SKIP:off; return; }
  [ "$1" = state:needs-human ] || { echo SKIP:state; return; }
  if has_label release && [ -z "$RELEASE_WORKFLOW" ]; then
    echo SKIP:no-release-dispatch
    return
  fi
  is_fleet_login "$AUTHOR" || { echo SKIP:author; return; }
  [ "$MERGEABLE" = MERGEABLE ] || { echo SKIP:mergeable; return; }
  echo MERGE
}

validate_auto_merge() {
  case "$AUTO_MERGE" in
    off | merge | squash | rebase) ;;
    *) echo "auto_merge must be one of: off, merge, squash, rebase" >&2; return 2 ;;
  esac
  case "$AUTO_MERGE_RELEASE" in
    off | merge | squash | rebase) ;;
    *) echo "auto_merge_release must be one of: off, merge, squash, rebase" >&2; return 2 ;;
  esac
}

validate_bootstrap() { # validate_auto_merge's shape, for the same reason (#472)
  case "$BOOTSTRAP" in
    yes | no) ;;
    *) echo "bootstrap must be 'yes' or 'no'" >&2; return 2 ;;
  esac
}

set_required_bots() { # the PR author is recused by construction
  # Minus-the-author applies to WHICHEVER set panel_for_author returns (#224
  # D2's safety net): an author who mistakenly appears inside its own
  # bracketed row is still recused.
  local author="$1" bot
  local -a effective=()
  read -r -a effective <<<"$(panel_for_author "$author")"
  REQUIRED_BOTS=()
  for bot in ${effective[@]+"${effective[@]}"}; do
    [ "$bot" = "$author" ] || REQUIRED_BOTS+=("$bot")
  done
}

# ---------------------------------------------------------------------------
# The state machine. Pure functions over these globals, set per PR:
#   DRAFT        true|false
#   HEAD_SHA     the PR's current head commit
#   BASE_SHA     the PR's base branch head (the release-shape guard's ref)
#   REQUESTED    newline-separated logins with a review currently requested
#   REVIEWS_JSON JSON array of submitted (non-PENDING) reviews
#   MERGEABLE    MERGEABLE | CONFLICTING | UNKNOWN  (GitHub's own verdict)
#   CHECKS       SUCCESS | FAILURE | PENDING | NONE (the check rollup)
#   LABELS       newline-separated labels currently on the PR
#   HEAD_COMMIT_AT  the head commit's own date, ISO-8601; empty when unread
#   NOW          this sweep's epoch seconds (main sets it once per run)
# ---------------------------------------------------------------------------

requested() { grep -qxF "$1" <<<"$REQUESTED"; }

bot_verdict() { # $1 = login → MISSING | BLOCK | APPROVE | STALE | FEEDBACK
  local review state commit
  review="$(jq -c --arg u "$1" \
    '[.[] | select(.user.login == $u)] | sort_by(.submitted_at) | last // empty' \
    <<<"$REVIEWS_JSON")"
  if [ -z "$review" ]; then echo MISSING; return; fi
  state="$(jq -r '.state' <<<"$review")"
  commit="$(jq -r '.commit_id' <<<"$review")"
  case "$state" in
    CHANGES_REQUESTED)
      # blocks at ANY head — GitHub's own semantic: only a newer review
      # from the same reviewer clears it
      echo BLOCK ;;
    APPROVED)
      if [ "$commit" = "$HEAD_SHA" ]; then echo APPROVE; else echo STALE; fi ;;
    *)
      # COMMENTED and anything else: a non-verdict. The machine does not
      # read bodies — if the comment is really an agreement, the AUTHOR
      # says so by requesting the human's review.
      echo FEEDBACK ;;
  esac
}

iso_epoch() { # $1 = ISO-8601 timestamp → epoch seconds; nothing, rc 1, when unreadable
  # An absent field reaches this as the empty string or as jq's literal "null";
  # both are "we did not read a time", and neither may be graded as one.
  local at="${1-}" epoch
  case "$at" in "" | null) return 1 ;; esac
  epoch="$(date -d "$at" +%s 2>/dev/null)" || return 1
  [ -n "$epoch" ] || return 1
  printf '%s\n' "$epoch"
}

unrequested_quiescent() { # 0 when the unrequested facts have stood for the grace (#236 D2)
  # The stall blocker's supporting facts are the head and the round's newest
  # submitted review: the ask it demands is owed only once both have stopped
  # moving. Measured off those timestamps, not off sweep memory — ceremony#235
  # was flagged inside the ~90 seconds between a round-answer push and the
  # author's re-request, because a sweep read the facts before the request
  # landed and wrote after it. That is a round in motion, not a dropped ball.
  #
  # "Newest submitted review" is any submitted review, COMMENTED included: a
  # non-verdict is still evidence the round is live, and counting it can only
  # delay a flag, never invent one.
  #
  # A timestamp we could not read refuses the blocker (the standing rule: an
  # unreadable fact never invents a verdict). This direction is deliberate and
  # asymmetric — a missed flag costs one sweep of the 15-minute cadence, a
  # false one flags a builder for doing exactly what BUILDER.md requires.
  local newest verdict_at verdict_epoch
  newest="$(iso_epoch "${HEAD_COMMIT_AT:-}")" || return 1
  verdict_at="$(jq -r '[.[].submitted_at] | max // empty' <<<"${REVIEWS_JSON:-[]}")"
  if [ -n "$verdict_at" ]; then
    # A round WITH verdicts whose newest one cannot be dated is unreadable, not
    # quiescent; a round with no verdicts at all is simply the head's clock.
    verdict_epoch="$(iso_epoch "$verdict_at")" || return 1
    [ "$verdict_epoch" -gt "$newest" ] && newest="$verdict_epoch"
  fi
  [ $((${NOW:-0} - newest)) -ge "$RECONCILE_UNREQUESTED_GRACE" ]
}

human_request_needed() { # 0 when needs-human requires a FRESH human request
  # already requested → the handoff is live; head-current human approval →
  # nothing left to ask. Anything else (never reviewed, an old comment, an
  # approval of an older head) stalls the handoff unless we request —
  # guarding on "has the human ever reviewed" wedged exactly that way.
  if requested "$HUMAN"; then return 1; fi
  if [ "$(bot_verdict "$HUMAN")" = APPROVE ]; then return 1; fi
  return 0
}

human_request_mark() { # comment first-lines on stdin → MACHINE | NONE (#479 D1)
  # Pure, so the fixtures drive the parse rather than the API around it — the
  # split rerun_owed_named_head and lib/attention.sh's attention_newest_flag
  # both make, and for the same reason: the read either worked or it did not,
  # and that is the caller's problem.
  #
  # Newest wins, which is the order the comments API returns: a request and a
  # withdrawal are one running state, not a tally, so the last thing this
  # machine said about its own ask is the whole answer. A withdrawal newer
  # than the request is why a maintainer asking after a retraction is not
  # answered by the retracted request's mark.
  #
  # Matched as the comment's FIRST LINE, which is where this file's other
  # markers are written. There is no author to filter by, unlike the
  # rerun-owed evidence read: the writer is the sweep's own token, and a
  # consumer's may be a bot or a PAT, so a login test would be a guess about
  # someone else's caller. The residual is the one reconcile_handoff_takeback's
  # marker read already carries — a comment whose first line is a verbatim
  # paste of the marker is read as this machine's — and it is bounded by which
  # way each forgery fails: a forged request-mark costs one maintainer request,
  # withdrawn visibly and re-requestable, while a forged withdrawal leaves a
  # machine request standing, which is exactly the behaviour before this
  # existed.
  local line mark=NONE
  while IFS= read -r line; do
    case "$line" in
      "$HUMAN_REQUEST_MARKER"*) mark=MACHINE ;;
      "$HUMAN_REQUEST_WITHDRAWN_MARKER"*) mark=NONE ;;
    esac
  done
  printf '%s\n' "$mark"
}

rerun_owed_state() { # → STANDS | CLEARED | ABSENT — what `rerun-owed` says about THIS head
  # The label a builder sets when the head is red on a rerun no identity in the
  # fleet can start (#423). It is not a blocker: every blocker:* names work the
  # BUILDER owes, and here the builder owes nothing and a human owes one API
  # call. So it is hand-set intent this machine reads, like `needs-ruling` and
  # `blocked` — with one difference that is the whole reason it is a label at
  # all: this one the machine CLEARS, because its subject is a head, and a head
  # moves. Set by the builder with its evidence, cleared here at the transition.
  #
  # Two transitions end it, and both are read off facts this sweep already has:
  #
  #   the head's checks left FAILURE — whatever was owed was serviced, or the
  #   run reported something else; nothing is owed at a green head; and
  #
  #   the head MOVED under the label — the evidence named a commit that is no
  #   longer this PR's head. Almost every such push clears by the first test
  #   (a new head's checks are NONE or PENDING before they are anything else);
  #   this second one is for the push that reds again, where the label would
  #   otherwise suppress blocker:ci-red for a failure nobody has evidenced.
  #
  # "The head moved" is a question about IDENTITY and is answered with identity:
  # the evidence names its head, and this asks whether that is still the head.
  # It deliberately does not ask whether the head commit is NEWER than the flag,
  # which an earlier draft of this did: a commit's date is a field its author
  # writes, so that test both discarded a valid label under clock skew and let
  # the label suppress blocker:ci-red after a reset onto an older red commit —
  # neither of which is a fact about which commit the branch points at (#423).
  #
  # A head not named, not read, or named unreadably leaves the question unjudged
  # and the label standing — an unread fact never invents a verdict, and here
  # the error directions are not symmetric: a label wrongly kept asks a human to
  # look at a PR that is fine, a label wrongly cleared tells a builder to fix a
  # tree that is not broken, which is the defect this label exists to end.
  has_label rerun-owed || { echo ABSENT; return; }
  case "${CHECKS:-NONE}" in FAILURE) ;; *) echo CLEARED; return ;; esac
  local named="${RERUN_OWED_HEAD:-}" head="${HEAD_SHA:-}"
  # Prefix, not equality: a marker naming an abbreviated SHA names this head as
  # surely as a full one, and reading it as a moved head would clear a label on
  # a spelling. Both empty-guards are load-bearing — an unread head SHA is not
  # a differing one.
  if [ -n "$named" ] && [ -n "$head" ] &&
    [ "${head:0:${#named}}" != "$named" ]; then
    echo CLEARED
    return
  fi
  echo STANDS
}

rerun_owed_named_head() { # evidence first-lines on stdin → the head the newest names
  # Pure, so the fixtures can drive the parse rather than the API around it, and
  # split off here for the reason lib/attention.sh splits attention_newest_flag
  # off: the read either worked or it did not, and that is the caller's problem,
  # never a shape this function has to infer from an empty line.
  #
  # Newest wins, which is the order the comments API returns: a builder who
  # re-evidences a second unrerunnable head on the same PR has said something
  # newer, and the older marker is history.
  local line rest sha=""
  while IFS= read -r line; do
    case "$line" in "$RERUN_OWED_MARKER"*) ;; *) continue ;; esac
    # Newest wins even when the newest is unreadable, so the candidate dies on
    # the marker and not on the validation: a builder who evidences a second
    # head has superseded the first whether or not the new line spells its SHA,
    # and an older marker outliving it would answer a question the newest
    # evidence declines to answer — clearing a live label from a head nobody
    # currently names, which is the one direction this parse must never take.
    sha=""
    rest="${line#"$RERUN_OWED_MARKER"}"
    rest="${rest#\`}"                # the house style backticks a SHA
    rest="${rest,,}"                 # ...and a pasted one may be upper-case
    rest="${rest%%[!0-9a-f]*}"       # everything after the hex run is prose
    # A marker whose head is not a SHA names no head. Seven is git's own floor
    # for an abbreviation and forty is a whole one; outside that the line is
    # decoration somebody wrote, not a fact to clear a label on.
    if [ "${#rest}" -ge 7 ] && [ "${#rest}" -le 40 ]; then sha="$rest"; fi
  done
  [ -z "$sha" ] || echo "$sha"
}

blockers() { # → the blocker:* labels this PR should carry, one per line
  # The second axis. These are FACTS ABOUT THE BRANCH, and they are mutually
  # independent — a PR can be conflicted and red and unasked at once — so they
  # are a set, not an ordering. That is the whole point of splitting them out
  # of state:*: every precedence bug this machine has had (needs-human
  # surviving a conflict, MISSING swallowing STALE) came from projecting
  # independent facts onto one totally-ordered label. A set has no precedence
  # to get wrong.
  #
  # UNKNOWN mergeability is deliberately NOT a conflict: GitHub reports it for
  # about a minute after every merge while it recomputes, and flapping every
  # open PR on each merge would be worse than the bug. Same for a failed read
  # of either fact — both default to the "do not know" value, which blocks
  # nothing. An unset global (an older fixture, a failed fetch) must never
  # invent a verdict it did not read.
  case "${MERGEABLE:-UNKNOWN}" in CONFLICTING) echo blocker:conflict ;; esac
  # A red head is the builder's by default and stays so. The one exception is a
  # head standing under `rerun-owed` (#423): blocker:ci-red asserts the builder
  # owes a FIX, and on a fork PR whose run only the base repo may restart that
  # sentence is false in every word — the tree is not broken, the fix does not
  # exist, and the actor is not in the fleet. Suppressing the blocker is not a
  # claim the head is green: `blocker:unrequested` still reads FAILURE below,
  # decide_state still refuses state:needs-human on it, and the label itself is
  # what the board says instead. The moment rerun_owed_state stops saying STANDS
  # — the head went green, or moved — this line returns unchanged, in the same
  # sweep that clears the label.
  case "${CHECKS:-NONE}" in
    FAILURE) [ "$(rerun_owed_state)" = STANDS ] || echo blocker:ci-red ;;
  esac

  # Nobody is on the hook for a verdict somebody still owes. Distinct from
  # bots-reviewing, which says a request is live and an answer is coming:
  # here the round is stalled because no one was ever asked, and the board
  # said "waiting on the bots" for the 48h it took `stale` to notice.
  # A draft is exempt (the bots ignore drafts by design), and so is an
  # explicit human request — a maintainer claiming a PR early is deliberate,
  # not a dropped ball. THE MAINTAINER'S, and only that one (#479): the
  # exemption's whole reason is the deliberate act, and this machine's own
  # request is not one — it is an ask this sweep made when the round passed and
  # has not yet taken back. Reading it as the deliberate claim suppresses the
  # blocker on exactly the head the four-step sequence produces, where a
  # required verdict is missing and nobody was asked for one. Same bit,
  # same correction as round_state's MISSING branch, and the same safe default:
  # unmarked or unread reads as the maintainer's and exempts as it always did.
  #
  # And so is a head whose checks have not answered yet (#236 D1). This is the
  # one blocker that names an act the author must PERFORM, so it is the one
  # that has to know when performing it is permitted: BUILDER.md's review round
  # requires a green check at the head before requesting, so a builder waiting
  # out a pending run is complying, and flagging compliance teaches its readers
  # to ignore the label. Both 2026-08-03 instances were exactly that —
  # crew#318 at ~12:44Z carried state:addressing + blocker:unrequested while
  # the head's run was IN_PROGRESS, and ceremony#235 at 12:30Z caught the
  # ~90-second gap between a round-answer push and the re-request.
  #
  # PENDING and FAILURE each already have an owner, which is why gating loses
  # no coverage: on PENDING the next move is CI's and state:addressing /
  # state:bots-reviewing already say what the PR is doing; on FAILURE
  # blocker:ci-red owns that head, and stacking a second blocker on it
  # double-flags one stall. NONE joins SUCCESS because no checks configured is
  # nothing to wait for — the same reading the request rule gives the builder.
  # UNREADABLE never arrives here: the caller skips the PR before deciding.
  local checks_permit_the_ask=false
  case "${CHECKS:-NONE}" in SUCCESS | NONE) checks_permit_the_ask=true ;; esac
  local human_claim=false
  if requested "$HUMAN" && [ "${HUMAN_REQUEST_MARK:-NONE}" != MACHINE ]; then
    human_claim=true
  fi
  if [ "$DRAFT" != true ] && [ "$checks_permit_the_ask" = true ] && [ "$human_claim" = false ]; then
    local b v owed=false any_requested=false
    for b in "${REQUIRED_BOTS[@]}"; do
      requested "$b" && any_requested=true
      # MISSING and STALE are both verdicts this head does not have: nobody
      # reviewed it, or everybody reviewed something else. The agent owes an
      # ask either way — the stale round is if anything the worse of the two,
      # since it has approvals on the page that no longer describe the tree.
      v="$(bot_verdict "$b")"
      case "$v" in MISSING | STALE) owed=true ;; esac
    done
    # The quiescence grace (#236 D2) is the last question, after the debt is
    # established: it asks whether the debt has stood long enough to be a
    # dropped ball rather than a round still in motion.
    if [ "$owed" = true ] && [ "$any_requested" = false ] && unrequested_quiescent; then
      echo blocker:unrequested
    fi
  fi
}

round_outranks_draft() { # 0 when the round's standing word survives a re-draft (#205)
  # A standing non-approving verdict outranks draft: a PR that took a round,
  # carries CHANGES_REQUESTED (or a comment owed a reply, or approvals a push
  # staled), and is then converted back to draft is a fix round in progress,
  # not a build — and hiding it behind state:building is a dropped ball the
  # staleness sweep reads as work in progress. Approvals do NOT outrank
  # draft: a re-draft after a passed round is deliberately building again,
  # and a draft must never read state:needs-human.
  #
  # A LIVE panel request on a draft also falls through — deliberately
  # surfaced, not absorbed (#205's must-not-paper-over): the bots ignore
  # drafts by design, so a draft wearing state:bots-reviewing on the board
  # is the visible symptom of a real defect (a request nobody cleared at
  # round close, or a hand-requested draft), and reading it as building
  # would hide exactly that.
  local b
  for b in "${REQUIRED_BOTS[@]}"; do
    requested "$b" && return 0
    case "$(bot_verdict "$b")" in BLOCK | FEEDBACK | STALE) return 0 ;; esac
  done
  [ "$(bot_verdict "$HUMAN")" = BLOCK ]
}

decide_state() { # → the one state:* label this PR should carry
  # Draft decides the state only when the round implies nothing else (#205):
  # a draft with no round history reads state:building exactly as it always
  # has, and round_outranks_draft is what "nothing else" means.
  if [ "$DRAFT" = true ] && ! round_outranks_draft; then
    echo state:building
    return
  fi

  local s
  s="$(round_state)"

  # A draft disqualifies needs-human unconditionally (#205, round 1): with
  # the short-circuit above now conditional, a draft carrying a live human
  # request plus a standing bot block or comment fell through to
  # round_state, whose explicit-human-request precedence sits above the
  # BLOCK/FEEDBACK cases — and GitHub cannot merge a draft at all, so
  # "a human could merge this right now" would lie no matter what the
  # round says. state:addressing is the same honest landing the blocker/
  # needs-ruling/blocked clauses below use: the round's word stands, only
  # the mergeable-now claim is off the table while the PR is a draft.
  if [ "$s" = state:needs-human ] && [ "$DRAFT" = true ]; then
    echo state:addressing
    return
  fi

  # The one rule joining the two axes: state:needs-human means a human could
  # merge this RIGHT NOW, so it requires a clear branch. Any blocker at all
  # means the work is the agent's — whatever the review round says — and the
  # blocker label says which work it is. Nothing else in this function reads
  # the branch, which is what keeps the ordering below purely about reviews.
  if [ "$s" = state:needs-human ] && [ -n "$(blockers)" ]; then
    echo state:addressing; return
  fi

  # And the branch fact behind blocker:ci-red, asked directly rather than
  # through the label (#423). Until `rerun-owed` existed these were the same
  # question — FAILURE always produced the blocker, and the clause above always
  # caught it — so on every PR without that label this line changes nothing and
  # a fixture pins that. With it, the clause above can come up empty at a head
  # whose checks are red, and state:needs-human means exactly "a human could
  # merge this RIGHT NOW", which is false at a red head however good the reason
  # for the red is. Deliberately NOT `has_label rerun-owed`: the label never
  # enters a refusal set, because a label that disqualifies needs-human is
  # acting as a blocker and this one is not one. The red head is what refuses;
  # the label only says who is owed the next move.
  if [ "$s" = state:needs-human ] && [ "${CHECKS:-NONE}" = FAILURE ]; then
    echo state:addressing; return
  fi

  # A pending ruling disqualifies needs-human the same way (#51): while
  # `needs-ruling` is up, the human's turn lives in the THREAD — the flag
  # marks it — and "mergeable right now" must not read true beside an open
  # decision. state:addressing is the honest landing because the ball ON THE
  # PR is the builder's: the flag-setter judges when agreement is reached and
  # carries the ruling in (#50 D6). The label is deliberately NOT in BLOCKERS:
  # that array is machine-owned, and the converge loop strips every entry the
  # current facts do not re-derive — `needs-ruling` is hand-set intent the
  # machine reads and never writes (#50 D9), so parking it there would strip
  # a live escalation on the next 15-minute tick.
  if [ "$s" = state:needs-human ] && has_label needs-ruling; then
    echo state:addressing; return
  fi

  # A directed hold disqualifies it the same way (#180): `blocked` is hand-set
  # intent — triage sets it, anyone may correct it — and during the #111
  # freeze rig#126/#128 carried it beside state:needs-human, so the board said
  # "mergeable right now" about PRs a hold said must not merge (rig#126 was
  # merged seven minutes later). Not a BLOCKERS entry, deliberately: that
  # array is machine-owned and the converge loop strips whatever the facts do
  # not re-derive, so emitting the label there would strip a live hold on the
  # next 15-minute tick — the same trap #51 names for `needs-ruling`.
  # state:addressing is the accepted imprecision: under a hold the builder
  # owes nothing, but "a human could merge this now" must not lie.
  if [ "$s" = state:needs-human ] && has_label blocked; then
    echo state:addressing; return
  fi
  echo "$s"
}

# The take-back's episode marker (#377). Not the `ceremony:` family the
# ruling and attention markers use: this one carries its episode IN the
# marker — the blocker set and the head SHA — rather than being scoped by a
# `labeled` event the way those are, so it reads as its own kind.
HANDOFF_TAKEBACK_MARKER_PREFIX='<!-- handoff-taken-back:'

handoff_takeback_set() { # blocker lines on stdin → the canonical comma-joined set
  # Sorted, so one standing set has exactly ONE spelling in the marker: the
  # BLOCKERS order is fixed today, and an episode must not re-fire because a
  # later edit reordered the emitters in blockers().
  local b joined=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    joined="${joined:+$joined,}$b"
  done < <(sort)
  printf '%s\n' "$joined"
}

handoff_takeback_marker() { # $1 = canonical set, $2 = head SHA → the episode marker
  # The episode IS (blocker set, head): a new head or a different set is a new
  # thing to say, the same head with the same set is the sweep repeating
  # itself — and repeating itself hourly is worse than the silence this
  # replaces (#377 D2).
  printf '%s%s:%s -->\n' "$HANDOFF_TAKEBACK_MARKER_PREFIX" "$1" "$2"
}

handoff_taken_back() { # → the blockers that took a handoff back, one per line; nothing otherwise
  # D3: only the hand-set take-back speaks. This is decide_state's :597 clause
  # asked as a question — the PR already carried state:needs-human, the round
  # alone still says needs-human, and a blocker is what moved it — and it is
  # written in that clause's PRECEDENCE, not just its facts: the draft rule
  # sits above it, so a draft is the draft rule's take-back and never this
  # one, and needs-ruling and blocked sit below it, so they are only ever
  # reached with no blocker standing. Those three each already wear a visible
  # label saying why; the blocker case is the one whose "why" lived only in a
  # run log, which is the whole defect (#377).
  #
  # Hand-set is not separately detectable, and deliberately not chased: a
  # needs-human the machine wrote and a later red overtook lands here too, and
  # the comment is right in both cases — the handoff is off, and this is what
  # standing between it and the human.
  #
  # These three conditions ARE that clause — its guard, plus the one rule
  # above it — so the answer is decide_state's own, not a second opinion
  # about it. A test pins the equivalence across the fixture matrix rather
  # than a runtime re-ask that no fixture could ever red.
  # Since #423 the clause has one arm this predicate deliberately does not
  # report: a red head under `rerun-owed` moves needs-human to addressing with
  # NO blocker standing, so `blockers` is empty here and no comment is posted.
  # That is the same treatment `needs-ruling` and `blocked` already get one
  # paragraph up, and for the same reason — each of those take-backs wears a
  # visible label saying why, and this one wears the label whose whole purpose
  # is to say why. The comment exists for the take-back whose cause lived only
  # in a run log; this cause is on the board.
  has_label state:needs-human || return 0
  [ "$DRAFT" != true ] || return 0
  [ "$(round_state)" = state:needs-human ] || return 0
  blockers
}

round_state() { # → the state the REVIEW ROUND alone implies; knows no branch facts
  local b verdicts=""
  for b in "${REQUIRED_BOTS[@]}"; do
    if requested "$b"; then echo state:bots-reviewing; return; fi
  done
  # Collect the WHOLE round before applying any precedence. Deciding inside
  # the loop let BOTS order pick the winner: a MISSING returned immediately,
  # so a STALE belonging to a later bot was never even read, and the mixed
  # round (one approval staled by a push, another bot yet to review) came out
  # needs-human — the #136 headline shape, with zero reviews bound to the head.
  for b in "${REQUIRED_BOTS[@]}"; do
    verdicts="$verdicts $(bot_verdict "$b")"
  done
  case "$verdicts" in
    # STALE = a verdict for an older head. Unlike MISSING, this outranks the
    # human request: every approval it covers was invalidated by a push, so
    # NOBODY has reviewed this tree. Handing that to the human is the #136 case
    # where everything reads green — mergeable, CI passing, "waiting on the
    # human" — over code no reviewer has seen. The agent owes a re-request.
    # Checked before MISSING because "unfinished" must not swallow "and also
    # stale": a round that is both is a push that outran the re-requests, not
    # a maintainer deliberately claiming the PR early.
    *STALE*) echo state:addressing; return ;;
  esac
  case "$verdicts" in
    # No verdict at all from some bot, and nothing staled. An explicit human
    # request still outranks an unfinished round — a maintainer pulling a PR
    # to themselves early is a deliberate act, and the original precedence.
    # THE MAINTAINER'S request, and only that one (#479 D4): this machine also
    # asks the human, when the round passes, and until it began marking its own
    # ask the two were one bit. A request made at a head whose round has since
    # come apart is this machine's own echo, and reading it as the deliberate
    # claim says a human may merge a head some required reviewer still owes a
    # verdict on — the same lie the paragraph below names, wearing a different
    # label. An unmarked request is a maintainer's and outranks as it always
    # did; so is an unread one, which is why NONE is the default.
    #
    # Otherwise it is the AGENT's ball, not the bots'. The loop above already
    # returned for every live bot request, so reaching here with a MISSING
    # means somebody owes a verdict and nobody was asked for one — the round
    # is not running. Calling that bots-reviewing was the lie that let a
    # forgotten PR read "waiting on the reviewers" for the 48h it took the
    # stale sweep to notice. blocker:unrequested says why.
    *MISSING*)
      if requested "$HUMAN" && [ "${HUMAN_REQUEST_MARK:-NONE}" != MACHINE ]; then
        echo state:needs-human
        return
      fi
      echo state:addressing; return ;;
  esac
  # an explicit human request outranks the remaining bot outcomes — it is the
  # final gate, and a maintainer pulling a PR to themselves early counts too
  if requested "$HUMAN"; then echo state:needs-human; return; fi
  case "$verdicts" in
    # FEEDBACK = a comment with no verdict → the agent owes the round-reply.
    *BLOCK* | *FEEDBACK*) echo state:addressing; return ;;
  esac
  # the bots all approve — but if the human's standing word is
  # changes-requested (and nobody re-requested them yet), the agent owes
  # fixes, not the human a nag
  if [ "$(bot_verdict "$HUMAN")" = BLOCK ]; then
    echo state:addressing
  else
    echo state:needs-human
  fi
}

# ---------------------------------------------------------------------------
# The sweep: fetch facts, decide, converge. One PR's failure never aborts the
# others — each PR reconciles in a subshell and a failure just logs.
# ---------------------------------------------------------------------------

core_label_rows() {
  cat <<'EOF'
state:building|FBCA04|Pre-round: the builder is still building — draft is evidence for it, not the definition
state:bots-reviewing|1D76DB|Waiting on the bot reviewers to finish the round
state:addressing|D93F0B|All bots reviewed — coding agent owes the single reply + fixes
state:needs-human|8250DF|No blockers, all bots approve — waiting on the human reviewer
blocker:conflict|B60205|Does not merge — the branch conflicts and the agent owes a rebase
blocker:ci-red|B60205|A check is failing — the agent owes a fix (not a rebase)
blocker:unrequested|E99695|Somebody still owes a verdict and nobody was asked for one
merge-next|0E8A16|Head of the merge queue — merge this one next (set by hand/agent, cleared here)
stale|B60205|No activity for 48h — needs a poke (sweep-managed)
blocked|6A737D|Waiting on another PR or issue to land first
offsite|CFD3D7|Issue deliverable is a PR in another repository — claim clock paused
needs-ruling|D4C5F9|A human decision is pending — question, options and a recommendation are in the comment
operator|A371F7|Operator-owned; the body names the evidence surface, the command, and the wake condition
rerun-owed|D4C5F9|The head is red on a rerun no agent may start — a human owes the button, not the builder a fix
attention|D93F0B|A demand is parked here for the assignee: pick up the thread, ack by removing this label
release|0E8A16|Release flow and version/packaging work
needs-triage|FBCA04|Did not come through triage — owes normalization or conversion to a discussion
ready|0E8A16|Triaged, spec complete, unblocked; its owner can start now and succeed
claimed|1D76DB|A builder owns it: assignee set, draft PR expected shortly
post-merge|006B75|Refs-linked PR merged; post-merge criteria remain and triage owns completion
epic|5319E7|Organizes other issues via a dependency-ordered task list — builders never pick it
EOF
}

retired_label_names() { # the GitHub defaults LABELS.md retires — a `question` is a discussion
  # One registry, kept beside core_label_rows() for the same reason those rows
  # are not in labels.conf: a rule that must hold in every governed repo
  # cannot live in a per-repo file. The six names match LABELS.md exactly.
  cat <<'EOF'
duplicate
invalid
question
wontfix
help wanted
good first issue
EOF
}

bootstrap_labels() { # BOOTSTRAP=yes only: ~20 upserts is too chatty for every sweep
  local rows name
  rows="$(core_label_rows)"
  if [ -f "$LABELS_CONF" ]; then
    rows="$rows
$(configured_label_rows "$LABELS_CONF")"
  fi
  # Per-row tolerance, for the reason the retire loop below already records
  # (#91's shape, #508): both run under `set -e`, so an unguarded call aborts
  # the whole loop and every row after it is never attempted. That truncates a
  # taxonomy rather than failing one label — and because the consumer's
  # configured rows are appended AFTER the core rows, one bad core row takes
  # the consumer's whole `scope:*` set with it. The observed shape: a bootstrap
  # that landed 21 of 33 labels left a board carrying `blocked` and no `ready`,
  # which reads as populated and is not a queue. Log the row, keep going, and
  # fail at the end so a partial taxonomy is loud instead of green.
  local failed_rows=""
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    if ! run gh label create "$name" -R "$REPO" --color "$color" --description "$desc" --force; then
      failed_rows="$failed_rows $name"
      log "bootstrap: '$name' not created — continuing"
    fi
  done <<<"$rows"

  # LABELS.md publishes the defaults as deleted at bootstrap; until #93
  # nothing deleted them — incubator's first dispatch ran green and left
  # `good first issue` standing. Deletion is `BOOTSTRAP=yes` only like the
  # upserts (#472 — it was dispatch-gated until then, and no event gates it
  # now), and never fatal: `gh label delete` exits non-zero on a label that
  # is already gone, the NORMAL case from the second bootstrap on, and under
  # set -e an unguarded call aborts the whole run (#91's shape). A 403
  # refusal gets the same tolerance — the bot bootstrap already 403s on
  # blocker:drill-pending, and a token that cannot delete must still get
  # the taxonomy it can create. Either way: log the name, keep going.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    run gh label delete "$name" -R "$REPO" --yes \
      || log "retire: '$name' not deleted (already absent, or refused) — continuing"
  done <<<"$(retired_label_names)"

  # One read, not one re-dispatch per bad row: a consumer looking at a
  # half-built board needs the whole gap named at once (#508).
  if [ -n "$failed_rows" ]; then
    echo "::error::labels: bootstrap could not create:$failed_rows — the taxonomy is INCOMPLETE; fix those rows and re-dispatch"
    return 1
  fi
}

has_label() { grep -qxF "$1" <<<"$LABELS"; }

release_shaped() { # $1 = head version, $2 = base version → 0 when the PR is release-shaped
  # The shape rule itself, in one place because two surfaces now read it: the
  # annotation below and the PR comment #501 added beside it. Split out rather
  # than duplicated — a guard whose two mouths could disagree about what they
  # are guarding is a worse defect than either silence.
  #
  # An unreadable HEAD version is not a shape (#130): the sweep must not nag on
  # facts it did not read, and tree_version's every-failure-path-prints-nothing
  # contract is what makes that test the whole of it (#501 D5).
  local head_ver="$1" base_ver="$2"
  [ -n "$head_ver" ] || return 1
  grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$head_ver" || return 1
  [ "$head_ver" != "$base_ver" ] || return 1
}

release_shape_warning() { # $1 = PR, $2 = head version, $3 = base version
  # The #128 incident's guard (#130): a release-shaped PR — bare X.Y.Z at
  # its head where the base says something else — reaching the board with
  # no `release` label is exactly the state whose merge would publish
  # nothing, so the sweep says so instead of letting the merge door
  # discover it. A WARNING, never a write: `release` is declared intent,
  # and the reconciler does not guess intent (LABELS.md's rule for
  # `blocked`/`release`). An unreadable version blocks nothing — the
  # sweep must not nag on facts it did not read.
  #
  # The annotation STAYS (#501 D1). It costs nothing and it is the
  # machine-readable trace; what it never was is a surface a human reads,
  # because it attaches to the check run that emitted it and those runs belong
  # to the sweep's own branch, never to the PR head. That is why it fired on 21
  # passes over #500 and reached a builder, three reviewers and the merger
  # none. release_shape_notice is the half that discharges the guard's purpose.
  local n="$1" head_ver="$2" base_ver="$3"
  release_shaped "$head_ver" "$base_ver" || return 0
  echo "::warning::labels: #$n is release-shaped (version ${base_ver:-unreadable} -> $head_ver at its head) but carries no release label — the merge door reads that label as declared intent and will refuse without it; if this is the ceremony PR, apply release (#130; the #128 incident)"
}

# The release-shape notice's episode marker (#501 D3). Prefix plus payload,
# the shape HANDOFF_TAKEBACK_MARKER_PREFIX uses and for its reason: the sweep
# is stateless per pass, so the episode has to be carried IN the marker rather
# than scoped by an event, and the PR's own thread is the only memory there is.
#
# The payload is the TRANSITION and deliberately not the head SHA. A head-keyed
# marker would open a new episode on every push, which over a live release PR is
# one comment per push — the noise the episode bound exists to prevent. A
# PR-keyed one would go the other way and let a standing comment name a
# transition the tree no longer has, which is D2's harm (a permanent false
# claim) wearing different clothes. The transition is the fact the comment
# asserts, so it is the fact the episode is keyed to.
RELEASE_SHAPE_NOTICE_MARKER_PREFIX='<!-- ceremony:release-shape-notice:'
# ...and the mark on its retraction (#501 D2). Two markers and not one, for
# HUMAN_REQUEST_WITHDRAWN_MARKER's reason: the question is what stands NOW, so
# the newest of the pair is the whole answer and the pair is a state rather
# than a history. That is also what makes "a PR that loses and regains the
# label may be told again" work — the retraction closes the episode, and the
# next pass with the label gone opens a fresh one. It carries no payload: a
# retraction is about the notice standing, whatever transition that notice named.
RELEASE_SHAPE_RETRACTED_MARKER='<!-- ceremony:release-shape-retracted -->'

release_shape_marker() { # $1 = base version, $2 = head version → this episode's marker
  # `unreadable` and not the empty string, so the marker of an episode opened
  # while the BASE read was failing is one stable spelling rather than a
  # prefix-only stub — and so it reads as the annotation's own text does.
  printf '%s%s->%s -->\n' "$RELEASE_SHAPE_NOTICE_MARKER_PREFIX" "${1:-unreadable}" "$2"
}

release_shape_state() { # comment first-lines on stdin → the standing notice's marker, RETRACTED, or NONE
  # Pure, so the fixtures drive the parse rather than the API around it — the
  # split human_request_mark and rerun_owed_named_head both make.
  #
  # Newest wins, which is the order the comments API returns: a notice and its
  # retraction are one running state, not a tally. Matched as the comment's
  # FIRST LINE, where this file's other markers are written, with
  # human_request_mark's residual and its bound — a comment whose first line is
  # a verbatim paste of the marker is read as this machine's, and both ways
  # that fails are cheap here: a forged notice-mark suppresses one comment for
  # one episode, a forged retraction posts one extra.
  local line state=NONE
  while IFS= read -r line; do
    case "$line" in
      "$RELEASE_SHAPE_NOTICE_MARKER_PREFIX"*) state="$line" ;;
      "$RELEASE_SHAPE_RETRACTED_MARKER"*) state=RETRACTED ;;
    esac
  done
  printf '%s\n' "$state"
}

release_shape_marks() { # $1 = PR → its comments' first lines; non-zero when they could not be read
  gh api --paginate "repos/$REPO/issues/$1/comments" \
    --jq '.[] | .body | split("\n")[0] | sub("\r$"; "")' 2>/dev/null
}

release_shape_notice() { # $1 = PR, $2 = head version, $3 = base version — the guard on a surface a human reads (#501 D1)
  local n="$1" head_ver="$2" base_ver="$3" marker marks standing
  release_shaped "$head_ver" "$base_ver" || return 0
  marker="$(release_shape_marker "$base_ver" "$head_ver")"

  # The comment read is behind the shape, so an ordinary PR pays nothing for
  # it. A failed read says nothing, for reconcile_handoff_takeback's reason:
  # everywhere in this file an unreadable fact must not invent a verdict, and
  # the verdict it would invent here is a REPEAT — duplicate comments are the
  # harm the marker exists to prevent, and the next sweep is an hour away.
  if ! marks="$(release_shape_marks "$n")"; then
    log "#$n: release-shape marks unreadable — no notice invented this pass"
    return 0
  fi
  standing="$(release_shape_state <<<"$marks")"
  [ "$standing" != "$marker" ] || return 0

  # NOT redirected to /dev/null, unlike the take-back and human-request marks:
  # those redirect because each RECORDS an act that is itself narrated
  # elsewhere, and here the comment IS the act. A rehearsal that swallowed this
  # `DRY_RUN:` line would say nothing about the one thing this function does
  # (the auto-merge provenance comment is unredirected for the same reason).
  if run gh issue comment "$n" -R "$REPO" --body "$marker
📦 **This pull request is release-shaped and carries no \`release\` label.**

Its tree declares version \`$head_ver\` where its base declares
\`${base_ver:-unreadable}\`. A bare \`X.Y.Z\` over a different base is the shape of a
ceremony PR, and \`release\` is the label the merge door reads as declared
intent.

**What happens on the merge without it.** The merge itself succeeds and looks
green. What does not happen is the publish: the release path refuses behind it
— *the version transitioned but no merged, release-labeled PR is behind this
commit* — and creates nothing. No tag, no release, no announcement, and no
red anywhere on this PR to say so.

**The remedy, if this is the ceremony PR: apply \`release\` before the merge.**
This machine will not apply it for you and never does — \`release\` is declared
intent, and a machine must not guess intent (LABELS.md's rule for
\`blocked\`/\`release\`). This comment is notice, not a guess.

**If this is not a release PR**, nothing here blocks anything; the bare version
at the head over a different base is simply what drew the notice.

*One comment per episode: this says nothing further while the transition and
the label stand as they are, and takes itself back when \`release\` arrives
(heavy-duty/ceremony#130, the heavy-duty/ceremony#128 incident;
heavy-duty/ceremony#501 is the pass that put it on this surface).*"; then
    log "#$n: release-shaped (${base_ver:-unreadable} -> $head_ver) with no release label — commented"
  else
    # A failed post recorded no marker, so the next sweep retries the episode;
    # only this log line would have lied about it.
    log "#$n: WARNING: release-shaped (${base_ver:-unreadable} -> $head_ver) with no release label — the comment failed to post; the next sweep retries"
  fi
}

release_shape_retract() { # $1 = PR — the notice takes itself back when `release` arrives (#501 D2)
  # A tripwire that never retracts becomes a permanent false claim on a PR that
  # was fixed, which is worse than the annotation it replaces. The withdrawal at
  # reconcile_human_request is the in-file precedent and this is its shape.
  local n="$1" marks standing
  if ! marks="$(release_shape_marks "$n")"; then
    log "#$n: release-shape marks unreadable — no retraction invented this pass"
    return 0
  fi
  standing="$(release_shape_state <<<"$marks")"
  # Only a STANDING notice is retracted, which is the whole of the retraction's
  # idempotency: after the first one the newest mark is RETRACTED and every
  # later pass returns here having said nothing. A PR that never drew a notice
  # never draws a retraction either.
  case "$standing" in "$RELEASE_SHAPE_NOTICE_MARKER_PREFIX"*) ;; *) return 0 ;; esac

  if run gh issue comment "$n" -R "$REPO" --body "$RELEASE_SHAPE_RETRACTED_MARKER
📦 **Retracted — this pull request carries \`release\` now.**

The release-shape notice on this PR no longer applies. The label the merge door
reads as declared intent is present, so the merge creates the release.

Nothing is owed here. If the label comes off again while the PR is still
release-shaped, this machine says so again — that is a new episode
(heavy-duty/ceremony#501)."; then
    log "#$n: release label arrived — retracted the release-shape notice"
  else
    log "#$n: WARNING: release label arrived but the retraction failed to post — the notice still stands and the next sweep retries"
  fi
}

reconcile_release_shape() { # $1 = PR, $2 = head version, $3 = base version (both empty where the gate did not read them)
  # The two halves behind one call, because which half is owed is the same
  # question the call site's gate already asked and the answer must not be able
  # to differ between them.
  #
  # The retraction is NOT gated on draft, and that is deliberate rather than an
  # oversight of D5's draft exemption. The exemption is about NAGGING — the
  # build phase is the builder's — and a retraction is not a nag; it is this
  # machine taking back something it said. The engine returns a PR to draft at
  # every round close, so a release PR labeled while drafted is the ordinary
  # case, not the exotic one, and gating here would strand the false claim on
  # exactly those PRs.
  if has_label release; then
    release_shape_retract "$1"
    return 0
  fi
  # Empty versions on a draft (the gate never read them) fall out of
  # release_shaped as "not a shape", so the draft exemption needs no second test.
  release_shape_notice "$1" "$2" "$3"
}

tree_version() { # $1 = ref → that tree's version via the API, or nothing
  # Both backends, no checkout: a VERSION file first, package.json's
  # version field second (jq, not node — a read needs no npm machinery).
  # Every failure path prints nothing: the caller treats "could not read"
  # as "not release-shaped" rather than warning on a guess.
  local ref="$1" ver
  ver="$(gh api "repos/$REPO/contents/VERSION?ref=$ref" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$ver" ]; then
    ver="$(gh api "repos/$REPO/contents/package.json?ref=$ref" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
  fi
  [ -z "$ver" ] || printf '%s\n' "$ver"
  return 0
}

reconcile_handoff_takeback() { # $1 = PR number, $2 = did the converge edit take it back?; at most one comment per episode (#377)
  # The defect this closes is not the take-back — that rule is correct and
  # unchanged — but its silence: `log` writes to the labels workflow's run
  # log, and a builder driving a PR reads the PR. On incubator#94 a hand-set
  # label vanished 45 seconds later with no comment three times running, and
  # writing it again is the rational answer to a write that disappears
  # without a reason.
  local n="$1" cleared="$2" standing joined marker bodies b pretty=""

  # D1's trigger is the replacement that LANDED, not the one attempted. The
  # caller passes the answer because only it knows: a `gh issue edit` that
  # failed, or one skipped because the repo's taxonomy has no
  # `state:addressing`, leaves `state:needs-human` standing on the PR — and
  # "the state is state:addressing again" would then be false ABOUT A LABEL
  # STILL THERE, which is the loudest way to be wrong here. Worse than the
  # falsehood is its durability: the marker such a comment records suppresses
  # the true one at that (set, head) forever, so the pass where the edit does
  # land would say nothing. Not a comment condition so much as the definition
  # of the event — nothing was taken back until the label came off.
  [ "$cleared" = true ] || return 0

  standing="$(handoff_taken_back)"
  [ -n "$standing" ] || return 0
  joined="$(handoff_takeback_set <<<"$standing")"
  marker="$(handoff_takeback_marker "$joined" "$HEAD_SHA")"

  # The comment read is behind the trigger, so an ordinary PR pays nothing for
  # it. A failed read says nothing: everywhere else in this file an unreadable
  # fact must not invent a verdict, and here it must not invent a REPEAT —
  # duplicate comments are the harm the marker exists to prevent, and the next
  # sweep is 15 minutes away.
  if ! bodies="$(gh api --paginate "repos/$REPO/issues/$n/comments" \
    --jq '.[].body' 2>/dev/null)"; then
    log "#$n: take-back comments unreadable — no comment invented this pass"
    return 0
  fi
  if grep -qF "$marker" <<<"$bodies"; then return 0; fi

  while IFS= read -r b; do
    [ -n "$b" ] || continue
    pretty="${pretty:+$pretty, }\`$b\`"
  done <<<"$standing"

  if run gh issue comment "$n" -R "$REPO" --body "$marker
\`state:needs-human\` was taken back on this PR — the state is
\`state:addressing\` again. That is not a machine error, and re-setting the
label will not stick: the label means a human could merge this **right now**,
so it requires a clear branch, and this head does not have one.

Standing at \`$HEAD_SHA\`: $pretty

The handoff's precondition is every panel verdict approving the current head
**and no \`blocker:*\` standing** — conflicts rebased, CI green, drill
recorded if this is a release PR
([BUILDER.md — Handoff](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#handoff)).
Clear what is standing above and the next sweep derives \`state:needs-human\`
by itself; setting it by hand only earns another take-back
(heavy-duty/ceremony#377).

*One comment per episode: a new head, or a different blocker set, says this
again — the same head with the same blockers never does.*" >/dev/null; then
    log "#$n: handoff taken back ($joined at $HEAD_SHA) — commented"
  else
    # A failed post recorded no marker, so the next sweep retries the episode;
    # only this log line would have lied about it.
    log "#$n: WARNING: handoff taken back ($joined at $HEAD_SHA) — the comment failed to post; the next sweep retries"
  fi
}

reconcile_human_request() { # $1 PR, $2 this pass's desired state, $3 did this pass ask the human
  # The two halves of #479's mark, together because they are one contract: the
  # machine records the ask it makes, and takes back only what it recorded.
  # They are mutually exclusive — asking happens on state:needs-human and
  # withdrawing happens off it — so the early return below is the whole of the
  # branching.
  local n="$1" desired="$2" asked="$3"

  # Both comments below redirect run()'s stdout, which spends their own
  # `DRY_RUN:` narration — the treatment every other `gh issue comment` in this
  # family gets, and safe here for a reason the auto-merge site does not have:
  # each mark RECORDS an act that is itself narrated. The request is written by
  # an unredirected `run` in reconcile_pr and the withdrawal by the unredirected
  # `run` in this function, so a rehearsal sees every act on the board and loses
  # only the bookkeeping about it. A fixture pins both.
  if [ "$asked" = true ]; then
    # A failed post leaves the request UNMARKED, which reads as a maintainer's
    # and is never withdrawn: the behaviour before this existed, and the
    # direction an unrecorded write has to fail in. It cannot be retried — the
    # request now stands, so human_request_needed suppresses the next pass's
    # ask and there is no second act to hang a mark on — which is why the
    # warning says what the PR is left carrying rather than promising a retry.
    if run gh issue comment "$n" -R "$REPO" --body "$HUMAN_REQUEST_MARKER
🧑 Requested \`$HUMAN\`'s review — the round passed at \`$HEAD_SHA\`.

This ask is **the sweep's own, and provisional**: if the round stops passing
here — a push stales the approvals, a required verdict goes missing, a blocker
comes up — the same sweep withdraws it, and says so. A request a *maintainer*
makes carries no such mark: it is a deliberate act, it outranks an unfinished
round, and this machine never withdraws it (heavy-duty/ceremony#479)." >/dev/null; then
      log "#$n: marked the $HUMAN request as this machine's"
    else
      log "#$n: WARNING: requested $HUMAN but the mark failed to post — that request now reads as a maintainer's and will never be withdrawn"
    fi
    return 0
  fi

  # D3, written as a standing condition and not as an edge. "The transition
  # where desired moves away from state:needs-human" is what this catches on
  # the first sweep after the round stops passing, which is the criterion; but
  # a pass whose DELETE failed, or whose label edit was skipped for a missing
  # taxonomy row, has already spent the edge, and an edge-shaped test would
  # never look again. The gate closes by itself, `requested` going false the
  # moment the withdrawal lands.
  [ "$desired" != state:needs-human ] || return 0
  requested "$HUMAN" || return 0
  # D3's other half: only its OWN. An unmarked request — a maintainer's, or one
  # whose mark could not be read this pass — is left exactly where it is.
  [ "${HUMAN_REQUEST_MARK:-NONE}" = MACHINE ] || return 0

  # D5: idempotent and never fatal. The gate above means this only ever fires
  # on a request that is standing, so the no-op case is not reached in practice
  # — GitHub answers a DELETE for a reviewer who is not requested with a
  # success and no change, and nothing here depends on which. A 4xx logs and
  # the sweep continues, the contract every other write in this file has.
  if ! run gh api --method DELETE "repos/$REPO/pulls/$n/requested_reviewers" \
    -f "reviewers[]=$HUMAN" --silent; then
    log "#$n: WARNING: could not withdraw this machine's $HUMAN request — the mark stands, so the next sweep retries"
    return 0
  fi
  log "#$n: withdrew this machine's $HUMAN request (state is $desired)"

  # The withdrawal's own mark, after the DELETE and conditional on it. The
  # order is the rule: a mark written before a DELETE that then failed would
  # say the machine's ask is gone while it stands, and D4's narrowing would go
  # back to reading that ask as a maintainer's — the defect, with the fix's own
  # bookkeeping vouching for it. This way a failed DELETE leaves both facts
  # unchanged and the next sweep retries.
  if ! run gh issue comment "$n" -R "$REPO" --body "$HUMAN_REQUEST_WITHDRAWN_MARKER
🧑 Withdrew \`$HUMAN\`'s review request — this sweep asked for it, and the round
that justified it no longer passes. The state at \`$HEAD_SHA\` is \`$desired\`.

Nothing is owed to the human here yet; the machine asks again by itself the
next time the round passes. Only the sweep's **own** request is withdrawn — a
maintainer who asks for this PR keeps it through every push
(heavy-duty/ceremony#479)." >/dev/null; then
    log "#$n: WARNING: withdrew this machine's $HUMAN request but the withdrawal mark failed to post — a later maintainer request on this PR reads as this machine's until one does"
  fi
  return 0
}

auto_merge_confirm() { # $1 = PR number → the refusal reason, empty when confirmed (#460 D3)
  # The second of the two locks. Between the pass that graded this PR and this
  # call a builder can push: the window is seconds and the loss is a merged
  # head nobody reviewed, so the head is re-read here and pinned again at the
  # call itself (D4). Either lock alone is a race; both is not.
  #
  # A read, so it does NOT go through run() — under DRY_RUN=1 the confirmation
  # still happens, which is what makes the rehearsal's narration say what the
  # sweep would really have merged rather than what it hoped to.
  #
  # It deliberately does not re-read mergeability (D3): a conflict arriving
  # from another PR's merge does not move THIS PR's head, and GitHub refuses
  # that merge itself — which D5 handles — so a second `gh pr view` would buy
  # a slower window, not a smaller one.
  #
  # stderr is captured the way this file's other two read sites capture it
  # (:1211, :1238) rather than through lib/read.sh's guarded_read: that
  # helper's header states it has no labels-side caller, and lib/read.sh is
  # outside this issue's scope fence, so a caller here would ship a comment
  # this PR may not correct.
  local n="$1" pr err err_file state head graded_release current_release
  err_file="$(mktemp)"
  if ! pr="$(gh api "repos/$REPO/pulls/$n" 2>"$err_file")"; then
    err="$(cat "$err_file")"
    rm -f "$err_file"
    # An unreadable fact never invents a verdict (#101) — and here the verdict
    # it would invent is irreversible, so the unreadable case refuses.
    printf 'the confirmation read failed: %s\n' "$(read_failure_reason "$err")"
    return 0
  fi
  rm -f "$err_file"

  # Re-read, never recomputed: reading back the values this pass already
  # computed would make the confirmation a comment rather than a lock.
  state="$(jq -r '.state // "unknown"' <<<"$pr")"
  head="$(jq -r '.head.sha // ""' <<<"$pr")"
  [ "$state" = open ] ||
    { printf 'the PR is no longer open (state: %s)\n' "$state"; return 0; }
  [ "$head" = "$HEAD_SHA" ] ||
    { printf 'the head moved since this pass graded it (graded %s, now %s)\n' \
      "$HEAD_SHA" "$head"; return 0; }
  graded_release=no
  has_label release && graded_release=yes
  current_release=no
  jq -e '.labels[]? | select(.name == "release")' <<<"$pr" >/dev/null && current_release=yes
  [ "$graded_release" = "$current_release" ] || {
    printf 'release %s on the PR since this pass graded it\n' \
      "$([ "$current_release" = yes ] && printf appeared || printf disappeared)"
    return 0
  }
}

reconcile_auto_merge() { # $1 = PR number, $2 = this pass's decide_state conclusion (#460), $3 = whether THIS pass requested the human (#461 D7)
  # The one irreversible act in the sweep. Everything that makes it safe is
  # upstream and is not re-derived here (D2): decide_state's conclusion is the
  # trigger and carries its five accumulated disqualifiers, auto_merge_verdict
  # (#459) owns the refusal set, and this function owns the act alone. A second
  # draft or blocker check here would be a refusal no fixture can reach (#458 E7).
  local n="$1" desired="$2" human_requested="$3" verdict reason err err_file
  local method path
  [ "$AUTO_MERGE" != off ] || [ "$AUTO_MERGE_RELEASE" != off ] || return 0
  method="$(auto_merge_method)"
  path=ordinary
  has_label release && path=release
  verdict="$(auto_merge_verdict "$desired")"
  if [ "$path" = release ]; then
    log "#$n: auto-merge[release]: $verdict"
  else
    log "#$n: auto-merge[ordinary]: $verdict"
  fi
  [ "$verdict" = MERGE ] || return 0

  reason="$(auto_merge_confirm "$n")"
  if [ -n "$reason" ]; then
    log "#$n: auto-merge refused: $reason"
    return 0
  fi

  # Pinned to the graded head (D4). Never `--auto`, which arms GitHub's own
  # auto-merge — option A, needing branch protection nobody has. Never
  # `--delete-branch`: every PR in this family arrives from a fork and the
  # branch is not ours to delete.
  # stdout is NOT sent to /dev/null, unlike this file's other mutations, and
  # the difference is load-bearing: `>/dev/null` on a `run` invocation
  # discards run()'s OWN `DRY_RUN:` narration along with the command's output,
  # so the rehearsal would fall silent about the one act it exists to preview.
  # That is the whole of the reason. It buys nothing from gh itself on the
  # happy path — gh prints its `✓ Merged pull request` line to STDERR, which
  # the redirect two lines below captures into err_file for D5's reason and
  # discards when the merge succeeds.
  err_file="$(mktemp)"
  if ! run gh pr merge "$n" -R "$REPO" "--$method" \
    --match-head-commit "$HEAD_SHA" 2>"$err_file"; then
    err="$(cat "$err_file")"
    rm -f "$err_file"
    # Loud, local and non-fatal (D5): the PR is exactly as it was, nothing is
    # retried this pass, no comment is posted, and the loop continues with the
    # remaining PRs. The next sweep re-derives all of it from scratch, which is
    # what a stateless sweep is for. read_failure_reason's collapse-and-truncate
    # treatment is why a multi-line API error cannot forge another PR's line.
    log "#$n: auto-merge refused: $(read_failure_reason "$err")"
    return 0
  fi
  rm -f "$err_file"

  # #461 D7 (#458 E18) — the human is review-requested at the TOP of this same
  # pass and merged by its last statement, so the first adopting repository's
  # human gets a request on a PR that is already merged when the notification
  # arrives. That ordering is #460's D1 working as specified; what is owed is
  # that the merge says so.
  #
  # Two properties, both load-bearing. The fact is PASSED IN, never re-read: a
  # second `requested_reviewers` read, or a second `human_request_needed` call,
  # would make the comment re-derive what the pass already knew (#460 D2), and
  # the two reads could disagree. And the line is CONDITIONAL, because the
  # claim must be true — a PR that already carried a live request, or whose
  # human approval was head-current, got no request in this pass, and a comment
  # stating an act that did not happen is the #377 defect this comment exists
  # to prevent. An `if` and not a `&&` one-liner: under `set -e` a trailing
  # false test is a failed command and takes the whole PR's subshell with it.
  local human_line=""
  if [ "$human_requested" = true ]; then
    human_line="
- **The human was asked:** this pass requested \`$HUMAN\`'s review moments
  before this merge, and this merge is the answer. The request is never
  suppressed — at the moment it is made the pass cannot know the merge will
  land, and a repository that opted in without \`contents: write\` merges
  nothing and would then also ask nobody."
  fi

  # #468 D6/D7 — a release merge opens the ship door with the exact head this
  # pass graded and pinned. Dispatch stays after the successful merge gate;
  # failure is loud but cannot undo the merge or stop the sweep.
  local release_dispatch_line=""
  if [ "$path" = release ]; then
    local release_err release_err_file
    release_err_file="$(mktemp)"
    release_dispatch_line="
- **Release dispatch:** attempted \`$RELEASE_WORKFLOW\` with \`merged-sha=$HEAD_SHA\`."
    if run gh workflow run "$RELEASE_WORKFLOW" -R "$REPO" \
      -f "merged-sha=$HEAD_SHA" 2>"$release_err_file"; then
      rm -f "$release_err_file"
      log "#$n: dispatched release workflow $RELEASE_WORKFLOW at $HEAD_SHA"
    else
      release_err="$(cat "$release_err_file")"
      rm -f "$release_err_file"
      log "#$n: WARNING: release dispatch of $RELEASE_WORKFLOW failed: $(read_failure_reason "$release_err") — the merge stands"
    fi
  fi

  # D6/D7 — the provenance. Under this toggle the merge commit is authored by
  # `github-actions[bot]` in an organization whose doctrine has said for its
  # whole life that only humans merge; a run log nobody opens is exactly the
  # invisibility #377 was about. The merge and the comment are one unit, which
  # is why a failed comment is loud and the merge is never re-attempted: it
  # already happened.
  if run gh issue comment "$n" -R "$REPO" --body "$AUTO_MERGED_MARKER
🤖 **Auto-merged by the labels sweep.**

- **Head merged:** \`$HEAD_SHA\` — the commit this pass graded, and the one
  the merge call was pinned to.
- **Method:** \`$method\`.
- **Authorised by:** \`$([ "$path" = release ] && printf auto_merge_release || printf auto_merge)=$method\` on this repository's labels
  caller. The toggle is closed by default; this repository opted in.
- **Trigger:** this sweep's own \`decide_state\` conclusion —
  \`state:needs-human\`, re-derived from the round, the blockers and the
  checks in this pass — and *not* the \`state:needs-human\` label, which the
  same pass validates rather than trusts.$release_dispatch_line$human_line

The head was re-read immediately before the merge and matched.
*Only humans merge* remains this organization's default: this repository
turned that default off deliberately (heavy-duty/ceremony#458)."; then
    log "#$n: auto-merged $HEAD_SHA ($method) — commented"
  else
    log "#$n: WARNING: auto-merged $HEAD_SHA ($method) but the provenance comment failed to post — the merge stands and is NOT re-attempted"
  fi

  # #461 D2/D3 — the post-merge wake. GitHub creates no workflow runs from
  # events raised by GITHUB_TOKEN, so the `push` this merge just made to the
  # default branch starts NOTHING: the consumer's own `push: branches: [main]`
  # CI never grades the merge commit, and a merge commit is a commit no PR
  # check ever ran against. `workflow_dispatch` is one of the two documented
  # exemptions, and it is the mechanism the trigger job in labels.yml already
  # relies on — so the repair is the exemption itself.
  #
  # HERE and not earlier, and the placement is the rule rather than a
  # preference. Only a merge that SUCCEEDED raises the push whose loss this
  # repairs: a dispatch on a pass that merged nothing would wake the consumer's
  # CI hourly for nothing, and a dispatch before the merge grades the pre-merge
  # tree and reports on a commit that does not exist yet. After the provenance
  # comment, so the comment is not held behind a dispatch that can hang.
  #
  # Through run(), like every mutation in this file: `drill/rehearsal.sh` runs
  # this script against THIS live repository with DRY_RUN=1, and a dispatch
  # written outside run() wakes real workflows here. stdout is deliberately not
  # redirected — `>/dev/null` on a `run` invocation discards run()'s own
  # `DRY_RUN:` narration along with the command's output.
  #
  # No `--ref`: `gh` targets the repository's default branch, which is the
  # branch the merge just landed on and the only branch this could mean.
  [ -n "$POST_MERGE_WORKFLOW" ] || return 0
  local dispatch_err dispatch_err_file
  dispatch_err_file="$(mktemp)"
  if run gh workflow run "$POST_MERGE_WORKFLOW" -R "$REPO" 2>"$dispatch_err_file"; then
    rm -f "$dispatch_err_file"
    log "#$n: dispatched $POST_MERGE_WORKFLOW after the merge"
  else
    # Loud and non-fatal (D3), and the asymmetry with the trigger job's
    # fail-the-job treatment is deliberate: that job's failure is a
    # PRE-condition alarm and this one is a POST-condition report. The merge
    # has already happened and cannot be undone by failing the pass, so one
    # log line naming the PR, the workflow and the reason is the whole
    # handling and the sweep continues to the next PR. read_failure_reason's
    # collapse-and-truncate is why a multi-line API error cannot forge
    # another PR's line.
    dispatch_err="$(cat "$dispatch_err_file")"
    rm -f "$dispatch_err_file"
    log "#$n: WARNING: post-merge dispatch of $POST_MERGE_WORKFLOW failed: $(read_failure_reason "$dispatch_err") — the merge stands"
  fi
}

reconcile_pr() { # $1 = PR number; relies on the globals set from its fetch
  local n="$1" desired remove s args last_activity last_activity_epoch age

  desired="$(decide_state)"

  # encode the runbook's last step for the no-judgment case: every required
  # verdict is a head-current approval → the human is asked, once. The guard
  # asks whether
  # a FRESH human review is needed for THIS head — never "has the human ever
  # reviewed", which wedged the handoff after any earlier human comment.
  # Idempotent (a live request suppresses it); race-free via the shared
  # concurrency group in labels.yml. With a comment-only bot on the panel
  # this path stays cold and the AUTHOR requests the human.
  #
  # Whether THIS pass made that request is recorded here and passed down, in
  # the shape reconcile_handoff_takeback's `$handoff_cleared` already uses
  # (#461 D7): it is knowable only here, and the alternative — asking again
  # further down — is the second read D2 forbids. `human_request_needed` is
  # therefore called exactly once per PR, and it stays the sole evaluation.
  local human_requested=false
  if [ "$desired" = state:needs-human ] && human_request_needed; then
    run gh api "repos/$REPO/pulls/$n/requested_reviewers" -f "reviewers[]=$HUMAN" --silent
    log "#$n: requested $HUMAN (round passed)"
    human_requested=true
  fi

  # ---- converge both axes ----
  # state:* is exclusive (everything but $desired comes off); blocker:* is a
  # set (each one on or off on its own); RETIRED always comes off. One edit
  # call for all of it, so a PR never flickers through a half-applied board.
  local want_blockers add=""
  want_blockers="$(blockers)"

  remove=""
  for s in "${STATES[@]}"; do
    if [ "$s" != "$desired" ] && has_label "$s"; then remove="$remove,$s"; fi
  done
  for s in "${RETIRED[@]}"; do
    if has_label "$s"; then remove="$remove,$s"; fi
  done
  # `rerun-owed` is cleared and never written (#423) — the one hand-set label
  # this machine takes off, because its subject is a head and a head moves. It
  # rides the same edit as everything else on purpose: the clear and the
  # blocker:ci-red that returns with it are one transition, and splitting them
  # across two calls would show the board a head with neither for a moment.
  # NOT a BLOCKERS entry, which would be the reverse contract: that array is
  # machine-owned and re-derived every pass, so the converge loop would strip a
  # live evidenced label on the next tick — the trap #51 and #180 name for
  # `needs-ruling` and `blocked`.
  # An `if`, not a `&&` one-liner: this runs under `set -e`, where a trailing
  # false test is a failed command and takes the whole PR's subshell with it.
  if [ "$(rerun_owed_state)" = CLEARED ]; then remove="$remove,rerun-owed"; fi
  for s in "${BLOCKERS[@]}"; do
    if grep -qxF "$s" <<<"$want_blockers"; then
      has_label "$s" || add="$add,$s"
    else
      has_label "$s" && remove="$remove,$s"
    fi
  done
  add="${add#,}"
  remove="${remove#,}"

  # Never NAME a label the repo does not have. `gh issue edit --add-label`
  # rejects the WHOLE call on one unknown name — nothing is applied — so a
  # single missing blocker would take the state convergence down with it, on
  # exactly the PRs this change exists to fix, surfacing only as a log line.
  # Batching state and blockers into one edit for anti-flicker is what widened
  # that blast radius; filtering the add side is what closes it again.
  # Removals need no filter: they are built from has_label, so the label
  # provably exists. REPO_LABELS unreadable means no filtering rather than
  # filtering everything out — a failed read must not silently strip the board.
  local skip_edit=false
  if [ -n "${REPO_LABELS:-}" ]; then
    local kept="" missing="" want
    for want in ${add//,/ }; do
      if grep -qxF "$want" <<<"$REPO_LABELS"; then kept="$kept,$want"
      else missing="$missing $want"; fi
    done
    add="${kept#,}"
    # A missing STATE label skips only the EDIT — never the rest of this
    # function. Everything below is independent of the state:* taxonomy, and
    # returning here stranded it: `merge-next` kept claiming "merge this one
    # next" on a PR the board had moved to the agent, and the stale sweep
    # stopped running. That is the original false-invitation bug, reintroduced
    # in the very fix meant to survive a cold-start repo — and a regression
    # against the old behaviour, which failed the edit and fell through.
    if ! grep -qxF "$desired" <<<"$REPO_LABELS"; then
      log "#$n: WARNING: state label '$desired' does not exist — skipping the label edit; dispatch the workflow to bootstrap"
      skip_edit=true
    elif [ -n "$missing" ]; then
      log "#$n: WARNING: missing label(s)$missing — state still converged; dispatch the workflow to bootstrap"
    fi
  fi

  # Whether THIS pass took a hand-set handoff back — the fact #377's comment
  # speaks for, and knowable only here: it needs the edit to have run, to have
  # succeeded, and to have carried `state:needs-human` on its removal side.
  # "The edit returned 0" is not the same claim and would still be true on a
  # pass that removed something else entirely.
  local handoff_cleared=false
  if [ "$skip_edit" = false ] && { ! has_label "$desired" || [ -n "$remove" ] || [ -n "$add" ]; }; then
    args=(--add-label "$desired${add:+,$add}")
    [ -n "$remove" ] && args+=(--remove-label "$remove")
    if run gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null; then
      log "#$n: state -> $desired${add:+ +$add}${remove:+ (cleared $remove)}"
      case ",$remove," in *,state:needs-human,*) handoff_cleared=true ;; esac
    else
      # a deleted label must not wedge the sweep — dispatch heals the taxonomy
      log "#$n: WARNING: label edit failed (missing label? run the workflow manually to bootstrap)"
    fi
  fi

  # ---- the release-shape guard (#130): a warning, never a write --------
  # Drafts are exempt (the build phase is the builder's); the version
  # reads cost two API calls and only on PRs missing the label.
  #
  # The gate is unchanged (#501 D5). What moved into locals is the two version
  # reads, so the notice below can assert the same facts the annotation just
  # printed without paying for them twice — and so the two can never disagree
  # about what this pass read. Both stay empty on the PRs the gate skips, which
  # is what keeps the draft exemption a property of this `if` and not of a test
  # repeated further down.
  local shape_head="" shape_base=""
  if [ "$DRAFT" != true ] && ! has_label release; then
    shape_head="$(tree_version "$HEAD_SHA")"
    shape_base="$(tree_version "$BASE_SHA")"
    release_shape_warning "$n" "$shape_head" "$shape_base"
  fi

  # ---- merge-next: cleared, never set ----------------------------------
  # Queue order is INTENT — which PR should land first is a judgement about
  # conflicts and dependencies that GitHub knows nothing about, so the
  # reconciler must not guess it (LABELS.md's rule for `blocked`/`release`).
  # What it CAN do is stop the label going stale the way needs-human did:
  # the moment the PR is no longer the thing a human should merge next, the
  # claim is removed. Setting it stays with whoever owns the queue.
  if has_label merge-next && [ "$desired" != state:needs-human ]; then
    run gh issue edit "$n" -R "$REPO" --remove-label merge-next >/dev/null
    log "#$n: cleared merge-next (state is $desired, not mergeable-by-a-human)"
  fi

  # ---- stale: real activity only, and blocked is legitimately quiet ----
  last_activity="$(
    {
      jq -r '.created_at' <<<"$PR_JSON"
      jq -r '.[].submitted_at' <<<"$REVIEWS_JSON"
      gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/commits" --jq '.[].commit.committer.date'
    } | sort | tail -n1
  )"
  last_activity_epoch="$(date -d "$last_activity" +%s)"
  age=$((NOW - last_activity_epoch))
  # needs-ruling joins blocked here: waiting on a human is legitimately quiet
  # (#50 D10). The 7-day nudge is #52's, once for both surfaces.
  if has_label blocked || has_label needs-ruling || [ "$age" -le "$STALE_AFTER" ]; then
    if has_label stale; then
      run gh issue edit "$n" -R "$REPO" --remove-label stale >/dev/null
      log "#$n: unstale"
    fi
  elif ! has_label stale; then
    run gh issue edit "$n" -R "$REPO" --add-label stale >/dev/null
    log "#$n: stale ($((age / 3600))h quiet)"
  fi

  # ---- say why a handoff was taken back (#377) -------------------------
  # Two constraints put it exactly here. After the converge edit, never inside
  # it: state and blockers ride ONE edit call so the board never half-applies,
  # and a comment between them would split exactly that. And after the
  # `last_activity` read, where reconcile_ruling's comments already sit: a
  # machine comment must not count as the PR's own activity in the pass that
  # posts it, or the sweep reads its own noise as a sign of life and holds
  # `stale` off. Bounded by the per-episode guard either way, but the sweep
  # should not have to be saved by a guard from believing itself.
  reconcile_handoff_takeback "$n" "$handoff_cleared"

  # ---- the human request this machine owns (#479) ----------------------
  # Here for the same two reasons, and one of its own. Both halves post a
  # comment, so both must sit after the `last_activity` read or the sweep would
  # read its own mark as the PR's sign of life and hold `stale` off. And the
  # withdrawal is a request-level act, not a label one, so it belongs after the
  # converge edit rather than inside it.
  #
  # The pass's OWN answers are what it is given — `$desired` and whether this
  # pass asked — never a second read: `human_request_needed` is evaluated
  # exactly once per PR (#460 D2), and a re-ask here could disagree with the
  # one that produced the request.
  reconcile_human_request "$n" "$desired" "$human_requested"

  # ---- the release-shape guard's other half: the notice (#501) ---------
  # HERE and not at the annotation's call site above, and the reason is the one
  # that already put reconcile_ruling's comments and the take-back's here: a
  # machine comment must not count as the PR's own activity in the pass that
  # posts it, or the sweep reads its own noise as a sign of life and holds
  # `stale` off. The annotation is exempt from that — it writes to a run log,
  # not to the thread — so its call site is the one place in this pair that did
  # not have to move, and D5 says it does not.
  #
  # The versions come from that gated read and are empty where it was skipped;
  # nothing re-reads them, so a draft still costs zero API calls here.
  reconcile_release_shape "$n" "$shape_head" "$shape_base"

  # ---- the ruling invariants (#52): the bare-flag check + the 7-day nudge --
  # The stale EXEMPTION above is #51's; these are the sweep halves that ride
  # the same real-activity computation (lib/ruling.sh, shared with the issue
  # side). Behind the flag check so flag-free PRs — all of them, almost
  # always — cost no extra API reads.
  if has_label needs-ruling; then
    reconcile_ruling "$n" "$last_activity_epoch" "$NOW"
  fi

  # `attention` belongs on the assigned issue that owns the claim, never on
  # a pull request (#232). Behind the label gate so ordinary PRs pay no read.
  if has_label attention; then
    reconcile_attention "$n" pr "$(jq '.assignees | length' <<<"$PR_JSON")" ""
  fi

  # ---- the merge, and nothing after it (#460 D1) -----------------------
  # LAST on purpose, and the ordering is the rule rather than a preference.
  # Everything above is what the board owes a PR that is still OPEN — the
  # converge edit, the release-shape warning and its notice, merge-next, stale,
  # the take-back comment, the ruling and attention halves — and all of it is cheap and
  # idempotent. This is the one irreversible act in the function, so it goes
  # after all of them: a write landing on a PR this call already closed is a
  # write into the void, and a take-back comment posting after the merge that
  # made it meaningless is worse than a write into the void.
  #
  # NOTHING MAY BE ADDED BELOW THIS LINE. A step appended here would run on a
  # closed PR on exactly the passes where the sweep did the most.
  reconcile_auto_merge "$n" "$desired" "$human_requested"
}

main() {
  validate_auto_merge || return $?
  validate_bootstrap || return $?
  REPO="${REPO:?set REPO to owner/name}"
  LABELS_CONF="${LABELS_CONF:-.github/labels.conf}"
  load_config "$LABELS_CONF"
  NOW="$(date +%s)"

  # The caller asks for the bootstrap, and the event that woke the sweep is
  # not the ask (#472). Every trigger-driven wake arrives as a
  # workflow_dispatch — that is how `gh workflow run` reaches the sweep
  # caller without a PAT — so an event-name gate could not tell the
  # operator's manual full-board bootstrap from a board event, and read
  # `yes` on roughly ten trigger-woken sweeps an hour while the step env
  # said `BOOTSTRAP: no`.
  if [ "$BOOTSTRAP" = yes ]; then
    log "bootstrap=yes: bootstrapping the taxonomy"
    bootstrap_labels
  fi

  # The repo's label set, read ONCE per sweep — reconcile_pr filters every
  # add against it, because one unknown name fails the whole edit call.
  REPO_LABELS="$(gh label list -R "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")"
  [ -z "$REPO_LABELS" ] && log "WARNING: could not read the label set — applying labels unfiltered"
  missing_core_labels_warning "$(core_label_rows)" "$REPO_LABELS"

  local n output status total=0 unreadable=0 sampled_reason="" read_failures
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    status=0
    output="$(
      (
      PR_JSON="$(gh api "repos/$REPO/pulls/$n")"
      DRAFT="$(jq -r '.draft' <<<"$PR_JSON")"
      AUTHOR="$(jq -r '.user.login' <<<"$PR_JSON")"
      set_required_bots "$AUTHOR"
      HEAD_SHA="$(jq -r '.head.sha' <<<"$PR_JSON")"
      BASE_SHA="$(jq -r '.base.sha' <<<"$PR_JSON")"
      LABELS="$(jq -r '.labels[].name' <<<"$PR_JSON")"
      REQUESTED="$(jq -r '.requested_reviewers[].login' <<<"$PR_JSON")"
      # PENDING reviews are unsubmitted drafts in someone's browser — not a verdict
      REVIEWS_JSON="$(gh api --paginate "repos/$REPO/pulls/$n/reviews" --jq '.[]' \
        | jq -s '[.[] | select(.state != "PENDING")]')"
      # mergeability + the check rollup, the two facts the state machine was
      # blind to (#136). `gh pr view` rather than the REST PR object: the API's
      # `mergeable` is a tri-state boolean that GitHub computes lazily, while
      # this returns the same MERGEABLE/CONFLICTING/UNKNOWN string the UI shows.
      # Failure to read them is NOT fatal and NOT treated as broken — an API
      # hiccup must never flap every PR into needs-rebase, so both degrade to
      # the "do not know" value that triggers nothing.
      # The WHY goes to gh's stderr, and 2>/dev/null threw it away — a
      # permanent denial and a network hiccup left byte-identical evidence,
      # and #95 had to infer a cause from a control case instead of reading
      # it off a run (wrongly, it turned out). Captured into a file (#101
      # D2), never left to interleave raw into the per-PR output block,
      # where an unlucky line could collide with a matched string.
      GH_VIEW_ERR_FILE="$(mktemp)"
      GH_VIEW="$(gh pr view "$n" -R "$REPO" --json mergeable,statusCheckRollup 2>"$GH_VIEW_ERR_FILE" || echo '{}')"
      GH_VIEW_ERR="$(cat "$GH_VIEW_ERR_FILE")"
      rm -f "$GH_VIEW_ERR_FILE"
      MERGEABLE="$(jq -r '.mergeable // "UNKNOWN"' <<<"$GH_VIEW")"
      CHECKS="$(checks_state <<<"$GH_VIEW")"
      # Read failed: leave this PR exactly as it is. Recomputing on facts we
      # did not read is how an API hiccup turns into a false "merge me" —
      # and the next tick is 15 minutes away, not 15 hours.
      if [ "$CHECKS" = UNREADABLE ]; then
        # Two lines on purpose (#101 D1): the sweep detects a wholly blind
        # pass by whole-line-matching the counted line below, so the reason
        # rides its OWN line — folding it in would silently break the
        # `unreadable` counter and the wholly-blind warning #96 landed.
        log "#$n: could not read mergeability/checks — left alone this pass"
        log "#$n: read failed: $(read_failure_reason "$GH_VIEW_ERR")"
        exit 0
      fi
      # The head's own clock, for the blocker:unrequested grace (#236 D2). One
      # read, pinned to the head SHA — not `gh pr view --json commits`, which
      # asks for the FIRST hundred commits and would date a longer PR by a
      # commit that is not its head. Last of the fetches on purpose: a PR the
      # skip above walked away from must not pay for it, and neither do drafts,
      # which never reach that blocker. Empty (a failed read, or a body without
      # the field) leaves the blocker unjudged, by unrequested_quiescent.
      HEAD_COMMIT_AT=""
      if [ "$DRAFT" != true ]; then
        HEAD_COMMIT_ERR_FILE="$(mktemp)"
        HEAD_COMMIT_AT="$(gh api "repos/$REPO/commits/$HEAD_SHA" \
          --jq '.commit.committer.date' 2>"$HEAD_COMMIT_ERR_FILE" || echo "")"
        HEAD_COMMIT_ERR="$(cat "$HEAD_COMMIT_ERR_FILE")"
        rm -f "$HEAD_COMMIT_ERR_FILE"
        case "$HEAD_COMMIT_AT" in
          "" | null)
            # Say why it degraded (#101 D2/D4), on its own line: this one
            # narrows a blocker rather than skipping the PR, so it must not
            # read as the wholly-blind shape the counted line above matches.
            HEAD_COMMIT_AT=""
            log "#$n: could not read the head commit's date: $(read_failure_reason "$HEAD_COMMIT_ERR") — blocker:unrequested not judged this pass" ;;
        esac
      fi
      # The head `rerun-owed`'s evidence names (#423). Behind the label, so an
      # ordinary PR pays nothing for it, and behind the AUTHOR too: the label is
      # the builder's to set with its evidence, so a marker quoted back by a
      # reviewer is a quotation and not a second flag. Read whole, then filtered
      # — the shape lib/attention.sh uses — so an unreadable list and a label
      # nobody evidenced are told apart by the read's own status and not by
      # whether a pipeline happened to be running under `pipefail`.
      RERUN_OWED_HEAD=""
      if has_label rerun-owed; then
        if ! RERUN_OWED_EVIDENCE="$(RERUN_OWED_AUTHOR="$AUTHOR" gh api --paginate \
          "repos/$REPO/issues/$n/comments" \
          --jq '.[] | select(.user.login == env.RERUN_OWED_AUTHOR)
                | .body | split("\n")[0] | sub("\r$"; "")' 2>/dev/null)"; then
          log "#$n: rerun-owed evidence unreadable — its moved-head test not judged this pass"
        else
          RERUN_OWED_HEAD="$(rerun_owed_named_head <<<"$RERUN_OWED_EVIDENCE")"
          # Told apart from the failed read on purpose: a label whose evidence
          # names no head is a builder to talk to, a list that would not read is
          # an API to look at. Both leave the label standing.
          [ -n "$RERUN_OWED_HEAD" ] ||
            log "#$n: rerun-owed evidence names no head — its moved-head test not judged this pass"
        fi
      fi
      # Whose request is standing, when one is (#479). Behind `requested`, so a
      # PR the human is not requested on pays nothing — the mark answers one
      # question, and with no request standing there is nothing to ask about.
      # Deliberately NOT behind a label or a state: the request outlives every
      # state the PR passes through, which is the whole defect.
      HUMAN_REQUEST_MARK=NONE
      if requested "$HUMAN"; then
        # Read whole, then parsed — the shape lib/attention.sh uses — so an
        # unreadable list and a request nobody marked are told apart by the
        # read's own status. Both leave the request standing as a maintainer's.
        if ! HUMAN_REQUEST_MARKS="$(gh api --paginate \
          "repos/$REPO/issues/$n/comments" \
          --jq '.[] | .body | split("\n")[0] | sub("\r$"; "")' 2>/dev/null)"; then
          log "#$n: human-request marks unreadable — the standing $HUMAN request read as a maintainer's this pass"
        else
          HUMAN_REQUEST_MARK="$(human_request_mark <<<"$HUMAN_REQUEST_MARKS")"
        fi
      fi
      reconcile_pr "$n"
      ) 2>&1
    )" || status=$?
    [ -n "$output" ] && printf '%s\n' "$output"
    if grep -qxF "labels: #$n: could not read mergeability/checks — left alone this pass" <<<"$output"; then
      unreadable=$((unreadable + 1))
      # the first observed reason stands in for the sweep in the blind warning
      if [ -z "$sampled_reason" ]; then
        # No second pipe, and NOT because this site can race today (#411
        # D10): what a second pipe into `head -n1` would carry here is not
        # $output but sed's matched subset, bounded twice over — exactly
        # one `read failed:` emitter exists per PR (:1138, whose branch
        # `exit 0`s on the next line), and read_failure_reason collapses
        # newlines and truncates at 300 characters. ~300 bytes fills no
        # pipe of any capacity, so `head -n1` would never take EPIPE and
        # `pipefail` would never kill the substitution.
        # It is converted anyway, for D2's reason: "bounded" is a property
        # of today's callers that no future reader of this line can check,
        # and the collision hazard named at :1121 — an unlucky raw stderr
        # line matching the counted prefix — is precisely the future in
        # which this writer stops being bounded. sed's writer is a command
        # and takes no herestring, so capture it whole and cut the first
        # line in the shell (#364, #411 D1's instruction, D10's grading).
        read_failures="$(sed -n "s/^labels: #$n: read failed: //p" <<<"$output")"
        sampled_reason="${read_failures%%$'\n'*}"
      fi
    elif [ "$status" -ne 0 ]; then
      log "#$n: reconcile failed — continuing with the remaining PRs"
    fi
  done < <(gh pr list -R "$REPO" --state open --limit 100 --json number --jq '.[].number')
  blind_sweep_warning "$unreadable" "$total" "$sampled_reason"
  log "reconciled."
}

# sourced by test/labels-reconcile.sh for the fixture tests; executed in CI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
