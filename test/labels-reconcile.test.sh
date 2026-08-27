#!/usr/bin/env bash
set -euo pipefail
# Byte-wise collation, matching CI: the probes sort ISO timestamps, and the
# verdict must not flip with the runner's ambient locale.
export LC_ALL=C

# Fixture tests for the labels-reconcile state machine: a comment is a
# non-verdict whatever its body says (the AUTHOR escalates by requesting the
# human), a stale approval does not promote unreviewed code, and an explicit
# human request outranks everything.
# Dependency-free beyond jq; no network, no daemon — pure decide_state.

cd "$(dirname "$0")/.."
# shellcheck source=actions/labels-reconcile/labels-reconcile.sh
unset AUTO_MERGE
unset AUTO_MERGE_RELEASE
unset POST_MERGE_WORKFLOW
unset RELEASE_WORKFLOW
. actions/labels-reconcile/labels-reconcile.sh
SCRIPT_AUTO_MERGE_DEFAULT="${AUTO_MERGE-<unset>}"
SCRIPT_AUTO_MERGE_RELEASE_DEFAULT="${AUTO_MERGE_RELEASE-<unset>}"
# Captured the same way and for the same reason: the sourced defaults are what
# a direct-script caller gets, and `<unset>` here would mean the script left
# the variable undefined and `set -u` would abort the sweep at the first read.
SCRIPT_POST_MERGE_DEFAULT="${POST_MERGE_WORKFLOW-<unset>}"
SCRIPT_RELEASE_WORKFLOW_DEFAULT="${RELEASE_WORKFLOW-<unset>}"

RTMP="$(mktemp -d)"
trap 'rm -rf "$RTMP"' EXIT

# The fixture roster is the test's own, and deliberately not the shipped one
# (#304). The state machine is roster-agnostic — it needs three distinct
# required logins, not THESE three — so binding the fixtures to
# .github/labels.conf by slot bought nothing and cost the file: when the
# operator shrank panel= from four members to three, the recused author left
# two, the third slot came up unbound, and set -u aborted this file before
# its first assertion. 217 assertions became 0, on main and on every branch cut
# from it, and no fixture here was about the panel's size. The shape below is
# test/labels.test.sh's, which has always written its own conf.
FIXTURE_CONF="$RTMP/fixture-labels.conf"
FIXTURE_AUTHOR=fixture-builder
# The DRAFT/HEAD_SHA/REQUESTED/REVIEWS_JSON assignments below are the state
# machine's inputs, consumed inside the sourced decide_state — not unused.
# shellcheck disable=SC2034
BOT1=fixture-bot-one BOT2=fixture-bot-two BOT3=fixture-bot-three
printf 'panel=%s %s %s %s\n' "$BOT1" "$BOT2" "$BOT3" "$FIXTURE_AUTHOR" \
  >"$FIXTURE_CONF"
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
pass=0 fail=0

expect() { # $1 = description, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
  fi
}

# ---------------------------------------------------------------------------
# The inert auto-merge reader (#459). The fleet is the union already encoded
# in labels.conf, and the verdict consumes decide_state's result rather than
# trusting the hand-set label that the same pass is about to validate.
# ---------------------------------------------------------------------------
expect "the direct script defaults auto_merge to off when unset" off \
  "$SCRIPT_AUTO_MERGE_DEFAULT"
expect "the reusable workflow defaults auto_merge to off" 1 \
  "$(awk '/^      auto_merge:/{seen=1} seen && /default: "off"/{print 1; exit}' \
    .github/workflows/labels-sweep.yml)"
expect "the composite action defaults auto_merge to off" 1 \
  "$(awk '/^  auto_merge:/{seen=1} seen && /default: "off"/{print 1; exit}' \
    actions/labels-reconcile/action.yml)"
expect "the direct script defaults auto_merge_release to off when unset" off \
  "$SCRIPT_AUTO_MERGE_RELEASE_DEFAULT"
expect "the reusable workflow defaults auto_merge_release to off" 1 \
  "$(awk '/^      auto_merge_release:/{seen=1} seen && /default: "off"/{print 1; exit}' \
    .github/workflows/labels-sweep.yml)"
expect "the composite action defaults auto_merge_release to off" 1 \
  "$(awk '/^  auto_merge_release:/{seen=1} seen && /default: "off"/{print 1; exit}' \
    actions/labels-reconcile/action.yml)"

# ---------------------------------------------------------------------------
# The post-merge dispatch's default (#461 D1). Empty at all three boundaries,
# which is what makes the whole input inert for every consumer that does not
# set it — and empty means dispatch NOTHING, never a guessed default name like
# "ci": a sweep that woke a workflow nobody configured would be the hourly
# noise this input exists to avoid.
# ---------------------------------------------------------------------------
expect "the direct script defaults post_merge_workflow to empty when unset" "" \
  "$SCRIPT_POST_MERGE_DEFAULT"
expect "the reusable workflow defaults post_merge_workflow to empty" 1 \
  "$(awk '/^      post_merge_workflow:/{seen=1} seen && /default: ""/{print 1; exit}' \
    .github/workflows/labels-sweep.yml)"
expect "the composite action defaults post_merge_workflow to empty" 1 \
  "$(awk '/^  post_merge_workflow:/{seen=1} seen && /default: ""/{print 1; exit}' \
    actions/labels-reconcile/action.yml)"
expect "the direct script defaults release_workflow to empty when unset" "" \
  "$SCRIPT_RELEASE_WORKFLOW_DEFAULT"
expect "the reusable workflow defaults release_workflow to empty" 1 \
  "$(awk '/^      release_workflow:/{seen=1} seen && /default: ""/{print 1; exit}' \
    .github/workflows/labels-sweep.yml)"
expect "the composite action defaults release_workflow to empty" 1 \
  "$(awk '/^  release_workflow:/{seen=1} seen && /default: ""/{print 1; exit}' \
    actions/labels-reconcile/action.yml)"
release_desc="$(awk '/^      release_workflow:/{seen=1; next}
                      seen && /^        type:/{exit} seen{print}' \
  .github/workflows/labels-sweep.yml)"
expect "the release input description names merged-sha" yes \
  "$(grep -q 'merged-sha' <<<"$release_desc" && echo yes || echo no)"
expect "...the actions: write the caller needs" yes \
  "$(grep -q 'actions:' <<<"$release_desc" && grep -q 'write' <<<"$release_desc" && echo yes || echo no)"
expect "...and that empty prevents release auto-merges" yes \
  "$(grep -q 'Empty means release pull requests are never auto-merged' <<<"$release_desc" && echo yes || echo no)"

# D14 — both reusable action sites carry the whole input family. Counting
# each literal twice makes deleting any one line from either block red.
# `bootstrap` joins it at #472, and is the one member whose silent default
# means NEVER BOOTSTRAP, EVER — the operator's manual full-board dispatch
# included, since after #472 that dispatch is the only thing that upserts the
# taxonomy. Deleting the line is legal YAML and invisible to actionlint.
for pass_input in bootstrap auto_merge post_merge_workflow auto_merge_release release_workflow; do
  expect "both reusable with blocks pass $pass_input" 2 \
    "$(grep -c "^          $pass_input:.*inputs.$pass_input" .github/workflows/labels-sweep.yml)"
done
# The action's description carries the three facts a consumer needs; the
# reusable workflow's carries them in full. Asserted on the reusable, which is
# the surface a consumer reads.
pmw_desc="$(awk '/^      post_merge_workflow:/{seen=1; next}
                 seen && /^        type:/{exit} seen{print}' \
  .github/workflows/labels-sweep.yml)"
expect "the input description names the workflow_dispatch requirement" yes \
  "$(grep -q 'must declare workflow_dispatch' <<<"$pmw_desc" && echo yes || echo no)"
expect "...the actions: write the caller needs" yes \
  "$(grep -q 'actions: write' <<<"$pmw_desc" && echo yes || echo no)"
expect "...and that a hand merge is unaffected" yes \
  "$(grep -q 'never on a hand merge' <<<"$pmw_desc" && echo yes || echo no)"
# D4 — no validation of the name at the action boundary, unlike auto_merge,
# whose accepted set is closed. Three questions gh answers by failing.
expect "the action adds no post_merge_workflow validation step" no \
  "$(grep -q 'validate post_merge_workflow' actions/labels-reconcile/action.yml \
    && echo yes || echo no)"
expect "...and plumbs it to the script as POST_MERGE_WORKFLOW" yes \
  "$(awk '/POST_MERGE_WORKFLOW:/ && /inputs.post_merge_workflow/{print "yes"; exit}' \
    actions/labels-reconcile/action.yml)"
# D5 — this arc opts nobody in, here least of all: no workflow file in this
# repository GAINS a trigger, `ci.yml` above all. The whole trigger map is
# pinned rather than `workflow_dispatch` merely being grepped for, because two
# files legitimately carry it already (`release-exercise.yml`,
# `self-labels-sweep.yml`) and an absence assertion would be false on `main`.
# Pinning the map is also the stronger claim: a file gaining ANY trigger reds,
# and so does a file losing one.
#
# The keys are read from under `on:` only, which is what makes this assertion
# survive the input D1 adds — that input lives under `on: workflow_call:
# inputs:`, two levels deeper than the trigger keys this reads. The
# criterion's parenthetical asks for no change to any `on:` BLOCK, which D1
# makes literally unmeetable; this is that criterion's substance, and the
# divergence is called out in the PR body rather than shipped silently.
workflow_trigger_map() {
  local wf
  for wf in .github/workflows/*.yml; do
    printf '%s:' "${wf##*/}"
    awk '/^on:/{inside=1; next}
         inside && /^[^ ]/{exit}
         inside && /^  [a-z_]+:/{sub(/:.*/, ""); sub(/^  /, ""); printf " %s", $0}' "$wf"
    printf '\n'
  done
}
expect "no workflow file in this repository gained or lost a trigger" \
  "ci-rerun.yml: workflow_call
ci.yml: pull_request push
labels-sweep.yml: workflow_call
labels.yml: workflow_call
refs-guard.yml: pull_request
release-exercise.yml: workflow_dispatch workflow_call
release.yml: workflow_call
self-ci-rerun.yml: pull_request_target
self-labels-sweep.yml: schedule workflow_dispatch
self-labels.yml: issues pull_request_target
self-release.yml: push" \
  "$(workflow_trigger_map)"

AUTO_MERGE=sometimes validation_rc=0
validation_output="$(validate_auto_merge 2>&1)" || validation_rc=$?
expect "the direct-script validator rejects an unknown mode with rc 2" 2 \
  "$validation_rc"
expect "the direct-script validator names the input and accepted set" \
  "auto_merge must be one of: off, merge, squash, rebase" "$validation_output"
empty_validation_rc=0
empty_validation_output="$(AUTO_MERGE='' bash actions/labels-reconcile/labels-reconcile.sh 2>&1)" \
  || empty_validation_rc=$?
expect "the direct-script boundary rejects an explicitly empty mode with rc 2" 2 \
  "$empty_validation_rc"
expect "the direct-script empty-mode diagnostic names the accepted set" \
  "$validation_output" "$empty_validation_output"
action_validation_body="$(awk '
  /- name: validate auto_merge input/ { found=1 }
  found && /^      run: \|/ { body=1; next }
  body && /^    - name:/ { exit }
  body { sub(/^        /, ""); print }
' actions/labels-reconcile/action.yml)"
action_validation_rc=0
action_validation_output="$(AUTO_MERGE=sometimes bash -c "$action_validation_body" 2>&1)" \
  || action_validation_rc=$?
expect "the action-boundary validator rejects an unknown mode with rc 2" 2 \
  "$action_validation_rc"
expect "the action-boundary validator uses the direct script's diagnostic" \
  "$validation_output" "$action_validation_output"

load_config .github/labels.conf
for fleet_login in \
  claude-bot-andresmgsl codex-bot-andresmgsl kimi-bot-andresmgsl \
  cndgrr andriujoseba dan-claude-bot; do
  expect "the shipped fleet admits $fleet_login" fleet \
    "$(is_fleet_login "$fleet_login" && echo fleet || echo outside)"
done
for outside_login in danmt "" cndgr dan-claude; do
  expect "the shipped fleet refuses ${outside_login:-an empty login}" outside \
    "$(is_fleet_login "$outside_login" && echo fleet || echo outside)"
done

ROW_REVIEWER_CONF="$RTMP/row-reviewer.conf"
printf '%s\n' \
  'panel=base-reviewer' \
  'panel[row-author]=row-only-reviewer' \
  >"$ROW_REVIEWER_CONF"
load_config "$ROW_REVIEWER_CONF"
expect "a per-author panel row reviewer is fleet" fleet \
  "$(is_fleet_login row-only-reviewer && echo fleet || echo outside)"

MALFORMED_FLEET_CONF="$RTMP/malformed-fleet.conf"
printf '%s\n' \
  'panel=fixture-reviewer' \
  'triage-actors=ok-bot bad!login' \
  >"$MALFORMED_FLEET_CONF"
load_config "$MALFORMED_FLEET_CONF" 2>"$RTMP/malformed-fleet.warning"
malformed_fleet_warning="$(cat "$RTMP/malformed-fleet.warning")"
expect "a malformed triage actor does not fail config loading" fleet \
  "$(is_fleet_login ok-bot && echo fleet || echo outside)"
expect "a malformed triage actor is skipped" outside \
  "$(is_fleet_login 'bad!login' && echo fleet || echo outside)"
expect "the malformed triage actor warning names its config file" yes \
  "$(grep -qF "$MALFORMED_FLEET_CONF" <<<"$malformed_fleet_warning" && echo yes || echo no)"

AUTO_MERGE=merge AUTO_MERGE_RELEASE=off RELEASE_WORKFLOW="" AUTHOR=fixture-reviewer LABELS="" MERGEABLE=MERGEABLE
expect "an eligible fleet PR returns MERGE" MERGE \
  "$(auto_merge_verdict state:needs-human)"
AUTO_MERGE=off
expect "off is the first refusal" SKIP:off \
  "$(auto_merge_verdict state:addressing)"
AUTO_MERGE=merge
expect "a non-handoff pass verdict is refused" SKIP:state \
  "$(auto_merge_verdict state:addressing)"
LABELS=release AUTO_MERGE_RELEASE=merge RELEASE_WORKFLOW=""
expect "the state refusal precedes the missing-release-dispatch refusal" SKIP:state \
  "$(auto_merge_verdict state:addressing)"
LABELS=$'state:needs-human\nrelease'
expect "a release PR with no dispatch is refused" SKIP:no-release-dispatch \
  "$(auto_merge_verdict state:needs-human)"
RELEASE_WORKFLOW=release.yml
expect "a configured release PR is eligible" MERGE \
  "$(auto_merge_verdict state:needs-human)"
LABELS="" AUTHOR=outside-author
expect "a non-fleet author is refused" SKIP:author \
  "$(auto_merge_verdict state:needs-human)"
AUTHOR=fixture-reviewer MERGEABLE=UNKNOWN
expect "unknown mergeability is refused" SKIP:mergeable \
  "$(auto_merge_verdict state:needs-human)"
LABELS=state:needs-human MERGEABLE=MERGEABLE
expect "the pass verdict outranks a standing needs-human label" SKIP:state \
  "$(auto_merge_verdict state:addressing)"

# Restore the fixture roster and common defaults for the pre-existing state
# machine assertions below.
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
AUTO_MERGE=off AUTO_MERGE_RELEASE=off RELEASE_WORKFLOW="" AUTHOR="$FIXTURE_AUTHOR" LABELS="" MERGEABLE=MERGEABLE

rev() { # $1=login $2=state $3=commit $4=body $5=submitted_at → one review object
  jq -n --arg u "$1" --arg s "$2" --arg c "$3" --arg b "$4" --arg t "$5" \
    '{user: {login: $u}, state: $s, commit_id: $c, body: $b, submitted_at: $t}'
}

reviews() { jq -s '.' <<<"$*"; } # collect review objects into an array

# The blocker:unrequested quiescence inputs (#236 D2). Every fixture below
# inherits a readable, settled world — a head commit an hour before this
# sweep's clock — so the cases written before #236 assert exactly what they
# always asserted. The #236 block sets both per case.
#
# One consequence a new fixture has to know: a case that means to raise
# blocker:unrequested needs a REAL submitted_at on its reviews, because the
# grace dates the round's newest review. The symbolic stamps this file uses
# elsewhere (`t1`, `t2`, …) are not unreadable — GNU date reads `t1` as 01:00
# in military timezone T, i.e. a time on WHATEVER day the suite runs — which is
# worse: the verdict would flip with the calendar, the hazard the LC_ALL pin at
# the top of this file guards on the other axis. Hence a fixed NOW here and
# real timestamps on the three stall fixtures below.
NOW="$(date -d 2026-08-03T12:00:00Z +%s)"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z

# -- a sweep-wide read failure is visible without changing any PR ------------
warning="$(blind_sweep_warning 3 3 "HTTP 403: Resource not accessible by integration")"
expect "a wholly blind sweep warns, leading with the observed reason" \
  "::warning::labels: every open PR was unreadable; sampled reason: HTTP 403: Resource not accessible by integration — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)" \
  "$warning"
expect "the blind warning names checks: read" named \
  "$(grep -qF "checks: read" <<<"$warning" && echo named || echo missing)"
expect "the blind warning names statuses: read" named \
  "$(grep -qF "statuses: read" <<<"$warning" && echo named || echo missing)"
# must-fail (#101 D5): the #95 inference — disproven on incubator while the
# run held the evidence — must never again be stated as the cause
expect "the warning no longer asserts the permissions diagnosis as fact" no \
  "$(grep -qF "grant checks: read and statuses: read" <<<"$warning" && echo yes || echo no)"
warning="$(blind_sweep_warning 3 3 "")"
expect "with no reason captured the warning says exactly that" yes \
  "$(grep -qF "no reason was captured" <<<"$warning" && echo yes || echo no)"
expect "...and keeps the permissions candidate" named \
  "$(grep -qF "checks: read" <<<"$warning" && echo named || echo missing)"
expect "a partially blind sweep does not warn" "" "$(blind_sweep_warning 1 3 "x")"
expect "a sweep with no open PRs does not warn" "" "$(blind_sweep_warning 0 0 "")"

# -- the reason helper: facts in, one bounded line out (#101 D3/D4) ----------
expect "empty stderr is reported as its own fact" "no error output" \
  "$(read_failure_reason "")"
expect "multi-line stderr collapses to one line" \
  "GraphQL: Resource not accessible by integration (repository.pullRequest.mergeable) Resource not accessible by integration (repository.pullRequest.statusCheckRollup)" \
  "$(read_failure_reason $'GraphQL: Resource not accessible by integration (repository.pullRequest.mergeable)\nResource not accessible by integration (repository.pullRequest.statusCheckRollup)')"
long_reason="$(printf 'e%.0s' {1..400})"
short_reason="$(read_failure_reason "$long_reason")"
expect "400 chars of stderr truncate to 300 plus an ellipsis, one line" \
  "$(printf 'e%.0s' {1..300})…" "$short_reason"
expect "...within the 304-byte bound" yes \
  "$([ "${#short_reason}" -le 304 ] && echo yes || echo no)"
exact_reason="$(read_failure_reason "$(printf 'e%.0s' {1..300})")"
expect "a 300-char reason passes through whole" 300 "${#exact_reason}"

# -- a missing core taxonomy row is visible without mutating labels ----------
core_rows="$(core_label_rows)"
core_names="$(cut -d'|' -f1 <<<"$core_rows")"
expect "post-merge core row is byte-exact" \
  "post-merge|006B75|Refs-linked PR merged; post-merge criteria remain and triage owns completion" \
  "$(grep '^post-merge|' <<<"$core_rows")"
expect "operator core row is byte-exact" \
  "operator|A371F7|Operator-owned; the body names the evidence surface, the command, and the wake condition" \
  "$(grep '^operator|' <<<"$core_rows")"
ready_core="$(grep '^ready|' <<<"$core_rows" | cut -d'|' -f3-)"
# shellcheck disable=SC2016 # backticks are LABELS.md literals
ready_doctrine="$(sed -n 's/^| `ready` | `#0E8A16` | \(.*\) | triage |$/\1/p' LABELS.md)"
expect "ready doctrine and registry glosses agree byte-for-byte" \
  "$ready_doctrine" "$ready_core"
expect "the owner-neutral ready gloss never says builder" no \
  "$(grep -qi builder <<<"$ready_core" && echo yes || echo no)"
expect "operator is absent from the consumer registry" no \
  "$(grep -q '^operator|' .github/labels.conf && echo yes || echo no)"
expect "a complete core taxonomy does not warn" "" \
  "$(missing_core_labels_warning "$core_rows" "$core_names")"
expect "one missing core label is named exactly" \
  "::warning::labels: missing core label(s): attention; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy" \
  "$(missing_core_labels_warning "$core_rows" "$(grep -vxF attention <<<"$core_names")")"
expect "three missing core labels are named in table order" \
  "::warning::labels: missing core label(s): offsite, needs-ruling, attention; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy" \
  "$(missing_core_labels_warning "$core_rows" "$(grep -vxF -e offsite -e needs-ruling -e attention <<<"$core_names")")"
expect "an unreadable empty label set does not report the taxonomy missing" "" \
  "$(missing_core_labels_warning "$core_rows" "")"
expect "unrelated scope labels do not affect a complete core taxonomy" "" \
  "$(missing_core_labels_warning "$core_rows" "$core_names
scope:consumer-one
scope:consumer-two")"

# -- the release-shape guard warns, never writes (#130; the #128 incident) ----
# The caller gates on NOT has_label release and NOT draft; these fix the
# version matrix. The warning is one line per call — reconcile_pr runs once
# per PR per sweep, so "exactly one warning per sweep" is by construction.
shape_warning="$(release_shape_warning 41 2.0.0 2.0.0-dev)"
expect "bare head over a -dev base warns" yes \
  "$(grep -qF '::warning::' <<<"$shape_warning" && echo yes || echo no)"
expect "...naming the PR and both versions" yes \
  "$(grep -qF '#41 is release-shaped (version 2.0.0-dev -> 2.0.0' <<<"$shape_warning" && echo yes || echo no)"
expect "...and pointing at the release label, not setting it" yes \
  "$(grep -qF 'apply release' <<<"$shape_warning" && echo yes || echo no)"
expect "an ordinary -dev head is silent" "" \
  "$(release_shape_warning 41 2.0.1-dev 2.0.0-dev)"
expect "a bare head equal to the base is silent" "" \
  "$(release_shape_warning 41 2.0.0 2.0.0)"
expect "an rc head is silent — pre-releases are not the merge door's shape" "" \
  "$(release_shape_warning 41 2.0.0-rc1 2.0.0-dev)"
expect "an unreadable head version is silent — never nag on a guess" "" \
  "$(release_shape_warning 41 "" 2.0.0-dev)"
expect "a bare head over an unreadable base still warns" yes \
  "$(release_shape_warning 41 2.0.0 "" | grep -qF '::warning::' && echo yes || echo no)"

# -- drafts are building, whoever is requested --------------------------------
DRAFT=true HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON='[]'
expect "draft PR is building" state:building "$(decide_state)"

# -- fresh ready PR with bots requested ---------------------------------------
DRAFT=false REQUESTED="$BOT1
$BOT2
$BOT3" REVIEWS_JSON='[]'
expect "requested bots mean bots-reviewing" state:bots-reviewing "$(decide_state)"

# -- a bot that never reviewed keeps the round open ---------------------------
#    With a live request that is the bots' ball; with NO request outstanding it
#    is the agent's, because nothing is coming until somebody asks.
REQUESTED="$BOT3" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED head1 "" 2026-08-03T10:01:00Z)")"
expect "a missing bot WITH a live request is bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""
expect "...but with nobody asked it is the agent's ball" state:addressing "$(decide_state)"
expect "...and the blocker names the stall" blocker:unrequested "$(blockers)"

# -- a comment is a non-verdict, agreement body or not: the author escalates --
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "✅ **Reviewed — I agree with everything.**" t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment-only agreement still parks on the author" state:addressing "$(decide_state)"
# ...and the author's escalation — requesting the human — flips it
REQUESTED="$HUMAN"
expect "author escalation flips to needs-human" state:needs-human "$(decide_state)"
REQUESTED=""

# -- three formal approvals need no author judgment ---------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "three formal approvals reach needs-human" state:needs-human "$(decide_state)"

# -- a comment WITHOUT a verdict parks the PR on the agent --------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "🔧 Reviewed — I agree with most; feedback below." t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment without verdict is addressing" state:addressing "$(decide_state)"

# -- changes requested blocks, at any head ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED old1 "blockers below" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "changes-requested blocks even from an old head" state:addressing "$(decide_state)"

# -- a stale approval must not promote unreviewed code ------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED old1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale approval is addressing (agent owes re-request)" state:addressing "$(decide_state)"

# -- a re-requested bot reopens the round even with an old approval on file ---
REQUESTED="$BOT1"
expect "re-requested bot means bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""

# -- only the LATEST review per bot counts ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 "blockers" t1)" \
  "$(rev "$BOT1" APPROVED head1 "" t2)" \
  "$(rev "$BOT2" APPROVED head1 "" t3)" \
  "$(rev "$BOT3" APPROVED head1 "" t4)")"
expect "later approval supersedes earlier block" state:needs-human "$(decide_state)"

# -- an explicit human request outranks the bot rounds ------------------------
REQUESTED="$HUMAN" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "feedback, no verdict" t1)")"
expect "human requested outranks bots" state:needs-human "$(decide_state)"
REQUESTED=""

# -- human CHANGES_REQUESTED puts the ball back on the agent ------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)" \
  "$(rev "$HUMAN" CHANGES_REQUESTED head1 "not yet" t4)")"
expect "human block with bots approving is addressing" state:addressing "$(decide_state)"
# ...and re-requesting the human hands it back to them
REQUESTED="$HUMAN"
expect "re-requested human is needs-human again" state:needs-human "$(decide_state)"
REQUESTED=""

# -- an old human comment must not wedge the handoff (codex, #85 round 3) -----
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" COMMENTED old1 "early thoughts" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "old human comment + three approvals is needs-human" state:needs-human "$(decide_state)"
expect "old human comment still needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a stale human APPROVAL likewise needs a re-request for the new head
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED old1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale human approval needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a HEAD-CURRENT human approval needs nothing more
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED head1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "head-current human approval needs no request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
# ...and a live request suppresses re-requesting
REQUESTED="$HUMAN"
expect "live human request suppresses re-request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
REQUESTED=""

# ---------------------------------------------------------------------------
# #136: state:needs-human must mean "a human could merge this RIGHT NOW".
# Both cases below were observed live in this repo on 2026-07-20, and both
# showed state:needs-human while being unmergeable in different ways.
# ---------------------------------------------------------------------------
ALL_APPROVE="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"

# -- flavour 1: not mergeable. The merge button is disabled, yet the board
#    said "your turn" on #119/#120/#127 for hours. The branch fact now rides
#    the blocker axis; the state says whose ball it is, which is the agent's.
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=CONFLICTING CHECKS=SUCCESS
expect "a CONFLICTING PR is the agent's, not the human's" state:addressing "$(decide_state)"
expect "...and says WHY on the blocker axis" blocker:conflict "$(blockers)"
REQUESTED="$HUMAN"
expect "...even with the human explicitly requested" state:addressing "$(decide_state)"

# -- red CI is the same claim, but NOT the same work: a rebase does not fix a
#    failing test. Collapsing both into one needs-rebase label told the agent
#    to do the wrong thing, which is why the axis split exists.
REQUESTED="" MERGEABLE=MERGEABLE CHECKS=FAILURE
expect "a red PR is the agent's" state:addressing "$(decide_state)"
expect "...and is distinguishable from a conflict" blocker:ci-red "$(blockers)"
REQUESTED="$HUMAN"
expect "...and a human request does not override red CI" state:addressing "$(decide_state)"

# -- both at once. The single-axis design could not say this at all: one label
#    had to win, and the loser silently vanished off the board.
REQUESTED="" MERGEABLE=CONFLICTING CHECKS=FAILURE
expect "a conflicted AND red PR reports both blockers" "blocker:conflict
blocker:ci-red" "$(blockers)"
expect "...and is still just the agent's ball" state:addressing "$(decide_state)"

# -- UNKNOWN is NOT unmergeable. GitHub reports it for ~a minute after every
#    merge while it recomputes; treating it as broken would flap every open PR
#    on each merge — worse than the bug being fixed.
REQUESTED="" MERGEABLE=UNKNOWN CHECKS=PENDING
expect "UNKNOWN mergeability blocks nothing" state:needs-human "$(decide_state)"
expect "...and raises no blocker" "" "$(blockers)"

# -- blocker:unrequested — the stalled round. Nobody owes an answer because
#    nobody was ever asked, yet the board read "waiting on the bots" until
#    `stale` noticed 48h later.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'
expect "ready, nobody asked, nothing reviewed raises unrequested" blocker:unrequested "$(blockers)"
# ...the partial case is equally stalled: one verdict in, nobody asked for the rest
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" 2026-08-03T10:00:00Z)")"
expect "one bot in, none requested is still unrequested" blocker:unrequested "$(blockers)"
# ...a STALE round with nobody asked is the same debt, and arguably worse: the
#    page carries approvals that no longer describe the tree. Guarding on
#    MISSING alone let this one through with no blocker at all.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED oldhead "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED oldhead "" 2026-08-03T10:02:00Z)")"
expect "a stale round with nobody asked is unrequested too" blocker:unrequested "$(blockers)"
expect "...and is still the agent's ball" state:addressing "$(decide_state)"
# ...but a live request means an answer IS coming
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
REQUESTED="$BOT2"
expect "a live bot request is not a stalled round" "" "$(blockers)"
# ...and a draft is exempt: the bots ignore drafts by design
DRAFT=true REQUESTED="" REVIEWS_JSON='[]'
expect "a draft with nobody asked is not stalled" "" "$(blockers)"
# ...as is an explicit human request — claiming a PR early is deliberate
DRAFT=false REQUESTED="$HUMAN"
expect "an early human claim is not a stalled round" "" "$(blockers)"
REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS

# -- flavour 2 (the dangerous one): mergeable, green, human requested, and
#    NOBODY has reviewed this head. Observed on #119 after a rebase: every
#    signal read "merge me" and nothing on the page contradicted it.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)" \
  "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "stale approvals outrank the human request (nobody reviewed this tree)" state:addressing "$(decide_state)"

# -- ...and a round that is BOTH unfinished and staled is still the agent's.
#    Deciding inside the bot loop made this depend on BOTS order: the MISSING
#    returned before any later bot's STALE was read, so the mixed round came
#    out needs-human with nothing bound to the head. Pinned at both ends of
#    the array, because the whole failure was one of ordering.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)")"
expect "stale approvals + a bot yet to review is addressing, not needs-human" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "...and the same when the stale verdict is the LAST bot in BOTS" \
  state:addressing "$(decide_state)"

# -- but an UNFINISHED round still yields to an explicit human request: a
#    maintainer pulling a PR to themselves early is deliberate, and was the
#    original precedence. MISSING differs from STALE — nobody has reviewed
#    YET, versus everyone reviewed something else.
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
expect "an unfinished round still yields to an explicit human request" state:needs-human "$(decide_state)"
REQUESTED=""
expect "...and without that request the agent owes the ask" state:addressing "$(decide_state)"

# ---------------------------------------------------------------------------
# The classifier's own assertions live in test/checks.test.sh, moved there
# byte-identical when #440 gave lib/checks.sh a second caller. What stays is
# below: not a test of checks_state but of the state machine BEHIND it — the
# one seam a classifier-only suite cannot reach, which is why it did not
# travel. The two builders and the pinned-empty SELF_WORKFLOW travel with it
# for the same reason (see that file's header for why the pin is not
# optional).
# ---------------------------------------------------------------------------
rollup() { jq -n --argjson c "$1" '{statusCheckRollup: $c}'; }
run_() { jq -n --arg n "$1" --arg o "$2" --arg t "${3:-2026-07-20T15:00:00Z}" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, conclusion:$o, completedAt:$t}'; }
SELF_WORKFLOW=""

# -- the classifier feeds the state machine: a cancelled required check must
#    take the PR off the human's plate, which is the whole point of #136.
DRAFT=false HEAD_SHA=head1 REQUESTED="$HUMAN" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE
CHECKS="$(rollup "[$(run_ a SUCCESS),$(run_ b CANCELLED)]" | checks_state)"
expect "a cancelled check reaches decide_state as the agent's ball" state:addressing "$(decide_state)"
expect "...via blocker:ci-red, not a conflict" blocker:ci-red "$(blockers)"

# -- the happy path survives all of the above.
REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED=""
expect "mergeable + green + three head-current approvals is needs-human" state:needs-human "$(decide_state)"
# -- and a draft outranks everything, including a conflict.
DRAFT=true MERGEABLE=CONFLICTING
expect "a draft is building even when conflicted" state:building "$(decide_state)"
DRAFT=false MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'

# ---------------------------------------------------------------------------
# reconcile_pr's cold-start path. Everything above tests pure functions, which
# is exactly why a per-PR `return` in the label pre-flight got through review:
# the fixtures could not reach it. A missing state:* label must skip the label
# EDIT only — merge-next clearing and the stale sweep are independent of the
# taxonomy, and stranding them reintroduced the false-invitation bug (a
# `merge-next` claim surviving on a PR the board had moved to the agent).
# ---------------------------------------------------------------------------
reconcile_probe() { # $1 = REPO_LABELS content, $2 = AUTO_MERGE (optional)
  (
    REPO_LABELS="$1" REPO=owner/repo NOW="$(date +%s)"
    AUTO_MERGE="${2:-off}" AUTHOR="$FIXTURE_AUTHOR"
    LABELS="merge-next"                      # the PR carries a queue claim
    DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON='[]'
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON='{"created_at":"2020-01-01T00:00:00Z"}'
    run() { :; }                              # swallow mutations
    gh() { :; }                               # no network
    reconcile_pr 777 2>&1
  )
}

cold="$(reconcile_probe "merge-next")"        # state:* labels absent entirely
expect "a cold-start repo still clears merge-next" \
  yes "$(grep -q 'cleared merge-next' <<<"$cold" && echo yes || echo no)"
expect "...and still runs the stale sweep" \
  yes "$(grep -q 'stale (' <<<"$cold" && echo yes || echo no)"
expect "...while warning that the state label is missing" \
  yes "$(grep -q "state label 'state:addressing' does not exist" <<<"$cold" && echo yes || echo no)"

warm="$(reconcile_probe "$(printf 'state:addressing\nmerge-next\nstale\nblocker:unrequested')")"
expect "a bootstrapped repo converges the state as well" \
  yes "$(grep -q 'state -> state:addressing' <<<"$warm" && echo yes || echo no)"
expect "toggle off emits no auto-merge line" no \
  "$(grep -q 'auto-merge\[' <<<"$warm" && echo yes || echo no)"
shadow="$(reconcile_probe "$(printf 'state:addressing\nmerge-next\nstale\nblocker:unrequested')" merge)"
expect "toggle on logs the pure verdict after attention reconciliation" yes \
  "$(grep -q '#777: auto-merge\[ordinary\]: SKIP:state' <<<"$shadow" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# needs-ruling (#51): a pending human decision. Hand-set intent the machine
# reads and never writes — an EXCLUSION on needs-human, never a blocker and
# never a latch. #50's D8 by construction: needs-ruling and state:needs-human
# can never share a PR.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS
LABELS=""
expect "the ruling-free fixture hands off (control)" state:needs-human "$(decide_state)"
LABELS="needs-ruling"
expect "a pending ruling excludes needs-human" state:addressing "$(decide_state)"
LABELS=""
expect "...and clearing it hands off again — an exclusion, not a latch" state:needs-human "$(decide_state)"
LABELS="needs-ruling" DRAFT=true
expect "a draft with a ruling pending is still building" state:building "$(decide_state)"
DRAFT=false

# blockers() must not know the label exists: it is not a branch fact, and the
# converge loop strips every BLOCKERS entry the facts do not re-derive —
# emitting it there is exactly the trap #51 names.
MERGEABLE=CONFLICTING
LABELS=""
expect "conflict fixture emits its blocker (control)" blocker:conflict "$(blockers)"
LABELS="needs-ruling"
expect "needs-ruling adds nothing to blockers()" blocker:conflict "$(blockers)"
MERGEABLE=MERGEABLE LABELS=""

# ---------------------------------------------------------------------------
# blocked (#180): a directed hold. Same shape as needs-ruling — hand-set
# intent the machine reads and never writes, an EXCLUSION on needs-human,
# never a blocker and never a latch. During the #111 freeze rig#126/#128
# carried blocked beside state:needs-human, and rig#126 was merged seven
# minutes after the reconciler wrote the green label.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS
LABELS=""
expect "the hold-free fixture hands off (control)" state:needs-human "$(decide_state)"
LABELS="blocked"
expect "a directed hold excludes needs-human" state:addressing "$(decide_state)"
LABELS=""
expect "...and clearing it hands off again — an exclusion, not a latch" state:needs-human "$(decide_state)"
LABELS="blocked" DRAFT=true
expect "a draft carrying blocked is still building" state:building "$(decide_state)"
DRAFT=false

# blockers() must not know this label exists either: it is not a branch fact,
# and the converge loop strips every BLOCKERS entry the facts do not
# re-derive — emitting it there would strip a live hold on the next tick.
MERGEABLE=CONFLICTING
LABELS=""
expect "conflict fixture emits its blocker (control)" blocker:conflict "$(blockers)"
LABELS="blocked"
expect "blocked adds nothing to blockers()" blocker:conflict "$(blockers)"
MERGEABLE=MERGEABLE LABELS=""

# The guard the other fixtures cannot see: an UNGUARDED has_label read under
# set -u does not go red — bash treats the unset expansion inside the
# herestring redirection as a redirection error (bash 5.2: rc 127, the shell
# survives), so has_label fails OPEN, answering "label absent" with only a
# stderr complaint. For needs-ruling that would wave a live escalation
# through to needs-human in any caller that never set LABELS. Pinned by
# re-sourcing in a clean shell: the LABELS="" init keeps the read silent,
# and deleting the init turns this red.
guard_noise="$(bash -uc '. actions/labels-reconcile/labels-reconcile.sh
  DRAFT=false HEAD_SHA=h REQUESTED="" REVIEWS_JSON="[]" MERGEABLE=MERGEABLE CHECKS=SUCCESS
  decide_state' 2>&1 >/dev/null)"
expect "a fresh source reads LABELS cleanly (no unbound complaint)" "" "$guard_noise"

# The full-sweep probes ride the needs-human-otherwise fixture (three
# head-current approvals, mergeable, green). reconcile_probe cannot serve
# here — its empty round lands on addressing for its own reasons, and the
# exclusion must be the ONLY thing moving the state.
ruling_probe() { # $1 = the PR's labels → the log lines reconcile_pr emits
  (
    REPO_LABELS="$(printf 'state:addressing\nstate:needs-human\nmerge-next\nstale\nneeds-ruling')"
    REPO=owner/repo NOW="$(date +%s)"
    LABELS="$1"
    DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE"
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON='{"created_at":"2020-01-01T00:00:00Z"}'
    run() { :; }                              # swallow mutations
    gh() { :; }                               # no network
    reconcile_pr 888 2>&1
  )
}

ruled="$(ruling_probe "$(printf 'needs-ruling\nmerge-next')")"
expect "the exclusion drives the full sweep to addressing" \
  yes "$(grep -q 'state -> state:addressing' <<<"$ruled" && echo yes || echo no)"
expect "...retracting merge-next: a PR awaiting a ruling is not merge-me-next" \
  yes "$(grep -q 'cleared merge-next' <<<"$ruled" && echo yes || echo no)"
expect "...and the sweep never touches needs-ruling itself" \
  no "$(grep -q 'needs-ruling' <<<"$ruled" && echo yes || echo no)"

# Staleness: waiting on a human is legitimately quiet (#50 D10) — same
# treatment as blocked, including taking an already-applied stale back off.
quiet="$(ruling_probe "needs-ruling")"
expect "quiet under a pending ruling is never stale" \
  no "$(grep -q 'stale (' <<<"$quiet" && echo yes || echo no)"
unstale="$(ruling_probe "$(printf 'needs-ruling\nstale')")"
expect "...and an already-applied stale comes off" \
  yes "$(grep -q 'unstale' <<<"$unstale" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The ruling pass on the PR surface (#52): the bare-flag check and the 7-day
# nudge ride reconcile_pr behind the flag, on the same real-activity
# computation the stale sweep reads. A recording stub serves the API facts:
# fixture JSON per endpoint (with the caller's --jq applied by real jq),
# posted comments appended back into the fixture so a second sweep sees the
# first one's writes, and every label edit recorded.
# ---------------------------------------------------------------------------
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
RNOW=2000000000

ruling_sweep_probe() { # $1 labels, $2 PR, $3 assignees, $4 requested, $5 activity age days
  (
    local n="${2:-77}" assignees="${3:-0}" requested="${4:-}"
    local activity_days="${5:-8}"
    local assignee_json='[]'
    [ "$assignees" -eq 0 ] || assignee_json='[{"login":"owner-bot"}]'
    REPO_LABELS="$(printf 'state:addressing\nstate:needs-human\nmerge-next\nstale\nneeds-ruling')"
    REPO=owner/repo NOW="$RNOW"
    LABELS="$1"
    DRAFT=false HEAD_SHA=head1 REQUESTED="$requested"
    # Approvals submitted 8 days ago — the newest real activity anywhere.
    REVIEWS_JSON="$(reviews \
      "$(rev "$BOT1" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")" \
      "$(rev "$BOT2" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")" \
      "$(rev "$BOT3" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")")"
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON="$(jq -n --arg at "$(iso_at $((RNOW - 10 * 86400)))" \
      --argjson assignees "$assignee_json" '{created_at: $at, assignees: $assignees}')"
    run() { "$@"; } # mutations reach the stub and are recorded, not swallowed
    gh() {
      if [ "$1" = api ]; then
        shift
        local jqexpr="" endpoint="" file
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        file="$RTMP/$(printf '%s' "$endpoint" | tr '/' '_').json"
        printf '%s\n' "$endpoint" >>"$RTMP/api-calls"
        [ ! -f "$file.error" ] || return 1
        # A missing fixture is an empty collection — projected through the
        # caller's --jq exactly like real gh, so '.[].foo' yields no lines.
        [ -f "$file" ] || { printf '[]\n' | jq -r "${jqexpr:-.}"; return 0; }
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local n="$3" body="" file
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$RTMP/posted-$n"
        file="$RTMP/repos_owner_repo_issues_${n}_comments.json"
        [ -f "$file" ] || printf '[]\n' >"$file"
        jq --arg b "$body" --arg at "$(iso_at "$RNOW")" \
          '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
          "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf '%s\n' "$*" >>"$RTMP/edits"
      fi
    }
    reconcile_pr "$n" 2>&1
  )
}

# The flag went up 10 days ago with its escalation posted seconds earlier;
# the newest activity is the reviews at 8 days. The escalation is conforming
# and the rung markers are pre-seeded — by now both rungs fired long ago
# (#73), older than the reviews so the quiet window still reads 8 days —
# and this probe observes the nudge wiring alone; shape and rung behavior
# have their own probes in test/ruling.test.sh.
jq -n --arg at "$(iso_at $((RNOW - 10 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$RTMP/repos_owner_repo_issues_77_timeline.json"
jq -n --arg at "$(iso_at $((RNOW - 10 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((RNOW - 10 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((RNOW - 10 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc77","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$RTMP/repos_owner_repo_issues_77_comments.json"

wired="$(ruling_sweep_probe "needs-ruling")"
expect "8 quiet days under a ruling nudges on the PR surface" \
  yes "$(grep -q 'ruling nudge' <<<"$wired" && echo yes || echo no)"
expect "...while the quiet stays stale-free (#51's skip intact)" \
  no "$(grep -q 'stale (' <<<"$wired" && echo yes || echo no)"
expect "...the accompanied flag is not called bare" \
  no "$(grep -q 'ruling flag is bare' <<<"$wired" && echo yes || echo no)"
expect "the nudge addressed the decider and linked the escalation" \
  yes "$(grep -qF '@danmt' "$RTMP/posted-77" && grep -qF 'https://x/esc77' "$RTMP/posted-77" && echo yes || echo no)"
again="$(ruling_sweep_probe "needs-ruling")"
expect "the sweep right after the nudge holds its silence — the comment reset the window" \
  no "$(grep -q 'ruling nudge' <<<"$again" && echo yes || echo no)"
expect "exactly one nudge across both sweeps" \
  1 "$(grep -c '^----$' "$RTMP/posted-77")"
expect "no label edit across both sweeps names the ruling flag" \
  no "$(grep -q 'needs-ruling' "$RTMP/edits" 2>/dev/null && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The attention pass on the PR surface (#232): every PR target is malformed,
# assigned or not. The episode marker makes the comment once-per-labeling;
# every other board mutation remains the ordinary state machine's concern.
# ---------------------------------------------------------------------------
attention_pr_fixture() { # $1 PR, $2 labeled timestamp
  jq -n --arg at "$2" \
    '[{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
    >"$RTMP/repos_owner_repo_issues_${1}_timeline.json"
  printf '[]\n' >"$RTMP/repos_owner_repo_issues_${1}_comments.json"
}

attention_pr_fixture 78 "$(iso_at $((RNOW - 120)))"
attention_mutations_before="$(wc -l <"$RTMP/edits")"
attention_pr="$(ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1)"
expect "attention on an unassigned PR is diagnosed" yes \
  "$(grep -q 'malformed attention (pr)' <<<"$attention_pr" && echo yes || echo no)"
expect "the PR comment points to the assigned claim issue" yes \
  "$(grep -qF 'assigned issue that owns the claim' "$RTMP/posted-78" && echo yes || echo no)"
expect "the PR comment does not guess a target issue number" no \
  "$(grep -Eq '#[0-9]+' "$RTMP/posted-78" && echo yes || echo no)"
ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1 >/dev/null
expect "two PR sweeps in one attention episode post once" 1 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-78")"
jq --arg at "$(iso_at $((RNOW - 30)))" \
  '. + [{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
  "$RTMP/repos_owner_repo_issues_78_timeline.json" \
  >"$RTMP/repos_owner_repo_issues_78_timeline.json.tmp" \
  && mv "$RTMP/repos_owner_repo_issues_78_timeline.json.tmp" \
    "$RTMP/repos_owner_repo_issues_78_timeline.json"
ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1 >/dev/null
expect "a re-set PR flag receives a second episode comment" 2 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-78")"

attention_pr_fixture 79 "$(iso_at $((RNOW - 60)))"
ruling_sweep_probe $'attention\nstate:needs-human' 79 1 danmt 1 >/dev/null
expect "attention on an assigned PR is still diagnosed" 1 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-79")"

attention_pr_fixture 80 "$(iso_at $((RNOW - 60)))"
: >"$RTMP/repos_owner_repo_issues_80_timeline.json.error"
unreadable_attention="$(ruling_sweep_probe $'attention\nstate:needs-human' 80 0 danmt 1)"
expect "an unreadable PR attention timeline posts nothing" no \
  "$([ -f "$RTMP/posted-80" ] && echo yes || echo no)"
expect "the unreadable fact is logged without a verdict" yes \
  "$(grep -qF 'attention timeline unreadable' <<<"$unreadable_attention" && echo yes || echo no)"

: >"$RTMP/api-calls"
ruling_sweep_probe state:needs-human 81 0 danmt 1 >/dev/null
expect "a flag-free PR performs no attention timeline read" no \
  "$(grep -qF 'repos/owner/repo/issues/81/timeline' "$RTMP/api-calls" && echo yes || echo no)"
expect "attention diagnosis caused no PR mutation" "$attention_mutations_before" \
  "$(wc -l <"$RTMP/edits")"

# ---------------------------------------------------------------------------
# The take-back's reason, on the PR (#377). incubator#94: a hand-set
# state:needs-human was taken back ~45 seconds later, three times in ten
# minutes, because the only record of the take-back was a line in the labels
# workflow's run log — which a builder driving a PR never opens. The :597
# precedence rule is correct and untouched here; what these fixtures pin is
# that it SAYS so where the builder is looking, exactly once per (blocker
# set, head), and that the three sibling exclusions stay silent.
# ---------------------------------------------------------------------------
TB="$RTMP/takeback"
mkdir -p "$TB"

takeback_probe() { # $1 PR, $2 labels, $3 head, $4 round, $5 checks, $6 mergeable, $7 draft
  # Three env overrides for the cases the positional shape has no room for,
  # each defaulting to the happy path: TB_EDIT_RC / TB_COMMENT_RC are the exit
  # status the stubbed mutation returns, TB_REPO_LABELS a taxonomy short of
  # what the sweep wants to write.
  (
    local n="$1" head="$3" round="$4" at
    at="$(iso_at $((RNOW - 3600)))"
    # The taxonomy from the script's own arrays: a fixture that hand-lists the
    # label names would keep passing after a rename while the sweep filtered
    # the add away.
    REPO_LABELS="${TB_REPO_LABELS:-$(printf '%s\n' "${STATES[@]}" "${BLOCKERS[@]}" \
      merge-next stale needs-ruling blocked)}"
    REPO=owner/repo NOW="$RNOW"
    LABELS="$2"
    DRAFT="${7:-false}" HEAD_SHA="$head" REQUESTED=""
    MERGEABLE="${6:-MERGEABLE}" CHECKS="${5:-SUCCESS}"
    case "$round" in
      # every verdict a head-current approval — the round says needs-human
      approve) REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
      # a standing block — the ROUND is what moves the state, not the branch
      block) REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" CHANGES_REQUESTED "$head" "" "$at")" \
        "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
      # the only round that reaches decide_state's :587 draft clause: a
      # non-verdict outranks the draft, and the live human request carries
      # round_state to needs-human anyway — so on a draft the DRAFT rule
      # fires above :597, which is the carve-out under test.
      draftable)
        REQUESTED="$HUMAN"
        REVIEWS_JSON="$(reviews \
          "$(rev "$BOT1" COMMENTED "$head" "looks fine" "$at")" \
          "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
          "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
    esac
    PR_JSON="$(jq -n --arg at "$at" '{created_at: $at, assignees: []}')"
    # TB_FORCE_PREDICATE isolates the CALL SITE's gate from the predicate that
    # normally stands in front of it. The two overlap on every reachable
    # fixture — a PR carrying needs-human and reported as taken back always
    # has needs-human on the edit's removal side — so without this the gate's
    # own condition is asserted by nothing, and "the edit succeeded" would
    # read the same as "the edit took the handoff back".
    if [ -n "${TB_FORCE_PREDICATE:-}" ]; then
      handoff_taken_back() { printf 'blocker:ci-red\n'; }
    fi
    run() { "$@"; } # mutations reach the stub and are recorded, not swallowed
    gh() {
      # every call in call ORDER, which is what pins where in the pass the
      # comment lands relative to the reads that measure the PR's activity
      printf '%s\n' "$*" >>"$TB/calls-$n"
      if [ "$1" = api ]; then
        shift
        local jqexpr="" endpoint="" file
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        file="$TB/$(printf '%s' "$endpoint" | tr '/' '_').json"
        [ -f "$file" ] || { printf '[]\n' | jq -r "${jqexpr:-.}"; return 0; }
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local c="$3" body="" file
        # a post that failed records NOTHING — no body, no marker in the
        # fixture — which is the state the retry path depends on
        [ "${TB_COMMENT_RC:-0}" = 0 ] || return "$TB_COMMENT_RC"
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$TB/posted-$c"
        # posted comments go back into the fixture, so the NEXT pass reads
        # this one's marker exactly as a real sweep would
        file="$TB/repos_owner_repo_issues_${c}_comments.json"
        [ -f "$file" ] || printf '[]\n' >"$file"
        jq --arg b "$body" --arg at "$(iso_at "$RNOW")" \
          '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/tb","body":$b}]' \
          "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        # recorded per PR: the atomicity assertion counts the EDIT CALLS one
        # pass makes, which is the property the comment must not disturb
        printf '%s\n' "$*" >>"$TB/edits-$3"
        return "${TB_EDIT_RC:-0}"
      fi
    }
    reconcile_pr "$n" 2>&1
  )
}

posted_count() { # $1 PR → take-back comments standing on it
  [ -f "$TB/posted-$1" ] || { echo 0; return; }
  grep -cF "$HANDOFF_TAKEBACK_MARKER_PREFIX" "$TB/posted-$1" || true
}
edit_count() { # $1 PR → label-edit calls recorded for it
  [ -f "$TB/edits-$1" ] || { echo 0; return; }
  wc -l <"$TB/edits-$1"
}

# -- the reported loop, as a regression -------------------------------------
loop1="$(takeback_probe 90 state:needs-human tbhead1 approve FAILURE)"
expect "a blocker takes the hand-set handoff back" yes \
  "$(grep -q 'state -> state:addressing' <<<"$loop1" && echo yes || echo no)"
expect "...and the take-back says so on the PR, exactly once" 1 "$(posted_count 90)"
expect "...naming the blocker standing" yes \
  "$(grep -qF "\`blocker:ci-red\`" "$TB/posted-90" && echo yes || echo no)"
expect "...and the head it is standing at" yes \
  "$(grep -qF 'tbhead1' "$TB/posted-90" && echo yes || echo no)"
expect "...and the precondition the handoff missed" yes \
  "$(grep -qF "no \`blocker:*\` standing" "$TB/posted-90" && echo yes || echo no)"
expect "...and the stop condition: re-setting the label is not the move" yes \
  "$(grep -qF 'setting it by hand only earns another take-back' "$TB/posted-90" && echo yes || echo no)"
expect "...logged as a take-back, not just as a state move" yes \
  "$(grep -q 'handoff taken back (blocker:ci-red at tbhead1)' <<<"$loop1" && echo yes || echo no)"
# The atomicity assertion (#377's last acceptance criterion): state and
# blocker ride ONE edit call, and the comment did not split them into two.
expect "one pass makes exactly one label-edit call" 1 "$(edit_count 90)"
expect "...carrying the state and the blocker together" yes \
  "$(grep -q -- '--add-label state:addressing,blocker:ci-red' "$TB/edits-90" && echo yes || echo no)"

# The loop itself: the builder re-sets the label, the sweep takes it back
# again — and this time says nothing, because the episode already spoke.
loop2="$(takeback_probe 90 state:needs-human tbhead1 approve FAILURE)"
expect "a re-set label at the same head is taken back again" yes \
  "$(grep -q 'state -> state:addressing' <<<"$loop2" && echo yes || echo no)"
expect "...in silence — one episode, one comment" 1 "$(posted_count 90)"
expect "...and the second pass still costs exactly one edit call" 2 "$(edit_count 90)"
for _ in 1 2 3 4 5 6 7 8; do
  takeback_probe 90 state:needs-human tbhead1 approve FAILURE >/dev/null
done
expect "ten passes over one episode post one comment in total" 1 "$(posted_count 90)"

# -- episode boundaries: the set and the head each open a new one -----------
takeback_probe 90 state:needs-human tbhead1 approve FAILURE CONFLICTING >/dev/null
expect "a different blocker set at the same head is a new episode" 2 "$(posted_count 90)"
expect "...and the new comment names both blockers" yes \
  "$(grep -qF "\`blocker:conflict\`, \`blocker:ci-red\`" "$TB/posted-90" \
    || grep -qF "\`blocker:ci-red\`, \`blocker:conflict\`" "$TB/posted-90" && echo yes || echo no)"
takeback_probe 90 state:needs-human tbhead2 approve FAILURE >/dev/null
expect "a new head with the same blocker is a new episode" 3 "$(posted_count 90)"
takeback_probe 90 state:needs-human tbhead2 approve FAILURE >/dev/null
expect "...which then repeats itself no more than the first did" 3 "$(posted_count 90)"
takeback_probe 90 state:needs-human tbhead1 approve FAILURE >/dev/null
expect "a head seen before is still its own episode, never a fresh one" 3 "$(posted_count 90)"

# -- the must-not-fire cases, each on its own PR so the count is its own ----
bots="$(takeback_probe 91 state:bots-reviewing tbhead1 block)"
expect "an ordinary bots-reviewing -> addressing move degrades" yes \
  "$(grep -q 'state -> state:addressing' <<<"$bots" && echo yes || echo no)"
expect "...and says nothing: the machine working is not a correction" 0 "$(posted_count 91)"

round="$(takeback_probe 92 state:needs-human tbhead1 block)"
expect "needs-human degrading on the ROUND still degrades" yes \
  "$(grep -q 'state -> state:addressing' <<<"$round" && echo yes || echo no)"
expect "...and says nothing: no blocker took anything back" 0 "$(posted_count 92)"

# The draft carve-out has the sharpest teeth here: the blocker IS standing,
# and only decide_state's :587 clause sitting above :597 keeps it quiet.
draft="$(takeback_probe 93 state:needs-human tbhead1 draftable FAILURE MERGEABLE true)"
expect "a draft degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$draft" && echo yes || echo no)"
expect "...silently, though a blocker stands: the draft rule outranks :597" 0 \
  "$(posted_count 93)"
control="$(takeback_probe 94 state:needs-human tbhead1 draftable FAILURE MERGEABLE false)"
expect "the same fixture off draft degrades the same way (control)" yes \
  "$(grep -q 'state -> state:addressing' <<<"$control" && echo yes || echo no)"
expect "...and speaks — the draft was the only thing keeping it quiet" 1 \
  "$(posted_count 94)"

ruled_tb="$(takeback_probe 95 $'state:needs-human\nneeds-ruling' tbhead1 approve)"
expect "a pending ruling degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$ruled_tb" && echo yes || echo no)"
expect "...silently: needs-ruling is its own visible carrier" 0 "$(posted_count 95)"

held="$(takeback_probe 96 $'state:needs-human\nblocked' tbhead1 approve)"
expect "a directed hold degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$held" && echo yes || echo no)"
expect "...silently: blocked is its own visible carrier" 0 "$(posted_count 96)"

# A red head UNDER a standing block: the state was already the agent's for
# the round's reason, so :597 never fired and nothing was taken back. The
# builder is owed "a reviewer blocked", which the round already says.
mixed="$(takeback_probe 99 state:needs-human tbhead1 block FAILURE)"
expect "a blocked round on a red head degrades" yes \
  "$(grep -q 'state -> state:addressing' <<<"$mixed" && echo yes || echo no)"
expect "...silently: the round moved the state, the blocker only rode along" 0 \
  "$(posted_count 99)"

clean="$(takeback_probe 97 state:needs-human tbhead1 approve SUCCESS)"
expect "a clear branch keeps needs-human" no \
  "$(grep -q 'state -> state:addressing' <<<"$clean" && echo yes || echo no)"
expect "...and nothing was taken back, so nothing is said" 0 "$(posted_count 97)"

# A PR that never CARRIED needs-human: the round passed, the head is red, and
# the sweep already moved it to state:addressing on an earlier pass. That is
# not exotic — it is every red-head PR with a passed round, on every pass
# after the first — and there is no hand-set label here to have been taken
# back from anyone.
carried="$(takeback_probe 89 state:addressing tbheadZ approve FAILURE)"
expect "a passed round on a red head already at addressing stays there" yes \
  "$(grep -q 'state -> state:addressing' <<<"$carried" && echo yes || echo no)"
expect "...and says nothing: no handoff was ever standing to take back" 0 \
  "$(posted_count 89)"

# -- a take-back that did not LAND says nothing -----------------------------
# The comment speaks for the replacement, not the attempt (#377 D1). Both
# failure shapes leave state:needs-human standing on the PR, so a comment
# would be false about a label still there — and its marker would then
# suppress the true comment on the pass where the edit does land.
edit_failed="$(TB_EDIT_RC=1 takeback_probe 88 state:needs-human tbhead1 approve FAILURE)"
expect "a label edit that failed says so" yes \
  "$(grep -q 'WARNING: label edit failed' <<<"$edit_failed" && echo yes || echo no)"
expect "...and claims no take-back: needs-human is still on the PR" 0 \
  "$(posted_count 88)"
expect "...and logged none either" no \
  "$(grep -q 'handoff taken back' <<<"$edit_failed" && echo yes || echo no)"
edit_landed="$(takeback_probe 88 state:needs-human tbhead1 approve FAILURE)"
expect "the pass where that same edit lands is not suppressed by the failed one" 1 \
  "$(posted_count 88)"
expect "...and reads as an ordinary take-back" yes \
  "$(grep -q 'handoff taken back (blocker:ci-red at tbhead1) — commented' \
    <<<"$edit_landed" && echo yes || echo no)"

# The cold-start repo: `state:addressing` is not in the taxonomy, so the edit
# is skipped entirely — the pass shouts a WARNING and the board keeps
# state:needs-human. Nothing was taken back, so nothing is said about it.
cold="$(TB_REPO_LABELS="$(printf '%s\n' state:needs-human blocker:ci-red)" \
  takeback_probe 87 state:needs-human tbhead1 approve FAILURE)"
expect "a repo missing state:addressing skips the label edit" yes \
  "$(grep -q "state label 'state:addressing' does not exist" <<<"$cold" && echo yes || echo no)"
expect "...makes no edit call at all" 0 "$(edit_count 87)"
expect "...and says nothing about a take-back that never happened" 0 \
  "$(posted_count 87)"

# What the gate actually asks is not "did the edit succeed" but "did it take
# the handoff back" — the removal side has to name state:needs-human. With
# the predicate forced to report a take-back, a landed edit that removed
# something else entirely still says nothing.
forced="$(TB_FORCE_PREDICATE=1 takeback_probe 84 state:addressing tbhead1 approve FAILURE)"
expect "the edit landed on that pass" yes \
  "$(grep -q 'state -> state:addressing' <<<"$forced" && echo yes || echo no)"
expect "...but removed no needs-human, so it took nothing back" 0 "$(posted_count 84)"
TB_FORCE_PREDICATE=1 takeback_probe 83 state:needs-human tbhead1 approve FAILURE >/dev/null
expect "an edit that did remove it speaks (control)" 1 "$(posted_count 83)"
expect "...the removal being the only difference between the two" yes \
  "$(grep -q -- '--remove-label state:needs-human' "$TB/edits-83" && echo yes || echo no)"

# -- a comment that failed to post is not logged as one ---------------------
post_failed="$(TB_COMMENT_RC=1 takeback_probe 86 state:needs-human tbhead1 approve FAILURE)"
expect "a failed post is logged as a failure, not as a comment" yes \
  "$(grep -q 'WARNING: handoff taken back .* the comment failed to post' \
    <<<"$post_failed" && echo yes || echo no)"
expect "...and not as one made" no \
  "$(grep -q -- '— commented' <<<"$post_failed" && echo yes || echo no)"
expect "...recording no marker, so nothing standing on the PR" 0 "$(posted_count 86)"
retried="$(takeback_probe 86 state:needs-human tbhead1 approve FAILURE)"
expect "...and the next sweep retries the same episode" 1 "$(posted_count 86)"
expect "...saying it once" yes \
  "$(grep -q -- '— commented' <<<"$retried" && echo yes || echo no)"

# -- the comment is not counted as the PR's own activity --------------------
# reconcile_ruling's comments run after the last_activity read for this
# reason; this one now does too. A machine comment read back as a sign of
# life is the sweep believing its own noise — bounded here by the episode
# guard, but the guard should not be what saves it.
takeback_probe 85 state:needs-human tbhead1 approve FAILURE >/dev/null
# A missing call is a verdict here, not a crash: under `set -e` an empty grep
# would take the runner down mid-file, which is what a silenced call site
# looked like when the mutation set was run. Both captures already read as
# "no" when empty, so absorbing the grep's exit status only ever adds a
# reported failure — it can mask nothing.
tb_commented_at="$(grep -n 'issue comment' "$TB/calls-85" | head -1 | cut -d: -f1 || true)"
tb_activity_at="$(grep -n 'created_at' "$TB/calls-85" | tail -1 | cut -d: -f1 || true)"
expect "the pass reads the PR's activity before posting its own comment" yes \
  "$([ -n "$tb_commented_at" ] && [ -n "$tb_activity_at" ] \
    && [ "$tb_commented_at" -gt "$tb_activity_at" ] && echo yes || echo no)"
expect "...having already made its one label edit before either" 1 "$(edit_count 85)"

# -- an unreadable comment list must not invent a repeat --------------------
# Everywhere else in this file an unreadable fact invents no verdict; here the
# thing it must not invent is a SECOND comment, which is the whole harm.
tb_unreadable="$(
  (
    gh() {
      if [ "$1" = api ]; then return 1; fi
      printf '%s\n' "$*" >>"$TB/unreadable-calls"
    }
    REPO=owner/repo NOW="$RNOW" HEAD_SHA=tbhead1
    LABELS=state:needs-human DRAFT=false REQUESTED="" CHECKS=FAILURE
    MERGEABLE=MERGEABLE
    REVIEWS_JSON="$(reviews \
      "$(rev "$BOT1" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")" \
      "$(rev "$BOT2" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")" \
      "$(rev "$BOT3" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")")"
    run() { "$@"; }
    # `true`: the converge edit landed and cleared needs-human, so the only
    # thing left in question is the comment read
    reconcile_handoff_takeback 98 true 2>&1
  )
)"
expect "an unreadable comment list says so" yes \
  "$(grep -q 'take-back comments unreadable' <<<"$tb_unreadable" && echo yes || echo no)"
expect "...and posts nothing on a fact it could not read" no \
  "$(grep -q 'issue comment' "$TB/unreadable-calls" 2>/dev/null && echo yes || echo no)"

# -- the marker's own shape: one spelling per (set, head) -------------------
expect "the marker names the set and the head" \
  '<!-- handoff-taken-back:blocker:ci-red:abc123 -->' \
  "$(handoff_takeback_marker "$(printf 'blocker:ci-red\n' | handoff_takeback_set)" abc123)"
expect "a set is canonicalized by sort, so emitter order cannot re-fire it" \
  "$(printf 'blocker:conflict\nblocker:ci-red\n' | handoff_takeback_set)" \
  "$(printf 'blocker:ci-red\nblocker:conflict\n' | handoff_takeback_set)"
expect "...joined with commas, sorted" 'blocker:ci-red,blocker:conflict' \
  "$(printf 'blocker:conflict\nblocker:ci-red\n' | handoff_takeback_set)"

# -- the identity the predicate rests on ------------------------------------
# handoff_taken_back is decide_state's :597 clause asked as a question, not a
# second opinion about it: it re-states that clause's guard plus the one rule
# above it. So over any fixture, a reported take-back must be a state
# decide_state really did move to addressing — a precedence edit that broke
# the identity would otherwise surface only as a comment about a take-back
# that never happened, on a live PR.
tb_at="$(iso_at $((RNOW - 3600)))"
tb_approve="$(reviews \
  "$(rev "$BOT1" APPROVED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT2" APPROVED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT3" APPROVED tbhead1 "" "$tb_at")")"
tb_block="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT2" APPROVED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT3" APPROVED tbhead1 "" "$tb_at")")"
tb_comment="$(reviews \
  "$(rev "$BOT1" COMMENTED tbhead1 "looks fine" "$tb_at")" \
  "$(rev "$BOT2" APPROVED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT3" APPROVED tbhead1 "" "$tb_at")")"
tb_stale="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" "$tb_at")" \
  "$(rev "$BOT2" APPROVED tbhead1 "" "$tb_at")" \
  "$(rev "$BOT3" APPROVED tbhead1 "" "$tb_at")")"

takeback_equivalence() { # → "<take-backs reported> <disagreements with decide_state>"
  local draft checks mergeable labels round human fired=0 disagreed=0
  HEAD_SHA=tbhead1
  for draft in true false; do
    for checks in SUCCESS FAILURE; do
      for mergeable in MERGEABLE CONFLICTING; do
        for round in approve block comment stale; do
          for human in "" "$HUMAN"; do
            # The needs-ruling and blocked variants are deliberately not on
            # this axis: both sit BELOW :597, so they are only ever reached
            # with no blocker standing and can never report a take-back to
            # check. Their silence is pinned by its own probe above.
            for labels in state:needs-human state:bots-reviewing; do
              DRAFT="$draft" CHECKS="$checks" MERGEABLE="$mergeable"
              LABELS="$labels" REQUESTED="$human"
              case "$round" in
                approve) REVIEWS_JSON="$tb_approve" ;;
                block) REVIEWS_JSON="$tb_block" ;;
                comment) REVIEWS_JSON="$tb_comment" ;;
                stale) REVIEWS_JSON="$tb_stale" ;;
              esac
              [ -n "$(handoff_taken_back)" ] || continue
              fired=$((fired + 1))
              [ "$(decide_state)" = state:addressing ] || disagreed=$((disagreed + 1))
            done
          done
        done
      done
    done
  done
  printf '%s %s\n' "$fired" "$disagreed"
}

# -- D3's first condition, asked of the predicate directly ------------------
# The PR must have CARRIED state:needs-human. This is pinned here rather than
# only through reconcile_pr because two independent guards now stand in front
# of the same case: the caller's `handoff_cleared` gate (the converge edit
# removed no needs-human, so the predicate is never even asked) would keep the
# fixture at PR 89 silent with this condition deleted, and the guard would be
# as unpinned as it was when this was reported. The equivalence matrix cannot
# stand in for it either: state:bots-reviewing + a passed round + a red head
# IS a state decide_state moves to addressing, so the identity holds while the
# predicate reports a take-back of a label nobody ever set.
tb_predicate() { # $1 = the state the PR carries → the blockers reported, if any
  (
    HEAD_SHA=tbhead1 DRAFT=false CHECKS=FAILURE MERGEABLE=MERGEABLE
    REQUESTED="" LABELS="$1" REVIEWS_JSON="$tb_approve"
    handoff_taken_back
  )
}
expect "a PR carrying addressing reports no take-back" "" \
  "$(tb_predicate state:addressing)"
expect "...nor one carrying bots-reviewing" "" \
  "$(tb_predicate state:bots-reviewing)"
expect "...while the same facts under a carried needs-human do (control)" \
  blocker:ci-red "$(tb_predicate state:needs-human)"

read -r tb_fired tb_disagreed <<<"$(takeback_equivalence)"
expect "every reported take-back is a state decide_state moved to addressing" 0 \
  "$tb_disagreed"
expect "...over a matrix that actually reaches the take-back" yes \
  "$([ "$tb_fired" -gt 0 ] && echo yes || echo no)"

# -- the sweep wiring observes the existing per-PR skip without writing -------
blind_main_probe() {
  (
    BOOTSTRAP=no
    REPO=owner/repo
    LABELS_CONF=.github/labels.conf
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then
        core_label_rows | cut -d'|' -f1
      elif [ "$1" = pr ] && [ "$2" = list ]; then
        printf '101\n102\n'
      elif [ "$1" = pr ] && [ "$2" = view ]; then
        # a denial with its reason on stderr, the way real gh fails (#101)
        printf 'GraphQL: Resource not accessible by integration (repository.pullRequest.statusCheckRollup)\n' >&2
        return 1
      elif [ "$1" = api ] && [[ "$*" = *"/reviews"* ]]; then
        return 0
      elif [ "$1" = api ]; then
        jq -n --arg n "${*: -1}" \
          '{draft:false,user:{login:"author"},head:{sha:"head"},labels:[],requested_reviewers:[],created_at:"2026-07-23T00:00:00Z"}'
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf 'MUTATION: %s\n' "$*"
      fi
    }
    main
  )
}

blind_main="$(blind_main_probe)"
expect "a wholly blind main sweep emits exactly one annotation" 1 \
  "$(grep -c '^::warning::' <<<"$blind_main")"
expect "...leading with the reason the sweep actually observed" 1 \
  "$(grep -c '^::warning::.*Resource not accessible by integration' <<<"$blind_main")"
expect "...still naming the permissions candidate" 1 \
  "$(grep -c '^::warning::.*checks: read.*statuses: read' <<<"$blind_main")"
# must-fail (#101 D5): red if the disproven diagnosis is re-asserted as fact
expect "...never as a stated cause" 0 \
  "$(grep -c 'grant checks: read and statuses: read' <<<"$blind_main" || true)"
expect "a wholly blind main sweep leaves every PR untouched" no \
  "$(grep -q '^MUTATION:' <<<"$blind_main" && echo yes || echo no)"
expect "each blind PR keeps its counted line, matched by the sweep's own grep -qxF" yes \
  "$(grep -qxF 'labels: #101: could not read mergeability/checks — left alone this pass' <<<"$blind_main" \
    && grep -qxF 'labels: #102: could not read mergeability/checks — left alone this pass' <<<"$blind_main" \
    && echo yes || echo no)"
expect "each blind PR logs its reason as its own line beside the counted one" 2 \
  "$(grep -c '^labels: #10[12]: read failed: GraphQL: Resource not accessible by integration' <<<"$blind_main")"
# must-fail (#101 D1): red if a reason line whole-line-matches the counted
# string (the counter would double-count) or the counted line changed (the
# counter would miss it and the warning never fire)
expect "exactly the blind PRs match the counted shape whole-line — no more, no less" 2 \
  "$(grep -c '^labels: #[0-9]*: could not read mergeability/checks — left alone this pass$' <<<"$blind_main")"

# -- the sampled reason survives a per-PR output block no pipe could hold ----
#
# An EQUIVALENCE case, not a regression one (#411 D10), and the grading is
# stated first because the site's classification changed after the mint:
# what would cross a `sed … | head -n1` here is not $output but sed's
# MATCHED subset, and this sweep bounds that subset twice over — one
# `read failed:` emitter per PR, and read_failure_reason caps each reason
# at 300 characters. One short line fills no pipe of any capacity, so the
# pre-change expression answers this correctly too and this case does not
# red on it. Measured, not assumed: the same `sed … | head -n1` reds at 141
# only once the MATCHED stream itself passes a MiB, which no input to this
# sweep can make it do.
#
# The site is converted anyway — D1's instruction, D2's reason — because
# "bounded" is a property of today's callers that no future reader of the
# line can check. What this case pins is the answer at a size no pipe can
# hold: a MiB of per-PR output with the read failure inside it, driven
# through `main` so the feed under test is the shipped one, under the shell
# options execution arms.
big_output_main_probe() {
  (
    BOOTSTRAP=no
    REPO=owner/repo
    LABELS_CONF=.github/labels.conf
    # gh's own diagnostics on the reviews read are NOT captured to a file the
    # way the mergeability read's are, so they land raw in the per-PR output
    # block — the one writer that can make $output large without touching
    # the reason the sweep samples.
    pad="note: a noisy read's diagnostics, matching neither the counted line nor the sampled one"$'\n'
    while [ "${#pad}" -lt $((1024 * 1024)) ]; do pad="$pad$pad"; done
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then
        core_label_rows | cut -d'|' -f1
      elif [ "$1" = pr ] && [ "$2" = list ]; then
        printf '101\n'
      elif [ "$1" = pr ] && [ "$2" = view ]; then
        printf 'GraphQL: Resource not accessible by integration (repository.pullRequest.statusCheckRollup)\n' >&2
        return 1
      elif [ "$1" = api ] && [[ "$*" = *"/reviews"* ]]; then
        printf '%s' "$pad" >&2
        return 0
      elif [ "$1" = api ]; then
        jq -n --arg n "${*: -1}" \
          '{draft:false,user:{login:"author"},head:{sha:"head"},labels:[],requested_reviewers:[],created_at:"2026-07-23T00:00:00Z"}'
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf 'MUTATION: %s\n' "$*"
      fi
    }
    # The options labels-reconcile.sh arms when it is EXECUTED; sourcing it
    # takes the `set -u` branch instead, and without `pipefail` a broken
    # pipe is invisible — the fixture could not fail for the reason the bug
    # exists (#411 D3).
    set -euo pipefail
    main
  )
}

big_main="$(big_output_main_probe)"
expect "the per-PR output block really did clear a MiB — the case is not vacuous by size" yes \
  "$([ "${#big_main}" -gt $((1024 * 1024)) ] && echo yes || echo no)"
expect "a MiB-long per-PR block still samples the reason the sweep observed" 1 \
  "$(grep -c '^::warning::.*Resource not accessible by integration' <<<"$big_main")"
expect "...exactly once, and the sweep survives to emit it" 1 \
  "$(grep -c '^::warning::' <<<"$big_main")"
expect "...and reconciles to the end" 1 \
  "$(grep -c '^labels: reconciled\.$' <<<"$big_main")"

# -- the grace's own wiring: the fixtures above prove the predicate, and only a
#    sweep can prove the fetch that feeds it (#236 D2). The fixture-only version
#    of this change would have passed with the global never assigned — the #91
#    shape, where the probes could not reach the per-PR path at all.
unrequested_main_probe() { # $1 = read | denied, the head-commit read's outcome
  (
    BOOTSTRAP=no
    REPO=owner/repo
    LABELS_CONF=.github/labels.conf
    UMODE="$1"
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then core_label_rows | cut -d'|' -f1; return 0; fi
      if [ "$1" = pr ] && [ "$2" = list ]; then printf '303\n'; return 0; fi
      if [ "$1" = pr ] && [ "$2" = view ]; then
        # green, so the D1 gate is open and D2 is the only question left
        jq -n '{mergeable:"MERGEABLE",
                statusCheckRollup:[{__typename:"CheckRun",workflowName:"ci",
                                    name:"check",conclusion:"SUCCESS",
                                    startedAt:"2026-07-01T00:00:00Z"}]}'
        return 0
      fi
      # recorded to a file, not to stdout: reconcile_pr sends the edit call's
      # stdout to /dev/null, so a narrating stub would look like no edit at all
      if [ "$1" = issue ] && [ "$2" = edit ]; then printf '%s\n' "$*" >>"$RTMP/uedits-$UMODE"; return 0; fi
      [ "$1" = api ] || return 0
      shift
      local jqexpr="" endpoint=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jqexpr="$2"; shift ;;
          -*) ;;
          *) [ -n "$endpoint" ] || endpoint="$1" ;;
        esac
        shift
      done
      case "$endpoint" in
        */commits/*) # the head-commit read; ordered before the commit LIST below
          if [ "$UMODE" = denied ]; then
            printf 'gh: Not Found (HTTP 404)\n' >&2
            return 1
          fi
          jq -n '{commit:{committer:{date:"2026-07-01T00:00:00Z"}}}' | jq -r "${jqexpr:-.}" ;;
        */pulls/303)
          jq -n '{draft:false,user:{login:"author"},head:{sha:"headsha"},
                  base:{sha:"basesha"},labels:[],requested_reviewers:[],
                  created_at:"2026-07-01T00:00:00Z"}' ;;
        *) printf '[]\n' | jq -r "${jqexpr:-.}" ;; # every collection empty
      esac
    }
    main
  )
}

read_sweep="$(unrequested_main_probe read)"
expect "the sweep reads the head's date and writes the stall it now dates" yes \
  "$(grep -q 'blocker:unrequested' "$RTMP/uedits-read" && echo yes || echo no)"
expect "...saying nothing about a degraded read" no \
  "$(grep -q "could not read the head commit's date" <<<"$read_sweep" && echo yes || echo no)"
denied_sweep="$(unrequested_main_probe denied)"
expect "a denied head-commit read names the denial (#101's shape)" yes \
  "$(grep -q "^labels: #303: could not read the head commit's date: gh: Not Found (HTTP 404)" <<<"$denied_sweep" \
    && echo yes || echo no)"
expect "...and writes no blocker it could not date" no \
  "$(grep -q 'blocker:unrequested' "$RTMP/uedits-denied" && echo yes || echo no)"
# ...while the PR is still converged: this read narrows one blocker, it does not
# skip the PR the way an unreadable rollup does
expect "...while the state still converges — one blocker unjudged, not a skip" yes \
  "$(grep -q 'state:addressing' "$RTMP/uedits-denied" && echo yes || echo no)"
expect "...and the sweep does not report it as a blind pass" 0 \
  "$(grep -c 'could not read mergeability/checks' <<<"$denied_sweep" || true)"

# ---------------------------------------------------------------------------
# bootstrap_labels retires the GitHub defaults (#93). LABELS.md published
# them as deleted at bootstrap; nothing deleted them — incubator's first
# dispatch (run 30041309187) ran green and left `good first issue` standing,
# the first honest read of the machine since the older repos were cleaned by
# hand. One registry beside the taxonomy, gated on `BOOTSTRAP=yes` like the
# upserts (#472 — dispatch-gated until then), and never fatal: absence is the
# NORMAL case from the second bootstrap on (#91's set -e shape), and a 403
# refusal must not cost the taxonomy the token CAN create.
# ---------------------------------------------------------------------------
BOOT="$RTMP/bootstrap"
mkdir -p "$BOOT"

RETIRED_WANT='duplicate
invalid
question
wontfix
help wanted
good first issue'
expect "the retired registry is exactly the six, no seventh" \
  "$RETIRED_WANT" "$(retired_label_names)"
# the sentence and the registry must not drift apart again: parse the names
# out of LABELS.md's own parenthetical and demand identity, name for name
# shellcheck disable=SC2016 # the backticks are LABELS.md literals, not expansions
doctrine="$(sed -n '/Default GitHub labels/,/are deleted at/p' LABELS.md \
  | tr '\n' ' ' | sed 's/.*(//;s/).*//' | grep -o '`[^`]*`' | tr -d '`')"
expect "...and matches LABELS.md name for name" "$doctrine" "$(retired_label_names)"

expected_upserts="$({ core_label_rows; configured_label_rows .github/labels.conf; } | cut -d'|' -f1)"

# -- happy path: the deletes ride the same dispatch, after an unchanged upsert set
(
  REPO=owner/repo LABELS_CONF=.github/labels.conf
  run() { printf '%s\n' "$*" >>"$BOOT/happy"; }
  bootstrap_labels
)
expect "a dispatch deletes the six in the same run as the upserts" \
  "$RETIRED_WANT" \
  "$(sed -n 's/^gh label delete \(.*\) -R owner\/repo --yes$/\1/p' "$BOOT/happy")"
expect "...and the recorded upsert set is unchanged from today's" \
  "$expected_upserts" \
  "$(sed -n 's/^gh label create \([^ ]*\) .*/\1/p' "$BOOT/happy")"
expect "the bootstrap upserts operator from the central registry" 1 \
  "$(grep -cF 'gh label create operator -R owner/repo --color A371F7 --description Operator-owned; the body names the evidence surface, the command, and the wake condition --force' "$BOOT/happy")"

# -- a missing label is success: gh exits non-zero with not-found, and the
#    guard keeps that from aborting the dispatch. Red without the guard.
boot_missing_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf
    run() { "$@"; }
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() {
      if [ "$1" = label ] && [ "$2" = delete ]; then
        printf '%s\n' "$3" >>"$BOOT/missing-deletes"
        echo "could not delete label: HTTP 404: Not Found" >&2
        return 1
      fi
    }
    bootstrap_labels
  ) 2>&1
}
missing_rc=0
missing_out="$(boot_missing_probe)" || missing_rc=$?
expect "an already-absent label does not abort the dispatch" 0 "$missing_rc"
expect "...every deletion still ran" "$RETIRED_WANT" "$(cat "$BOOT/missing-deletes")"
expect "...and each absence is logged at most once per name" \
  1 "$(grep -c "retire: 'question'" <<<"$missing_out")"

# -- a refusal is tolerated: the blocker:drill-pending 403 shape, on a delete.
#    The other five still go, the taxonomy still lands, the log says who.
boot_refusal_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf
    run() { "$@"; }
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() {
      if [ "$1" = label ] && [ "$2" = delete ]; then
        if [ "$3" = question ]; then
          echo "HTTP 403: Resource not accessible by integration" >&2
          return 1
        fi
        printf '%s\n' "$3" >>"$BOOT/refusal-deletes"
      elif [ "$1" = label ] && [ "$2" = create ]; then
        printf '%s\n' "$3" >>"$BOOT/refusal-creates"
      fi
    }
    bootstrap_labels
  ) 2>&1
}
refusal_rc=0
refusal_out="$(boot_refusal_probe)" || refusal_rc=$?
expect "a refused delete does not abort the dispatch" 0 "$refusal_rc"
expect "...the other five still deleted" "duplicate
invalid
wontfix
help wanted
good first issue" "$(cat "$BOOT/refusal-deletes")"
expect "...the taxonomy still upserted whole" \
  "$expected_upserts" "$(cat "$BOOT/refusal-creates")"
expect "...and the log names the refused label" \
  yes "$(grep -q "retire: 'question'" <<<"$refusal_out" && echo yes || echo no)"

# -- DRY_RUN narrates the deletions like every other mutation, and does none
boot_dry_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf DRY_RUN=1
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() { printf '%s\n' "$*" >>"$BOOT/dry-real"; }
    bootstrap_labels
  )
}
dry_out="$(boot_dry_probe)"
expect "DRY_RUN narrates each deletion" \
  6 "$(grep -c '^labels: DRY_RUN: gh label delete' <<<"$dry_out")"
expect "...and performs none" \
  no "$(test -f "$BOOT/dry-real" && echo yes || echo no)"

# -- the case a sourced probe cannot see (#91): the script EXECUTED, set -e
#    live, every delete failing the way the second dispatch of every repo
#    fails. The run must end green with the taxonomy created whole.
EXEC="$RTMP/bootstrap-exec"
mkdir -p "$EXEC/stub"
cat >"$EXEC/stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "label delete")
    printf 'delete %s\n' "$3" >>"$GH_RECORD"
    echo "could not delete label: HTTP 404: Not Found (owner/repo)" >&2
    exit 1 ;;
  "label create")
    printf 'create %s\n' "$3" >>"$GH_RECORD" ;;
esac
exit 0
EOF
chmod +x "$EXEC/stub/gh"
printf 'panel=bot-a bot-b bot-c\n' >"$EXEC/labels.conf"

exec_env() { # $1 = BOOTSTRAP, $2 = GITHUB_EVENT_NAME; "-" leaves either unset.
             # $3, optional, is DRY_RUN.
             # → the real script, executed under the PATH stub
  : >"$EXEC/record"
  local -a vars=(PATH="$EXEC/stub:$PATH" GH_RECORD="$EXEC/record"
    REPO=owner/repo LABELS_CONF="$EXEC/labels.conf")
  [ "$1" = - ] || vars+=("BOOTSTRAP=$1")
  [ "$2" = - ] || vars+=("GITHUB_EVENT_NAME=$2")
  # $3 rather than an inherited DRY_RUN: a prefix assignment on a bash
  # FUNCTION call is not exported, so the child would never see it.
  [ -z "${3:-}" ] || vars+=("DRY_RUN=$3")
  # The event name is still SET on most of these calls, deliberately (#472):
  # a fixture that stopped setting it could not see the defect at all, since
  # the whole repair is that the two facts are now independent. It is passed
  # here for the gate to ignore.
  env -u BOOTSTRAP -u GITHUB_EVENT_NAME -u DRY_RUN "${vars[@]}" \
    bash actions/labels-reconcile/labels-reconcile.sh
}
exec_created() { sed -n 's/^create //p' "$EXEC/record"; }
exec_deleted() { grep -c '^delete ' "$EXEC/record" || true; }

exec_rc=0
exec_out="$(exec_env yes workflow_dispatch 2>&1)" || exec_rc=$?
expect "an executed bootstrap with all six absent completes green" 0 "$exec_rc"
expect "...reaching the end of the sweep" \
  yes "$(grep -q 'reconciled.' <<<"$exec_out" && echo yes || echo no)"
expect "...having attempted all six deletions" 6 "$(exec_deleted)"
expect "...and created the full taxonomy" \
  "$(core_label_rows | cut -d'|' -f1)" "$(exec_created)"
expect "...and the log names the input, not the event that woke the sweep" \
  yes "$(grep -q '^labels: bootstrap=yes: bootstrapping the taxonomy' <<<"$exec_out" \
    && echo yes || echo no)"

# -- THE DISCRIMINATING CASE (#472). One fixture, two readings: the event says
#    workflow_dispatch and the input says no. Only the input is the ask.
#
#    This is the defect restated as a test, and it fails on main: the
#    composite exported GITHUB_EVENT_NAME=workflow_dispatch on bootstrap=yes
#    and main() gated on that export, so `no` could not be obeyed — every
#    trigger-woken sweep already arrives as a dispatch, that being how the
#    trigger job wakes the sweep caller with no PAT. Run 32004881752 logged
#    `BOOTSTRAP: no` and, 21 ms later, a log line crediting the event with a
#    bootstrap the caller had declined: 28 upserts and six retire probes on
#    ~10 sweeps an hour, in every governed repo. That literal is asserted
#    absent below, so it is described here rather than quoted.
disc_rc=0
disc_out="$(exec_env no workflow_dispatch 2>&1)" || disc_rc=$?
expect "a dispatch carrying bootstrap=no completes green" 0 "$disc_rc"
expect "...reaching the end of the sweep" \
  yes "$(grep -q 'reconciled.' <<<"$disc_out" && echo yes || echo no)"
expect "...creating nothing" "" "$(exec_created)"
expect "...deleting nothing" 0 "$(exec_deleted)"
expect "...and narrating no bootstrap at all" \
  0 "$(grep -c 'bootstrapping the taxonomy' <<<"$disc_out" || true)"

# -- the same defect from the other side, and the case that proves the
#    composite's export is gone rather than merely moved: the input says yes
#    while the event name is unset, and then while it says schedule.
for ev in - schedule; do
  mirror_rc=0
  exec_env yes "$ev" >/dev/null 2>&1 || mirror_rc=$?
  expect "bootstrap=yes with the event name '$ev' completes green" 0 "$mirror_rc"
  expect "...creating the full taxonomy" \
    "$(core_label_rows | cut -d'|' -f1)" "$(exec_created)"
  expect "...and attempting all six retirements" 6 "$(exec_deleted)"
done

# -- unset is `no` at the direct-script boundary, whatever woke the run. The
#    composite always passes a value (its own validation runs first), so this
#    is the boundary where the default is the only answer.
for ev in - workflow_dispatch pull_request_target; do
  unset_rc=0
  exec_env - "$ev" >/dev/null 2>&1 || unset_rc=$?
  expect "an unset BOOTSTRAP on event '$ev' completes green" 0 "$unset_rc"
  expect "...and touches no label" "" "$(exec_created)$(sed -n 's/^delete //p' "$EXEC/record")"
done

# -- DRY_RUN mutates nothing through the EXECUTED path, under BOOTSTRAP=yes:
#    the sourced probe above drives bootstrap_labels directly, so only this
#    one proves the gate and the narration together.
dry_exec_rc=0
dry_exec_out="$(exec_env yes workflow_dispatch 1 2>&1)" || dry_exec_rc=$?
expect "a DRY_RUN bootstrap completes green" 0 "$dry_exec_rc"
expect "...narrating the upserts" yes \
  "$(grep -q '^labels: DRY_RUN: gh label create' <<<"$dry_exec_out" && echo yes || echo no)"
expect "...and recording no gh invocation whatsoever" "" "$(cat "$EXEC/record")"

# -- validate_bootstrap, in validate_auto_merge's shape (#472 D3). Empty is
#    asserted explicitly: it is the one case `-` rather than `:-` decides, and
#    a typo that silently selected "do not bootstrap" is this issue's subject.
for bad in Yes true "" "1" "on"; do
  bad_rc=0
  bad_out="$(exec_env "$bad" workflow_dispatch 2>&1)" || bad_rc=$?
  expect "BOOTSTRAP='$bad' exits 2" 2 "$bad_rc"
  expect "...with a message naming the accepted set" yes \
    "$(grep -q "bootstrap must be 'yes' or 'no'" <<<"$bad_out" && echo yes || echo no)"
  expect "...before any label write" "" "$(cat "$EXEC/record")"
done

# -- the gate's only reader is the input: no line of the action reads or
#    writes an event name any more (#472 D1, D2). Asserted on the tree rather
#    than in the PR body, because a body claim guards nothing.
expect "no line of the action mentions GITHUB_EVENT_NAME" "" \
  "$(git grep -n GITHUB_EVENT_NAME -- actions/labels-reconcile/ || true)"
# Assembled from two adjacent literals, not written whole: this file is inside
# the tree it greps, so a contiguous literal here would be its own only match.
# Tree-wide minus CHANGELOG.md alone: history is the one prose the census says
# is never edited, and a published section quoting the retired line would red
# this for a file no builder may touch. Subtracting that one file rather than
# allow-listing directories keeps every editable path — lib/, bin/, drill/,
# the role files — inside the guard.
event_log_literal="workflow_dispatch: ""bootstrapping"
expect "no log line attributes the bootstrap to the event name" "" \
  "$(git grep -nF "$event_log_literal" -- . ':(exclude)CHANGELOG.md' || true)"
# ...and no comment in the shipped surfaces still calls the bootstrap or its
# retirements dispatch-gated. The prose was false in both directions after
# D1 — a dispatch carrying bootstrap=no deletes nothing, and BOOTSTRAP=yes
# under any event deletes — so the phrase is retired from the action, the
# workflows and the docs, and asserted gone rather than merely fixed once.
# This file is outside the pathspec, which is why the literal can be written
# whole here.
expect "no shipped comment calls the bootstrap dispatch-gated" "" \
  "$(git grep -nF "dispatch-only" -- actions/ .github/ docs/ || true)"
# shellcheck disable=SC2016,SC2028 # action.yml literals, not expansions
expect "the composite runs the script bare, with no shell prologue" \
  'run: bash "$GITHUB_ACTION_PATH/labels-reconcile.sh"' \
  "$(awk '/^      run: bash /{sub(/^ +/, ""); print; exit}' actions/labels-reconcile/action.yml)"
# Twice: the validation step reads it to close the accepted set, and the
# reconcile step plumbs it to the script that now acts on it.
# shellcheck disable=SC2016 # an action.yml literal, not an expansion
expect "...while still plumbing BOOTSTRAP to the script" 2 \
  "$(grep -cF 'BOOTSTRAP: ${{ inputs.bootstrap }}' actions/labels-reconcile/action.yml)"
expect "...keeping its own validation step" yes \
  "$(grep -q 'name: validate bootstrap input' actions/labels-reconcile/action.yml \
    && echo yes || echo no)"
expect "...and the input's closed default" 1 \
  "$(awk '/^  bootstrap:/{seen=1} seen && /default: "no"/{print 1; exit}' \
    actions/labels-reconcile/action.yml)"
# -- a re-drafted fix round is not a build (#205) ----------------------------
# Draft used to short-circuit decide_state before the round was consulted, so
# a PR carrying a standing CHANGES_REQUESTED that its builder converted back
# to draft read state:building — and the staleness sweep read a dropped fix
# round as a build in progress.
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
MERGEABLE=MERGEABLE CHECKS=SUCCESS LABELS="" HEAD_SHA=head1
DRAFT=true REQUESTED="" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 no t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a re-drafted PR with a standing block is addressing, not building" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews "$(rev "$BOT1" COMMENTED head1 thoughts t1)")"
expect "a re-drafted PR owing a round-reply is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head0 ok t1)" \
  "$(rev "$BOT2" APPROVED head0 ok t2)" \
  "$(rev "$BOT3" APPROVED head0 ok t3)")"
expect "a re-drafted PR whose approvals a push staled is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 ok t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)" \
  "$(rev "$HUMAN" CHANGES_REQUESTED head1 no t4)")"
expect "the human's standing changes-requested outranks draft too" \
  state:addressing "$(decide_state)"
# Approvals do NOT outrank draft: a re-draft after a passed round is
# deliberately building again — and a draft must never read needs-human.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 ok t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a re-draft after a passed round is building again" \
  state:building "$(decide_state)"
REQUESTED="$HUMAN"
expect "...even with the human requested — a draft never reads needs-human" \
  state:building "$(decide_state)"
# Round 1's 224-case hole (claude's differential): a draft with a LIVE HUMAN
# REQUEST plus a standing block or comment fell through to round_state,
# whose human-request precedence sits above BLOCK/FEEDBACK — and read
# needs-human on a PR GitHub cannot merge. These are the same inputs as the
# addressing rows above with REQUESTED="$HUMAN", which is where the
# criterion can actually fail.
REQUESTED="$HUMAN" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 no t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a draft with a human request and a standing block is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 thoughts t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a draft with a human request and an owed reply is addressing" \
  state:addressing "$(decide_state)"

# The must-not-paper-over combination: a live panel request on a draft is a
# board defect (the bots ignore drafts by design) and stays VISIBLE as
# bots-reviewing rather than being absorbed into building.
REQUESTED="$BOT2" REVIEWS_JSON='[]'
expect "a live panel request on a draft surfaces as bots-reviewing" \
  state:bots-reviewing "$(decide_state)"
# The byte-identical baseline: a virgin draft still reads building.
REQUESTED="" REVIEWS_JSON='[]'
expect "a draft with no round history still reads building" \
  state:building "$(decide_state)"

# ---------------------------------------------------------------------------
# blocker:unrequested knows when the ask is permitted (#236). The blocker
# demands an act — request the panel — that BUILDER.md forbids under a head
# whose checks have not answered, so the predicate that flags the omission has
# to read CHECKS and has to let a round in motion finish moving. Two guards,
# each proved load-bearing by a mutation at the end of the block.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" MERGEABLE=MERGEABLE LABELS=""
NOW="$(date -d 2026-08-03T12:00:00Z +%s)"
# the genuine #26/#39 debt: three approvals of a head a push staled, nobody
# asked for the re-verdicts, and every fact hours old
OWED_QUIET_ROUND="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED oldhead "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED oldhead "" 2026-08-03T10:02:00Z)")"
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:00:00Z
CHECKS=SUCCESS
expect "green, quiescent, owed and unasked is the stall (the control)" \
  blocker:unrequested "$(blockers)"
# D1 — the gate. crew#318's shape: the same debt under a running check, where
# requesting is the one thing the builder must not do.
CHECKS=PENDING
expect "a pending head is CI's move, not a dropped ask" "" "$(blockers)"
CHECKS=FAILURE
expect "a red head raises ci-red alone — the two never co-occur" \
  blocker:ci-red "$(blockers)"
CHECKS=NONE
expect "no checks configured is nothing to wait for, so the stall still shows" \
  blocker:unrequested "$(blockers)"
# D2 — the grace. ceremony#235's shape: a sweep landing in the ~90 seconds
# between a round-answer push and the author's re-request.
CHECKS=SUCCESS HEAD_COMMIT_AT=2026-08-03T11:57:30Z
expect "a head pushed inside the grace is a round in motion, not a stall" \
  "" "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:55:00Z
expect "...and exactly at the grace it flags — the boundary is inclusive" \
  blocker:unrequested "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:50:00Z
expect "...and a later pass flags it with nothing else changed" \
  blocker:unrequested "$(blockers)"
# a verdict is the other supporting fact, and an old head does not license
# flagging a round whose newest verdict landed a minute ago
HEAD_COMMIT_AT=2026-08-03T10:00:00Z
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T11:59:00Z)")"
expect "a verdict submitted inside the grace is motion too" "" "$(blockers)"
# no verdicts at all is not an unreadable round — it is the first-ask stall,
# and the head's clock is the whole of it
REVIEWS_JSON='[]' HEAD_COMMIT_AT=2026-08-03T11:00:00Z
expect "nothing reviewed and nobody asked flags off the head's clock alone" \
  blocker:unrequested "$(blockers)"
# an unreadable fact never invents a verdict — the standing rule, applied to
# both timestamps
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=""
expect "an unread head date leaves the blocker unjudged" "" "$(blockers)"
HEAD_COMMIT_AT=null
expect "...and jq's literal null is unread, not epoch zero" "" "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED oldhead "" not-a-timestamp)")"
expect "a round whose newest verdict cannot be dated is unread, not quiescent" \
  "" "$(blockers)"
# the constant is overridable the way this file's others are
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:57:30Z
RECONCILE_UNREQUESTED_GRACE=60
expect "a shorter configured grace flags the same facts" \
  blocker:unrequested "$(blockers)"
RECONCILE_UNREQUESTED_GRACE=300

# the timestamp reader, directly: the three unreadable spellings it must refuse
expect "iso_epoch reads a real stamp" \
  "$(date -d 2026-08-03T12:00:00Z +%s)" "$(iso_epoch 2026-08-03T12:00:00Z)"
expect "iso_epoch refuses an absent stamp" "" "$(iso_epoch "")"
expect "iso_epoch refuses jq's null" "" "$(iso_epoch null)"
expect "iso_epoch refuses a stamp date cannot read" "" "$(iso_epoch not-a-timestamp)"
# ...and the trap it does NOT catch, recorded because a fixture author will
# reach for it: `t1` is a valid date to GNU date — 01:00 in military timezone T,
# on the day the suite runs — so it reads as a moving stamp rather than as an
# unreadable one. Real timestamps in any fixture the grace touches.
expect "a symbolic stamp is readable, and moves with the run's day" \
  "$(date -d t1 +%s)" "$(iso_epoch t1)"

# -- the mutation proofs: both guards are load-bearing, and this runs them ----
# A guard the fixtures cannot see removed is a guard nobody is testing, so each
# is deleted from a COPY of the script and the fixture that covers it must flip.
# The sed programs target one token each, so a refactor that moves a guard
# fails here loudly instead of passing silently.
mutant_blockers() { # $1 = sed program → blockers() from a copy of the script
  # The copy keeps its position in the tree — the script sources lib/ruling.sh
  # relative to its own path, and a copy dropped anywhere else would source
  # nothing and say so on stderr instead of failing.
  local root="$RTMP/mutant" mutated
  mutated="$root/actions/labels-reconcile/labels-reconcile.sh"
  mkdir -p "$root/actions/labels-reconcile"
  ln -sfn "$PWD/lib" "$root/lib"
  sed "$1" actions/labels-reconcile/labels-reconcile.sh >"$mutated"
  DRAFT="$DRAFT" HEAD_SHA="$HEAD_SHA" REQUESTED="$REQUESTED" \
    REVIEWS_JSON="$REVIEWS_JSON" MERGEABLE="$MERGEABLE" CHECKS="$CHECKS" \
    NOW="$NOW" HEAD_COMMIT_AT="$HEAD_COMMIT_AT" \
    RECONCILE_UNREQUESTED_GRACE="$RECONCILE_UNREQUESTED_GRACE" \
    bash -u -c '
      . "$1"
      load_config "$2"
      set_required_bots "$3"
      blockers
    ' bash "$mutated" "$FIXTURE_CONF" "$FIXTURE_AUTHOR"
}
# the harness itself, unmutated: it must reproduce the verdict the sourced
# functions give, or a "flip" below proves nothing about the guard
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:00:00Z CHECKS=SUCCESS
expect "the mutation harness reproduces the control verdict" \
  blocker:unrequested "$(mutant_blockers 's/^#no-such-line$//')"
CHECKS=PENDING
expect "...and the pending fixture is green in the unmutated copy" \
  "" "$(mutant_blockers 's/^#no-such-line$//')"
expect "removing the green gate reds the pending fixture" \
  blocker:unrequested \
  "$(mutant_blockers 's/checks_permit_the_ask=false/checks_permit_the_ask=true/')"
CHECKS=SUCCESS HEAD_COMMIT_AT=2026-08-03T11:57:30Z
expect "removing the grace reds the inside-the-window fixture" \
  blocker:unrequested \
  "$(mutant_blockers 's/ \&\& unrequested_quiescent//')"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z

# -- per-author panels (#224): the required set flows from the one ----------
#    resolution point, and convergence counts the effective set — never the
#    base panel beside a reduced request set (the must-fail the issue names)
PANEL_DIR="$RTMP/panel-author"
mkdir -p "$PANEL_DIR"
printf '%s\n' 'panel=bot-a bot-b bot-c bot-d' \
  'panel[builder-z]=bot-b bot-c bot-d' >"$PANEL_DIR/labels.conf"
load_config "$PANEL_DIR/labels.conf"
set_required_bots builder-z
expect "a bracketed author requires exactly its configured row" \
  "bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"
set_required_bots bot-a
expect "an unbracketed author beside a bracketed row requires panel minus self" \
  "bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"
set_required_bots outsider
expect "an unbracketed non-panelist author requires the whole base panel" \
  "bot-a bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"

# The engine shape: the three configured reviewers approving the head IS the
# whole round for a bracketed author — bot-a's absent verdict must not hold
# convergence, or the request side and the convergence side disagree forever
# (the deadlock crew#285 was filed over).
set_required_bots builder-z
THREE_APPROVE="$(reviews \
  "$(rev bot-b APPROVED head1 ok 2026-08-02T10:00:00Z)" \
  "$(rev bot-c APPROVED head1 ok 2026-08-02T10:01:00Z)" \
  "$(rev bot-d APPROVED head1 ok 2026-08-02T10:02:00Z)")"
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$THREE_APPROVE" \
  MERGEABLE=MERGEABLE CHECKS=SUCCESS LABELS=""
expect "the bracketed author's round converges on its three approvals" \
  state:needs-human "$(decide_state)"
expect "...with no blocker standing" "" "$(blockers)"
# The control: the same three approvals under the base panel are NOT a full
# round — the fourth verdict is owed and unrequested. If this pair ever
# reads the same, one side stopped consulting the resolution point.
printf '%s\n' 'panel=bot-a bot-b bot-c bot-d' >"$PANEL_DIR/labels.conf"
load_config "$PANEL_DIR/labels.conf"
set_required_bots builder-z
expect "without the row the same approvals leave the round incomplete" \
  state:addressing "$(decide_state)"
expect "...and the owed, unasked verdict is named" \
  blocker:unrequested "$(blockers)"

# -- the shipped roster, as a property rather than a slot (#304 D2) ----------
# The one case that reads the real .github/labels.conf, and it asserts only
# what that file can honestly prove here: it parses, and recusal removes the
# author from whatever it names. No index, no expected size — the panel is the
# operator's to resize (D3), and the fixtures above no longer care. What this
# does catch is a shipped conf that stopped parsing, which must never be
# reported as a green suite.
#
# The probe runs in a subshell so a refusal cannot leave this file's globals
# half-loaded, and it quantifies over every member rather than sampling one:
# there is no member whose recusal is special. load_config's stderr is dropped
# because the exit status is the assertion; the broken-conf case below would
# otherwise print its (correct) complaint into a passing run.
live_panel_probe() { # $1 = conf → PARSE:<rc> [RECUSED:<yes|no> SHRANK:<yes|no>]
  bash -u -c '
    . actions/labels-reconcile/labels-reconcile.sh
    rc=0
    load_config "$1" 2>/dev/null || rc=$?
    printf "PARSE:%s" "$rc"
    [ "$rc" -eq 0 ] || { printf "\n"; exit 0; }
    recused=yes shrank=yes
    for author in "${BOTS[@]}"; do
      set_required_bots "$author"
      for bot in ${REQUIRED_BOTS[@]+"${REQUIRED_BOTS[@]}"}; do
        [ "$bot" != "$author" ] || recused=no
      done
      [ "${#REQUIRED_BOTS[@]}" -eq "$((${#BOTS[@]} - 1))" ] || shrank=no
    done
    printf " RECUSED:%s SHRANK:%s\n" "$recused" "$shrank"
  ' bash "$1"
}
expect "the shipped labels.conf parses, and recuses each member from its own panel" \
  "PARSE:0 RECUSED:yes SHRANK:yes" "$(live_panel_probe .github/labels.conf)"
# ...and the teeth: the same probe on a copy whose panel= line names nobody.
# A roster edit that empties the line is the shape this catches — the file
# still looks like a conf, and every panel in the repo would resolve to
# nothing.
BROKEN_CONF="$RTMP/broken-labels.conf"
sed 's/^panel=.*/panel=/' .github/labels.conf >"$BROKEN_CONF"
expect "...and a malformed panel= line in that same file is refused, not passed" \
  PARSE:1 "$(live_panel_probe "$BROKEN_CONF")"

# ---------------------------------------------------------------------------
# rerun-owed — the red head nobody in the fleet can rerun (#423). A fork PR's
# `pull_request` run lives in the BASE repo, so restarting it needs
# `actions: write` there, which no fleet identity holds; GitHub answers the
# permission miss with 404 on both rerun endpoints. `blocker:ci-red` says the
# builder owes a fix, and on that head every word of it is false.
#
# The label is hand-set with its evidence and machine-cleared, which is the
# contract these fixtures hold in both directions: the suppression must be
# exactly as wide as the label, and the label must not outlive its head.
# ---------------------------------------------------------------------------
# The panel blocks above leave a foreign roster loaded, and a round read
# against it comes out MISSING — which reads as state:addressing and would have
# made several of these assertions pass for the wrong reason. Restore the
# fixture roster first, the way the #205 block does for the same reason.
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
# The heads this block moves between. Real SHAs, not the symbolic `head1` the
# rest of this file uses, because one of the cases below is an ABBREVIATED head
# in the evidence — and `head` is a prefix of `head1`, so a symbolic name would
# make that case pass for a reason no real PR has.
RERUN_HEAD=04843457bd88c326156e4b7fc9e6fe9e98007c95   # the head the evidence names
RERUN_HEAD_NEW=9f2c1d7e6a5b4c3d2e1f0a9b8c7d6e5f40312233  # a push that lands after it
RERUN_HEAD_OLD=1b6d0f3a2c4e5d7f8091a2b3c4d5e6f708192a3b  # ...and a reset BACK to an older one

rerun_reviews() { # $1 = head → a whole panel approving exactly that head
  reviews "$(rev "$BOT1" APPROVED "$1" "" t1)" \
    "$(rev "$BOT2" APPROVED "$1" "" t2)" \
    "$(rev "$BOT3" APPROVED "$1" "" t3)"
}

DRAFT=false HEAD_SHA="$RERUN_HEAD" REQUESTED="" MERGEABLE=MERGEABLE NOW="$RNOW"
REVIEWS_JSON="$(rerun_reviews "$RERUN_HEAD")"
RERUN_OWED_HEAD="$RERUN_HEAD"
# The head commit's date is a lie in every case below, and no case may notice.
# A commit's committer date is a field its author writes: an earlier draft of
# this decided "the head moved" by comparing it with the flag's own `labeled`
# event, which discarded a valid label under clock skew and kept a stale one
# after a reset onto an older commit. Ten years in the future here, and an
# ancient date on the reset case, are what pin that the clock is gone.
HEAD_COMMIT_AT="$(iso_at $((RNOW + 315360000)))"

# -- the bound, first: an ordinary red head is unchanged in every respect ----
# This is the case the issue says must NOT move. If the amended machine ever
# lets a red head with no evidenced label off the builder's plate, it is wrong,
# and this block is where that shows.
LABELS="" CHECKS=FAILURE
expect "with no label the class does not exist" ABSENT "$(rerun_owed_state)"
expect "...an ordinary red head still raises ci-red" blocker:ci-red "$(blockers)"
expect "...and is still the builder's ball, approvals notwithstanding" \
  state:addressing "$(decide_state)"

# -- the label suppresses the blocker, and nothing else does -----------------
LABELS=rerun-owed
expect "an evidenced unrerunnable head stands under the label" STANDS \
  "$(rerun_owed_state)"
expect "...and blocker:ci-red is not asserted there" "" "$(blockers)"
expect "...while the state stays the builder-or-human question, never merge-me" \
  state:addressing "$(decide_state)"
# the other direction, same head, same facts — the label is the whole delta
LABELS=""
expect "the same head with the label removed carries the blocker again" \
  blocker:ci-red "$(blockers)"

# -- it clears when the head's checks leave FAILURE --------------------------
LABELS=rerun-owed CHECKS=SUCCESS
expect "a head that went green owes no rerun" CLEARED "$(rerun_owed_state)"
CHECKS=NONE
expect "...nor does one with no checks configured" CLEARED "$(rerun_owed_state)"
CHECKS=PENDING
expect "...nor one whose checks are running again" CLEARED "$(rerun_owed_state)"

# -- and when the head moves out from under the evidence ---------------------
# The push that reds again is the only case the first test cannot reach: the
# label would otherwise suppress a blocker for a failure nobody has evidenced.
# "Moved" is IDENTITY here — is the evidenced head still the head — so both
# directions of a move are the same question, and the second one is the reset
# that the committer-date test used to get wrong.
CHECKS=FAILURE HEAD_SHA="$RERUN_HEAD_NEW" REVIEWS_JSON="$(rerun_reviews "$RERUN_HEAD_NEW")"
expect "a head that is not the evidenced one is a new question" CLEARED \
  "$(rerun_owed_state)"
expect "...and the blocker returns in the SAME pass that clears the label" \
  blocker:ci-red "$(blockers)"
HEAD_SHA="$RERUN_HEAD_OLD" REVIEWS_JSON="$(rerun_reviews "$RERUN_HEAD_OLD")"
HEAD_COMMIT_AT="$(iso_at $((RNOW - 315360000)))"
expect "a RESET onto an older commit moved the head too" CLEARED \
  "$(rerun_owed_state)"
expect "...and that head is red with nobody's evidence on it" blocker:ci-red \
  "$(blockers)"
# ...and the case the clock got wrong in the other direction: the head has not
# moved, and no date its commit carries may say otherwise.
HEAD_SHA="$RERUN_HEAD" REVIEWS_JSON="$(rerun_reviews "$RERUN_HEAD")"
HEAD_COMMIT_AT="$(iso_at $((RNOW + 315360000)))"
expect "an unmoved head stands whatever date its commit claims" STANDS \
  "$(rerun_owed_state)"
HEAD_COMMIT_AT=""
expect "...and stands with no date read at all" STANDS "$(rerun_owed_state)"
HEAD_COMMIT_AT="$(iso_at $((RNOW + 315360000)))"
# an abbreviated head in the evidence names this head as surely as a whole one
RERUN_OWED_HEAD=0484345
expect "an abbreviated evidenced head is still this head" STANDS \
  "$(rerun_owed_state)"
RERUN_OWED_HEAD=9f2c1d7
expect "...and an abbreviation of ANOTHER head still moved it" CLEARED \
  "$(rerun_owed_state)"
RERUN_OWED_HEAD="$RERUN_HEAD"

# -- an unreadable fact never clears a label somebody evidenced --------------
# The standing rule of this file, applied in the direction that costs least: a
# label wrongly kept asks a human to look at a PR that is fine; a label wrongly
# cleared tells a builder to fix a tree that is not broken.
RERUN_OWED_HEAD=""
expect "evidence naming no head leaves the moved-head test unjudged" STANDS \
  "$(rerun_owed_state)"
RERUN_OWED_HEAD="$RERUN_HEAD_OLD" HEAD_SHA=""
expect "...and an unread head SHA is not a differing one" STANDS \
  "$(rerun_owed_state)"
HEAD_SHA="$RERUN_HEAD" RERUN_OWED_HEAD="$RERUN_HEAD"
# ...and the whole way through, from evidence to verdict: a builder who names a
# second head unreadably has superseded the first, so the pair names no head
# and the label stands. The parse is asserted on its own below; this is the
# consequence the label cares about, and it is what the two would-be-cleared
# heads make interesting — neither the old marker's head nor a readable new one
# may be what the state decides on.
RERUN_OWED_HEAD="$(printf '%s\n%s\n' "${RERUN_OWED_MARKER}${RERUN_HEAD_OLD}" \
  "${RERUN_OWED_MARKER}not-a-sha" | rerun_owed_named_head)"
expect "an older marker superseded unreadably leaves the label standing" STANDS \
  "$(rerun_owed_state)"
RERUN_OWED_HEAD="$RERUN_HEAD"

# -- the evidence parse, driven rather than read -----------------------------
# What the sweep hands this function is one line per comment BY THE PR AUTHOR,
# already reduced to its first line: a marker is how a comment declares itself,
# so a SHA quoted mid-prose is prose. Newest wins, the order the comments API
# returns.
expect "a bare marker names its head" "$RERUN_HEAD" \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}${RERUN_HEAD}")"
expect "...backticked, as this repo writes a SHA" "$RERUN_HEAD" \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}\`$RERUN_HEAD\` — actions/rerun 404s")"
expect "...abbreviated, at git's own floor of seven" 0484345 \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}0484345.")"
expect "...upper-case, as a paste from a UI can be" "$RERUN_HEAD" \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}04843457BD88C326156E4B7FC9E6FE9E98007C95")"
expect "the newest marker is the one that counts" "$RERUN_HEAD_NEW" \
  "$(printf '%s\n%s\n' "${RERUN_OWED_MARKER}${RERUN_HEAD}" \
    "${RERUN_OWED_MARKER}${RERUN_HEAD_NEW}" | rerun_owed_named_head)"
# ...including when the newest names no readable head: it supersedes anyway, so
# the pair reads as UNJUDGED and the label stands. An older marker surviving a
# newer unreadable one would clear a live label on a head nobody currently
# names, which is the one direction this parse may not take.
expect "a newer unreadable marker supersedes an older valid one" "" \
  "$(printf '%s\n%s\n' "${RERUN_OWED_MARKER}${RERUN_HEAD}" \
    "${RERUN_OWED_MARKER}not-a-sha" | rerun_owed_named_head)"
expect "...and so does a newer one whose head is too short" "" \
  "$(printf '%s\n%s\n' "${RERUN_OWED_MARKER}${RERUN_HEAD}" \
    "${RERUN_OWED_MARKER}048434" | rerun_owed_named_head)"
expect "a comment that is not the marker names nothing" "" \
  "$(printf '%s\n' "🔨 Worklog — the rerun 404s at $RERUN_HEAD" | rerun_owed_named_head)"
# ...and the same, in the two shapes that would name a head if the marker were
# read loosely: a line that merely OPENS with a SHA, and the marker quoted
# inside a sentence. A builder's other comments are full of both.
expect "...nor a line that merely opens with a SHA" "" \
  "$(rerun_owed_named_head <<<"$RERUN_HEAD is red and both rerun endpoints 404")"
expect "...nor the marker quoted inside a sentence" "" \
  "$(rerun_owed_named_head <<<"I posted ${RERUN_OWED_MARKER}${RERUN_HEAD} an hour ago")"
expect "...nor does a marker with too short a head" "" \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}048434")"
expect "...nor one whose head is not hex at all" "" \
  "$(rerun_owed_named_head <<<"${RERUN_OWED_MARKER}the head above")"
expect "...nor one naming no head whatsoever" "" \
  "$(rerun_owed_named_head <<<"$RERUN_OWED_MARKER")"
expect "no comments at all name no head" "" "$(rerun_owed_named_head </dev/null)"

# -- must fail: rerun-owed reaching the blocker set, by any of its three doors
# The array itself. Read from the shipped array rather than a hand-listed copy,
# so a later edit that adds the name is what reds this.
expect "rerun-owed is not in BLOCKERS" no \
  "$(printf '%s\n' "${BLOCKERS[@]}" | grep -qxF rerun-owed && echo yes || echo no)"
expect "...and the taxonomy the action writes still ships its row" yes \
  "$(core_label_rows | cut -d'|' -f1 | grep -qxF rerun-owed && echo yes || echo no)"
# needs-human's refusal set. The label alone must disqualify nothing — a label
# that stops a handoff is acting as a blocker, and this one is not one. What
# refuses the handoff is the RED HEAD, which refused it before this label
# existed and refuses it identically now.
LABELS=rerun-owed CHECKS=SUCCESS
expect "the label alone never takes a green passed round off the human" \
  state:needs-human "$(decide_state)"
LABELS="rerun-owed
blocked"
expect "...while the labels that ARE refusals still refuse" state:addressing \
  "$(decide_state)"
# the zero-delta claim for decide_state's new FAILURE clause: on every PR
# without the label the answer is what the blocker used to produce
LABELS="" CHECKS=FAILURE
expect "a red head refuses needs-human with no label in sight" state:addressing \
  "$(decide_state)"
# the take-back predicate. Its set is blockers(), so the suppressed case
# reports nothing — the same silence needs-ruling and blocked already get,
# because the visible label is the why.
LABELS="state:needs-human
rerun-owed"
expect "the suppressed take-back names no blocker" "" "$(handoff_taken_back)"
LABELS=state:needs-human
expect "...while the unlabelled one still names ci-red (control)" blocker:ci-red \
  "$(handoff_taken_back)"

# -- and through the whole of reconcile_pr, where the edit is the deliverable
# The pure functions above say what the pass should decide; these say what it
# WRITES. One edit call either way: the clear and the blocker that returns with
# it are one transition, and a board that showed neither for a moment would be
# the same lie by another route.
RERUN_OWED_HEAD=tbhead0
moved="$(takeback_probe 120 "state:needs-human
rerun-owed" tbhead1 approve FAILURE)"
expect "a head the evidence does not name clears the label" yes \
  "$(grep -q -- '--remove-label state:needs-human,rerun-owed' "$TB/edits-120" \
    && echo yes || echo no)"
expect "...and raises the blocker in the same call" yes \
  "$(grep -q -- '--add-label state:addressing,blocker:ci-red' "$TB/edits-120" \
    && echo yes || echo no)"
expect "...which is exactly one call, not two passes" 1 "$(edit_count 120)"
expect "...logged as the transition it is" yes \
  "$(grep -q 'cleared state:needs-human,rerun-owed' <<<"$moved" && echo yes || echo no)"
RERUN_OWED_HEAD=tbhead1
standing="$(takeback_probe 121 "state:needs-human
rerun-owed" tbhead1 approve FAILURE)"
expect "a standing flag keeps its label through the pass" no \
  "$(grep -q -- 'rerun-owed' "$TB/edits-121" && echo yes || echo no)"
expect "...takes the false merge-me claim back anyway" yes \
  "$(grep -q 'state -> state:addressing' <<<"$standing" && echo yes || echo no)"
expect "...raising no blocker while it stands" no \
  "$(grep -q -- 'blocker:ci-red' "$TB/edits-121" && echo yes || echo no)"
expect "...and says nothing, because the label already says it" 0 \
  "$(posted_count 121)"
LABELS="" HEAD_COMMIT_AT=2026-08-03T11:00:00Z RERUN_OWED_HEAD=""

# ---------------------------------------------------------------------------
# The merge itself (#460): head-pinned, confirmed, and through run().
#
# The seam is run(): every mutation in this file already passes through it, so
# what a fixture must pin is WHAT CROSSES IT. That recording is done in the gh
# stub rather than in a run() override, and the choice is the point rather than
# a convenience. run() is the unit under test here — `DRY_RUN=1` narrating
# instead of doing is one of this issue's acceptance criteria — so a fixture
# that replaced run() with its own recorder would have to re-implement the
# DRY_RUN branch, and would then pass identically whether the shipped run()
# still honoured it or not. Worse, it would blind the must-fail case that costs
# the most: a merge written OUTSIDE run() executes under DRY_RUN, and DRY_RUN=1
# is how this script is rehearsed against this live repository (:30) — by hand
# today, and a reviewer of this very PR ran exactly that rehearsal against this
# repository twice. Leaving the shipped run() in place and recording at the gh
# boundary makes that case red — the merge reaches the stub on a pass that must
# record nothing.
#
# The roster is re-loaded first: this block sits at the file's tail, where the
# panel probes above have left load_config pointed at their own confs, and
# is_fleet_login — the verdict's author test — reads exactly those arrays.
# ---------------------------------------------------------------------------
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
AM="$RTMP/automerge"
mkdir -p "$AM"

am_pull_json() { # $1 head sha, $2 state, $3 labels as a JSON array → the confirmation read's body
  jq -n --arg h "$1" --arg s "$2" --argjson l "$3" \
    '{state: $s, head: {sha: $h}, labels: $l}'
}

am_probe() { # $1 PR, $2 AUTO_MERGE, $3 confirmed head, $4 confirmed state, $5 confirmed labels JSON, $6 merge rc, $7 dry run
             # #461 adds four, all optional, so every call above stays a call:
             # $8 POST_MERGE_WORKFLOW (empty = the shipped default),
             # $9 dispatch rc, ${10} REQUESTED, ${11} round shape —
             # "block" swaps one approval for a change-request, which is how a
             # SKIP:state pass is BOUGHT from decide_state rather than asserted.
             # #468 adds $12 AUTO_MERGE_RELEASE, $13 RELEASE_WORKFLOW and
             # $14 the labels graded by this pass.
  (
    local n="$1" at
    at="$(iso_at $((RNOW - 3600)))"
    REPO_LABELS="$(printf '%s\n' "${STATES[@]}" "${BLOCKERS[@]}" \
      merge-next stale needs-ruling blocked)"
    REPO=owner/repo NOW="$RNOW"
    AUTO_MERGE="$2"
    AUTO_MERGE_RELEASE="${12:-off}"
    RELEASE_WORKFLOW="${13:-}"
    # A fleet login, so #459's author refusal is not what is being measured.
    AUTHOR="$FIXTURE_AUTHOR"
    # The needs-human fixture: three head-current approvals, mergeable, green,
    # nothing excluded. decide_state's conclusion is the trigger (D2), so the
    # fixture buys it honestly rather than hand-setting the label.
    LABELS="${14:-}" DRAFT=false HEAD_SHA=amhead1 REQUESTED="${10:-}"
    MERGEABLE=MERGEABLE CHECKS=SUCCESS HEAD_COMMIT_AT="$at"
    if [ "${11:-}" = block ]; then
      REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" CHANGES_REQUESTED amhead1 "" "$at")" \
        "$(rev "$BOT2" APPROVED amhead1 "" "$at")" \
        "$(rev "$BOT3" APPROVED amhead1 "" "$at")")"
    else
      REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" APPROVED amhead1 "" "$at")" \
        "$(rev "$BOT2" APPROVED amhead1 "" "$at")" \
        "$(rev "$BOT3" APPROVED amhead1 "" "$at")")"
    fi
    PR_JSON="$(jq -n --arg at "$at" '{created_at: $at, assignees: []}')"
    AM_CONFIRM="$(am_pull_json "$3" "$4" "$5")"
    AM_MERGE_RC="$6"
    POST_MERGE_WORKFLOW="${8:-}"
    AM_DISPATCH_RC="${9:-0}"
    [ -z "${7:-}" ] || DRY_RUN=1
    # human_request_needed is COUNTED, not re-implemented: D7's second
    # criterion is that reaching the recorded fact costs no second evaluation,
    # and a count is the only thing that can see a re-evaluation added further
    # down the function. The original is renamed rather than copied so the
    # wrapper cannot drift from the guard it wraps.
    eval "am_orig_human_request_needed() $(declare -f human_request_needed | tail -n +2)"
    human_request_needed() {
      printf 'called\n' >>"$AM/hrn-$n"
      am_orig_human_request_needed
    }
    # NOT overridden: run() is the unit under test (see this block's header).
    gh() {
      # The whole invocation list, verbatim and in order — what D7's
      # no-second-read criterion is graded on. A count of `requested_reviewers`
      # lines cannot be forged by a read that happens to return the right
      # answer, which is why the assertion is on the calls and not the outcome.
      printf '%s\n' "$*" >>"$AM/calls-$n"
      if [ "$1" = workflow ] && [ "$2" = run ]; then
        printf '%s\n' "$*" >>"$AM/dispatch-$n"
        [ "$AM_DISPATCH_RC" = 0 ] || {
          # multi-line, like the merge stub: read_failure_reason's collapse is
          # what stops one PR's dispatch error forging another PR's log line
          printf 'could not find any workflows named %s\nHTTP 404: Not Found\n' "$3" >&2
          return "$AM_DISPATCH_RC"
        }
        return 0
      fi
      if [ "$1" = api ]; then
        shift
        local jqexpr="" endpoint=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        # The confirmation read, and only it: every other endpoint the pass
        # touches degrades to an empty collection the way the sibling probes
        # above serve theirs.
        if [ "$endpoint" = "repos/$REPO/pulls/$n" ]; then
          printf '%s\n' "$AM_CONFIRM" | jq -r "${jqexpr:-.}"
        else
          printf '[]\n' | jq -r "${jqexpr:-.}"
        fi
        return 0
      elif [ "$1" = pr ] && [ "$2" = merge ]; then
        # the recorded argv, verbatim — the assertion is on what was called,
        # never on a count of calls
        printf '%s\n' "$*" >>"$AM/merges-$n"
        [ "$AM_MERGE_RC" = 0 ] || {
          # multi-line on purpose: D5 reuses read_failure_reason's collapse so
          # a merge error cannot forge a second log line for another PR
          printf 'failed to merge: Base branch was modified.\nReview and try the merge again.\n' >&2
          return "$AM_MERGE_RC"
        }
        return 0
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local body=""
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$AM/posted-$n"
        return 0
      fi
      return 0
    }
    reconcile_pr "$n" 2>&1
  )
}

am_merges() { # $1 PR → merge invocations recorded
  [ -f "$AM/merges-$1" ] || { echo 0; return; }
  wc -l <"$AM/merges-$1" | tr -d ' '
}
am_posts() { # $1 PR → auto-merge comments recorded
  [ -f "$AM/posted-$1" ] || { echo 0; return; }
  grep -cF "$AUTO_MERGED_MARKER" "$AM/posted-$1" || true
}
NO_LABELS='[]'

# -- off merges nothing. The fixture satisfies every other condition, so what
#    is measured is the toggle and nothing else.
am_off="$(am_probe 900 off amhead1 open "$NO_LABELS" 0)"
expect "toggle off records no merge invocation" 0 "$(am_merges 900)"
expect "...and posts no comment" 0 "$(am_posts 900)"
expect "...and still says nothing about auto-merge at all" no \
  "$(grep -q 'auto-merge' <<<"$am_off" && echo yes || echo no)"
expect "...while the pass it rode did its ordinary work (control)" yes \
  "$(grep -q 'state -> state:needs-human' <<<"$am_off" && echo yes || echo no)"

# -- a MERGE verdict records exactly one merge, carrying the method flag and
#    the head this pass graded. The argv, not the count, is the assertion.
am_on="$(am_probe 901 merge amhead1 open "$NO_LABELS" 0)"
expect "a MERGE verdict records exactly one merge invocation" 1 "$(am_merges 901)"
expect "...whose argv pins the graded head" \
  "pr merge 901 -R owner/repo --merge --match-head-commit amhead1" \
  "$(cat "$AM/merges-901")"
expect "...and the verdict that authorised it is logged" yes \
  "$(grep -q '#901: auto-merge\[ordinary\]: MERGE' <<<"$am_on" && echo yes || echo no)"
expect "...and the merge is logged as done, naming head and method" yes \
  "$(grep -q '#901: auto-merged amhead1 (merge) — commented' <<<"$am_on" && echo yes || echo no)"

# -- the method is AUTO_MERGE's value, not a constant
am_probe 902 squash amhead1 open "$NO_LABELS" 0 >/dev/null
expect "squash mode merges with --squash" \
  "pr merge 902 -R owner/repo --squash --match-head-commit amhead1" \
  "$(cat "$AM/merges-902")"
am_probe 903 rebase amhead1 open "$NO_LABELS" 0 >/dev/null
expect "rebase mode merges with --rebase" \
  "pr merge 903 -R owner/repo --rebase --match-head-commit amhead1" \
  "$(cat "$AM/merges-903")"

# -- neither flag that would change what the merge MEANS is ever passed.
#    --auto arms GitHub's own auto-merge (option A, needing branch protection
#    nobody has); --delete-branch deletes a fork branch that is not ours.
expect "the merge never arms GitHub's own auto-merge" no \
  "$(grep -q -- '--auto' "$AM/merges-901" && echo yes || echo no)"
expect "...and never deletes the branch" no \
  "$(grep -q -- '--delete-branch' "$AM/merges-901" && echo yes || echo no)"

# -- THE TWO-LOCK PROPERTY, which is why this issue exists. The pass graded
#    amhead1; a builder pushed amhead2 in the seconds since. Nothing merges.
am_moved="$(am_probe 904 merge amhead2 open "$NO_LABELS" 0)"
expect "a head moved since the grading records no merge at all" 0 "$(am_merges 904)"
expect "...and posts nothing" 0 "$(am_posts 904)"
expect "...and says so on one line naming the PR and both heads" yes \
  "$(grep -q '#904: auto-merge refused: the head moved since this pass graded it (graded amhead1, now amhead2)' \
    <<<"$am_moved" && echo yes || echo no)"
expect "...on exactly one line" 1 \
  "$(grep -c 'auto-merge refused' <<<"$am_moved")"

# -- the confirmation's other two refusals: a PR that closed under the pass,
#    and a release label that arrived after the grading (#459 refuses one
#    present at grading time, so a re-read carrying it is by construction new).
am_closed="$(am_probe 905 merge amhead1 closed "$NO_LABELS" 0)"
expect "a PR that closed since the grading records no merge" 0 "$(am_merges 905)"
expect "...naming the state it is in now" yes \
  "$(grep -q '#905: auto-merge refused: the PR is no longer open (state: closed)' \
    <<<"$am_closed" && echo yes || echo no)"
am_release="$(am_probe 906 merge amhead1 open '[{"name":"release"}]' 0)"
expect "a release label arriving after the grading records no merge" 0 "$(am_merges 906)"
expect "...naming what appeared" yes \
  "$(grep -q '#906: auto-merge refused: release appeared on the PR since this pass graded it' \
    <<<"$am_release" && echo yes || echo no)"

am_dispatches() { # $1 PR -> workflow dispatch invocations recorded
  [ -f "$AM/dispatch-$1" ] || { echo 0; return; }
  wc -l <"$AM/dispatch-$1" | tr -d ' '
}

# -- #468's disjoint selector. The four corners differ only in the two toggle
# values and the graded release label; every merging argv is asserted.
am_probe 960 merge amhead1 open "$NO_LABELS" 0 "" "" 0 "" "" off "" "" >/dev/null
expect "auto_merge on / release toggle off merges a non-release PR" \
  "pr merge 960 -R owner/repo --merge --match-head-commit amhead1" \
  "$(cat "$AM/merges-960")"
am_corner_release_off="$(am_probe 961 merge amhead1 open '[{"name":"release"}]' 0 "" "" 0 "" "" off release.yml release)"
expect "auto_merge on / release toggle off refuses a release PR" 0 "$(am_merges 961)"
expect "...and records no release dispatch" 0 "$(am_dispatches 961)"
expect "...on the release-labelled log path" yes \
  "$(grep -q '#961: auto-merge\[release\]: SKIP:off' <<<"$am_corner_release_off" && echo yes || echo no)"
am_probe 962 off amhead1 open "$NO_LABELS" 0 "" "" 0 "" "" merge release.yml "" >/dev/null
expect "auto_merge off / release toggle on refuses a non-release PR" 0 "$(am_merges 962)"
am_probe 963 off amhead1 open '[{"name":"release"}]' 0 "" "" 0 "" "" merge release.yml release >/dev/null
expect "auto_merge off / release toggle on merges a release PR" \
  "pr merge 963 -R owner/repo --merge --match-head-commit amhead1" \
  "$(cat "$AM/merges-963")"
expect "...and dispatches the release caller with the graded head" \
  "workflow run release.yml -R owner/repo -f merged-sha=amhead1" \
  "$(cat "$AM/dispatch-963")"
expect "...and its provenance names the release toggle and dispatch input" yes \
  "$(grep -qF 'auto_merge_release=merge' "$AM/posted-963" \
    && grep -qF 'release.yml' "$AM/posted-963" \
    && grep -qF 'merged-sha=amhead1' "$AM/posted-963" && echo yes || echo no)"

am_release_no_dispatch="$(am_probe 964 off amhead1 open '[{"name":"release"}]' 0 "" "" 0 "" "" merge "" release)"
expect "a release toggle with no dispatch configured records no merge" 0 "$(am_merges 964)"
expect "...and records no release dispatch" 0 "$(am_dispatches 964)"
expect "...and logs the dedicated refusal" yes \
  "$(grep -q '#964: auto-merge\[release\]: SKIP:no-release-dispatch' <<<"$am_release_no_dispatch" && echo yes || echo no)"

am_release_disappeared="$(am_probe 965 off amhead1 open "$NO_LABELS" 0 "" "" 0 "" "" squash release.yml release)"
expect "a release label disappearing after grading records no merge" 0 "$(am_merges 965)"
expect "...and records no release dispatch" 0 "$(am_dispatches 965)"
expect "...and names the symmetric confirmation refusal" yes \
  "$(grep -q '#965: auto-merge refused: release disappeared on the PR since this pass graded it' \
    <<<"$am_release_disappeared" && echo yes || echo no)"

am_release_dry="$(am_probe 966 off amhead1 open '[{"name":"release"}]' 0 dry "" 0 "" "" rebase release.yml release)"
expect "a release DRY_RUN mutates neither merge nor dispatch" "0 0" \
  "$(am_merges 966) $([ -f "$AM/dispatch-966" ] && wc -l <"$AM/dispatch-966" | tr -d ' ' || echo 0)"
expect "...and narrates both exact mutations" yes \
  "$(grep -q 'DRY_RUN: gh pr merge 966 -R owner/repo --rebase --match-head-commit amhead1' <<<"$am_release_dry" \
    && grep -q 'DRY_RUN: gh workflow run release.yml -R owner/repo -f merged-sha=amhead1' <<<"$am_release_dry" \
    && echo yes || echo no)"

# -- a refused merge is loud, local and non-fatal (D5)
am_fail="$(am_probe 907 merge amhead1 open "$NO_LABELS" 1)"
am_fail_rc=0
am_probe 908 merge amhead1 open "$NO_LABELS" 1 >/dev/null || am_fail_rc=$?
expect "a merge GitHub refused posts NO comment" 0 "$(am_posts 907)"
expect "...is attempted exactly once — never retried in the same pass" 1 \
  "$(am_merges 907)"
expect "...logs its reason on exactly one line" 1 \
  "$(grep -c 'auto-merge refused' <<<"$am_fail")"
expect "...carrying gh's own words, collapsed to that one line" yes \
  "$(grep -q '#907: auto-merge refused: failed to merge: Base branch was modified. Review and try the merge again.' \
    <<<"$am_fail" && echo yes || echo no)"
expect "...and never fails the PR's reconcile, so the sweep loop continues" 0 \
  "$am_fail_rc"

# -- reconcile_pr is re-enterable after a refusal: a fresh PR reconciles and
#    merges. This says nothing about the LOOP — every am_probe call is its own
#    invocation — and the criterion asks for the next PR in the same run,
#    which the sweep case below is the evidence for.
am_next="$(am_probe 909 merge amhead1 open "$NO_LABELS" 0)"
expect "a PR reconciled after a refused merge converges normally" yes \
  "$(grep -q 'state -> state:needs-human' <<<"$am_next" && echo yes || echo no)"
expect "...and merges" 1 "$(am_merges 909)"

# -- THE CONTINUATION, at the boundary the criterion names: ONE main() sweep
#    carrying two PRs, the first of which GitHub refuses to merge. D5's
#    "the loop continues with the remaining PRs" is a property of main's
#    per-PR error handling, and nothing above can see it: the probes call
#    reconcile_pr directly, one PR per invocation, so a regression that
#    abandoned the sweep after a refused merge — an unguarded `|| return`,
#    a `set -e` reaching the loop body — would leave every one of them green
#    while the board silently stopped being swept after its first bad merge.
#    Round 1, codex-bot-andresmgsl.
#
#    The stubs here are the sweep's whole feed, on the pattern the main()
#    probes above use: main fetches the PR itself, so the confirmation read
#    (D3) and that fetch share one endpoint, which is what an open PR at the
#    graded head looks like to both.
am_sweep_probe() { # $1 = the first PR's merge rc; the second always succeeds
                   # #461 adds two, both optional: $2 POST_MERGE_WORKFLOW and
                   # $3 the FIRST PR's dispatch rc — the second always
                   # dispatches cleanly, which is what makes the continuation
                   # after a failed dispatch visible.
                   # #468 adds $4=mixed: PR 920 is a release governed by
                   # auto_merge_release=squash and PR 921 is ordinary/merge.
  (
    BOOTSTRAP=no
    REPO=owner/repo
    LABELS_CONF="$FIXTURE_CONF"
    AUTO_MERGE=merge
    AUTO_MERGE_RELEASE=off
    RELEASE_WORKFLOW=""
    AM_FIRST_RC="$1"
    POST_MERGE_WORKFLOW="${2:-}"
    AM_FIRST_DISPATCH_RC="${3:-0}"
    AM_MIXED="${4:-0}"
    if [ "$AM_MIXED" = mixed ]; then
      AUTO_MERGE_RELEASE=squash
      RELEASE_WORKFLOW=release.yml
    fi
    AM_SWEEP_PR=none
    # the recordings are per-run: this probe is driven several times and an
    # appended file would let a later run answer an earlier run's assertions
    AM_RUN="rc$1${2:+-pm}${3:+-d$3}${4:+-mixed}"
    # main sets NOW from the real clock, so the fixture's own dates are
    # relative to it rather than to this file's fixed RNOW.
    local at
    at="$(iso_at $(($(date +%s) - 3600)))"
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then core_label_rows | cut -d'|' -f1; return 0; fi
      if [ "$1" = pr ] && [ "$2" = list ]; then printf '920\n921\n'; return 0; fi
      if [ "$1" = pr ] && [ "$2" = view ]; then
        # green and mergeable: the verdict's last two conditions, so what the
        # sweep is measured on is the loop and not a refusal.
        jq -n '{mergeable:"MERGEABLE",
                statusCheckRollup:[{__typename:"CheckRun",workflowName:"ci",
                                    name:"check",conclusion:"SUCCESS",
                                    startedAt:"2026-07-01T00:00:00Z"}]}'
        return 0
      fi
      if [ "$1" = pr ] && [ "$2" = merge ]; then
        # main() reconciles each PR inside its own command-substitution
        # subshell, so this assignment is per-PR and cannot leak to the next
        # one — which is what lets the dispatch stub below know whose merge it
        # is following without the argv naming a PR at all.
        AM_SWEEP_PR="$3"
        printf '%s\n' "$*" >>"$AM/sweep-$AM_RUN-merges-$3"
        if [ "$3" = 920 ] && [ "$AM_FIRST_RC" != 0 ]; then
          printf 'failed to merge: Base branch was modified.\nReview and try the merge again.\n' >&2
          return "$AM_FIRST_RC"
        fi
        return 0
      fi
      if [ "$1" = workflow ] && [ "$2" = run ]; then
        # keyed by the CURRENT PR, which the sweep's dispatch names nowhere in
        # its argv: the log line is what carries the PR, so the recording is
        # keyed off the reconcile in flight via $AM_SWEEP_PR.
        printf '%s\n' "$*" >>"$AM/sweep-$AM_RUN-dispatch-$AM_SWEEP_PR"
        if [ "$AM_SWEEP_PR" = 920 ] && [ "$AM_FIRST_DISPATCH_RC" != 0 ]; then
          printf 'could not find any workflows named %s\nHTTP 404: Not Found\n' "$3" >&2
          return "$AM_FIRST_DISPATCH_RC"
        fi
        return 0
      fi
      if [ "$1" = issue ] && [ "$2" = comment ]; then
        local n="$3" body="" ; shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$AM/sweep-$AM_RUN-posted-$n"
        return 0
      fi
      # recorded to a file: reconcile_pr sends the edit's stdout to /dev/null
      if [ "$1" = issue ] && [ "$2" = edit ]; then printf '%s\n' "$*" >>"$AM/sweep-$AM_RUN-edits-$3"; return 0; fi
      [ "$1" = api ] || return 0
      shift
      local jqexpr="" endpoint=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jqexpr="$2"; shift ;;
          -*) ;;
          *) [ -n "$endpoint" ] || endpoint="$1" ;;
        esac
        shift
      done
      case "$endpoint" in
        */reviews) # the round: three head-current approvals, so decide_state
                   # buys state:needs-human rather than the fixture asserting it
          reviews \
            "$(rev "$BOT1" APPROVED amhead1 "" "$at")" \
            "$(rev "$BOT2" APPROVED amhead1 "" "$at")" \
            "$(rev "$BOT3" APPROVED amhead1 "" "$at")" | jq -r "${jqexpr:-.}" ;;
        */commits/*)
          jq -n --arg at "$at" '{commit:{committer:{date:$at}}}' | jq -r "${jqexpr:-.}" ;;
        */pulls/92[01]) # main's own fetch AND the confirmation read (D3)
          local fixture_labels='[]'
          if [ "$AM_MIXED" = mixed ] && [[ "$endpoint" = */pulls/920 ]]; then
            fixture_labels='[{"name":"release"}]'
          fi
          jq -n --arg at "$at" --arg author "$FIXTURE_AUTHOR" --argjson labels "$fixture_labels" \
            '{state:"open",draft:false,user:{login:$author},head:{sha:"amhead1"},
              base:{sha:"basesha"},labels:$labels,requested_reviewers:[],
              created_at:$at,assignees:[]}' | jq -r "${jqexpr:-.}" ;;
        *) printf '[]\n' | jq -r "${jqexpr:-.}" ;;
      esac
    }
    main
  )
}

am_sweep_rc=0
am_sweep="$(am_sweep_probe 1)" || am_sweep_rc=$?
expect "a sweep whose first merge is refused still exits 0" 0 "$am_sweep_rc"
expect "...and runs to the end of the loop" 1 \
  "$(grep -c '^labels: reconciled\.$' <<<"$am_sweep")"
expect "...attempting the refused merge exactly once" 1 \
  "$(wc -l <"$AM/sweep-rc1-merges-920" | tr -d ' ')"
# By MARKER and not by "this PR received no comment at all", which is what
# this line used to assert (#479). The claim is and always was about the
# auto-merge SUCCESS comment; the sweep also marks the human request it makes
# on the way to state:needs-human, and a file-existence test reads that mark as
# a success comment. am_posts above has counted by marker since #460 — this is
# the same count, spelled for the sweep probe's recording.
expect "...posting no success comment for it" no \
  "$(grep -qF "$AUTO_MERGED_MARKER" "$AM/sweep-rc1-posted-920" 2>/dev/null && echo yes || echo no)"
expect "...logging its reason on one line, naming that PR" 1 \
  "$(grep -c '^labels: #920: auto-merge refused: failed to merge: Base branch was modified. Review and try the merge again.$' \
    <<<"$am_sweep")"
expect "...and never reporting the refusal as a failed reconcile" no \
  "$(grep -q 'reconcile failed' <<<"$am_sweep" && echo yes || echo no)"
# the criterion itself: the NEXT PR of the same run.
expect "the next PR in the same sweep is reconciled" yes \
  "$(grep -q 'state:needs-human' "$AM/sweep-rc1-edits-921" && echo yes || echo no)"
expect "...and merges, head-pinned" \
  "pr merge 921 -R owner/repo --merge --match-head-commit amhead1" \
  "$(cat "$AM/sweep-rc1-merges-921")"
expect "...and gets its provenance comment" 1 \
  "$(grep -cF "$AUTO_MERGED_MARKER" "$AM/sweep-rc1-posted-921")"
expect "...after the first PR's refusal, in the one run (order)" yes \
  "$(awk '/#920: auto-merge refused/{r=NR} /#921: auto-merged amhead1/{m=NR}
          END{print (r && m && r < m) ? "yes" : "no"}' <<<"$am_sweep")"
# The control the case needs to not be vacuous: with the same fixture and a
# merge GitHub accepts, BOTH PRs merge. Without it, a sweep that reconciled
# #921 for some reason unrelated to continuing past #920 would read the same.
am_sweep_ok="$(am_sweep_probe 0)"
expect "the same sweep with both merges accepted merges both PRs" 2 \
  "$(grep -c 'auto-merged amhead1 (merge) — commented' <<<"$am_sweep_ok")"
expect "...and refuses nothing" 0 \
  "$(grep -c 'auto-merge refused' <<<"$am_sweep_ok")"

# -- #461's continuation, at the same boundary and for the same reason: ONE
#    main() sweep, both merges accepted, and the FIRST PR's dispatch refused.
#    D3's "the sweep continues to the next PR" is a property of main's per-PR
#    error handling and nothing in the reconcile_pr probes above can see it —
#    a regression that let one misconfigured workflow name strand every
#    remaining PR would leave all of them green, *after* a merge had landed.
am_pmsweep_rc=0
am_pmsweep="$(am_sweep_probe 0 ci.yml 1)" || am_pmsweep_rc=$?
expect "a sweep whose first dispatch is refused still exits 0" 0 "$am_pmsweep_rc"
expect "...and runs to the end of the loop" 1 \
  "$(grep -c '^labels: reconciled\.$' <<<"$am_pmsweep")"
expect "...merging both PRs regardless" 2 \
  "$(grep -c 'auto-merged amhead1 (merge) — commented' <<<"$am_pmsweep")"
expect "...attempting the refused dispatch exactly once" 1 \
  "$(wc -l <"$AM/sweep-rc0-pm-d1-dispatch-920" | tr -d ' ')"
expect "...logging its reason on one line, naming that PR and the workflow" 1 \
  "$(grep -c '^labels: #920: WARNING: post-merge dispatch of ci.yml failed: could not find any workflows named ci.yml HTTP 404: Not Found — the merge stands$' \
    <<<"$am_pmsweep")"
expect "...and never reporting it as a failed reconcile" no \
  "$(grep -q 'reconcile failed' <<<"$am_pmsweep" && echo yes || echo no)"
# the criterion itself: the NEXT PR of the same run is still reconciled, still
# merged, and still dispatched.
expect "the next PR in the same sweep is reconciled" yes \
  "$(grep -q 'state:needs-human' "$AM/sweep-rc0-pm-d1-edits-921" && echo yes || echo no)"
expect "...and dispatches cleanly, head-independent and ref-free" \
  "workflow run ci.yml -R owner/repo" \
  "$(cat "$AM/sweep-rc0-pm-d1-dispatch-921")"
expect "...after the first PR's failure, in the one run (order)" yes \
  "$(awk '/#920: WARNING: post-merge dispatch/{f=NR} /#921: dispatched ci.yml/{d=NR}
          END{print (f && d && f < d) ? "yes" : "no"}' <<<"$am_pmsweep")"
# The control the case needs to not be vacuous: the same sweep with a dispatch
# GitHub accepts dispatches for BOTH PRs. Without it, a sweep that dispatched
# for #921 for some reason unrelated to continuing past #920 would read alike.
am_pmsweep_ok="$(am_sweep_probe 0 ci.yml)"
expect "the same sweep with both dispatches accepted dispatches twice" 2 \
  "$(grep -c 'dispatched ci.yml after the merge' <<<"$am_pmsweep_ok")"
expect "...and warns about none of them" 0 \
  "$(grep -c 'post-merge dispatch of' <<<"$am_pmsweep_ok")"

# -- #468's mixed pass: one sweep proves the governing method is selected per
# PR, and a failed release dispatch cannot strand the ordinary PR behind it.
am_mixed_rc=0
am_mixed="$(am_sweep_probe 0 "" 1 mixed)" || am_mixed_rc=$?
expect "a sweep whose release dispatch fails still exits 0" 0 "$am_mixed_rc"
expect "the release PR uses auto_merge_release's squash method" \
  "pr merge 920 -R owner/repo --squash --match-head-commit amhead1" \
  "$(cat "$AM/sweep-rc0-d1-mixed-merges-920")"
expect "the ordinary PR in that same sweep uses auto_merge's merge method" \
  "pr merge 921 -R owner/repo --merge --match-head-commit amhead1" \
  "$(cat "$AM/sweep-rc0-d1-mixed-merges-921")"
expect "the release dispatch carries the exact graded head" \
  "workflow run release.yml -R owner/repo -f merged-sha=amhead1" \
  "$(cat "$AM/sweep-rc0-d1-mixed-dispatch-920")"
expect "the failed release dispatch is loud and names PR and workflow" yes \
  "$(grep -q '^labels: #920: WARNING: release dispatch of release.yml failed: could not find any workflows named release.yml HTTP 404: Not Found — the merge stands$' \
    <<<"$am_mixed" && echo yes || echo no)"
expect "the next PR in the same sweep is still reconciled and merged" yes \
  "$(grep -q '#921: auto-merged amhead1 (merge) — commented' <<<"$am_mixed" \
    && echo yes || echo no)"
expect "the ordinary merge fires no release dispatch" no \
  "$([ -e "$AM/sweep-rc0-d1-mixed-dispatch-921" ] && echo yes || echo no)"
# ...and the same sweep with the input UNSET dispatches for neither, which is
# every consumer today: the criterion's "exactly the invocations #460 ships".
expect "the same sweep with post_merge_workflow unset dispatches nothing" no \
  "$([ -e "$AM/sweep-rc0-dispatch-920" ] || [ -e "$AM/sweep-rc0-dispatch-921" ] \
    && echo yes || echo no)"

# -- DRY_RUN=1 mutates nothing, and this is the case that protects the live
#    repository: DRY_RUN=1 is how this script is rehearsed against it (:30),
#    and a merge written outside run() reaches the stub here and reds.
am_dry="$(am_probe 910 merge amhead1 open "$NO_LABELS" 0 dry)"
expect "DRY_RUN records no merge invocation" 0 "$(am_merges 910)"
expect "...and no comment" 0 "$(am_posts 910)"
expect "...narrating the merge it would have made, head-pinned" yes \
  "$(grep -q 'DRY_RUN: gh pr merge 910 -R owner/repo --merge --match-head-commit amhead1' \
    <<<"$am_dry" && echo yes || echo no)"
expect "...and narrating the comment it would have posted" yes \
  "$(grep -q 'DRY_RUN: gh issue comment 910' <<<"$am_dry" && echo yes || echo no)"
expect "...while the confirmation READ still happened: a rehearsal that
  skipped it would narrate a merge the real sweep would have refused" yes \
  "$(grep -q '#910: auto-merge\[ordinary\]: MERGE' <<<"$am_dry" && echo yes || echo no)"

# -- the comment: the marker and D6's four facts, asserted against the
#    recorded body. Under a doctrine that says only humans merge, a bot merge
#    whose provenance is only in a run log is #377's defect again.
expect "the success comment carries the machine marker" 1 "$(am_posts 901)"
expect "...naming the head SHA merged" yes \
  "$(grep -qF 'amhead1' "$AM/posted-901" && echo yes || echo no)"
expect "...naming the method" yes \
  "$(grep -qF "**Method:** \`merge\`" "$AM/posted-901" && echo yes || echo no)"
expect "...naming the auto_merge value that authorised it" yes \
  "$(grep -qF 'auto_merge=merge' "$AM/posted-901" && echo yes || echo no)"
expect "...and naming decide_state, not the label, as the trigger" yes \
  "$(grep -qF 'decide_state' "$AM/posted-901" && echo yes || echo no)"
expect "...saying so explicitly against the label" yes \
  "$(grep -qF "not* the \`state:needs-human\` label" "$AM/posted-901" && echo yes || echo no)"
expect "...and the squash run names ITS method, not the first run's" yes \
  "$(grep -qF "**Method:** \`squash\`" "$AM/posted-902" && echo yes || echo no)"

# -- ORDER (D1): the merge is the last thing reconcile_pr does. Everything the
#    board owes an OPEN PR lands before it, or it lands on a closed one.
am_order="$(am_probe 911 merge amhead1 open "$NO_LABELS" 0)"
expect "the converge edit is logged before the merge" yes \
  "$(awk '/state -> state:needs-human/{s=NR} /auto-merged amhead1/{m=NR} END{print (s && m && s < m) ? "yes" : "no"}' \
    <<<"$am_order")"
expect "...and the verdict line before the merge it authorised" yes \
  "$(awk '/auto-merge\[ordinary\]: MERGE/{v=NR} /auto-merged amhead1/{m=NR} END{print (v && m && v < m) ? "yes" : "no"}' \
    <<<"$am_order")"
# The structural half of the same rule, which no log ordering can show: the
# call is the LAST statement of reconcile_pr. A step appended below it would
# run on a PR this call already closed.
expect "reconcile_auto_merge is the last statement in reconcile_pr" yes \
  "$(awk '/^reconcile_pr\(\)/{inside=1}
          inside && /^  reconcile_auto_merge /{seen=NR}
          inside && /^}/{print (seen && NR == seen + 1) ? "yes" : "no"; exit}' \
    actions/labels-reconcile/labels-reconcile.sh)"

# -- the refusals #459 owns are NOT re-implemented here (D2, #458 E7): the act
#    reads the verdict and nothing else. Asserted on the source, because a
#    duplicated refusal is a branch no fixture can reach — its guard would
#    simply never fire while the verdict already refused.
# Whole-comment lines are stripped before the grep, and that is not tidiness:
# the header of reconcile_auto_merge NAMES the refusals it must not
# re-implement, so a pattern read over the comments finds the words it is
# hunting for in the very sentence promising they are absent, and the
# assertion passes or fails on prose rather than on code.
# `|| true` so a tree where the function is ABSENT still reaches this file's
# summary line. Without it the empty awk output reds grep under pipefail, the
# file aborts mid-suite, and the failure count a reader quotes is a floor
# rather than a total — which is exactly the shape of run this block is the
# evidence for.
am_body="$(awk '/^reconcile_auto_merge\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh | grep -v '^[[:space:]]*#' || true)"
# The patterns match CODE SHAPE — an array reference, a command substitution,
# a call — and not the bare words. Stripping the comments above was not enough
# on its own: the success comment's own prose tells the reader that the
# trigger was re-derived "from the round, the blockers and the checks", so a
# bare-word pattern reds on a sentence that is both true and the thing worth
# saying. The rule being asserted is about calls, so the pattern is too.
expect "the act re-derives no draft check" no \
  "$(grep -q 'DRAFT' <<<"$am_body" && echo yes || echo no)"
expect "the act re-derives no blocker check" no \
  "$(grep -qF 'BLOCKERS' <<<"$am_body" || grep -qF '(blockers)' <<<"$am_body" \
    && echo yes || echo no)"
expect "the act reads the graded labels once, only to select the governing toggle" 1 \
  "$(grep -c 'has_label release' <<<"$am_body")"
# ...and the confirmation re-reads rather than recomputing: a confirmation
# built from the values this pass already holds is a comment, not a lock.
am_confirm_body="$(awk '/^auto_merge_confirm\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh | grep -v '^[[:space:]]*#' || true)"
expect "the confirmation reads the PR back from the API" yes \
  "$(grep -qF 'gh api "repos/' <<<"$am_confirm_body" \
    && grep -qF 'pulls/' <<<"$am_confirm_body" && echo yes || echo no)"
expect "...and is a read, so it never goes through run()" no \
  "$(grep -q '^  *run ' <<<"$am_confirm_body" && echo yes || echo no)"
expect "...and does not re-read mergeability (D3: a slower window, not a smaller one)" no \
  "$(grep -q 'mergeable\|MERGEABLE' <<<"$am_confirm_body" && echo yes || echo no)"
# An unreadable confirmation refuses: the verdict it would otherwise invent is
# the one act in this file that cannot be taken back (#101).
am_unreadable="$(
  (
    REPO=owner/repo HEAD_SHA=amhead1
    gh() { printf 'gh: Not Found (HTTP 404)\n' >&2; return 1; }
    auto_merge_confirm 912
  ) || true
)"
expect "an unreadable confirmation refuses rather than merging" yes \
  "$(grep -q 'the confirmation read failed: gh: Not Found (HTTP 404)' \
    <<<"$am_unreadable" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# THE POST-MERGE DISPATCH (#461 D1–D4). A GITHUB_TOKEN merge raises a `push`
# that starts no workflow run, so the consumer's `push: branches: [main]` CI
# never grades the merge commit. The repair is the one exemption GitHub
# allows. Every assertion below is on the RECORDED ARGV or on its absence,
# because the cases that cost are all "something fired that should not have".
# ---------------------------------------------------------------------------
# -- empty is the default and dispatches nothing. The fixture merges, so what
#    is measured is the input alone: #901 above ran with no POST_MERGE_WORKFLOW
#    at all and is the control for "exactly the invocations #460 ships".
expect "an unset post_merge_workflow records no dispatch on a merged PR" 0 \
  "$(am_dispatches 901)"
expect "...and says nothing about a dispatch at all" no \
  "$(grep -q 'dispatch' <<<"$am_on" && echo yes || echo no)"
am_pm_empty="$(am_probe 940 merge amhead1 open "$NO_LABELS" 0 "" "")"
expect "an explicitly empty post_merge_workflow still merges" 1 "$(am_merges 940)"
expect "...and still dispatches nothing" 0 "$(am_dispatches 940)"
expect "...and never invents a default workflow name" no \
  "$(grep -q 'workflow run' "$AM/calls-940" && echo yes || echo no)"
expect "...while the pass it rode converged as usual (control)" yes \
  "$(grep -q 'state -> state:needs-human' <<<"$am_pm_empty" && echo yes || echo no)"

# -- set plus a successful merge: exactly one dispatch, naming the configured
#    workflow and this repository, with NO --ref. gh targets the default
#    branch, which is the branch the merge just landed on and the only branch
#    this could mean; a --ref would name a branch the merge did not touch.
am_pm="$(am_probe 941 merge amhead1 open "$NO_LABELS" 0 "" ci.yml)"
expect "a set post_merge_workflow records exactly one dispatch" 1 \
  "$(am_dispatches 941)"
expect "...whose argv names the workflow and the repository, and nothing else" \
  "workflow run ci.yml -R owner/repo" \
  "$(cat "$AM/dispatch-941")"
expect "...carrying no --ref" no \
  "$(grep -q -- '--ref' "$AM/dispatch-941" && echo yes || echo no)"
expect "...logged as done, naming the workflow" yes \
  "$(grep -q '#941: dispatched ci.yml after the merge' <<<"$am_pm" && echo yes || echo no)"
# ORDER: after the merge and after the provenance comment. A dispatch before
# the merge grades the pre-merge tree and reports on a commit that does not
# exist yet — the whole point of the input inverted.
expect "the dispatch is logged after the merge it followed" yes \
  "$(awk '/#941: auto-merged amhead1/{m=NR} /#941: dispatched ci.yml/{d=NR}
          END{print (m && d && m < d) ? "yes" : "no"}' <<<"$am_pm")"
expect "...and the merge call precedes the dispatch call in the recorded argv" yes \
  "$(awk '/^pr merge 941/{m=NR} /^workflow run ci.yml/{d=NR}
          END{print (m && d && m < d) ? "yes" : "no"}' "$AM/calls-941")"
expect "...as does the provenance comment" yes \
  "$(awk '/^issue comment 941/{c=NR} /^workflow run ci.yml/{d=NR}
          END{print (c && d && c < d) ? "yes" : "no"}' "$AM/calls-941")"

# -- set plus NO merge dispatches nothing, in each of the three shapes a pass
#    reaches that state by. Every sweep would otherwise wake the consumer's CI
#    hourly, for nothing.
am_pm_off="$(am_probe 942 off amhead1 open "$NO_LABELS" 0 "" ci.yml)"
expect "SKIP:off records no dispatch" 0 "$(am_dispatches 942)"
expect "...because it merged nothing" 0 "$(am_merges 942)"
expect "...and the pass still did its ordinary work (control)" yes \
  "$(grep -q 'state -> state:needs-human' <<<"$am_pm_off" && echo yes || echo no)"
am_pm_state="$(am_probe 943 merge amhead1 open "$NO_LABELS" 0 "" ci.yml 0 "" block)"
expect "SKIP:state records no dispatch" 0 "$(am_dispatches 943)"
expect "...because it merged nothing" 0 "$(am_merges 943)"
expect "...and the verdict that refused is the one logged" yes \
  "$(grep -q '#943: auto-merge\[ordinary\]: SKIP:state' <<<"$am_pm_state" && echo yes || echo no)"
am_pm_refused="$(am_probe 944 merge amhead1 open "$NO_LABELS" 1 "" ci.yml)"
expect "a merge GitHub refused records no dispatch" 0 "$(am_dispatches 944)"
expect "...and is still attempted exactly once" 1 "$(am_merges 944)"
expect "...and its refusal is what the log says" yes \
  "$(grep -q '#944: auto-merge refused: failed to merge' <<<"$am_pm_refused" \
    && echo yes || echo no)"
# The head-moved refusal is the same shape from the other lock, and it is the
# one a reader is most likely to assume is covered by the row above.
am_pm_moved="$(am_probe 945 merge amhead2 open "$NO_LABELS" 0 "" ci.yml)"
expect "a head that moved since the grading records no dispatch" 0 \
  "$(am_dispatches 945)"
expect "...because the confirmation refused, not because the input was unset" yes \
  "$(grep -q '#945: auto-merge refused: the head moved since this pass graded it' \
    <<<"$am_pm_moved" && echo yes || echo no)"

# -- DRY_RUN=1 narrates the dispatch and invokes nothing. This is the case that
#    protects THIS repository: drill/rehearsal.sh runs the reconciler here that
#    way, and a dispatch written outside run() wakes real workflows.
am_pm_dry="$(am_probe 946 merge amhead1 open "$NO_LABELS" 0 dry ci.yml)"
expect "DRY_RUN records no dispatch invocation" 0 "$(am_dispatches 946)"
expect "...narrating the dispatch it would have made" yes \
  "$(grep -q 'DRY_RUN: gh workflow run ci.yml -R owner/repo' <<<"$am_pm_dry" \
    && echo yes || echo no)"
expect "...with the narration intact, not swallowed by a redirect" 1 \
  "$(grep -c 'DRY_RUN: gh workflow run' <<<"$am_pm_dry")"

# -- a failed dispatch is loud, local and non-fatal (D3). The merge has already
#    happened and cannot be undone by failing the pass; the opposite of the
#    trigger job's fail-the-job treatment, deliberately — that job's failure is
#    a PRE-condition alarm and this one is a POST-condition report.
am_pm_fail_rc=0
am_pm_fail="$(am_probe 947 merge amhead1 open "$NO_LABELS" 0 "" no-such.yml 1)" \
  || am_pm_fail_rc=$?
expect "a failed dispatch never fails the PR's reconcile" 0 "$am_pm_fail_rc"
expect "...is attempted exactly once, never retried in the same pass" 1 \
  "$(am_dispatches 947)"
expect "...logs its reason on exactly one line, naming PR and workflow" 1 \
  "$(grep -c '^labels: #947: WARNING: post-merge dispatch of no-such.yml failed: could not find any workflows named no-such.yml HTTP 404: Not Found — the merge stands$' \
    <<<"$am_pm_fail")"
expect "...and the merge it follows still stands and is still reported" yes \
  "$(grep -q '#947: auto-merged amhead1 (merge) — commented' <<<"$am_pm_fail" \
    && echo yes || echo no)"
expect "...and the merge is never re-attempted after it" 1 "$(am_merges 947)"

# -- the dispatch lives in the SUCCESS branch, asserted on the source: a
#    dispatch reachable from any earlier return is a branch no fixture above
#    can distinguish from one that simply never fired.
am_pm_body="$(awk '/^reconcile_auto_merge\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh | grep -v '^[[:space:]]*#' || true)"
expect "the dispatch goes through run(), like every mutation in the file" yes \
  "$(grep -q 'run gh workflow run' <<<"$am_pm_body" && echo yes || echo no)"
expect "the generic and release dispatches are the only gh workflow calls in the function" 2 \
  "$(grep -c 'gh workflow run' <<<"$am_pm_body")"
expect "...after the provenance comment, in source order" yes \
  "$(awk '/gh issue comment/{c=NR} /run gh workflow run "\$POST_MERGE_WORKFLOW"/{d=NR}
          END{print (c && d && c < d) ? "yes" : "no"}' <<<"$am_pm_body")"
# D4 — the name is never validated here: three questions gh answers by failing.
expect "the act validates no workflow name of its own" no \
  "$(grep -qE 'workflow_dispatch|gh workflow list|actions/workflows' \
    <<<"$am_pm_body" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# D7 (#458 E18) — the merge says the human was asked, and only when it was.
# THE DISCRIMINATING PAIR: the same merged PR shape twice, differing in one
# input only. A single fixture cannot grade this — the case that costs is the
# comment claiming an act that did not happen (#377).
# ---------------------------------------------------------------------------
D7_LINE='**The human was asked:**'
am_d7_yes="$(am_probe 930 merge amhead1 open "$NO_LABELS" 0)"
# ...and the half that must NOT carry it: a live request already stood, so
# human_request_needed refuses and this pass asks nobody.
am_d7_no="$(am_probe 931 merge amhead1 open "$NO_LABELS" 0 "" "" 0 "$HUMAN")"
expect "the pass that requested the human logs that it did" yes \
  "$(grep -q "#930: requested $HUMAN (round passed)" <<<"$am_d7_yes" && echo yes || echo no)"
expect "...and its provenance comment carries D7's line" yes \
  "$(grep -qF "$D7_LINE" "$AM/posted-930" && echo yes || echo no)"
expect "...naming the human it asked" yes \
  "$(grep -qF "requested \`$HUMAN\`'s review" "$AM/posted-930" && echo yes || echo no)"
expect "the pass that requested nobody says so by omission" no \
  "$(grep -q "#931: requested" <<<"$am_d7_no" && echo yes || echo no)"
expect "...and its provenance comment omits D7's line entirely" no \
  "$(grep -qF "$D7_LINE" "$AM/posted-931" && echo yes || echo no)"
# The pair is only a pair if BOTH halves merged and commented: a half that
# merged nothing would omit the line for a reason that is not the one measured.
expect "both halves of the pair merged" "1 1" \
  "$(am_merges 930) $(am_merges 931)"
expect "...and both posted exactly one provenance comment" "1 1" \
  "$(am_posts 930) $(am_posts 931)"
# ...and differ in NOTHING else. Everything #460 asserted is still in both.
expect "the omitting half still names the head, method and authorisation" yes \
  "$(grep -qF 'amhead1' "$AM/posted-931" \
    && grep -qF "**Method:** \`merge\`" "$AM/posted-931" \
    && grep -qF 'auto_merge=merge' "$AM/posted-931" && echo yes || echo no)"
expect "...and the carrying half does too" yes \
  "$(grep -qF 'amhead1' "$AM/posted-930" \
    && grep -qF "**Method:** \`merge\`" "$AM/posted-930" \
    && grep -qF 'auto_merge=merge' "$AM/posted-930" && echo yes || echo no)"
# The line's own claim, which is the reason it is conditional: it says the
# request is never suppressed, because at line 979 the pass cannot know the
# merge will land (E18), and a suppression would starve the human on exactly
# the configuration that needs them most.
expect "D7's line says the request is not suppressed" yes \
  "$(grep -qF 'The request is never' "$AM/posted-930" && echo yes || echo no)"

# -- NO SECOND READ (D7, #460 D2). The fact is passed down from the request
#    site, not re-derived. Two independent measurements, because either alone
#    can be satisfied by the other's defect: the recorded argv cannot see a
#    second call to a pure guard, and the guard's call count cannot see an
#    extra API read added beside it.
expect "the merged PR's recorded calls touch requested_reviewers exactly once" 1 \
  "$(grep -c 'requested_reviewers' "$AM/calls-930")"
expect "...and that one is the WRITE, never a read" yes \
  "$(grep 'requested_reviewers' "$AM/calls-930" \
    | grep -qF -- "-f reviewers[]=$HUMAN" && echo yes || echo no)"
expect "the half that asked nobody touches requested_reviewers not at all" 0 \
  "$(grep -c 'requested_reviewers' "$AM/calls-931" || true)"
expect "human_request_needed is called exactly once for the asking pass" 1 \
  "$(wc -l <"$AM/hrn-930" | tr -d ' ')"
expect "...and exactly once for the non-asking pass" 1 \
  "$(wc -l <"$AM/hrn-931" | tr -d ' ')"
# ...and the act itself never reaches for the fact a second time. Asserted on
# the source, because a second read added there would simply agree with the
# first on every fixture this file can write.
expect "the act re-reads no requested_reviewers of its own" no \
  "$(grep -q 'requested_reviewers' <<<"$am_pm_body" && echo yes || echo no)"
expect "...and re-evaluates no human_request_needed" no \
  "$(grep -q 'human_request_needed' <<<"$am_pm_body" && echo yes || echo no)"
expect "...and takes the fact as its third argument" yes \
  "$(grep -q "human_requested=\"\\\$3\"" <<<"$am_pm_body" && echo yes || echo no)"
# The caller half of the same contract: reconcile_pr records it at the request
# site, which is the only place it is knowable.
am_pr_body="$(awk '/^reconcile_pr\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh | grep -v '^[[:space:]]*#' || true)"
expect "reconcile_pr evaluates human_request_needed exactly once" 1 \
  "$(grep -c 'human_request_needed' <<<"$am_pr_body")"
expect "...and passes the recorded fact into the act" yes \
  "$(grep -q "reconcile_auto_merge \"\\\$n\" \"\\\$desired\" \"\\\$human_requested\"" \
    <<<"$am_pr_body" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# #479 — the reconciler could not tell its own human request from a
# maintainer's. It asks the human at the round's pass and never withdrew the
# ask; from then on `requested "$HUMAN"` was true forever, and round_state read
# that flag as the deliberate early claim a maintainer's request is. The four
# steps below are all ordinary — pass at head A, push to B, re-request the
# panel, one bot's request dropped — and they ended with the board saying a
# human could merge a head some required reviewer still owed a verdict on.
#
# The mark is what separates the two requests, so every fixture here is a PAIR
# on that one input: the same round, the same standing request, differing only
# in whose ask it is.
# ---------------------------------------------------------------------------

# -- the pure reader: a running state, newest wins --------------------------
expect "no marks at all read as nobody's mark" NONE "$(human_request_mark </dev/null)"
expect "the machine's mark reads MACHINE" MACHINE \
  "$(human_request_mark <<<"$HUMAN_REQUEST_MARKER")"
expect "prose after the marker is still the marker" MACHINE \
  "$(human_request_mark <<<"$HUMAN_REQUEST_MARKER extra")"
expect "an unrelated comment stream marks nothing" NONE \
  "$(printf '%s\n' 'hello' '🔧 addressing round on head abc' | human_request_mark)"
expect "a withdrawal newer than the request supersedes it" NONE \
  "$(printf '%s\n%s\n' "$HUMAN_REQUEST_MARKER" "$HUMAN_REQUEST_WITHDRAWN_MARKER" \
    | human_request_mark)"
# ...and the other order, which is the case a maintainer asking after a
# retraction produces: request, withdrawal, request again.
expect "a request newer than a withdrawal stands again" MACHINE \
  "$(printf '%s\n%s\n%s\n' "$HUMAN_REQUEST_MARKER" "$HUMAN_REQUEST_WITHDRAWN_MARKER" \
    "$HUMAN_REQUEST_MARKER" | human_request_mark)"
# The two markers must not be each other's prefix, or the case arms above
# would answer for both and the withdrawal could never supersede.
expect "the withdrawal marker is not a request marker" NONE \
  "$(human_request_mark <<<"$HUMAN_REQUEST_WITHDRAWN_MARKER")"
# Matched as the FIRST LINE, the shape this file's other markers are written
# in: a marker quoted further down a comment is quoted, not written.
expect "a marker below the first line is not this machine's mark" NONE \
  "$(printf '%s\n' "quoting: $HUMAN_REQUEST_MARKER" | human_request_mark)"

# -- the four-step sequence, and its discriminating twin --------------------
# APPROVE + MISSING with nothing staled and no bot requested: the shape the
# comment at round_state's *MISSING* branch calls "somebody owes a verdict and
# nobody was asked for one". The human request stands from step 1.
DRAFT=false HEAD_SHA=head479B MERGEABLE=MERGEABLE CHECKS=SUCCESS LABELS=""
REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head479B "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED head479B "" 2026-08-03T10:01:00Z)")"
HUMAN_REQUEST_MARK=MACHINE
expect "a stale self-made request no longer reads as a human claim" \
  state:addressing "$(decide_state)"
expect "...and the stall it was hiding is named" blocker:unrequested "$(blockers)"
HUMAN_REQUEST_MARK=NONE
expect "the same round with a MAINTAINER's request is still needs-human" \
  state:needs-human "$(decide_state)"
expect "...and a deliberate claim is no dropped ball" "" "$(blockers)"
# An unread mark is an unmarked one: an API that would not answer must not take
# a maintainer's deliberate act away, so the fixture's default direction is the
# pre-#479 reading.
HUMAN_REQUEST_MARK=""
expect "an unread mark reads as the maintainer's" state:needs-human "$(decide_state)"
HUMAN_REQUEST_MARK=NONE

# D4 is graded on round_state DIRECTLY, and it has to be. decide_state reaches
# the same answer above through the blockers clause — blocker:unrequested now
# fires on this head, and any blocker disqualifies needs-human — so a
# decide_state fixture alone is satisfied by the blockers() half and would keep
# passing with D4 reverted. The two halves are separate rules about the same
# bit, and each is pinned where it is decided.
HUMAN_REQUEST_MARK=MACHINE
expect "the round alone no longer reads a machine request as a claim" \
  state:addressing "$(round_state)"
HUMAN_REQUEST_MARK=NONE
expect "...while a maintainer's still outranks the unfinished round" \
  state:needs-human "$(round_state)"

# ...and the head where nothing else can stand in for it: checks still running.
# blockers() writes nothing on a PENDING head — the ask is not permitted yet,
# so blocker:unrequested is withheld — which leaves decide_state carrying
# round_state's answer alone.
CHECKS=PENDING
HUMAN_REQUEST_MARK=MACHINE
expect "a pending head with a verdict missing is the builder's, not the human's" \
  state:addressing "$(decide_state)"
expect "...and no blocker is doing that work" "" "$(blockers)"
HUMAN_REQUEST_MARK=NONE
expect "...while the maintainer's claim survives a pending head" \
  state:needs-human "$(decide_state)"
CHECKS=SUCCESS

# -- the regression guard: narrowing MISSING must not widen STALE -----------
# The mixed round 0.7.4 already handles — one head-current approval, one
# approval staled by a push — is *STALE*, which is checked BEFORE *MISSING* and
# never consults the request at all. Both marks, because a narrowing written
# one case too high would show up as the machine mark changing this answer.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head479B "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED head479A "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED head479B "" 2026-08-03T10:02:00Z)")"
HUMAN_REQUEST_MARK=MACHINE
expect "APPROVE + STALE is addressing under a machine request" \
  state:addressing "$(decide_state)"
HUMAN_REQUEST_MARK=NONE
expect "...and under a maintainer's, unchanged by #479" \
  state:addressing "$(decide_state)"

# -- and the final gate below *MISSING* is untouched (D4 is one branch) -----
# Every verdict in, one of them a non-verdict: no MISSING, no STALE, so the
# request is read at round_state's last gate — which #479 does not narrow.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head479B "feedback" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED head479B "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED head479B "" 2026-08-03T10:02:00Z)")"
HUMAN_REQUEST_MARK=MACHINE
expect "the gate below MISSING still honours any standing request" \
  state:needs-human "$(decide_state)"
HUMAN_REQUEST_MARK=NONE
REQUESTED=""

# -- the sweep: who is asked, who is withdrawn, and what is never read ------
HR="$RTMP/humanreq"
mkdir -p "$HR"

hr_probe() { # $1 PR, $2 round, $3 requested logins, $4 marks: none|machine|withdrawn|unreadable
  # HR_DELETE_RC / HR_COMMENT_RC are the stubbed mutations' exit status, each
  # defaulting to the happy path.
  (
    BOOTSTRAP=no
    REPO=owner/repo
    LABELS_CONF="$FIXTURE_CONF"
    AUTO_MERGE=off
    AUTO_MERGE_RELEASE=off
    HR_PR="$1" HR_ROUND="$2" HR_REQ="$3" HR_MARKS="$4"
    local at
    at="$(iso_at $(($(date +%s) - 3600)))"
    gh() {
      printf '%s\n' "$*" >>"$HR/calls-$HR_PR"
      if [ "$1" = label ] && [ "$2" = list ]; then core_label_rows | cut -d'|' -f1; return 0; fi
      if [ "$1" = pr ] && [ "$2" = list ]; then printf '%s\n' "$HR_PR"; return 0; fi
      if [ "$1" = pr ] && [ "$2" = view ]; then
        jq -n '{mergeable:"MERGEABLE",
                statusCheckRollup:[{__typename:"CheckRun",workflowName:"ci",
                                    name:"check",conclusion:"SUCCESS",
                                    startedAt:"2026-07-01T00:00:00Z"}]}'
        return 0
      fi
      if [ "$1" = issue ] && [ "$2" = comment ]; then
        [ "${HR_COMMENT_RC:-0}" = 0 ] || return "$HR_COMMENT_RC"
        local body=""; shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$HR/posted-$HR_PR"
        return 0
      fi
      if [ "$1" = issue ] && [ "$2" = edit ]; then printf '%s\n' "$*" >>"$HR/edits-$HR_PR"; return 0; fi
      [ "$1" = api ] || return 0
      shift
      local jqexpr="" endpoint="" method=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jqexpr="$2"; shift ;;
          --method) method="$2"; shift ;;
          -*) ;;
          *) [ -n "$endpoint" ] || endpoint="$1" ;;
        esac
        shift
      done
      # the two writes on the request, told apart by method and not by shape
      case "$endpoint" in
        */requested_reviewers)
          [ "$method" != DELETE ] || return "${HR_DELETE_RC:-0}"
          return 0 ;;
      esac
      case "$endpoint" in
        */commits/*)
          jq -n --arg at "$at" '{commit:{committer:{date:$at}}}' | jq -r "${jqexpr:-.}" ;;
        */reviews)
          case "$HR_ROUND" in
            # step 4: one head-current approval, one required verdict missing,
            # nothing staled and no bot requested
            missing) reviews \
              "$(rev "$BOT1" APPROVED hrhead "" "$at")" \
              "$(rev "$BOT2" APPROVED hrhead "" "$at")" | jq -r "${jqexpr:-.}" ;;
            # the round that passes: every required verdict head-current
            approve) reviews \
              "$(rev "$BOT1" APPROVED hrhead "" "$at")" \
              "$(rev "$BOT2" APPROVED hrhead "" "$at")" \
              "$(rev "$BOT3" APPROVED hrhead "" "$at")" | jq -r "${jqexpr:-.}" ;;
            # step 2: the push. Every approval covers an older head, so
            # round_state answers *STALE* — above the branch #479 narrows, and
            # without consulting any request at all. This is the round that
            # reaches the withdrawal's own gate, `desired` having moved off
            # state:needs-human for a reason that is not the mark.
            stale) reviews \
              "$(rev "$BOT1" APPROVED hrold "" "$at")" \
              "$(rev "$BOT2" APPROVED hrold "" "$at")" \
              "$(rev "$BOT3" APPROVED hrold "" "$at")" | jq -r "${jqexpr:-.}" ;;
            *) printf '[]\n' | jq -r "${jqexpr:-.}" ;;
          esac ;;
        */issues/*/comments)
          # The marks read is the one asking for each body's FIRST line; the
          # stale clock's read of the same endpoint asks for created_at, and
          # must keep working when the marks read is the one refused.
          case "$jqexpr" in
            *'split("\n")[0]'*)
              [ "$HR_MARKS" != unreadable ] || return 1 ;;
          esac
          local marks='[]'
          case "$HR_MARKS" in
            machine) marks="$(jq -n --arg b "$HUMAN_REQUEST_MARKER" \
              '[{user:{login:"sweep-bot"},body:$b}]')" ;;
            withdrawn) marks="$(jq -n --arg r "$HUMAN_REQUEST_MARKER" \
              --arg w "$HUMAN_REQUEST_WITHDRAWN_MARKER" \
              '[{user:{login:"sweep-bot"},body:$r},{user:{login:"sweep-bot"},body:$w}]')" ;;
          esac
          jq --arg at "$at" '[.[] | . + {created_at: $at}]' <<<"$marks" | jq -r "${jqexpr:-.}" ;;
        */pulls/*)
          jq -n --arg at "$at" --arg author "$FIXTURE_AUTHOR" --arg req "$HR_REQ" \
            '{state:"open",draft:false,user:{login:$author},head:{sha:"hrhead"},
              base:{sha:"basesha"},labels:[],
              requested_reviewers:($req | if . == "" then [] else [{login:.}] end),
              created_at:$at,assignees:[]}' | jq -r "${jqexpr:-.}" ;;
        *) printf '[]\n' | jq -r "${jqexpr:-.}" ;;
      esac
    }
    main
  )
}

hr_calls() { # $1 PR, $2 pattern → how many recorded calls match
  # -F and -- : the pattern under test is literally `--method DELETE`, whose
  # leading dashes grep would otherwise read as its own options.
  [ -f "$HR/calls-$1" ] || { echo 0; return; }
  grep -cF -- "$2" "$HR/calls-$1" || true
}
hr_marks() { # $1 PR, $2 marker → how many comments carrying it were posted
  [ -f "$HR/posted-$1" ] || { echo 0; return; }
  grep -cF -- "$2" "$HR/posted-$1" || true
}

# -- the round passes: the machine asks, and marks what it asked ------------
hr_pass_rc=0
hr_pass="$(hr_probe 940 approve "" none)" || hr_pass_rc=$?
expect "the passing round's sweep exits 0" 0 "$hr_pass_rc"
expect "...requesting the human exactly once" 1 \
  "$(hr_calls 940 'requested_reviewers')"
expect "...as a write and never a DELETE" 0 \
  "$(hr_calls 940 '--method DELETE')"
expect "...and marking that ask as this machine's" 1 \
  "$(hr_marks 940 "$HUMAN_REQUEST_MARKER")"
expect "...saying in words whose ask it is" yes \
  "$(grep -qF "the sweep's own, and provisional" "$HR/posted-940" && echo yes || echo no)"
expect "...and logging the mark" yes \
  "$(grep -q "#940: marked the $HUMAN request as this machine's" <<<"$hr_pass" \
    && echo yes || echo no)"

# -- the round stops passing: withdrawn, and marked withdrawn ---------------
hr_wd_rc=0
hr_wd="$(hr_probe 941 missing "$HUMAN" machine)" || hr_wd_rc=$?
expect "the withdrawing sweep exits 0" 0 "$hr_wd_rc"
expect "...taking the machine's own request back" 1 \
  "$(hr_calls 941 '--method DELETE')"
expect "...and saying so on the PR" 1 \
  "$(hr_marks 941 "$HUMAN_REQUEST_WITHDRAWN_MARKER")"
expect "...and never re-asking in the same pass" 0 \
  "$(hr_marks 941 "$HUMAN_REQUEST_MARKER")"
expect "...leaving the board on the builder with the stall named" yes \
  "$(grep -q 'state:addressing' "$HR/edits-941" \
    && grep -q 'blocker:unrequested' "$HR/edits-941" && echo yes || echo no)"
expect "...and logging the withdrawal against the state that caused it" yes \
  "$(grep -q "#941: withdrew this machine's $HUMAN request (state is state:addressing)" \
    <<<"$hr_wd" && echo yes || echo no)"

# -- the SAME round with a maintainer's request: nothing is withdrawn -------
# The discriminating twin. Every input but the mark is 941's.
hr_keep_rc=0
hr_keep="$(hr_probe 942 missing "$HUMAN" none)" || hr_keep_rc=$?
expect "the maintainer-claim sweep exits 0" 0 "$hr_keep_rc"
expect "...withdrawing nothing" 0 "$(hr_calls 942 '--method DELETE')"
expect "...posting no withdrawal mark" 0 \
  "$(hr_marks 942 "$HUMAN_REQUEST_WITHDRAWN_MARKER")"
expect "...and leaving the deliberate claim on the board" yes \
  "$(grep -q 'state:needs-human' "$HR/edits-942" && echo yes || echo no)"
expect "...with no unrequested blocker against it" no \
  "$(grep -q 'blocker:unrequested' "$HR/edits-942" && echo yes || echo no)"
expect "...and logging no withdrawal at all" no \
  "$(grep -q '#942: withdrew' <<<"$hr_keep" && echo yes || echo no)"

# -- the push, which is where the withdrawal's own gate is graded -----------
# 942 above cannot grade that gate: its round leaves `desired` on
# state:needs-human, so the withdrawal returns at its FIRST condition and the
# mark is never consulted — a silent case satisfied by a step that never ran.
# These two are the same push-staled round, differing in the mark alone, and
# they are what a gate-removing mutation reds.
hr_push_keep_rc=0
hr_push_keep="$(hr_probe 948 stale "$HUMAN" none)" || hr_push_keep_rc=$?
expect "the push-staled sweep over a maintainer's request exits 0" 0 "$hr_push_keep_rc"
expect "...moving the board to the builder, the round having come apart" yes \
  "$(grep -q 'state:addressing' "$HR/edits-948" && echo yes || echo no)"
expect "...and withdrawing nothing, the request being none of its own" 0 \
  "$(hr_calls 948 '--method DELETE')"
expect "...and saying nothing about a withdrawal" no \
  "$(grep -q '#948: withdrew' <<<"$hr_push_keep" && echo yes || echo no)"
hr_push_wd_rc=0
hr_push_wd="$(hr_probe 949 stale "$HUMAN" machine)" || hr_push_wd_rc=$?
expect "the same push over this machine's own request exits 0" 0 "$hr_push_wd_rc"
expect "...and moves the board to the builder alike" yes \
  "$(grep -q 'state:addressing' "$HR/edits-949" && echo yes || echo no)"
expect "...but withdraws the ask it made" 1 "$(hr_calls 949 '--method DELETE')"
expect "...and marks the withdrawal" 1 \
  "$(hr_marks 949 "$HUMAN_REQUEST_WITHDRAWN_MARKER")"
expect "...logging it against the state the push produced" yes \
  "$(grep -q "#949: withdrew this machine's $HUMAN request (state is state:addressing)" \
    <<<"$hr_push_wd" && echo yes || echo no)"

# -- a request this machine already withdrew is not withdrawn twice ---------
hr_again_rc=0
hr_again="$(hr_probe 943 missing "$HUMAN" withdrawn)" || hr_again_rc=$?
expect "a superseded mark withdraws nothing" 0 "$(hr_calls 943 '--method DELETE')"
expect "...and its sweep exits 0" 0 "$hr_again_rc"
expect "...and logs no second withdrawal" no \
  "$(grep -q '#943: withdrew' <<<"$hr_again" && echo yes || echo no)"

# -- no standing request: nothing to withdraw, and nothing to read ----------
hr_noop_rc=0
hr_noop="$(hr_probe 944 missing "" machine)" || hr_noop_rc=$?
expect "a PR with no standing request exits the sweep 0" 0 "$hr_noop_rc"
expect "...issuing no DELETE" 0 "$(hr_calls 944 '--method DELETE')"
# The read is gated on the request, so an ordinary PR pays nothing for #479:
# the only comments read left is the stale clock's own.
expect "...and reading no marks it has no request to judge" 0 \
  "$(hr_calls 944 'split(' )"
expect "...while the stall is still named, the exemption having nothing to exempt" yes \
  "$(grep -q 'blocker:unrequested' "$HR/edits-944" && echo yes || echo no)"
expect "...and the sweep runs to the end of its loop" 1 \
  "$(grep -c '^labels: reconciled\.$' <<<"$hr_noop")"

# -- an unreadable mark leaves the request exactly where it is --------------
hr_blind_rc=0
hr_blind="$(hr_probe 945 missing "$HUMAN" unreadable)" || hr_blind_rc=$?
expect "an unreadable mark exits the sweep 0" 0 "$hr_blind_rc"
expect "...saying why, in this file's degraded-read shape" yes \
  "$(grep -q "#945: human-request marks unreadable" <<<"$hr_blind" && echo yes || echo no)"
expect "...and withdrawing nothing on a fact it did not read" 0 \
  "$(hr_calls 945 '--method DELETE')"

# -- a maintainer's standing request is never double-asked ------------------
# The round passes with the human already requested: human_request_needed
# refuses, so this pass asks nobody — and marks nobody, or the next pass would
# read a maintainer's request as this machine's.
hr_dbl_rc=0
hr_dbl="$(hr_probe 946 approve "$HUMAN" none)" || hr_dbl_rc=$?
expect "a passing round over a standing request exits 0" 0 "$hr_dbl_rc"
expect "...requesting nobody a second time" 0 \
  "$(hr_calls 946 'requested_reviewers')"
expect "...and marking nothing it did not ask for" 0 \
  "$(hr_marks 946 "$HUMAN_REQUEST_MARKER")"
expect "...and logging no request it did not make" no \
  "$(grep -q "#946: requested $HUMAN" <<<"$hr_dbl" && echo yes || echo no)"

# -- D5: a refused DELETE logs and the sweep continues ----------------------
hr_del_rc=0
hr_del="$(HR_DELETE_RC=1 hr_probe 947 missing "$HUMAN" machine)" || hr_del_rc=$?
expect "a refused withdrawal does not fail the sweep" 0 "$hr_del_rc"
expect "...and says the mark stands so the next sweep retries" yes \
  "$(grep -q "#947: WARNING: could not withdraw this machine's $HUMAN request" \
    <<<"$hr_del" && echo yes || echo no)"
expect "...writing no withdrawal mark over a withdrawal that did not happen" 0 \
  "$(hr_marks 947 "$HUMAN_REQUEST_WITHDRAWN_MARKER")"
expect "...while the pass still converges the board" yes \
  "$(grep -q 'state:addressing' "$HR/edits-947" && echo yes || echo no)"

# -- the order inside the act: DELETE first, its mark second ---------------
# Asserted on the source, because the failing-DELETE fixture above can only
# show that no mark was written — not that a mark would have been written
# first had the call been made in the other order.
hr_body="$(awk '/^reconcile_human_request\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh | grep -v '^[[:space:]]*#' || true)"
expect "the withdrawal calls DELETE before it marks the withdrawal" yes \
  "$(awk -v d=0 -v m=0 '/--method DELETE/ && !d {d=NR}
      /HUMAN_REQUEST_WITHDRAWN_MARKER/ && !m {m=NR}
      END{print (d && m && d < m) ? "yes" : "no"}' <<<"$hr_body")"
expect "...and re-reads no requested_reviewers of its own" 1 \
  "$(grep -c 'requested_reviewers' <<<"$hr_body")"
expect "...and re-evaluates no human_request_needed" no \
  "$(grep -q 'human_request_needed' <<<"$hr_body" && echo yes || echo no)"

# -- DRY_RUN: a rehearsal sees both acts on the board ----------------------
# The two marks redirect run()'s stdout, which spends their own narration —
# the whole comment family's treatment (#411's reading of it). What must
# survive is the ACT each one records, so this asserts the request and the
# withdrawal narrate, not the bookkeeping about them.
hr_dry="$(DRY_RUN=1 hr_probe 950 stale "$HUMAN" machine)"
expect "a rehearsal narrates the withdrawal it would perform" yes \
  "$(grep -qF "DRY_RUN: gh api --method DELETE repos/owner/repo/pulls/950/requested_reviewers" \
    <<<"$hr_dry" && echo yes || echo no)"
hr_dry_ask="$(DRY_RUN=1 hr_probe 951 approve "" none)"
expect "...and the request it would make" yes \
  "$(grep -qF "DRY_RUN: gh api repos/owner/repo/pulls/951/requested_reviewers" \
    <<<"$hr_dry_ask" && echo yes || echo no)"
expect "...performing neither" 0 \
  "$(( $(hr_calls 950 'requested_reviewers') + $(hr_calls 951 'requested_reviewers') ))"
# The caller half: the act is handed the pass's own answers, never a re-ask.
expect "reconcile_pr passes desired and the recorded ask into the act" yes \
  "$(grep -q "reconcile_human_request \"\\\$n\" \"\\\$desired\" \"\\\$human_requested\"" \
    <<<"$am_pr_body" && echo yes || echo no)"

# -- LABELS.md names which request the precedence is about (#479) -----------
# Wrap-tolerantly: the sentence is prose in a wrapped file, and a line break
# inside the phrase would hide it from a line-oriented grep while the doc says
# exactly what the criterion asks for.
labels_md_flat="$(tr '\n' ' ' <LABELS.md | tr -s ' ')"
expect "LABELS.md says the precedence is the maintainer's, in the code's words" yes \
  "$(grep -qF 'a maintainer pulling a PR to themselves early is a deliberate act' \
    <<<"$labels_md_flat" && echo yes || echo no)"
expect "...and that the machine's own ask is marked and withdrawn" yes \
  "$(grep -qF "$HUMAN_REQUEST_MARKER" LABELS.md && echo yes || echo no)"


# ---------------------------------------------------------------------------
# The release-shape guard's notice (#501). #130's guard fired on 21 sweep
# passes over #500 and reached nobody: a `::warning::` attaches to the check
# run that emitted it, and the sweep's runs belong to `main`, never to a PR
# head. The cut merged unlabelled and published nothing. What these fixtures
# pin is that the same guard now says so ON THE PULL REQUEST, once per episode,
# and takes it back when `release` arrives — and that it still never writes the
# label.
#
# The fixture conf is re-loaded first. Blocks above this one drive `main` with
# the SHIPPED `.github/labels.conf`, and a roster read from there would bind
# these probes to today's panel size (#304's defect, one insertion point later).
# ---------------------------------------------------------------------------
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"

SH="$RTMP/shape"
mkdir -p "$SH"

shape_probe() { # $1 PR, $2 labels (newline-separated), $3 head version, $4 base version, $5 draft
  # SHAPE_COMMENTS_RC / SHAPE_COMMENT_RC are the exit status the stubbed read
  # and the stubbed post return, each defaulting to the happy path — the two
  # cases the positional shape has no room for.
  (
    local n="$1" at
    at="$(iso_at $((RNOW - 3600)))"
    # The taxonomy from the script's own arrays, plus the hand-set names this
    # pass can name. `release` is in it deliberately: a fixture whose taxonomy
    # lacked the label could not tell "never writes it" from "could not".
    REPO_LABELS="$(printf '%s\n' "${STATES[@]}" "${BLOCKERS[@]}" \
      merge-next stale needs-ruling blocked release)"
    REPO=owner/repo NOW="$RNOW"
    LABELS="$2"
    DRAFT="${5:-false}" HEAD_SHA=shapehead BASE_SHA=shapebase REQUESTED=""
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    # A standing block, so the round parks the PR at state:addressing: the
    # guard is orthogonal to the round, and a passing one would drag the human
    # request and the auto-merge path into every assertion below.
    REVIEWS_JSON="$(reviews \
      "$(rev "$BOT1" CHANGES_REQUESTED shapehead "" "$at")" \
      "$(rev "$BOT2" APPROVED shapehead "" "$at")" \
      "$(rev "$BOT3" APPROVED shapehead "" "$at")")"
    PR_JSON="$(jq -n --arg at "$at" '{created_at: $at, assignees: []}')"
    SHAPE_HEAD_VER="$3" SHAPE_BASE_VER="$4"
    gh() {
      # every call in call ORDER, which is what pins where in the pass the
      # comment lands relative to the reads that measure the PR's activity
      printf '%s\n' "$*" >>"$SH/calls-$n"
      if [ "$1" = api ]; then
        # The two version reads, intercepted ahead of the generic handler:
        # their endpoints carry a `?ref=` query the file mapping below has no
        # shape for, and what they return is `.content`, which tree_version
        # base64-decodes. An empty version answers nothing at all — the API
        # failure tree_version's every-failure-path-prints-nothing contract
        # collapses to "not readable".
        case "$*" in
          *"contents/VERSION?ref=shapehead"*)
            [ -n "$SHAPE_HEAD_VER" ] || return 1
            printf '%s' "$SHAPE_HEAD_VER" | base64 | tr -d '\n'
            printf '\n'
            return 0 ;;
          *"contents/VERSION?ref=shapebase"*)
            [ -n "$SHAPE_BASE_VER" ] || return 1
            printf '%s' "$SHAPE_BASE_VER" | base64 | tr -d '\n'
            printf '\n'
            return 0 ;;
          *contents/package.json*) return 1 ;;
        esac
        case "$*" in
          *"issues/$n/comments"*) [ "${SHAPE_COMMENTS_RC:-0}" = 0 ] \
            || return "${SHAPE_COMMENTS_RC:-0}" ;;
        esac
        shift
        local jqexpr="" endpoint="" file
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        file="$SH/$(printf '%s' "$endpoint" | tr '/' '_').json"
        [ -f "$file" ] || { printf '[]\n' | jq -r "${jqexpr:-.}"; return 0; }
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local c="$3" body="" file
        # a post that failed records NOTHING — no body, no marker in the
        # fixture — which is the state the retry path depends on
        [ "${SHAPE_COMMENT_RC:-0}" = 0 ] || return "$SHAPE_COMMENT_RC"
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$SH/posted-$c"
        # posted comments go back into the fixture, so the NEXT pass reads
        # this one's marker exactly as a real sweep would
        file="$SH/repos_owner_repo_issues_${c}_comments.json"
        [ -f "$file" ] || printf '[]\n' >"$file"
        jq --arg b "$body" --arg at "$(iso_at "$RNOW")" \
          '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/sh","body":$b}]' \
          "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf '%s\n' "$*" >>"$SH/edits-$3"
      fi
    }
    reconcile_pr "$n" 2>&1
  )
}

notice_count() { # $1 PR → release-shape notices standing on it
  [ -f "$SH/posted-$1" ] || { echo 0; return; }
  grep -cF "$RELEASE_SHAPE_NOTICE_MARKER_PREFIX" "$SH/posted-$1" || true
}
retraction_count() { # $1 PR → retractions standing on it
  [ -f "$SH/posted-$1" ] || { echo 0; return; }
  grep -cF "$RELEASE_SHAPE_RETRACTED_MARKER" "$SH/posted-$1" || true
}

# -- the #500 scenario, which is the reason this exists ---------------------
shape500="$(shape_probe 500 state:needs-human 0.7.6 0.7.6-dev)"
expect "a release-shaped non-draft PR with no release label is told, on the PR" 1 \
  "$(notice_count 500)"
expect "...and the annotation still fires beside it (#501 D1)" yes \
  "$(grep -qF '::warning::labels: #500 is release-shaped' <<<"$shape500" && echo yes || echo no)"
expect "...naming the transition it read" yes \
  "$(grep -qF "declares version \`0.7.6\` where its base declares" "$SH/posted-500" \
    && grep -qF '0.7.6-dev' "$SH/posted-500" && echo yes || echo no)"
expect "...naming what the merge does without the label" yes \
  "$(grep -qF 'What happens on the merge without it' "$SH/posted-500" \
    && grep -qF 'creates nothing' "$SH/posted-500" && echo yes || echo no)"
expect "...and the remedy, in the annotation's own terms" yes \
  "$(grep -qF "apply \`release\` before the merge" "$SH/posted-500" && echo yes || echo no)"
expect "...saying the machine will not apply it (#501 D4)" yes \
  "$(grep -qF 'This machine will not apply it for you' "$SH/posted-500" && echo yes || echo no)"
expect "...and logged as what it is" yes \
  "$(grep -q 'release-shaped (0.7.6-dev -> 0.7.6) with no release label — commented' \
    <<<"$shape500" && echo yes || echo no)"

# -- the episode bound: 21 passes was the measured number over #500 ---------
for _ in $(seq 1 21); do
  shape_probe 500 state:needs-human 0.7.6 0.7.6-dev >/dev/null
done
expect "twenty-two passes over one episode post one comment in total" 1 \
  "$(notice_count 500)"

# -- the retraction, and its own idempotency (#501 D2) ----------------------
shape_ret="$(shape_probe 500 $'state:needs-human\nrelease' 0.7.6 0.7.6-dev)"
expect "applying release retracts the notice" 1 "$(retraction_count 500)"
expect "...saying the label is what changed" yes \
  "$(grep -qF "this pull request carries \`release\` now" "$SH/posted-500" && echo yes || echo no)"
expect "...and logged as the retraction it is" yes \
  "$(grep -q 'release label arrived — retracted the release-shape notice' \
    <<<"$shape_ret" && echo yes || echo no)"
for _ in 1 2 3 4 5; do
  shape_probe 500 $'state:needs-human\nrelease' 0.7.6 0.7.6-dev >/dev/null
done
expect "...and five more passes under the label add none" 1 "$(retraction_count 500)"
expect "...nor a second notice" 1 "$(notice_count 500)"

# The retraction is NOT gated on draft, and that is a choice rather than an
# oversight of D5's exemption: the engine returns a PR to draft at every round
# close, so a release PR labelled while drafted is the ordinary case and gating
# here would strand the false claim on exactly those PRs. Pinned because a
# `[ "$DRAFT" = true ]` guard added to the retraction reddened nothing in this
# file when the mutation set was run.
shape_probe 517 state:needs-human 0.7.6 0.7.6-dev >/dev/null
expect "a non-draft release-shaped PR is told (setup)" 1 "$(notice_count 517)"
shape_draft_ret="$(shape_probe 517 $'state:building\nrelease' 0.7.6 0.7.6-dev true)"
expect "the label arriving while the PR is DRAFT still retracts the notice" 1 \
  "$(retraction_count 517)"
expect "...and says so in the log like any other retraction" yes \
  "$(grep -q 'release label arrived — retracted the release-shape notice' \
    <<<"$shape_draft_ret" && echo yes || echo no)"
expect "a labelled draft that was never told draws no retraction (control)" 0 \
  "$(shape_probe 518 $'state:building\nrelease' 0.7.6 0.7.6-dev true >/dev/null
    retraction_count 518)"

# The episode boundary D3 names: the label comes off again, and the PR is told
# again. The retraction is what closes the episode, which is why the pair is
# read newest-wins rather than as a tally.
shape_probe 500 state:needs-human 0.7.6 0.7.6-dev >/dev/null
expect "a label lost and regained opens a new episode" 2 "$(notice_count 500)"
shape_probe 500 state:needs-human 0.7.6 0.7.6-dev >/dev/null
expect "...which then repeats itself no more than the first did" 2 "$(notice_count 500)"

# The other boundary, and the one that is mine rather than D3's: the marker
# carries the TRANSITION, so a PR whose declared version moves is a new fact
# and says so — while a standing notice can never name a transition the tree
# no longer has.
shape_probe 500 state:needs-human 0.7.7 0.7.6-dev >/dev/null
expect "a changed transition is a new episode" 3 "$(notice_count 500)"
shape_probe 500 state:needs-human 0.7.7 0.7.6-dev >/dev/null
expect "...and that one is bounded too" 3 "$(notice_count 500)"

# -- the must-not-fire set, each on its own PR so the count is its own ------
shape_labeled="$(shape_probe 510 $'state:bots-reviewing\nrelease' 0.7.6 0.7.6-dev)"
expect "a PR carrying release from the start draws no notice" 0 "$(notice_count 510)"
expect "...and no retraction either: nothing was ever said to take back" 0 \
  "$(retraction_count 510)"
expect "...and no annotation, the gate never having read a version" no \
  "$(grep -q '::warning::labels: #510' <<<"$shape_labeled" && echo yes || echo no)"
expect "...on a pass that did run — the label closed the gate, not the harness" yes \
  "$(grep -q '#510: state -> ' <<<"$shape_labeled" && echo yes || echo no)"
expect "...and paid for no version read either" 0 \
  "$(grep -c 'contents/VERSION' "$SH/calls-510" || true)"

shape_draft="$(shape_probe 511 state:building 0.7.6 0.7.6-dev true)"
expect "a draft is silent — the build phase is the builder's (#501 D5)" 0 \
  "$(notice_count 511)"
expect "...and pays for no version read at all" 0 \
  "$(grep -c 'contents/VERSION' "$SH/calls-511" || true)"
expect "...and draws no annotation" no \
  "$(grep -q '::warning::labels: #511' <<<"$shape_draft" && echo yes || echo no)"

expect "an unreadable head version is silent — never nag on a guess" 0 \
  "$(shape_probe 512 state:bots-reviewing "" 0.7.6-dev >/dev/null; notice_count 512)"
expect "an ordinary -dev head is silent" 0 \
  "$(shape_probe 513 state:bots-reviewing 0.7.7-dev 0.7.6-dev >/dev/null; notice_count 513)"
expect "an rc head is silent — pre-releases are not the merge door's shape" 0 \
  "$(shape_probe 514 state:bots-reviewing 0.7.6-rc1 0.7.6-dev >/dev/null; notice_count 514)"
expect "a bare head equal to its base is silent" 0 \
  "$(shape_probe 515 state:bots-reviewing 0.7.6 0.7.6 >/dev/null; notice_count 515)"
# The positive flag beside each silence. A must-not-fire case is satisfied by a
# pass that never reached the guard at all, and every one of the four above
# would read the same if the gate had closed on some other ground — so each is
# asserted to have OPENED the gate and read the head version it then declined
# to act on. (511's silence has the opposite flag, asserted with it: the draft
# gate is supposed to close before the read.)
for sh_silent in 512 513 514 515; do
  expect "...case $sh_silent reached the guard and read a head version" yes \
    "$(grep -q 'contents/VERSION?ref=shapehead' "$SH/calls-$sh_silent" && echo yes || echo no)"
done

# The base half is the annotation's own carve-out and the notice keeps it: an
# unreadable BASE still speaks, because the head alone is the release shape.
shape_probe 516 state:bots-reviewing 0.7.6 "" >/dev/null
expect "a bare head over an unreadable base still speaks" 1 "$(notice_count 516)"
expect "...saying so in the marker rather than leaving it blank" yes \
  "$(grep -qF 'release-shape-notice:unreadable->0.7.6' "$SH/posted-516" && echo yes || echo no)"
shape_probe 516 state:bots-reviewing 0.7.6 "" >/dev/null
expect "...and that episode is bounded like any other" 1 "$(notice_count 516)"

# -- an unreadable comment list must not invent a repeat --------------------
shape_unreadable="$(SHAPE_COMMENTS_RC=1 shape_probe 520 state:bots-reviewing 0.7.6 0.7.6-dev)"
expect "an unreadable comment list says so" yes \
  "$(grep -q 'release-shape marks unreadable — no notice invented this pass' \
    <<<"$shape_unreadable" && echo yes || echo no)"
expect "...and posts nothing on a fact it could not read" 0 "$(notice_count 520)"
expect "...while the annotation, which reads nothing, still fires" yes \
  "$(grep -qF '::warning::labels: #520 is release-shaped' <<<"$shape_unreadable" \
    && echo yes || echo no)"
shape_ret_unreadable="$(shape_probe 520 state:bots-reviewing 0.7.6 0.7.6-dev >/dev/null
  SHAPE_COMMENTS_RC=1 shape_probe 520 $'state:bots-reviewing\nrelease' 0.7.6 0.7.6-dev)"
expect "an unreadable list invents no retraction either" yes \
  "$(grep -q 'release-shape marks unreadable — no retraction invented this pass' \
    <<<"$shape_ret_unreadable" && echo yes || echo no)"
expect "...leaving the notice standing to be taken back next pass" 0 \
  "$(retraction_count 520)"
shape_probe 520 $'state:bots-reviewing\nrelease' 0.7.6 0.7.6-dev >/dev/null
expect "...which the next readable pass does" 1 "$(retraction_count 520)"

# -- a comment that failed to post is not logged as one ---------------------
shape_failed="$(SHAPE_COMMENT_RC=1 shape_probe 521 state:bots-reviewing 0.7.6 0.7.6-dev)"
expect "a failed post is logged as a failure, not as a comment" yes \
  "$(grep -q 'WARNING: release-shaped (0.7.6-dev -> 0.7.6) with no release label — the comment failed to post' \
    <<<"$shape_failed" && echo yes || echo no)"
expect "...and not as one made" no \
  "$(grep -q -- '— commented' <<<"$shape_failed" && echo yes || echo no)"
expect "...recording no marker, so nothing standing on the PR" 0 "$(notice_count 521)"
shape_probe 521 state:bots-reviewing 0.7.6 0.7.6-dev >/dev/null
expect "...and the next sweep retries the same episode" 1 "$(notice_count 521)"

# -- the comment is not counted as the PR's own activity --------------------
# reconcile_ruling's and the take-back's comments run after the last_activity
# read for this reason; this one now does too. A machine comment read back as a
# sign of life is the sweep believing its own noise.
shape_probe 522 state:bots-reviewing 0.7.6 0.7.6-dev >/dev/null
sh_commented_at="$(grep -n 'issue comment' "$SH/calls-522" | head -1 | cut -d: -f1 || true)"
sh_activity_at="$(grep -n 'created_at' "$SH/calls-522" | tail -1 | cut -d: -f1 || true)"
expect "the pass reads the PR's activity before posting its own notice" yes \
  "$([ -n "$sh_commented_at" ] && [ -n "$sh_activity_at" ] \
    && [ "$sh_commented_at" -gt "$sh_activity_at" ] && echo yes || echo no)"

# -- D4, asked of the code and not of one fixture's silence -----------------
# Every label name this file can apply or remove: the literals at its write
# sites, plus the machine-owned arrays the converge loop feeds to
# --add-label/--remove-label. `release` is in none of them, and that is the
# assertion — a fixture that merely made no such write would keep passing after
# a change that started making one on some other path.
shape_writable="$(
  {
    printf '%s\n' "${STATES[@]}" "${BLOCKERS[@]}" "${RETIRED[@]}"
    grep -oE -- '--(add|remove)-label [a-zA-Z:-]+' \
      actions/labels-reconcile/labels-reconcile.sh | awk '{print $2}'
  } | sort -u
)"
expect "no label this file can write is 'release' (#501 D4)" no \
  "$(grep -qxF release <<<"$shape_writable" && echo yes || echo no)"
expect "...over a set that is actually populated" yes \
  "$([ "$(grep -c . <<<"$shape_writable")" -gt 4 ] && echo yes || echo no)"
expect "...and the set does contain the labels it really writes (control)" yes \
  "$(grep -qxF merge-next <<<"$shape_writable" \
    && grep -qxF state:needs-human <<<"$shape_writable" && echo yes || echo no)"
# ...and the behavioural half beside it: over every probe above, across the
# labelled and unlabelled episodes both, no edit call named the label.
expect "no probe pass ever edited the release label" no \
  "$(cat "$SH"/edits-* 2>/dev/null | grep -qE -- '-label ([a-z:,-]*,)?release(,|$)' \
    && echo yes || echo no)"
expect "...over edit calls that were really made (control)" yes \
  "$([ -s "$SH/edits-500" ] && echo yes || echo no)"

# -- the parse, driven directly ---------------------------------------------
expect "the marker names the transition" \
  '<!-- ceremony:release-shape-notice:1.0.0-dev->1.0.0 -->' \
  "$(release_shape_marker 1.0.0-dev 1.0.0)"
expect "an unreadable base has one stable spelling, not a blank" \
  '<!-- ceremony:release-shape-notice:unreadable->1.0.0 -->' \
  "$(release_shape_marker "" 1.0.0)"
expect "no marks at all is NONE" NONE "$(release_shape_state </dev/null)"
expect "a notice alone stands" '<!-- ceremony:release-shape-notice:a->b -->' \
  "$(release_shape_state <<<'<!-- ceremony:release-shape-notice:a->b -->')"
expect "a retraction after it closes the episode" RETRACTED \
  "$(printf '%s\n%s\n' '<!-- ceremony:release-shape-notice:a->b -->' \
    "$RELEASE_SHAPE_RETRACTED_MARKER" | release_shape_state)"
expect "a notice after a retraction opens the next one" \
  '<!-- ceremony:release-shape-notice:a->b -->' \
  "$(printf '%s\n%s\n' "$RELEASE_SHAPE_RETRACTED_MARKER" \
    '<!-- ceremony:release-shape-notice:a->b -->' | release_shape_state)"
expect "an unrelated comment moves nothing" RETRACTED \
  "$(printf '%s\n%s\n%s\n' '<!-- ceremony:release-shape-notice:a->b -->' \
    "$RELEASE_SHAPE_RETRACTED_MARKER" 'looks fine to me' | release_shape_state)"
expect "the newest of two notices is the one that stands" \
  '<!-- ceremony:release-shape-notice:c->d -->' \
  "$(printf '%s\n%s\n' '<!-- ceremony:release-shape-notice:a->b -->' \
    '<!-- ceremony:release-shape-notice:c->d -->' | release_shape_state)"

# The shape rule itself, in the one place both surfaces read it.
shape_says() { release_shaped "$1" "$2" && echo yes || echo no; }
expect "a bare head over a -dev base is a shape" yes "$(shape_says 2.0.0 2.0.0-dev)"
expect "a bare head over an unreadable base is a shape" yes "$(shape_says 2.0.0 "")"
expect "an unreadable head is not" no "$(shape_says "" 2.0.0-dev)"
expect "an rc head is not" no "$(shape_says 2.0.0-rc1 2.0.0-dev)"
expect "a head equal to its base is not" no "$(shape_says 2.0.0 2.0.0)"
expect "a two-part version is not" no "$(shape_says 2.0 2.0-dev)"

# -- DRY_RUN: a rehearsal sees the act ---------------------------------------
# NOT redirected into /dev/null, unlike the take-back and human-request marks:
# those redirect because each records an act narrated elsewhere, and here the
# comment IS the act. A rehearsal that said nothing about it would be a
# rehearsal of nothing.
shape_dry="$(DRY_RUN=1 shape_probe 530 state:bots-reviewing 0.7.6 0.7.6-dev)"
expect "a rehearsal narrates the notice it would post" yes \
  "$(grep -qF 'DRY_RUN: gh issue comment 530' <<<"$shape_dry" && echo yes || echo no)"
expect "...and posts nothing" 0 "$(notice_count 530)"
shape_probe 531 state:bots-reviewing 0.7.6 0.7.6-dev >/dev/null
shape_dry_ret="$(DRY_RUN=1 shape_probe 531 $'state:bots-reviewing\nrelease' 0.7.6 0.7.6-dev)"
expect "...and the retraction it would post" yes \
  "$(grep -qF 'DRY_RUN: gh issue comment 531' <<<"$shape_dry_ret" && echo yes || echo no)"
expect "...performing neither" 0 "$(retraction_count 531)"

# -- the call site, which is where the ordering lives -------------------------
shape_pr_body="$(awk '/^reconcile_pr\(\)/{inside=1} inside{print} inside && /^}/{exit}' \
  actions/labels-reconcile/labels-reconcile.sh)"
expect "the notice is called after the last_activity read" yes \
  "$(awk '/last_activity="\$\(/ && !a {a=NR}
      /reconcile_release_shape/ && !c {c=NR}
      END{print (a && c && a < c) ? "yes" : "no"}' <<<"$shape_pr_body")"
expect "...and the annotation before it, at the gate that did not move (#501 D5)" yes \
  "$(awk '/release_shape_warning/ && !w {w=NR}
      /last_activity="\$\(/ && !a {a=NR}
      END{print (w && a && w < a) ? "yes" : "no"}' <<<"$shape_pr_body")"
expect "...under the gate D5 keeps: not a draft, and no release label" yes \
  "$(grep -qF "[ \"\$DRAFT\" != true ] && ! has_label release" <<<"$shape_pr_body" \
    && echo yes || echo no)"
expect "...and nothing was added below the merge (#460 D1)" yes \
  "$(awk '/reconcile_release_shape/ && !c {c=NR}
      /reconcile_auto_merge/ && !m {m=NR}
      END{print (c && m && c < m) ? "yes" : "no"}' <<<"$shape_pr_body")"

# -- the guide stops claiming the guard works (#501 D7) ----------------------
# Wrap-tolerantly: the sentence is prose in a wrapped file, and a line break
# inside the phrase would hide it from a line-oriented grep.
consumers_flat="$(tr '\n' ' ' <docs/CONSUMERS.md | tr -s ' ')"
expect "the guide no longer says the sweep says so first, with nowhere named" no \
  "$(grep -qF 'the merge door would refuse that merge, and the sweep says so first' \
    <<<"$consumers_flat" && echo yes || echo no)"
expect "...it names the surface the notice arrives on" yes \
  "$(grep -qF 'a comment on the pull request' <<<"$consumers_flat" && echo yes || echo no)"
expect "...says the notice is retracted when the label arrives" yes \
  "$(grep -qF 'retracted when the label arrives' <<<"$consumers_flat" && echo yes || echo no)"
expect "...and is honest about what the annotation alone could reach" yes \
  "$(grep -qF 'not reachable from the pull request' <<<"$consumers_flat" && echo yes || echo no)"

# -- every label description fits GitHub's 100-character cap (#508) --------
# The API rejects a longer one with `422 description is too long`, and because
# bootstrap_labels() creates rows in order, one over-cap row truncated the
# taxonomy at that row: `operator` measured 106 and took `ready`, `claimed`,
# `epic`, `release` and every consumer `scope:*` row with it. Asserting the cap
# here means the next over-long row reds in this repo rather than in a
# stranger's first bootstrap.
over_cap="$(core_label_rows | awk -F'|' 'NF>=3 && length($3)>100 {printf "%s(%d) ", $1, length($3)}')"
expect "every core label description is within GitHub's 100-char cap" "" "$over_cap"

# The longest row today, so a future addition can see the headroom it has.
longest="$(core_label_rows | awk -F'|' 'NF>=3 {if (length($3)>m) m=length($3)} END{print m+0}')"
expect "...and the longest is under the cap" yes \
  "$([ "$longest" -le 100 ] && echo yes || echo no)"

# -- the create loop tolerates one bad row (#508) ---------------------------
# shellcheck disable=SC2016 # the '$' are literals in the script being grepped
# The retire loop below it always did; this one did not, and `set -e` turned a
# single 422 into a silently truncated taxonomy. Tolerance is what makes the
# cap test above a belt rather than the only line of defence.
expect "bootstrap_labels tolerates a failed create and continues" yes \
  "$(grep -qF 'failed_rows="$failed_rows $name"' actions/labels-reconcile/labels-reconcile.sh \
    && echo yes || echo no)"
expect "...and fails the run rather than passing a partial taxonomy" yes \
  "$(grep -qF 'the taxonomy is INCOMPLETE' actions/labels-reconcile/labels-reconcile.sh \
    && echo yes || echo no)"

# -- LABELS.md's table and core_label_rows() agree on `operator` (#508) -----
# The reword had to happen twice: LABELS.md publishes its own copy of every
# description, and its `operator` row differed in wording ("issue-only: an
# operator owns the work…") enough that a grep for the script's exact string
# did not find it. Two copies of one sentence with no assertion between them is
# how a doc goes stale without anything reporting it.
# shellcheck disable=SC2016 # backticks and '$' are LABELS.md/awk literals
op_script="$(core_label_rows | awk -F'|' '$1=="operator"{print $3}')"
# shellcheck disable=SC2016 # backticks are LABELS.md literals, not expansions
op_doc="$(grep -F '| `operator` | `#A371F7` |' LABELS.md \
  | sed 's/.*`#A371F7` | issue-only: //; s/ |$//')"
expect "LABELS.md's operator row matches the registry's description" yes \
  "$([ "$(printf '%s' "$op_script" | tr '[:upper:]' '[:lower:]')" = \
       "$(printf '%s' "$op_doc" | tr '[:upper:]' '[:lower:]')" ] && echo yes || echo no)"
expect "...and the doc copy is within the cap too" yes \
  "$([ "${#op_doc}" -le 100 ] && echo yes || echo no)"

printf 'labels-reconcile tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
