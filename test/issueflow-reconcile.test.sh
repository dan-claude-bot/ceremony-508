#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=actions/issueflow-reconcile/issueflow-reconcile.sh
source "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  'panel=one two' \
  'triage-actors=triage-one triage-two' \
  'scope:one|C5DEF5|First scope' >"$TMP/good.conf"
check "triage actors parse beside panel and labels" 0 "" load_issueflow_config "$TMP/good.conf"
load_issueflow_config "$TMP/good.conf"
check "triage actor is recognized" 0 "" is_triage_actor triage-two
check "non-triage actor is rejected" 1 "" is_triage_actor builder
printf '%s\n' 'panel=one' >"$TMP/missing.conf"
check "missing triage actors fails loudly" 1 "missing triage-actors=" load_issueflow_config "$TMP/missing.conf"
printf '%s\n' 'triage-actors=one' 'triage-actors=two' >"$TMP/duplicate.conf"
check "duplicate triage actors fails loudly" 1 "duplicate triage-actors" load_issueflow_config "$TMP/duplicate.conf"
# A panel[<login>]= row (#224 D8) must not take the issue board down: this
# loader ignores every line that is not triage-actors=. That tolerance was
# incidental; this row makes it deliberate, so a future tightening cannot
# break the sweep as a side effect.
printf '%s\n' \
  'panel=one two' \
  'panel[builder-z]=two' \
  'triage-actors=triage-one' >"$TMP/bracketed.conf"
check "a per-author panel row is tolerated by the issue-flow loader" 0 "" \
  load_issueflow_config "$TMP/bracketed.conf"

# The dogfood caller and reusable workflow must expose the same runtime facts
# as the documented consumer stub. Static pins catch YAML blocks drifting to
# the adjacent composite step, which otherwise fails only after merge.
check "dogfood caller wakes on issue events" 0 "  issues:" \
  grep -F "  issues:" "$ROOT/.github/workflows/self-labels.yml"
dogfood_pr_step="$(sed -n \
  '/name: reconcile state + stale (dogfood/,/name: reconcile issue flow/p' \
  "$ROOT/.github/workflows/labels-sweep.yml")"
# shellcheck disable=SC2016 # GitHub expressions are asserted as literals
check "dogfood PR reconcile receives repository" 0 '          REPO: ${{ github.repository }}' \
  grep -F '          REPO: ${{ github.repository }}' <<<"$dogfood_pr_step"
# shellcheck disable=SC2016 # GitHub expressions are asserted as literals
check "dogfood PR reconcile receives token" 0 '          GH_TOKEN: ${{ github.token }}' \
  grep -F '          GH_TOKEN: ${{ github.token }}' <<<"$dogfood_pr_step"

# Invariant 1: exactly one queue category.
check "one ready queue label is valid" 0 "KEEP" queue_decision <<<"ready"
check "zero queue labels is derivably needs-triage" 0 "ADD_NEEDS_TRIAGE" queue_decision <<<"enhancement"
check "multiple queue labels are ambiguous" 0 "FLAG_CONFLICT" queue_decision <<< $'ready\nblocked'
check "needs-triage plus queue is a conflict" 0 "FLAG_CONFLICT" queue_decision <<< $'needs-triage\nready'
check "claimed plus post-merge is a conflict" 0 "FLAG_CONFLICT" \
  queue_decision <<< $'claimed\npost-merge'
check "post-merge plus needs-ruling is healthy" 0 "KEEP" \
  queue_decision <<< $'post-merge\nneeds-ruling'

# Invariant 2: claims have an owner and either a PR or recent activity.
check "claim with open PR stays claimed" 0 "KEEP" claim_decision 1 true 999999
check "unassigned claim is flagged" 0 "FLAG_UNASSIGNED" claim_decision 0 false 60
check "quiet unassigned claim is also reclaimed" 0 "RECLAIM" claim_decision 0 false $((STALE_AFTER + 1))
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: below stale boundary stays claimed" 0 "KEEP" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96401' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: exact stale boundary stays claimed" 0 "KEEP" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96400' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: past stale boundary is reclaimed" 0 "RECLAIM" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96399' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansion belongs to the isolated bash -c process
check "invalid injected clock fails loudly" 1 "ISSUEFLOW_NOW must be UTC epoch seconds" \
  bash -c 'ISSUEFLOW_NOW=garbage source "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
check "reclaim marker is stable within a claim episode" 0 "claim-reclaimed-96399" \
  claim_reclaim_marker 96399
check "a later claim episode receives a new reclaim marker" 0 "claim-reclaimed-99999" \
  claim_reclaim_marker 99999
check "offsite exempts the claim clock" 0 "EXEMPT" claim_clock_exempt <<<"offsite"
check "needs-ruling still exempts through the shared gate" 0 "EXEMPT" \
  claim_clock_exempt <<<"needs-ruling"
check "both quiet flags still produce one exemption verdict" 0 "EXEMPT" \
  claim_clock_exempt <<< $'offsite\nneeds-ruling'
check "blocked does not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt <<<"blocked"
check "attention does not exempt a claimed issue" 0 "SWEEP" \
  claim_clock_exempt <<<"attention"
check "ready does not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt <<<"ready"
check "empty labels do not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt </dev/null
refs_body=$'Refs #12\nAlso refs: #8 and heavy-duty/rig#4.\nCloses #99\nNot refs-ish #7\nfix refs parsing from #200\nCloses #40; refs: none\nRefs #175 (split from #150)'
check "Refs parser returns only references owned by a valid Refs marker" 0 "" \
  test "$(refs_references <<<"$refs_body")" = $'8\n12\n175'
open_records=$'BODY\tRefs #5\nCLOSING\t9\nBODY\tRefs heavy-duty/rig#112\nBODY\tRefs #5\nCLOSING\t5'
check "open PR linkage unions closing and local Refs body references" 0 $'5\n9' \
  open_pr_issues <<<"$open_records"
check "cross-repo Refs never enter the local open PR set" 0 "" \
  open_pr_issues <<< $'BODY\tRefs heavy-duty/rig#112'
check "an issue named by both linkage paths appears exactly once" 0 "1" \
  grep -cxF 5 <<<"$(open_pr_issues <<<"$open_records")"
check "unchecked criteria preserve their source lines verbatim" 0 \
  $'- [ ] first criterion\n  * [ ] indented criterion\n1. [ ] numbered criterion' \
  unchecked_criteria <<< $'- [x] done\n- [ ] first criterion\r\n  * [ ] indented criterion\n1. [ ] numbered criterion'
check "merged Refs with unchecked criteria transitions" 0 "TRANSITION" \
  post_merge_decision 12 false false <<<"- [ ] verify after merge"
check "open Refs does not transition" 0 "KEEP" \
  post_merge_decision 12 true false <<<"- [ ] verify after merge"
check "a handled merged Refs episode does not transition again" 0 "KEEP" \
  post_merge_decision 12 false true <<<"- [ ] verify after merge"
check "merged Refs with all criteria checked does not transition" 0 "KEEP" \
  post_merge_decision 12 false false </dev/null

# The deliverable is the PR that merged last, not the one numbered highest
# (#242). The first row is crew#176's measured shape — #184 merged
# 19:05:16Z, #182 merged 19:05:18Z — so it fails against the old sort -n.
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z\n176\t182\t2026-07-30T19:05:18Z'
check "the later merge wins over the higher PR number" 0 "182" \
  post_merge_pr_for_issue 176
MERGED_REF_PR_RECORDS=$'12\t100\t2026-07-30T10:00:00Z\n12\t101\t2026-07-30T11:00:00Z'
check "number order agreeing with merge order still answers the later merge" 0 "101" \
  post_merge_pr_for_issue 12
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z\n321\t326\t2026-08-03T14:44:46Z\n176\t182\t2026-07-30T19:05:18Z\n321\t322\t2026-08-03T16:00:00Z'
check "interleaved issues each resolve to their own last merge" 0 "182" \
  post_merge_pr_for_issue 176
check "...and a neighbouring issue's later merge never leaks in" 0 "322" \
  post_merge_pr_for_issue 321
# Two PRs can share a mergedAt second, so the tie-break is specified rather
# than left to whichever record the sweep happened to emit first.
MERGED_REF_PR_RECORDS=$'55\t70\t2026-07-30T19:05:16Z\n55\t71\t2026-07-30T19:05:16Z'
check "an identical mergedAt breaks to the highest PR number" 0 "71" \
  post_merge_pr_for_issue 55
MERGED_REF_PR_RECORDS=$'55\t71\t2026-07-30T19:05:16Z\n55\t70\t2026-07-30T19:05:16Z'
check "...and swapping the two input lines gives the same answer" 0 "71" \
  post_merge_pr_for_issue 55
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z'
check "an issue with no merged Refs PR still answers empty" 0 "" \
  test -z "$(post_merge_pr_for_issue 999)"
check "...so its post-merge decision is KEEP" 0 "KEEP" \
  post_merge_decision "$(post_merge_pr_for_issue 999)" false false \
  <<<"- [ ] verify after merge"
MERGED_REF_PR_RECORDS=""
# mergedAt must stay a field on the merged-PR node set already fetched: the
# record shape gets richer, the request count does not (#242).
check "the sweep still issues exactly two GraphQL queries" 0 "2" \
  grep -c 'gh api graphql' "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
check "...with mergedAt selected on the merged-PR node it already fetched" 0 "" \
  grep -qF 'nodes { number mergedAt body }' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

check "one closed offsite PR nudges" 0 "NUDGE" offsite_resolved_decision <<<"CLOSED"
check "two closed offsite PRs nudge" 0 "NUDGE" offsite_resolved_decision <<< $'CLOSED\nCLOSED'
check "one open offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision <<< $'CLOSED\nOPEN'
check "no visible offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision </dev/null
check "an unreadable offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision <<< $'CLOSED\nUNKNOWN'

timeline='[
  {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}},
  {"event":"cross-referenced","source":{"issue":{"number":7,"repository":{"full_name":"heavy-duty/rig"}}}},
  {"event":"mentioned","source":{"issue":{"number":9,"repository":{"full_name":"heavy-duty/box"},"pull_request":{"url":"x"}}}},
  {"event":"assigned"}
]'
check "offsite timeline extracts only cross-referenced PRs" 0 "heavy-duty/rig#112" \
  offsite_cross_referenced_prs <<<"$timeline"
check "empty offsite timeline extracts nothing" 0 "" offsite_cross_referenced_prs <<<"[]"

# Invariant 3: blocked declarations parse and release only when all close.
refs="$(blocked_references <<< $'Context #99. Blocked by #12 (first), #7 (second). Blocks #44.')"
check "blocked declaration extracts only declared refs" 0 $'7\n12' printf '%s\n' "$refs"
body=$'Blocked by #12 (first),\n#7 (soft-wrapped second). Blocks #44.'
check "soft-wrapped blocker declaration retains continuation refs" 0 "" test \
  "$(blocked_references <<<"$body")" = $'7\n12'
body=$'Blocked by #12 (known)\nFollow-up context mentions #7 without a sentence boundary'
check "unterminated blocker prose errs toward retaining dependencies" 0 "" test \
  "$(blocked_references <<<"$body")" = $'7\n12'
body="Part of #1. Blocked by #11 (needs a ceremony tag to pin), #12 (must be executed from the guide), #19 (the conversion vendors the doctrine). Blocks #14, #15 (they inherit the pilot's lessons)."
check "real issue 13 inline blockers parse" 0 "" test \
  "$(blocked_references <<<"$body")" = $'11\n12\n19'
body="Part of #1. Blocked by #13 (inherits the pilot's lessons). Can run in parallel with #15."
check "real issue 14 inline blocker parses" 0 "" test \
  "$(blocked_references <<<"$body")" = "13"
body="Part of #1. Blocked by #13 (pilot lessons). Can run in parallel with #14."
check "real issue 15 inline blocker parses" 0 "" test \
  "$(blocked_references <<<"$body")" = "13"
body="Part of #1. Blocked by #11, #12 (needs a released ceremony + the bootstrap guide); benefits from #13's lessons but does not need #14/#15."
check "real issue 16 inline blockers parse" 0 "" test \
  "$(blocked_references <<<"$body")" = $'11\n12'
check "qualified short repository reference drops" 0 "" test \
  -z "$(blocked_references <<<"Blocked by rig#112.")"
check "qualified owner/repository reference drops" 0 "" test \
  -z "$(blocked_references <<<"Blocked by heavy-duty/box#9.")"
check "parenthesized local reference survives" 0 "13" blocked_references <<<"Blocked by (#13)."
check "slash-adjacent local references survive" 0 $'14\n15' \
  blocked_references <<<"Blocked by #14/#15."
check "comma-adjacent local references survive" 0 $'11\n12' \
  blocked_references <<<"Blocked by #11, #12."
# A repeated declaration contributes every sentence, not just the first —
# rig#154's body promoted on `#152` alone while #153 and #148 were open (#184).
body="Part of #151. Blocked by #152. Blocked by #153. Blocked by #148 — the registry PR merges under landed governance. Blocks #155."
check "repeated blocker sentences all contribute" 0 "" test \
  "$(blocked_references <<<"$body")" = $'148\n152\n153'
body=$'Note: restored because it is blocked by an operator act. See below.\nBlocked by #152, #153, #148.'
check "earlier blocked-by prose does not hijack the declaration" 0 "" test \
  "$(blocked_references <<<"$body")" = $'148\n152\n153'
body=$'This was blocked by #9 before the split.\nBlocked by #12.'
check "prose refs are retained beside the declaration, never substituted" 0 "" test \
  "$(blocked_references <<<"$body")" = $'9\n12'
repeated_refs="$(blocked_references <<<"Blocked by #152. Blocked by #153.")"
check "repeated declaration with one open blocker keeps issue blocked" 0 "KEEP" \
  blocked_decision "$repeated_refs" $'CLOSED\nOPEN'
check "cross-repo ref in a later clause still flags" 0 "FLAG_CROSS_REPO" \
  blocked_decision "12" "CLOSED" \
  "$(blocked_cross_references <<<"Blocked by #12. Blocked by rig#7.")"
check "open blocker keeps issue blocked" 0 "KEEP" blocked_decision "$refs" $'CLOSED\nOPEN'
check "all closed blockers release issue" 0 "READY" blocked_decision "$refs" $'CLOSED\nCLOSED'
check "missing blocked declaration is flagged" 0 "FLAG_UNPARSEABLE" blocked_decision "" ""
check "unreadable blocker is flagged" 0 "FLAG_UNPARSEABLE" blocked_decision "12" "UNKNOWN"
check "cross-repo-only blocker is flagged distinctly" 0 "FLAG_CROSS_REPO" \
  blocked_decision "" "" "rig#112"
check "cross-repo blocker prevents false promotion when locals close" 0 "FLAG_CROSS_REPO" \
  blocked_decision "9" "CLOSED" "rig#9"

# The parse echo (#252): the machine states what it read, so a
# readable-but-wrong declaration is visible in one sweep instead of five days.
check "the rendered set names the locals in parse order" 0 "{#7, #12}" \
  blocked_parse_set "$(printf '7\n12\n')" ""
check "a single blocker still renders as a set" 0 "{#12}" blocked_parse_set "12" ""
check "an empty parse renders as the empty set" 0 "{}" blocked_parse_set "" ""
check "cross-repo references are echoed beside the locals" 0 "{#12, rig#9}" \
  blocked_parse_set "12" "rig#9"
check "a cross-repo-only parse is echoed too" 0 "{heavy-duty/box#9}" \
  blocked_parse_set "" "heavy-duty/box#9"
# crew#308: a *negated* marker phrase unions as the thing it denies, and the
# silent result was a set nobody saw until a human ran the parser. Echoed, the
# union is visible in the thread that contains the declaration.
echo_308="$(blocked_parse_set \
  "$(blocked_references <<<'Blocked by #162, #265. It is no longer blocked by #221.')" \
  "$(blocked_cross_references <<<'Blocked by #162, #265. It is no longer blocked by #221.')")"
check "the #308 shape echoes the negation-unioned blocker verbatim" 0 "" test \
  "$echo_308" = "{#162, #221, #265}"
# The marker is scoped to the SET's value — the whole idempotency contract.
# Mutation proof, both directions: same set must reuse its marker (or a
# 15-minute cron repeats itself forever), different set must not (or a
# misparse is echoed under a marker the thread already carries, and stays
# invisible — exactly the failure this change exists to close).
check "an unchanged set reuses its marker" 0 "" test \
  "$(blocked_parse_marker '{#7, #12}')" = "$(blocked_parse_marker '{#7, #12}')"
check "a changed set takes a different marker" 1 "" test \
  "$(blocked_parse_marker '{#7, #12}')" = "$(blocked_parse_marker '{#7, #12, #19}')"
check "the empty set has a marker of its own" 0 "blockers-parsed-none-44136fa355b3" \
  blocked_parse_marker "{}"
check "the marker survives a cross-repo reference's punctuation" 0 \
  "blockers-parsed-12-heavy-duty-box-9-c8e36fe3b793" \
  blocked_parse_marker "{#12, heavy-duty/box#9}"
# The readable half of the marker is many-to-one and must not be the identity.
# Every pair below is two reference tokens `issue_references` classifies, that
# slug identically; a slug-keyed marker made the second one find the first
# one's marker and post nothing — silence in the one case the echo exists to
# speak about. Distinguishing `/` alone would close the first pair and leave
# the rest, so the digest of the whole rendered set is what decides.
#
# Classifies, not parses: three of the four are reachable as a declared set —
# `{acme.widgets#9}` is not, because the clause parser stops at the `.` and
# `blocked_reference_records` never hands that token through, though
# `issue_references` does answer CROSS for it. It stays in the family because
# the marker's contract is over the tokens the classifier admits, not over the
# subset today's clause parser happens to reach; the class proof does not rest
# on it either way, since `{acme-widgets#9}` vs `{acme_widgets#9}` is reachable
# on both sides and reds the cheap fix on its own.
check "the slug alone cannot separate a qualified ref from a hyphenated one" 0 "" \
  test "$(printf '%s' '{acme/widgets#9}' | tr -c '[:alnum:]' '-' | sed 's/--*/-/g; s/^-//; s/-$//')" \
     = "$(printf '%s' '{acme-widgets#9}' | tr -c '[:alnum:]' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
# Pairwise, and deliberately so. Anchoring every pair on the `/` spelling
# would pass under a fix that only taught the slug about `/` — and that fix
# leaves `{acme-widgets#9}`, `{acme_widgets#9}` and `{acme.widgets#9}` sharing
# one marker. The contract is that no two distinct parses collide, so the test
# is every pair, not every pair through one representative.
marker_family=(
  '{acme/widgets#9}' '{acme-widgets#9}' '{acme_widgets#9}' '{acme.widgets#9}'
)
for left in "${marker_family[@]}"; do
  for right in "${marker_family[@]}"; do
    [ "$left" != "$right" ] || continue
    check "...but the marker does: $left vs $right" 1 "" test \
      "$(blocked_parse_marker "$left")" = "$(blocked_parse_marker "$right")"
  done
done
check "the qualifier's punctuation reaches the marker's identity" 1 "" test \
  "$(blocked_parse_marker '{#12, heavy-duty/box#9}')" \
  = "$(blocked_parse_marker '{#12, heavy-duty-box#9}')"
# shellcheck disable=SC2016 # expansions belong to the generated fake gh
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$1" = api ]; then [ ! -f "$GH_COMMENTS" ] || cat "$GH_COMMENTS"; exit; fi' \
  'if [ "$1 $2" = "issue comment" ]; then' \
  '  while [ "$#" -gt 0 ]; do' \
  '    if [ "$1" = --body ]; then shift; printf "%s\n" "$1" >>"$GH_COMMENTS"; exit; fi' \
  '    shift' \
  '  done' \
  'fi' >"$TMP/gh"
chmod +x "$TMP/gh"
: >"$TMP/comments"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "cross-repo warning is idempotent across two sweeps" 0 "" \
  env PATH="$TMP:$PATH" GH_COMMENTS="$TMP/comments" bash -c \
  'source "$1"; REPO=heavy-duty/ceremony
  ensure_comment 99 blocked-cross-repo "cross-repo warning"
  ensure_comment 99 blocked-cross-repo "cross-repo warning"
  test "$(grep -cF "<!-- issueflow:blocked-cross-repo -->" "$GH_COMMENTS")" -eq 1' \
  _ "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# Invariant 4: only configured triage actors mint directly into the queue.
check "triage-authored ready issue is accepted" 0 "KEEP" author_decision true <<<"ready"
check "outside author receives needs-triage" 0 "ADD_NEEDS_TRIAGE" author_decision false <<<"ready"
check "outside author already marked needs-triage is stable" 0 "KEEP" author_decision false <<<"needs-triage"
check "later sweep accepts a normalized outside-authored issue" 0 "KEEP" queue_decision <<<"ready"

# Invariant 5: completed epics get one nudge; incomplete/unparseable do not.
epic_refs="$(epic_references <<< $'## Definition of done\n- [ ] outside #8\n\n## Task list\n- [ ] #3 first\n- [x] #2 done\nplain #9')"
check "epic parser reads task-list refs only" 0 $'2\n3' printf '%s\n' "$epic_refs"
body=$'## Task list\n- [x] #2 done\n- [x] #3 done\n\n## Definition of done\n- [ ] open issue #99 must not suppress the nudge'
check "epic parser stops before later checkbox sections" 0 "" test \
  "$(epic_references <<<"$body")" = $'2\n3'
# shellcheck disable=SC2016 # backticks and ${{ }}-shaped prose are fixture literals
body=$'## Task list\n\n- [x] #2 Scaffold: layout, test harness, shellcheck + actionlint CI\n- [x] #3 `lib/version.sh` — one version abstraction, two backends\n- [x] #4 `lib/changelog.sh` — the one canonical section extractor\n- [x] #5 `actions/changelog-armed` — the version-keyed arming guard\n- [x] #6 `actions/changelog-monotonic` — shipped release headings are append-only\n- [x] #7 `actions/drill-recorded` — a release carries its evidence\n- [x] #8 `lib/decide.sh` — the merge door'\''s decision, pure\n- [x] #9 The reusable release workflow — both doors, one implementation\n- [x] #10 Labels machinery: reusable workflow + core/scope split\n- [x] #11 Dogfood: ceremony releases itself (0.1.0) — **shipped: tag `0.1.0`, release, `drills/0.1.0.md`; main re-armed at `0.1.1-dev`**\n- [x] #12 `docs/CONSUMERS.md` + README doctrine\n- [ ] #13 Convert rig (pilot) — **PR [rig#112](https://github.com/heavy-duty/rig/pull/112) is approved by the whole panel on head `3c72c1b` and sits at `state:needs-human` since 2026-07-23 10:47Z; the merge is the human'\''s. #14/#15 unblock when it lands**\n- [ ] #14 Convert box\n- [ ] #15 Convert cast (artifact hook debut)\n- [ ] #16 Adopt in incubator (greenfield consumer)\n\nAdjacent, same repo, separable from the release chain: the **agent team flow** (discussion → triage → issue → build → review → human merge) landed as doctrine in PR #17 (CONTRIBUTING.md, LABELS.md, TRIAGE.md, BUILDER.md, REVIEWER.md); #10'\''s bootstrap carries its labels, #12'\''s guide carries its adoption checklist. Consumption is split by what has a runtime: **machinery by reference** (GitHub materializes pinned workflows/actions at run time), **doctrine as a machine-verified mirror** (`.ceremony/` in each consumer, byte-identical to the pin, CI-guarded — agents read rules from the checkout, never cross-repo):\n\n- [x] #18 Issue-flow reconciliation — the work-queue sweep — **shipped 2026-07-23** in #32 (`66f1c08`)\n- [ ] #61 issueflow-reconcile — cross-repo references must not be read as local issue numbers (found in triage hygiene against the live corpus after #18 shipped; it is why this epic cannot currently be nudged complete)\n- [x] #19 actions/docs-sync — the vendored-doctrine mirror + guard\n- [x] #24 Entry templates — the pipeline'\''s doors made mechanical (from discussion #23)\n- [ ] #50 `needs-ruling` — the pending-human-decision flag (its own epic; from discussion #30)\n- [ ] #56 Fleet scope and cross-repo discovery — the two guards, the runner hole, the roster question (its own epic; from discussion #55, filed at @danmt'\''s request). Children: #57 (BUILDER/REVIEWER/FLEET discovery guards), #58 (`actions/runner-isolated`). Added to this list by triage 2026-07-23 — it is agent-team-flow work like #50, so a scan of this epic must see it.'
check "real epic 1 task list drops rig PR and retains local references" 0 \
  $'2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n18\n19\n23\n24\n30\n32\n50\n55\n56\n57\n58\n61' \
  epic_references <<<"$body"
check "completed epic is nudged" 0 "NUDGE" epic_decision "$epic_refs" $'CLOSED\nCLOSED'
check "open epic child suppresses nudge" 0 "KEEP" epic_decision "$epic_refs" $'CLOSED\nOPEN'
check "epic without parseable children is stable" 0 "KEEP" epic_decision "" ""

# Invariant 1 keeps ignoring the ruling flag (#50 D8): it composes with the
# queue labels and is not one of them.
check "claimed plus a pending ruling is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\nneeds-ruling'
check "a ruling flag alone is still invariant 1's violation" 0 "ADD_NEEDS_TRIAGE" \
  queue_decision <<< $'needs-ruling'
check "claimed plus offsite is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\noffsite'
check "offsite alone still needs triage" 0 "ADD_NEEDS_TRIAGE" \
  queue_decision <<<"offsite"
check "claimed plus attention is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\nattention'

# ---------------------------------------------------------------------------
# The ruling pass on the issue surface (#52), against a recording stub: the
# reclaim clock stops under a pending ruling, an applied stale heals off,
# label churn is not activity, the nudge resets on its own comment, and no
# edit anywhere names the flag (#50 D9). The stub serves fixture JSON per
# endpoint with the caller's --jq applied by real jq, appends posted comments
# back into the fixture (a second sweep sees the first one's writes), and
# records every label edit.
# ---------------------------------------------------------------------------
INOW=2000000000
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# gh's own rendering of a 5xx whose body carries a `message` key — the line
# crew#329's job log carried, verbatim (#247), and the payload beside it.
GH_STUB_STDERR="gh: We couldn't respond to your request in time. (HTTP 504)"
GH_STUB_ERROR_BODY='{"message":"We could not respond to your request in time.","documentation_url":"https://docs.github.com/rest"}'
export GH_STUB_STDERR # the PATH-stubbed gh of the executable runs reads it too

issue_stub_gh() {
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
    file="$TMP/$(printf '%s' "$endpoint" | tr '/' '_').json"
    printf '%s\n' "$endpoint" >>"$TMP/api-calls"
    # A `.http-error` sentinel is the real 5xx (#247): `gh api` prints the
    # response body — GitHub's JSON error object — to STDOUT, says why on
    # stderr, and exits non-zero. The `.error` sentinel models a failure with
    # no payload, which is the *safe* path (an empty label set is empty either
    # way), and is why this class was never caught. Both now speak on stderr,
    # because the real gh always does and the reason line renders it.
    if [ -f "$file.http-error" ]; then
      # A --jq call gets the filter applied to the error body, as gh does.
      # That is what "yields no timestamps" looks like — the shape that let
      # last_issue_activity fall back to created_at and reclaim a live claim.
      if [ -n "$jqexpr" ]; then
        jq -r "$jqexpr" "$file.http-error" 2>/dev/null || true
      else
        cat "$file.http-error"
      fi
      printf '%s\n' "$GH_STUB_STDERR" >&2
      return 1
    fi
    [ ! -f "$file.error" ] || { printf '%s\n' "$GH_STUB_STDERR" >&2; return 1; }
    # An absent fixture answers an empty list, and a --jq call gets the filter
    # applied to it — the arrival stub's shape, and gh's. Returning the raw
    # `[]` to a --jq caller made every missing fixture answer a literal `[]`
    # where the real API answers nothing, and `[]` outsorts an ISO-8601
    # timestamp in the C locale but not in a UTF-8 one, so last_issue_activity
    # dated an issue by a stub artifact on the runner and by its created_at
    # here. The old code swallowed the resulting date failure; #247's guards
    # turn it into a skip, which is what made the lie visible.
    local payload='[]'
    [ ! -f "$file" ] || payload="$(cat "$file")"
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$payload"; else printf '%s\n' "$payload"; fi
  elif [ "$1" = issue ] && [ "$2" = comment ]; then
    local n="$3" body="" file
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in --body) body="$2"; shift ;; esac
      shift
    done
    printf '%s\n----\n' "$body" >>"$TMP/posted-$n"
    file="$TMP/$(printf 'repos/%s/issues/%s/comments' "$REPO" "$n" | tr / _).json"
    [ -f "$file" ] || printf '[]\n' >"$file"
    jq --arg b "$body" --arg at "$(iso_at "$INOW")" \
      '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
      "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  elif [ "$1" = issue ] && [ "$2" = edit ]; then
    printf '%s\n' "$*" >>"$TMP/issue-edits"
  fi
}

issue_probe() { # $1 issue, $2 labels, $3 assignees, $4 false|closing|refs, $5 merged PR specs, $6 body
  (
    local assignees="${3:-1}" open_pr="${4:-false}" merged_ref_prs="${5:-}"
    local body="${6:-}" assignee_json='[]' open_pr_records="" spec pr merged_at
    [ "$assignees" -eq 0 ] || assignee_json='[{"login":"owner-bot"}]'
    # `PROBE_NOW` moves the sweep's clock without moving the fixtures — the
    # only way to prove a rule that self-rate-limits on its own comment's
    # timestamp (#254): sweep, then sweep again a day later and watch the
    # nudge stay silent because the comment it posted is now the activity.
    REPO="${PROBE_REPO:-owner/repo}" NOW="${PROBE_NOW:-$INOW}"
    ISSUE_LABELS="$2"
    ISSUE_JSON="$(jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
      --argjson assignees "$assignee_json" --arg body "$body" \
      '{created_at: $at, assignees: $assignees, body: $body}')"
    case "$open_pr" in
      true|closing) open_pr_records="$(printf 'CLOSING\t%s\n' "$1")" ;;
      refs|draft-refs) open_pr_records="$(printf 'BODY\tRefs #%s\n' "$1")" ;;
    esac
    OPEN_PR_ISSUES="$(open_pr_issues <<<"$open_pr_records")"
    # Records are ISSUE<TAB>PR<TAB>MERGED_AT (#242). A spec is `PR` or
    # `PR@<iso>`; the bare form takes a fixed hour-old merge, which is every
    # probe that does not care about merge order. An empty list is no record
    # at all, so the no-merged-PR probes read exactly as they did.
    MERGED_REF_PR_RECORDS="$(
      # shellcheck disable=SC2086 # the spec list is deliberately word-split
      for spec in $merged_ref_prs; do
        pr="${spec%%@*}"
        merged_at="${spec#*@}"
        [ "$merged_at" != "$spec" ] || merged_at="$(iso_at $((INOW - 3600)))"
        printf '%s\t%s\t%s\n' "$1" "$pr" "$merged_at"
      done)"
    run() { "$@"; }
    gh() { issue_stub_gh "$@"; }
    reconcile_issue "$1" 2>&1
  )
}

tfix() { printf '%s/repos_owner_repo_issues_%s_timeline.json' "$TMP" "$1"; }
cfix() { printf '%s/repos_owner_repo_issues_%s_comments.json' "$TMP" "$1"; }

# -- release epics announce an opened declared gate, comment-only (#253) -----
printf '{"state":"closed"}\n' >"$TMP/repos_owner_repo_issues_201.json"
printf '{"state":"closed"}\n' >"$TMP/repos_owner_repo_issues_202.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_203.json"
printf '[]\n' >"$(cfix 53)"
: >"$TMP/issue-edits"
release_init_edits_before="$(wc -l <"$TMP/issue-edits")"
release_init_body=$'Blocked by #201, #202.\n\n## Task list\n- [ ] #203 later work'
release_init="$(issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body")"
check "a release epic with every declared blocker closed announces init" 0 "" \
  grep -qF '<!-- issueflow:release-init-due -->' "$TMP/posted-53"
check "the init announce names all five steps" 0 "5" \
  grep -cE '^[1-5]\. ' "$TMP/posted-53"
# shellcheck disable=SC2016 # backticks are the literal portable doctrine citation
check "the init announce cites the portable vendored doctrine path" 0 "" \
  grep -qF 'See `.ceremony/RELEASES.md`.' "$TMP/posted-53"
check "the init announce names the never-automated operator blessing" 0 "" \
  grep -qF 'operator blessing the order is the one step this chain never automates' \
  "$TMP/posted-53"
check "the opened release gate is logged" 0 "" \
  grep -qF '#53: release-init due' <<<"$release_init"
release_init_gate_reads_before_repeat="$(
  grep -cE 'repos/owner/repo/issues/(201|202)$' "$TMP/api-calls"
)"
issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body" >/dev/null
check "an unchanged opened gate announces only once" 0 "1" \
  grep -cF '<!-- issueflow:release-init-due -->' "$TMP/posted-53"
check "an announced gate does not re-read its durable blockers" 0 \
  "$release_init_gate_reads_before_repeat" \
  grep -cE 'repos/owner/repo/issues/(201|202)$' "$TMP/api-calls"

printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_ceremony_issues_201.json"
printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_ceremony_issues_202.json"
printf '[]\n' >"$TMP/repos_heavy-duty_ceremony_issues_53_comments.json"
PROBE_REPO=heavy-duty/ceremony \
  issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body" >/dev/null
# shellcheck disable=SC2016 # backticks are the literal dogfood doctrine citation
check "the ceremony dogfood announce cites its root doctrine path" 0 "" \
  grep -qF 'See `RELEASES.md`.' "$TMP/posted-53"

printf '[]\n' >"$(cfix 54)"
issue_probe 54 $'epic\nrelease' 0 false "" \
  $'Blocked by #203.\n\n## Task list\n- [x] #201 complete' >/dev/null
check "an open declared blocker suppresses init despite a complete task list" 1 "" \
  grep -qF '<!-- issueflow:release-init-due -->' "$TMP/posted-54"
check "the independent epic-complete nudge still fires" 0 "" \
  grep -qF '<!-- issueflow:epic-complete -->' "$TMP/posted-54"

printf '[]\n' >"$(cfix 55)"
issue_probe 55 $'epic\nrelease' 0 false "" \
  $'Blocked by #201.\n\n## Task list\n- [x] #202 complete' >/dev/null
check "release-init and epic-complete can coexist" 0 "2" \
  grep -c -- '^----$' "$TMP/posted-55"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the coexisting comments keep distinct markers" 0 "" \
  bash -c 'grep -qF "<!-- issueflow:release-init-due -->" "$1" && grep -qF "<!-- issueflow:epic-complete -->" "$1"' \
  _ "$TMP/posted-55"

for n in 56 57 58 59; do printf '[]\n' >"$(cfix "$n")"; done
issue_probe 56 $'epic\nrelease' 0 false "" 'No dependency declaration.' >/dev/null
check "a release epic without a Blocked by declaration stays silent" 1 "" \
  test -f "$TMP/posted-56"
issue_probe 57 $'epic\nrelease' 0 false "" 'Blocked by heavy-duty/rig#9.' >/dev/null
check "a cross-repo release gate stays silent" 1 "" test -f "$TMP/posted-57"
issue_probe 58 $'epic\nrelease' 0 false "" 'Blocked by #204.' >/dev/null
check "an unreadable release gate stays silent" 1 "" test -f "$TMP/posted-58"
: >"$TMP/api-calls"
issue_probe 59 epic 0 false "" 'Blocked by #201.' >/dev/null
check "a plain epic does not parse or announce a release gate" 1 "" \
  test -f "$TMP/posted-59"
check "a plain epic pays no Blocked by reference read" 1 "" \
  grep -qF 'repos/owner/repo/issues/201' "$TMP/api-calls"

printf '[]\n' >"$(cfix 60)"
issue_probe 60 $'ready\nrelease' 0 false "" 'Blocked by #201.' >/dev/null
check "a non-epic release issue does not announce init" 1 "" \
  test -f "$TMP/posted-60"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "every release-init probe is comment-only" 0 "$release_init_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- malformed attention targets are diagnosed, never repaired (#232) -------
attention_episode() { # $1 issue, $2 labeled timestamp
  jq -n --arg at "$2" \
    '[{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
    >"$(tfix "$1")"
  printf '[]\n' >"$(cfix "$1")"
}

: >"$TMP/issue-edits"
attention_edits_before="$(wc -l <"$TMP/issue-edits")"
for n in 61 62 63; do
  attention_episode "$n" "$(iso_at $((INOW - 60)))"
done
# The assignment event is the claim clock's own activity fact. The live issue
# has since lost its assignee, which is exactly the claimed-unassigned shape.
jq --arg at "$(iso_at $((INOW - 60)))" \
  '. + [{"event":"assigned","created_at":$at}]' \
  "$(tfix 63)" >"$(tfix 63).tmp" && mv "$(tfix 63).tmp" "$(tfix 63)"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_999.json"

issue_probe 61 $'ready\nattention' 0 >/dev/null
check "unassigned attention under ready is diagnosed once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-61"

issue_probe 62 $'blocked\nattention' 0 false "" 'Blocked by #999' >/dev/null
check "unassigned attention under blocked is diagnosed once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-62"

claimed_attention="$(issue_probe 63 $'claimed\nattention' 0)"
check "claimed-unassigned owns the only board comment" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-63"
check "the claimed-unassigned marker, not attention's, was posted" 0 "1" \
  grep -cF '<!-- issueflow:claimed-unassigned -->' "$TMP/posted-63"
check "the suppressed attention detection remains in the log" 0 "1" \
  grep -cF 'comment suppressed by claimed-unassigned precedence' <<<"$claimed_attention"

attention_episode 64 "$(iso_at $((INOW - 60)))"
issue_probe 64 $'ready\nattention' 1 >/dev/null
check "assigned attention under ready is healthy" 1 "" test -f "$TMP/posted-64"
attention_episode 65 "$(iso_at $((INOW - 60)))"
issue_probe 65 $'claimed\nattention' 1 true >/dev/null
check "assigned attention under claimed is healthy" 1 "" test -f "$TMP/posted-65"
attention_episode 66 "$(iso_at $((INOW - 60)))"
issue_probe 66 $'blocked\nattention' 1 false "" 'Blocked by #999' >/dev/null
# A `blocked` issue now always carries one comment — the parse echo (#252) —
# so "healthy" can no longer be spelled "no comment file at all". It is spelled
# the way this section's other cases already spell it: no attention diagnostic.
# Both halves are pinned, so the case still fails if an attention comment
# appears beside the echo, or if a second comment of any kind does.
check "assigned attention under blocked is healthy" 1 "" \
  grep -qF '<!-- ceremony:attention-malformed:' "$TMP/posted-66"
check "...drawing the #252 parse echo and nothing else" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-66"

attention_episode 67 "$(iso_at $((INOW - 60)))"
# Recent activity keeps the evidence nudge (#254) off this probe: it is a
# precedence case, and "exactly one comment" is the assertion doing the work.
# The nudge's own coexistence with the post-merge diagnostic is pinned in its
# section below, on a probe that is quiet on purpose.
jq -n --arg at "$(iso_at $((INOW - 60)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c67","body":"still waiting on the tag"}]' \
  >"$(cfix 67)"
post_merge_attention="$(issue_probe 67 $'post-merge\nattention' 0)"
check "post-merge precedence leaves exactly its existing comment" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-67"
check "post-merge's existing diagnostic wins" 0 "1" \
  grep -cF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-67"
check "the post-merge suppression remains in the log" 0 "1" \
  grep -cF 'comment suppressed by post-merge-assigned precedence' <<<"$post_merge_attention"

attention_episode 68 "$(iso_at $((INOW - 120)))"
issue_probe 68 $'ready\nattention' 0 >/dev/null
issue_probe 68 $'ready\nattention' 0 >/dev/null
check "two sweeps in one malformed episode post once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-68"
jq --arg at "$(iso_at $((INOW - 30)))" \
  '. + [{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
  "$(tfix 68)" >"$(tfix 68).tmp" && mv "$(tfix 68).tmp" "$(tfix 68)"
issue_probe 68 $'ready\nattention' 0 >/dev/null
check "a re-set flag creates a second episode comment" 0 "2" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-68"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the two comments carry distinct episode markers" 0 "2" \
  bash -c 'grep -F "<!-- ceremony:attention-malformed:" "$1" | sort -u | wc -l' _ \
  "$TMP/posted-68"

: >"$(tfix 69).error"
printf '[]\n' >"$(cfix 69)"
unreadable_attention="$(issue_probe 69 $'ready\nattention' 0)"
check "an unreadable attention timeline posts nothing" 1 "" test -f "$TMP/posted-69"
check "the unreadable fact is visible in the log" 0 "1" \
  grep -cF 'attention timeline unreadable' <<<"$unreadable_attention"

: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 70)"
printf '[]\n' >"$(cfix 70)"
issue_probe 70 ready 0 >/dev/null
check "a flag-free issue performs no attention episode read" 1 "" \
  grep -qF 'repos/owner/repo/issues/70/timeline' "$TMP/api-calls"

# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the attention sweep probes perform no issue edits" 0 "$attention_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- the reclaim clock stops under a pending ruling (48h quiet, no PR) -------
jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l},
    {"event":"assigned","created_at":$l}]' >"$(tfix 21)"
# The escalation is conforming and the rung markers are pre-seeded — by 10
# days in both rungs fired long ago (#73), so this probe observes the nudge
# wiring alone; shape and rung behavior have their own probes in
# test/ruling.test.sh.
jq -n --arg at "$(iso_at $((INOW - 10 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((INOW - 10 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((INOW - 10 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc21","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$(cfix 21)"
exempt="$(issue_probe 21 $'claimed\nneeds-ruling')"
check "a 10-day-quiet claim under a ruling is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$exempt"
check "...the same silence still nudges the pending ruling" 0 "" \
  grep -q 'ruling nudge' <<<"$exempt"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...and the nudge went to the decider with the escalation linked" 0 "" \
  bash -c 'grep -qF "@danmt" "$1" && grep -qF "https://x/esc21" "$1"' _ "$TMP/posted-21"
again="$(issue_probe 21 $'claimed\nneeds-ruling')"
check "the sweep right after the nudge holds its silence" 1 "" \
  grep -q 'ruling nudge' <<<"$again"
check "exactly one nudge across both sweeps" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-21"

# -- control: the same silence without the flag is reclaimed -----------------
jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$l}]' >"$(tfix 22)"
printf '[]\n' >"$(cfix 22)"
control="$(issue_probe 22 claimed)"
check "the flag-free control is reclaimed (the clock still runs elsewhere)" 0 "" \
  grep -q 'stale claim reclaimed -> ready' <<<"$control"

# -- merged Refs work releases the claim before the reclaim clock ------------
printf '[]\n' >"$(cfix 35)"
transition="$(issue_probe 35 claimed 1 false 350 $'- [x] built\n- [ ] verify dispatch\n  * [ ] confirm warning clears')"
check "merged Refs + unchecked criteria transitions in the sweep body" 0 "" \
  grep -q 'merged Refs PR -> post-merge; claim released' <<<"$transition"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...names every remaining criterion verbatim in the comment" 0 "" \
  bash -c 'grep -qF -- "- [ ] verify dispatch" "$1" &&
    grep -qF -- "  * [ ] confirm warning clears" "$1"' _ "$TMP/posted-35"
check "...states triage owes completion with owner and wake condition" 0 "" \
  grep -qF 'Triage owes completion in a follow-up comment that names the owner and wake condition.' \
  "$TMP/posted-35"
check "...unassigns and swaps claimed to post-merge" 0 "" \
  grep -qF -- '--remove-assignee owner-bot --remove-label claimed --add-label post-merge' \
  "$TMP/issue-edits"

printf '[]\n' >"$(cfix 36)"
post_merge_quiet="$(issue_probe 36 post-merge 0)"
check "quiet unassigned post-merge work is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$post_merge_quiet"
# The quiet itself is now visible (#254) — this probe is 10 days old with no
# activity, so it draws the evidence nudge and nothing else. It used to
# assert no comment at all; that assertion described the starvation this
# issue exists to end, and the edit half of it is what still matters.
check "...and causes no edit" 1 "" grep -qF -- 'issue edit 36' "$TMP/issue-edits"
check "...only the evidence nudge speaks" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-36"

printf '[]\n' >"$(cfix 37)"
# The live shape of an assigned `post-merge` issue: the assignee in the issue
# payload AND the `assigned` event that put it there in the timeline. With an
# empty timeline this fixture could not see the defect it exists to guard —
# the evidence clock counting that hour-old assignment as activity and
# silencing the nudge for another 7 days, on the one board state where an
# assignee is itself the bug being reported.
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 37)"
issue_probe 37 post-merge 1 >/dev/null
check "assigned post-merge is flagged" 0 "" \
  grep -qF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-37"
check "...and the hand-assignment is not repaired" 1 "" \
  grep -qF -- 'issue edit 37' "$TMP/issue-edits"
# The flag and the nudge answer different questions — a board bug and a
# starved wake condition — so neither suppresses the other (#254).
check "...and the evidence nudge rides beside it, neither suppressed" 0 "2" \
  grep -c -- '^----$' "$TMP/posted-37"

# -- the post-merge evidence nudge (#254), the ruling nudge's twin ----------
# The ruling nudge solved "a wait goes quiet and nobody is told" for
# `needs-ruling`; `post-merge` had no equivalent, and crew#181's real-host
# criterion starved four times across two releases for want of one. Same
# 7-day constant (`ruling_nudge_decision`, reused not mirrored), same
# deliberate absence of an idempotency marker, and — unlike the ruling
# nudge — addressed to the triage actor, because `post-merge` is triage's
# completion queue and the operator owes nothing here (#254 D1).
nudge_edits_before="$(wc -l <"$TMP/issue-edits")"

quiet_comment() { # $1 issue, $2 seconds of quiet — one ordinary comment, then silence
  jq -n --arg at "$(iso_at $((INOW - $2)))" \
    '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c","body":"evidence pending"}]' \
    >"$(cfix "$1")"
  printf '[]\n' >"$(tfix "$1")"
}

quiet_comment 80 $((8 * 86400))
nudged="$(issue_probe 80 post-merge 0)"
check "8 quiet days on a post-merge item draws the evidence nudge" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$nudged"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...addressed to the triage actor, never the human reviewer" 0 "" \
  bash -c 'grep -qF "@triage-one" "$1" && ! grep -qF "@danmt" "$1"' _ "$TMP/posted-80"
check "...with the issue link as the payload" 0 "" \
  grep -qF 'https://github.com/owner/repo/issues/80' "$TMP/posted-80"
check "...carrying the do-not-add-a-marker warning in the comment" 0 "" \
  grep -qF 'Do not add a marker.' "$TMP/posted-80"
# Asserted directly, not merely omitted: a marker would turn "once per 7
# quiet days" into "once per issue, forever" — the exact "fix" lib/ruling.sh's
# header records as the thing that breaks this rule.
check "...and no idempotency marker on the path" 1 "" \
  grep -qF '<!-- issueflow:' "$TMP/posted-80"

# Self-rate-limiting, proven by the property and not by the mechanism: sweep
# again a day later, against fixtures the first sweep's own comment mutated.
nudged_again="$(PROBE_NOW=$((INOW + 86400)) issue_probe 80 post-merge 0)"
check "a sweep one day after the nudge holds its silence" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$nudged_again"
check "...so exactly one nudge exists across both sweeps" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-80"

quiet_comment 81 $((6 * 86400))
six_days="$(issue_probe 81 post-merge 0)"
check "6 quiet days is inside the window and draws nothing" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$six_days"
check "...and posts no comment at all" 1 "" test -f "$TMP/posted-81"

# Label churn is not activity, or the sweep resets its own clock. The rule is
# `last_issue_activity`'s, shared with the reclaim and ruling clocks rather
# than restated here — this probe pins that the nudge inherits it.
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"labeled","label":{"name":"scope:docs"},"created_at":$at},
    {"event":"unlabeled","label":{"name":"scope:docs"},"created_at":$at}]' >"$(tfix 82)"
printf '[]\n' >"$(cfix 82)"
churn="$(issue_probe 82 post-merge 0)"
check "an hour-old label churn does not reset the 7-day clock" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$churn"

quiet_comment 83 3600
fresh="$(issue_probe 83 post-merge 0)"
check "an hour-old comment does reset it" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$fresh"

# Neither is an assignment. That event is the *claim* clock's activity fact —
# 48 hours of silence must not include the seconds between a claim and its
# required draft PR — and `post-merge` has no claim for it to protect: an
# assignee here is the invalid composition the flag above reports. Counting
# it would let a broken board buy the item another 7 days of quiet, which is
# this issue's failure direction taken backwards. No current assignee on this
# probe, so nothing stands between the clock rule and the nudge.
quiet_comment 93 $((8 * 86400))
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},{"event":"unassigned","created_at":$at}]' >"$(tfix 93)"
assigned_clock="$(issue_probe 93 post-merge 0)"
check "an hour-old assignment does not reset the evidence clock either" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$assigned_clock"

# The two clocks over the one computation, asserted directly rather than
# through a probe: same fixture, one input's difference, and the reclaim
# clock is pinned unmoved by the split.
jq -n --arg at "$(iso_at $((INOW - 5 * 86400)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c95","body":"evidence pending"}]' \
  >"$(cfix 95)"
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 95)"
two_clocks="$( (REPO=owner/repo; gh() { issue_stub_gh "$@"; }
  printf '%s %s\n' \
    "$(last_issue_activity 95 "$(iso_at $((INOW - 10 * 86400)))")" \
    "$(last_issue_comment_activity 95 "$(iso_at $((INOW - 10 * 86400)))")") )"
check "the claim clock counts the assignment, the evidence clock the comment" 0 \
  "$((INOW - 3600)) $((INOW - 5 * 86400))" printf '%s\n' "$two_clocks"
# One body, two callers: a second activity computation is the drift the
# reuse exists to prevent, so the timeline read has exactly one spelling.
# shellcheck disable=SC2016 # the read is asserted as a literal, unexpanded
check "the timeline read is not respelled for the evidence clock" 0 "1" \
  grep -c 'issues/\$n/timeline' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# Both waits are quiet, both are owed, and to different parties: suppressing
# one because the other spoke is a starved criterion, which is the failure
# this nudge exists to remove.
jq -n --arg l "$(iso_at $((INOW - 9 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' \
  >"$(tfix 84)"
jq -n --arg at "$(iso_at $((INOW - 9 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((INOW - 9 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((INOW - 9 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc84","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$(cfix 84)"
both="$(issue_probe 84 $'post-merge\nneeds-ruling' 0)"
check "a quiet post-merge item under a pending ruling nudges both waits" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$both"
check "...and the ruling nudge is not suppressed by it" 0 "" \
  grep -q 'ruling nudge' <<<"$both"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...each addressing its own party" 0 "" \
  bash -c 'grep -qF "@triage-one" "$1" && grep -qF "@danmt" "$1"' _ "$TMP/posted-84"

# Every other queue state: the nudge is `post-merge`'s alone. Each is equally
# quiet, and `claimed` carries an open PR so its own reclaim clock — the one
# other 10-day rule on this path — stays out of the way.
non_post_merge=(85:ready:0:false 86:claimed:1:true 87:blocked:0:false 88:epic:0:false 89:needs-triage:0:false)
for spec in "${non_post_merge[@]}"; do
  IFS=: read -r n state probe_assignees probe_pr <<<"$spec"
  printf '[]\n' >"$(cfix "$n")"
  printf '[]\n' >"$(tfix "$n")"
  check "a 10-day-quiet $state issue draws no evidence nudge" 1 "" \
    grep -q 'post-merge evidence nudge' \
    <<<"$(issue_probe "$n" "$state" "$probe_assignees" "$probe_pr")"
done

# The machine never judges prose: which criterion starved is not a fact the
# sweep reads, so a body it could not parse if it tried still nudges.
quiet_comment 90 $((8 * 86400))
unparseable_body="$(issue_probe 90 post-merge 0 false "" '¯\_(ツ)_/¯ wake: ask danmt sometime')"
check "an unparseable body still nudges — the link is the payload" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$unparseable_body"
check "...and the nudge quotes none of it" 1 "" \
  grep -qF 'ask danmt sometime' "$TMP/posted-90"

# One spelling of the 7-day rule. `lib/ruling.sh` exists because this family
# already paid for two copies of a constant; a second one here is the drift,
# and it is cheap to pin at the grep level.
# Code lines only: the branch's comment names the constant it must not
# respell, which is the sentence a future reader needs and not a second copy.
check "the 7-day rule is not respelled in the sweep" 1 "" \
  grep -nE '^[^#]*(7 \* 24 \* 3600|604800)' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the call site is asserted as a literal
check "...it is reused from lib/ruling.sh" 0 "" \
  grep -qF 'ruling_nudge_decision "$NOW" "$evidence_age"' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# `post-merge` is the one queue state whose whole meaning is that the machine
# owes nothing (LABELS.md: the sweep never reclaims it). This issue makes the
# quiet visible; it must never make it actionable.
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the evidence-nudge probes perform no issue edits" 0 "$nudge_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- the issue-side ruling clock is comments-only (#284) ---------------------
# #52 D10's "reuse the activity computation" made the issue-side ruling nudge
# ride the claim-reclamation clock, `assigned` events included — so claiming
# a flagged issue dated it, and the escalation the flag exists to keep
# visible went quiet for another 7 days at exactly the moment somebody
# started working through it. The ruling clock is now the comments-only one
# (D1); the reclaim clock keeps the assignment (D2), because there the
# assignment IS the claim. Every must-nudge probe below was run against the
# pre-#284 sweep and went red — the #274 round-1 discipline: the fixture
# proves the defect, not merely the fix.
ruling_clock_edits_before="$(wc -l <"$TMP/issue-edits")"
ruling_quiet() { # $1 issue — conforming escalation, both rungs fired, ~9d of comment quiet
  jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
    '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' \
    >"$(tfix "$1")"
  jq -n --arg at "$(iso_at $((INOW - 10 * 86400 - 60)))" \
    --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
    --arg r12 "$(iso_at $((INOW - 10 * 86400 + 13 * 3600)))" \
    --arg r24 "$(iso_at $((INOW - 10 * 86400 + 25 * 3600)))" \
    '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc","body":$b},
      {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
      {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
    >"$(cfix "$1")"
}
timeline_add() { # $1 issue, $2 event, $3 seconds ago
  jq --arg e "$2" --arg at "$(iso_at $((INOW - $3)))" \
    '. + [{"event":$e,"created_at":$at}]' \
    "$(tfix "$1")" >"$(tfix "$1").tmp" && mv "$(tfix "$1").tmp" "$(tfix "$1")"
}
comment_add() { # $1 issue, $2 seconds ago
  jq --arg at "$(iso_at $((INOW - $2)))" \
    '. + [{"user":{"login":"decider"},"created_at":$at,"html_url":"https://x/d","body":"still thinking"}]' \
    "$(cfix "$1")" >"$(cfix "$1").tmp" && mv "$(cfix "$1").tmp" "$(cfix "$1")"
}

# The live shape, and the defect: a builder claims the flagged issue, the
# assignment is an hour old, the decider has been silent ~9 days.
ruling_quiet 101
timeline_add 101 assigned 3600
claimed_fresh="$(issue_probe 101 $'claimed\nneeds-ruling' 1 true)"
check "an hour-old claim does not silence a ruling 9 days quiet" 0 "" \
  grep -q 'ruling nudge' <<<"$claimed_fresh"
check "...and the fresh assignment is not reclaim bait either" 1 "" \
  grep -q 'reclaimed' <<<"$claimed_fresh"

# The claimed-branch top read, pinned (review round 1): `claimed` +
# `needs-ruling` with no assignee posts `claimed-unassigned` before the
# tail, so a ruling read taken down there would date the issue by the
# sweep's own comment — the #274 hazard, on the very branch this issue is
# about. One sweep, both outputs: the board diagnostic and the nudge it
# must not silence. Reds the moment the top read drifts below the post.
ruling_quiet 110
timeline_add 110 assigned 3600
unassigned_flag="$(issue_probe 110 $'claimed\nneeds-ruling' 0 false)"
check "an unassigned claim under a ruling still draws its board flag" 0 "1" \
  grep -cF '<!-- issueflow:claimed-unassigned -->' "$TMP/posted-110"
check "...and the ruling nudge fires beside it, undated by it" 0 "" \
  grep -q 'ruling nudge' <<<"$unassigned_flag"

# The clock rule alone, no assignee in the way: an assigned/unassigned pair
# in the timeline is the claim's history, not activity toward the ruling.
ruling_quiet 102
timeline_add 102 assigned 3600
timeline_add 102 unassigned 3500
ready_pair="$(issue_probe 102 $'ready\nneeds-ruling' 0)"
check "a ready issue nudges through an hour-old assignment pair" 0 "" \
  grep -q 'ruling nudge' <<<"$ready_pair"

# post-merge + needs-ruling fires BOTH nudges in one sweep, from one read
# taken before either write. This probe is also the read-order pin: the
# evidence nudge posts first and the stub stamps it as fresh activity, so
# restoring a ruling-clock read below `ensure_comment` turns the second
# check red — the hazard #274 met and killed inside one round.
ruling_quiet 103
timeline_add 103 assigned 3600
timeline_add 103 unassigned 3500
both_fresh="$(issue_probe 103 $'post-merge\nneeds-ruling' 0)"
check "a fresh assignment starves neither post-merge wait" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$both_fresh"
check "...the ruling nudge fires beside it, not behind it" 0 "" \
  grep -q 'ruling nudge' <<<"$both_fresh"

# blocked composes the same way. The #252 parse echo is pre-seeded old so
# the probe isolates the clock rule — steady state, where the echo for this
# parse set already exists and the branch posts nothing before the tail.
ruling_quiet 104
timeline_add 104 assigned 3600
refs_104="$(blocked_references <<<'Blocked by #999.')"
cross_104="$(blocked_cross_references <<<'Blocked by #999.')"
marker_104="$(blocked_parse_marker "$(blocked_parse_set "$refs_104" "$cross_104")")"
jq --arg m "$marker_104" --arg at "$(iso_at $((INOW - 9 * 86400)))" \
  '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/echo","body":("<!-- issueflow:" + $m + " -->\necho")}]' \
  "$(cfix 104)" >"$(cfix 104).tmp" && mv "$(cfix 104).tmp" "$(cfix 104)"
blocked_fresh="$(issue_probe 104 $'blocked\nneeds-ruling' 0 false "" 'Blocked by #999.')"
check "a blocked issue nudges through an hour-old assignment" 0 "" \
  grep -q 'ruling nudge' <<<"$blocked_fresh"

# 6 days of comment quiet is 6, with or without an assignment inside it.
ruling_quiet 105
timeline_add 105 assigned 3600
comment_add 105 $((6 * 86400))
six_days="$(issue_probe 105 $'claimed\nneeds-ruling' 1 true)"
check "6 days of comment quiet draws no nudge" 1 "" \
  grep -q 'ruling nudge' <<<"$six_days"

# Label churn is not activity on this clock either — it reads no timeline
# at all, which closes the class rather than the spelling.
ruling_quiet 106
timeline_add 106 labeled 1800
timeline_add 106 unlabeled 1700
churn="$(issue_probe 106 $'ready\nneeds-ruling' 0)"
check "hour-old label churn does not hold the nudge back" 0 "" \
  grep -q 'ruling nudge' <<<"$churn"

# Self-rate-limiting, asserted as the property (#254's discipline): sweep
# again a day after probe 101's nudge and the nudge it posted is the
# activity that keeps it silent — no marker involved.
day_after="$(PROBE_NOW=$((INOW + 86400)) issue_probe 101 $'claimed\nneeds-ruling' 1 true)"
check "the sweep a day after its nudge holds its silence" 1 "" \
  grep -q 'ruling nudge' <<<"$day_after"

# No flag, no nudge, whatever the clock says.
quiet_comment 107 $((60 * 86400))
noflag="$(issue_probe 107 ready 0)"
check "an unflagged issue draws no ruling nudge at any age" 1 "" \
  grep -q 'ruling nudge' <<<"$noflag"

# D2's input doing its job — the one thing a "the clocks are the same now,
# merge them" refactor would break. Red the instant `last_issue_activity`
# loses `assigned`.
printf '[]\n' >"$(cfix 108)"
jq -n --arg at "$(iso_at $((INOW - 600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 108)"
not_reclaimed="$(issue_probe 108 claimed 1 false)"
check "a 10-minute-old claim on a silent issue is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$not_reclaimed"

# One fixture, two clocks, asserted directly and not by inspection: the
# newest event is the assignment; the reclaim clock returns it and the
# ruling clock returns the older comment.
jq -n --arg at "$(iso_at $((INOW - 8 * 86400)))" \
  '[{"user":{"login":"decider"},"created_at":$at,"html_url":"https://x/c9","body":"x"}]' >"$(cfix 109)"
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 109)"
clock_read() { # $1 clock fn — both against fixture 109
  ( REPO=owner/repo
    # shellcheck disable=SC2317 # reached indirectly, through the clock under test
    gh() { issue_stub_gh "$@"; }
    "$1" 109 "$(iso_at $((INOW - 10 * 86400)))" )
}
check "one fixture, two clocks: the reclaim clock returns the assignment" \
  0 "$((INOW - 3600))" clock_read last_issue_activity
check "...and the ruling clock returns the older comment" \
  0 "$((INOW - 8 * 86400))" clock_read last_issue_comment_activity

# The mechanical call-site pins: the reclaim clock can never reach
# reconcile_ruling, on any path, asserted against the source and not the
# diff. Beside them, the one-spelling pins this issue inherits stay green.
# shellcheck disable=SC2016 # the call sites are asserted as literals
check "reconcile_ruling is never handed the reclaim clock" 1 "" \
  grep -E '^[^#]*reconcile_ruling.*\$age' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the call site is asserted as a literal
check "...its one call site is fed the comments-only clock" 0 "1" \
  grep -cF 'reconcile_ruling "$n" "$ruling_age" "$NOW"' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the guarded_read is asserted as a literal
check "...and ruling_age is never fed by the reclaim clock" 1 "" \
  grep -E 'ruling_age.*last_issue_activity ' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the #284 probes perform no issue edits" 0 "$ruling_clock_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- non-triggers stay byte-for-byte outside the transition ------------------
recent_timeline() {
  jq -n --arg at "$(iso_at $((INOW - 60)))" \
    '[{"event":"assigned","created_at":$at}]' >"$(tfix "$1")"
  printf '[]\n' >"$(cfix "$1")"
}
edit_count_before="$(wc -l <"$TMP/issue-edits")"
recent_timeline 38
open_refs="$(issue_probe 38 claimed 1 refs 380 '- [ ] verify after merge')"
check "issue_probe: open Refs PR leaves the issue exactly as found" 0 "" \
  test -z "$open_refs"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-38"

recent_timeline 46
open_closing="$(issue_probe 46 claimed 1 closing 460 '- [ ] verify after merge')"
check "issue_probe: closing-linked open PR remains the unchanged control" 0 "" \
  test -z "$open_closing"

recent_timeline 39
merged_closes="$(issue_probe 39 claimed 1 false "" '- [ ] verify after merge')"
check "merged Closes PR leaves a recent claim exactly as found" 0 "" \
  test -z "$merged_closes"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-39"

recent_timeline 40
all_checked="$(issue_probe 40 claimed 1 false 400 '- [x] verified after merge')"
check "merged Refs with zero unchecked boxes leaves the issue exactly as found" 0 "" \
  test -z "$all_checked"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-40"

printf '[]\n' >"$(cfix 41)"
attention_transition="$(issue_probe 41 $'claimed\nattention' 1 false 410 '- [ ] verify')"
check "derived post-merge transition clears attention with the released claim" 0 "" \
  grep -qF -- '--remove-label claimed,attention --add-label post-merge' "$TMP/issue-edits"
check "...still completes the transition" 0 "" \
  grep -qF 'merged Refs PR -> post-merge; claim released' <<<"$attention_transition"

recent_timeline 43
jq -n --arg b '<!-- issueflow:post-merge-transition-pr-430 -->' \
  --arg at "$(iso_at $((INOW - 60)))" \
  '[{"body":$b,"created_at":$at}]' >"$(cfix 43)"
reentry_edit_count="$(wc -l <"$TMP/issue-edits")"
historical="$(issue_probe 43 claimed 1 false 430 '- [ ] corrective verification')"
check "a handled historical Refs merge cannot steal a re-entered claim" 0 "" \
  test -z "$historical"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and re-entry produces no edit or duplicate transition comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$reentry_edit_count" "$TMP/issue-edits" "$TMP/posted-43"

printf '[]\n' >"$(cfix 44)"
second_transition="$(issue_probe 44 claimed 1 false 441 '- [ ] second verification')"
check "a later merged Refs PR gets an episode-specific transition comment" 0 "" \
  grep -qF '<!-- issueflow:post-merge-transition-pr-441 -->' "$TMP/posted-44"
check "...and the later episode still transitions" 0 "" \
  grep -qF 'merged Refs PR -> post-merge; claim released' <<<"$second_transition"

# End to end on the crew#321 shape: the later merge is the *lower*-numbered
# PR, and its marker is already on the issue. Selecting by number would find
# no marker for #461, fire the transition a second time, and release a claim
# the board already released (#242).
recent_timeline 46
jq -n --arg b '<!-- issueflow:post-merge-transition-pr-460 -->' \
  --arg at "$(iso_at $((INOW - 60)))" \
  '[{"body":$b,"created_at":$at}]' >"$(cfix 46)"
spent_edit_count="$(wc -l <"$TMP/issue-edits")"
spent="$(issue_probe 46 claimed 1 false \
  "461@$(iso_at $((INOW - 7200))) 460@$(iso_at $((INOW - 3600)))" \
  '- [ ] verify after merge')"
check "the marker of the later-merged lower-numbered PR is the one read" 0 "" \
  test -z "$spent"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...so the spent transition is not fired a second time" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$spent_edit_count" "$TMP/issue-edits" "$TMP/posted-46"

printf '[]\n' >"$(cfix 45)"
issue_probe 45 $'claimed\npost-merge' >/dev/null
# shellcheck disable=SC2016 # Markdown backticks are literal evidence
check "queue-conflict evidence lists every category including post-merge" 0 "" \
  grep -qF 'needs-triage`, `epic`, `ready`, `claimed`, `blocked`, or `post-merge`' \
  "$TMP/posted-45"

printf '[]\n' >"$(cfix 42)"
issue_probe 42 $'post-merge\nattention' 0 >/dev/null
check "hand-created post-merge plus attention is flagged, not rewritten" 0 "" \
  grep -qF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-42"

# -- offsite stops only the reclaim clock ------------------------------------
offsite="$(issue_probe 25 $'claimed\noffsite')"
check "a 10-day-quiet offsite claim is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite"
issue_probe 26 $'claimed\noffsite' 0 >/dev/null
check "an unassigned offsite claim is still flagged" 0 "" \
  grep -q 'issueflow:claimed-unassigned' "$TMP/posted-26"
offsite_open="$(issue_probe 27 $'claimed\noffsite' 1 true)"
check "an offsite claim with an open PR stays claimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite_open"
offsite_both="$(issue_probe 28 $'claimed\noffsite\nneeds-ruling')"
check "offsite plus needs-ruling stays claimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite_both"

# -- resolved offsite work nudges once and only from complete evidence -------
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},
    {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}}]' \
  >"$(tfix 29)"
printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_rig_pulls_112.json"
printf '[]\n' >"$(cfix 29)"
resolved="$(issue_probe 29 $'claimed\noffsite')"
check "a closed cross-referenced PR nudges and names the PR" 0 "" \
  grep -q 'heavy-duty/rig#112 is closed' "$TMP/posted-29"
check "the resolved nudge leaves the claim untouched" 1 "" \
  grep -q 'reclaimed' <<<"$resolved"
issue_probe 29 $'claimed\noffsite' >/dev/null
check "the resolved nudge is idempotent across sweeps" 0 "1" \
  grep -cF '<!-- issueflow:offsite-resolved -->' "$TMP/posted-29"

jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},
    {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}},
    {"event":"cross-referenced","source":{"issue":{"number":9,"repository":{"full_name":"heavy-duty/box"},"pull_request":{"url":"x"}}}}]' \
  >"$(tfix 30)"
printf '{"state":"open"}\n' >"$TMP/repos_heavy-duty_box_pulls_9.json"
printf '[]\n' >"$(cfix 30)"
issue_probe 30 $'claimed\noffsite' >/dev/null
check "one open cross-referenced PR suppresses the nudge" 1 "" \
  test -f "$TMP/posted-30"

printf '[]\n' >"$(tfix 31)"
printf '[]\n' >"$(cfix 31)"
issue_probe 31 $'claimed\noffsite' >/dev/null
check "no visible cross-referenced PR stays silent" 1 "" test -f "$TMP/posted-31"

: >"$(tfix 32).error"
printf '[]\n' >"$(cfix 32)"
unreadable="$(issue_probe 32 $'claimed\noffsite')"
check "an unreadable timeline stays silent" 1 "" test -f "$TMP/posted-32"
check "...and leaves the sweep running without an alarming log" 1 "" \
  grep -qiE 'error|failed' <<<"$unreadable"
# Both checks above still hold, and #247 D1 changed what reaches them:
# last_issue_activity reads the same timeline endpoint, so the issue is now
# skipped before the offsite verification runs. The skip is why nothing is
# posted, and its reason line is a deliberate report rather than an alarm
# (D4). D8 leaves offsite_timeline's own silence alone, so it is pinned here
# directly rather than through a probe that can no longer reach it.
offsite_timeline_probe() { ( REPO=owner/repo; gh() { issue_stub_gh "$@"; }; offsite_timeline "$1" ); }
check "an unreadable offsite timeline yields nothing and still fails closed" 1 "" \
  offsite_timeline_probe 32
check "...while a readable one answers its payload" 0 "[]" offsite_timeline_probe 31

: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 33)"
printf '[]\n' >"$(cfix 33)"
issue_probe 33 claimed >/dev/null
check "a non-offsite claim performs only the ordinary timeline read" 0 "1" \
  grep -cF 'repos/owner/repo/issues/33/timeline' "$TMP/api-calls"
: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 34)"
printf '[]\n' >"$(cfix 34)"
issue_probe 34 $'claimed\noffsite' >/dev/null
check "an offsite claim performs the one guarded verification read" 0 "2" \
  grep -cF 'repos/owner/repo/issues/34/timeline' "$TMP/api-calls"

check "a one-hour claim stays claimed for the ordinary age reason" 0 "KEEP" \
  claim_decision 1 false 3600
check "no reconciler mutation names offsite (#68 D4)" 1 "" \
  grep -E 'gh (issue|pr) edit.*offsite' \
    "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" \
    "$ROOT/actions/labels-reconcile/labels-reconcile.sh"

# -- the parse echo: one comment per changed set, none per sweep (#252) ------
# The whole point is a sweep-visible statement of what was read, so it is
# probed through the sweep and not only as a rendering: the marker has to
# survive the comment body, the second pass has to find it, and the third has
# to miss it because the declaration changed.
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_90.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_91.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_92.json"
printf '[]\n' >"$(cfix 35)"
echo_edits_before="$(wc -l <"$TMP/issue-edits")"
first_echo="$(issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91.")"
check "a first parse is echoed, naming the set" 0 "" \
  grep -qF 'parse to: {#90, #91}' "$TMP/posted-35"
check "...and the sweep log carries the same set" 0 \
  "issueflow: #35: blocked declarations parse to {#90, #91}" \
  printf '%s\n' "$first_echo"
issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91." >/dev/null
check "an unchanged parse draws nothing on the next sweep" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
# AC-1's other input, and it is not the sweep above. A re-sweep of a
# BYTE-IDENTICAL body is quiet under both spellings of the decision — the one
# that keys on the parse and the one that keys on the body — so it cannot tell
# them apart. Only an edit that changes the prose and preserves the parse can:
# the refs are reordered and sentences are added on either side, and the set is
# still {#90, #91}. What this pins is that the marker is a function of the
# PARSE and not of the prose around it, which is the property the echo's whole
# idempotency rests on and which nothing else in the suite states.
preserved_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 35 blocked 1 false "" \
  "Some new prose here. Blocked by #91, #90. And more text." >/dev/null
check "a body edit that preserves the parse draws nothing" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
check "...and adds no echo under any other marker either" 0 "1" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-35"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and writes no label from the parse-preserving path" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$preserved_edits_before" "$TMP/issue-edits"
changed_echo="$(issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91, #92.")"
check "a body edit that changes the set draws exactly one new echo" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91, #92}') -->" "$TMP/posted-35"
check "...naming the new set" 0 "" \
  grep -qF 'parse to: {#90, #91, #92}' "$TMP/posted-35"
check "...and saying so in the sweep log" 0 \
  "issueflow: #35: blocked declarations parse to {#90, #91, #92}" \
  printf '%s\n' "$changed_echo"
check "...and leaving the first echo alone" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the echo path" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$echo_edits_before" "$TMP/issue-edits"

# crew#308, replayed through the sweep: the declaration denies #221 and the
# parse unions it anyway. Nobody saw that set for as long as it stayed inside
# the machine; the echo puts it in the thread that contains the declaration.
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_162.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_221.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_265.json"
printf '[]\n' >"$(cfix 36)"
issue_probe 36 blocked 1 false "" \
  'Blocked by #162, #265. It is no longer blocked by #221.' >/dev/null
check "the #308 misparse is echoed verbatim, denial and all" 0 "" \
  grep -qF 'parse to: {#162, #221, #265}' "$TMP/posted-36"

# The empty parse says so, and the flag that catches the UNREADABLE
# declaration is untouched beside it: one comment states what was read, the
# other states that nothing was.
printf '[]\n' >"$(cfix 37)"
issue_probe 37 blocked 1 false "" 'No declaration anywhere in this body.' >/dev/null
check "an empty parse is echoed as the empty set" 0 "" \
  grep -qF 'parse to: {}' "$TMP/posted-37"
check "...and blocked-unparseable still fires beside it" 0 "" \
  grep -qF '<!-- issueflow:blocked-unparseable -->' "$TMP/posted-37"

# The collision the round found, replayed through the sweep: two declarations
# whose parsed sets differ but whose slugs do not. Keyed on the slug, the
# second edit found the first echo's marker and posted nothing — the machine
# silently gating on `acme-widgets#9` while the thread said `acme/widgets#9`,
# which is the readable-but-wrong shape this whole change exists to surface.
# Asserted end-to-end, so it is the second echo landing that is observed.
printf '[]\n' >"$(cfix 38)"
issue_probe 38 blocked 1 false "" 'Blocked by acme/widgets#9.' >/dev/null
check "a qualified cross-repo declaration is echoed" 0 "1" \
  grep -cF 'parse to: {acme/widgets#9}' "$TMP/posted-38"
collision_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 38 blocked 1 false "" 'Blocked by acme-widgets#9.' >/dev/null
check "a slug-colliding edit still draws its own echo" 0 "1" \
  grep -cF 'parse to: {acme-widgets#9}' "$TMP/posted-38"
check "...under a marker of its own" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{acme-widgets#9}') -->" "$TMP/posted-38"
check "...leaving the colliding first echo alone" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{acme/widgets#9}') -->" "$TMP/posted-38"
# The cross-repo flag is marker-constant across both parses, so it stays at one
# while the echo moves: what spoke on the second sweep was the changed set.
check "...and not re-flagging cross-repo, which did not change" 0 "1" \
  grep -cF '<!-- issueflow:blocked-cross-repo -->' "$TMP/posted-38"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the colliding-edit path either" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$collision_edits_before" "$TMP/issue-edits"

# A -> B -> A. The marker names the SET, so the return to A is a marker this
# thread has carried before; the question the echo has to answer is not "have I
# ever said this" but "is this still what I am saying". Searching the whole
# history answers the first, and the return went silent while the thread's
# newest echo asserted B and the sweep gated on A — a stale parse presented as
# the current one, which is the readable-but-wrong shape #252 exists to kill.
# All four sweeps are driven, because the bug is only visible as a sequence.
printf '[]\n' >"$(cfix 52)"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91, #92.' >/dev/null
return_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
check "a set edited back to a previously echoed one speaks again" 0 "3" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-52"
check "...under the returning set's own marker, twice on the thread now" 0 "2" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-52"
# The assertion the silence used to fail: it is the NEWEST echo that has to
# name what the sweep gates on, not merely some echo somewhere in the thread.
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...leaving the newest echo naming the set the sweep now gates on" 0 \
  "parse to: {#90, #91}" \
  bash -c 'grep -o "parse to: {[^}]*}" "$1" | tail -n 1' _ "$TMP/posted-52"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
check "an unchanged sweep after the return still draws nothing" 0 "3" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-52"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the returning-set path either" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$return_edits_before" "$TMP/issue-edits"

# -- an already-applied stale heals off, and no edit names the flag ----------
jq -n --arg l "$(iso_at $((INOW - 3600)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' >"$(tfix 23)"
jq -n --arg at "$(iso_at $((INOW - 3660)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc23","body":"question, options, recommendation"}]' \
  >"$(cfix 23)"
healed="$(issue_probe 23 $'claimed\nneeds-ruling\nstale')"
check "an applied stale comes off under a pending ruling" 0 "" \
  grep -q 'unstale (a ruling is pending)' <<<"$healed"
check "...via an edit that removes exactly stale" 0 "" \
  grep -q -- '--remove-label stale' "$TMP/issue-edits"
check "no issue edit across every probe names the ruling flag (#50 D9)" 1 "" \
  grep -q 'needs-ruling' "$TMP/issue-edits"

# -- label churn is not activity: the nudge clock reads comments, not labels --
jq -n --arg flag "$(iso_at $((INOW - 8 * 86400)))" \
  --arg churn "$(iso_at $((INOW - 2 * 86400)))" \
  --arg assigned "$(iso_at $((INOW - 9 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$flag},
    {"event":"labeled","label":{"name":"priority"},"actor":{"login":"anyone"},"created_at":$churn},
    {"event":"assigned","created_at":$assigned}]' >"$(tfix 24)"
jq -n --arg at "$(iso_at $((INOW - 8 * 86400 - 60)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc24","body":"question, options, recommendation"}]' \
  >"$(cfix 24)"
churn_last="$( (REPO=owner/repo; gh() { issue_stub_gh "$@"; }
  last_issue_activity 24 "$(iso_at $((INOW - 10 * 86400)))") )"
check "last activity ignores the 2-day-old label churn" 0 "" \
  test "$churn_last" = "$((INOW - 8 * 86400 - 60))"
churned="$(issue_probe 24 $'claimed\nneeds-ruling')"
check "8 real-quiet days nudge through a 2-day-old label churn" 0 "" \
  grep -q 'ruling nudge' <<<"$churned"

# ---------------------------------------------------------------------------
# An unreadable fact invents no verdict on the issue surface either (#247).
# `gh api` prints a 5xx body to stdout AND exits non-zero, and GitHub's 5xx
# body is a JSON object — so the payload that reached the guards was valid
# JSON, `.labels[]` came back empty, and queue_decision was handed the wrong
# input. The pure guards first, then the two decisions the fall-through
# reached.
# ---------------------------------------------------------------------------
payload_refused() { ! issue_payload_valid "$@"; } # 0 when the payload is refused

check "a healthy issue payload is accepted" 0 "" \
  issue_payload_valid 40 <<<'{"number":40,"labels":[{"name":"ready"}]}'
check "an issue carrying no labels at all is still a valid payload" 0 "" \
  issue_payload_valid 40 <<<'{"number":40,"labels":[]}'
# The reported shape: gh renders `gh: <message> (HTTP 504)` from a body with a
# `message` key, which proves the body was valid JSON. The status check is what
# catches this one; the shape check refuses it independently.
check "a JSON error object is not an issue payload" 0 "" \
  payload_refused 40 <<<"$GH_STUB_ERROR_BODY"
# The live path a status check alone would leave open (D3): 200, exit 0, and
# `.labels[]` empties exactly as it does on the 504.
check "an HTTP 200 whose body is null is refused" 0 "" payload_refused 40 <<<'null'
check "a payload missing .labels is refused" 0 "" \
  payload_refused 40 <<<'{"number":40}'
check "a payload whose .labels is not an array is refused" 0 "" \
  payload_refused 40 <<<'{"number":40,"labels":"ready"}'
check "a payload about a different issue is refused" 0 "" \
  payload_refused 40 <<<'{"number":41,"labels":[]}'
check "a payload that is not JSON at all is refused" 0 "" \
  payload_refused 40 <<<'not json'
check "an empty payload is refused" 0 "" payload_refused 40 </dev/null

# The reason line's shape (#101 D3/D4), reachable from this surface too — it
# is one implementation in lib/read.sh, not a second spelling.
check "empty stderr is reported as its own fact" 0 "no error output" \
  read_failure_reason ""
check "the captured 504 renders verbatim on one line" 0 \
  "$GH_STUB_STDERR" read_failure_reason "$GH_STUB_STDERR"
long_stderr="$(read_failure_reason "$(printf 'e%.0s' {1..400})")"
check "400 chars of stderr truncate to 300 plus an ellipsis" 0 "" \
  test "$long_stderr" = "$(printf 'e%.0s' {1..300})…"

# The D6 tail: silent on a whole pass, and naming both count and numbers on a
# partial one.
check "a whole pass adds no tail line" 0 "" test -z "$(skipped_tail 0 "")"
check "one skipped issue is named in the singular" 0 \
  "1 issue skipped this pass on an unreadable fact: #12" skipped_tail 1 "#12"
check "several skipped issues are all named" 0 \
  "2 issues skipped this pass on unreadable facts: #12 #40" \
  skipped_tail 2 "#12 #40"

# -- the destroyed claim: a 504 on the comments read of a live claim ---------
# created_at long ago, a comment seconds old, and the comments read fails. The
# swallowed read dated the issue by created_at and reclaimed it, unassigning
# the builder under a comment asserting 48 hours of silence.
jq -n --arg at "$(iso_at $((INOW - 10)))" \
  '[{"user":{"login":"builder"},"created_at":$at,"html_url":"https://x/live","body":"still on it"}]' \
  >"$(cfix 50)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 50).http-error"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 50)"
claim_edits_before="$(wc -l <"$TMP/issue-edits")"
check "a 504 on the comments read skips the issue instead of grading its age" \
  3 "#50: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  issue_probe 50 claimed 1
check "...so the live claim is not reclaimed" 1 "" \
  grep -q 'stale claim reclaimed -> ready' <<<"$(issue_probe 50 claimed 1)"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...no unassign, no label swap, and no reclaim comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$claim_edits_before" "$TMP/issue-edits" "$TMP/posted-50"

# -- the quiet diagnostic: a 504 on a post-merge activity read (#254) --------
# The guarded read is unconditional at the top of the branch, so a
# `post-merge` issue can be skipped where before this change it never could —
# and the assigned flag, which needed no read at all, goes quiet with it.
# That is #247 D1's direction (a whole pass or none of it, never a verdict
# derived from a read that did not answer) and the trade `claimed`, `blocked`
# and `needs-ruling` already make. It is still a new way for that diagnostic
# to fall silent, so it is pinned here rather than left to inspection.
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c94","body":"evidence pending"}]' \
  >"$(cfix 94)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 94).http-error"
post_merge_skip_edits="$(wc -l <"$TMP/issue-edits")"
check "a 504 on a post-merge activity read skips the issue" \
  3 "#94: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  issue_probe 94 post-merge 1
check "...so neither the nudge nor the assigned flag speaks" 1 "" test -f "$TMP/posted-94"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and the skipped pass edits nothing" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ \
  "$post_merge_skip_edits" "$TMP/issue-edits"

# -- the suppressed comment: a 504 on the marker read -----------------------
# The marker is on the issue. Read as "no marker", a failed read re-posts the
# comment the marker exists to suppress — every sweep, forever.
jq -n --arg b '<!-- issueflow:blocked-unparseable -->' \
  --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/m","body":$b}]' \
  >"$(cfix 51)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 51).http-error"
check "a 504 on the marker read skips rather than reading it as no marker" \
  3 "#51: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  issue_probe 51 blocked 1 false "" "no parseable declaration here"
check "...so no duplicate comment is posted" 1 "" test -f "$TMP/posted-51"

# -- a deliberate skip is counted; a genuine crash is still named (D4) -------
printf '%s\n' '{"number":60,"labels":[{"name":"ready"}],"assignees":[]}' \
  >"$TMP/repos_owner_repo_issues_60.json"
printf '%s\n' '{"number":61,"labels":[{"name":"ready"}],"assignees":[]}' \
  >"$TMP/repos_owner_repo_issues_61.json"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$TMP/repos_owner_repo_issues_61.json.http-error"
pass_probe() { # $1 issue; $2 non-empty makes reconcile_issue crash
  (
    REPO=owner/repo
    gh() { issue_stub_gh "$@"; }
    [ -z "${2:-}" ] || reconcile_issue() { return 9; }
    SKIPPED_COUNT=0
    SKIPPED_ISSUES=""
    reconcile_issue_pass "$1"
    printf 'rc=%s count=%s issues=%s\n' "$?" "$SKIPPED_COUNT" "$SKIPPED_ISSUES"
  )
}
check "a genuine non-read crash still names the failure byte-identically" 0 \
  "issueflow: #60: reconcile failed — continuing with the remaining issues" \
  pass_probe 60 crash
check "...and the pass still returns 0, so the loop reaches the next issue" 0 \
  "rc=0" pass_probe 60 crash
check "...and a crash is not counted as a skip" 0 "count=0" pass_probe 60 crash
check "a skipped issue is counted and named" 0 "count=1 issues=#61" pass_probe 61
check "...and is not also reported as a crash" 1 "" \
  grep -q 'reconcile failed' <<<"$(pass_probe 61)"
check "...leaving the loop free to continue" 0 "rc=0" pass_probe 61

# ---------------------------------------------------------------------------
# The arrival path, executed the way the action executes it (#91): four
# triage-authored mints died silently because the stand-down `return`s in
# reconcile_opened_issue carried the failed test's status into `set -e`. A
# sourced test takes the `set -u`-only branch and is blind to that class of
# bug by construction, so these run the script as a subprocess behind a
# PATH-stubbed gh — the house pattern from test/release-chain.test.sh.
# ---------------------------------------------------------------------------
ARRIVAL="$TMP/arrival"
mkdir -p "$ARRIVAL/stub" "$ARRIVAL/fixtures"
printf 'triage-actors=triage-one triage-two\n' >"$ARRIVAL/labels.conf"
cat >"$ARRIVAL/stub/gh" <<'EOF'
#!/usr/bin/env bash
# Endpoints map to files under $GH_FIXTURES ('/?&=' -> '_'); an absent file
# answers an empty list, a .error sentinel fails the call like a dead API.
if [ "$1" = api ]; then
  shift
  endpoint="" jqexpr="" query=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq) jqexpr="$2"; shift ;;
      -f|-F)
        case "$2" in query=*) query="${2#query=}" ;; esac
        shift ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$1" ;;
    esac
    shift
  done
  file="$GH_FIXTURES/$(printf '%s' "$endpoint" | tr '/?&=' '____').json"
  if [ "$endpoint" = graphql ]; then
    case "$query" in
      *'states: OPEN'*) file="$GH_FIXTURES/graphql-open.json" ;;
      *'states: MERGED'*) file="$GH_FIXTURES/graphql-merged.json" ;;
    esac
  fi
  # `.http-error` is the real 5xx (#247): the response body — GitHub's JSON
  # error object — goes to STDOUT, the reason to stderr, and the status is
  # non-zero. `.error` is the payload-free failure, which is the safe path.
  if [ -f "$file.http-error" ]; then
    if [ -n "$jqexpr" ]; then
      jq -r "$jqexpr" "$file.http-error" 2>/dev/null || true
    else
      cat "$file.http-error"
    fi
    printf '%s\n' "${GH_STUB_STDERR:-}" >&2
    exit 1
  fi
  [ ! -f "$file.error" ] || { printf '%s\n' "${GH_STUB_STDERR:-}" >&2; exit 1; }
  if [ -f "$file" ]; then payload="$(cat "$file")"; else payload='[]'; fi
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$payload"; else printf '%s\n' "$payload"; fi
  exit 0
fi
if [ "$1" = issue ]; then printf '%s\n' "$*" >>"$GH_FIXTURES/edits"; exit 0; fi
echo "gh stub: unexpected call: gh $*" >&2
exit 97
EOF
chmod +x "$ARRIVAL/stub/gh"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
cp "$ARRIVAL/fixtures/graphql-open.json" "$ARRIVAL/fixtures/graphql-merged.json"
arrival_fixture() { printf '%s\n' "$1" >"$ARRIVAL/fixtures/repos_owner_repo_issues_91.json"; }
arrival_run() {
  : >"$ARRIVAL/fixtures/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    EVENT_NAME=issues EVENT_ACTION=opened EVENT_ISSUE=91 \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
}

arrival_fixture '{"user":{"login":"triage-one"},"labels":[{"name":"ready"}]}'
triage_out="$(arrival_run 2>&1)"
triage_rc=$?
check "a triage-authored arrival exits 0 (#91's four dead mints)" 0 "" \
  test "$triage_rc" -eq 0
check "...and its output reaches the sweep" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$triage_out"
check "...and mints nothing" 1 "" test -s "$ARRIVAL/fixtures/edits"

arrival_fixture '{"user":{"login":"outsider"},"labels":[{"name":"ready"}]}'
outside_out="$(arrival_run 2>&1)"
outside_rc=$?
check "an outside-authored arrival exits 0" 0 "" test "$outside_rc" -eq 0
check "...still mints needs-triage" 0 "" \
  grep -qF 'needs-triage (opened by outsider)' <<<"$outside_out"
check "...still strips the smuggled queue label" 0 "" \
  grep -qxF 'issue edit 91 -R owner/repo --add-label needs-triage --remove-label ready' \
  "$ARRIVAL/fixtures/edits"
check "...and the sweep still runs after the mint" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$outside_out"

arrival_fixture '{"user":{"login":"outsider"},"labels":[],"pull_request":{"url":"x"}}'
pr_out="$(arrival_run 2>&1)"
pr_rc=$?
check "a PR arrival exits 0" 0 "" test "$pr_rc" -eq 0
check "...stands down without minting" 1 "" test -s "$ARRIVAL/fixtures/edits"
check "...and the sweep still runs" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$pr_out"

# Exercise both directions through main(): a merged-Refs transition still
# fires without a linked open PR, then the open-body gather suppresses it.
# A sourced decision probe cannot exercise the GraphQL gather and loop
# (#91's lesson).
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":400,"mergedAt":"2026-07-30T19:05:16Z","body":"Refs #40","closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-merged.json"
printf '[{"number":40}]\n' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_state_open_per_page_100.json"
jq -n --arg at "$(iso_at "$INOW")" \
  '{number:40,user:{login:"triage-one"},created_at:$at,body:"- [x] built\n- [ ] verify live label",labels:[{name:"claimed"}],assignees:[{login:"builder"}]}' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_40.json"
printf '[]\n' >"$ARRIVAL/fixtures/repos_owner_repo_issues_40_comments.json"
: >"$ARRIVAL/fixtures/edits"
transition_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
transition_rc=$?
check "an executable sweep with no linked open PR exits 0" 0 "" \
  test "$transition_rc" -eq 0
check "...reaches the transition through GraphQL and the issue loop" 0 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$transition_out"
check "...and performs the release edit from the executable path" 0 "" \
  grep -qF -- 'issue edit 40 -R owner/repo --remove-assignee builder --remove-label claimed --add-label post-merge' \
  "$ARRIVAL/fixtures/edits"

printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":401,"body":"Refs #40","isDraft":false,"closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
subprocess_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
subprocess_rc=$?
check "an open Refs-bodied PR suppresses the post-merge transition" 0 "" \
  test "$subprocess_rc" -eq 0
check "...leaves the live claim assigned" 1 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$subprocess_out"
check "...performs no release edit" 1 "" \
  grep -qF -- 'issue edit 40 -R owner/repo --remove-assignee builder --remove-label claimed --add-label post-merge' \
  "$ARRIVAL/fixtures/edits"

# The query selects every OPEN PR and deliberately does not select isDraft;
# this fixture-only flip documents that draft identity cannot narrow the set.
sed 's/"isDraft":false/"isDraft":true/' "$ARRIVAL/fixtures/graphql-open.json" \
  >"$ARRIVAL/fixtures/graphql-open.json.tmp"
mv "$ARRIVAL/fixtures/graphql-open.json.tmp" "$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
draft_transition_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
check "a draft Refs-bodied PR suppresses post-merge transition identically" 1 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$draft_transition_out"

# The same body linkage protects the reclaim clock even when no Refs-linked
# PR has merged. This is the derived half of crew#321's destructive shape.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":411,"body":"Refs #41","isDraft":false,"closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-merged.json"
printf '[{"number":41}]\n' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_state_open_per_page_100.json"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '{number:41,user:{login:"triage-one"},created_at:$at,body:"- [ ] build",labels:[{name:"claimed"}],assignees:[{login:"builder"}]}' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_41.json"
printf '[]\n' >"$ARRIVAL/fixtures/repos_owner_repo_issues_41_comments.json"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$at}]' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_41_timeline.json"
: >"$ARRIVAL/fixtures/edits"
reclaim_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    ISSUEFLOW_NOW="$INOW" REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
reclaim_rc=$?
check "an open Refs-bodied PR suppresses stale reclaim" 0 "" test "$reclaim_rc" -eq 0
check "...keeps the quiet live claim" 1 "" \
  grep -qF '#41: stale claim reclaimed -> ready' <<<"$reclaim_out"

# Drafts are live claim evidence by the same OPEN query (D4). The query does
# not select isDraft, so this fixture-only flip deliberately leaves production
# input byte-identical and guards the absence of a draft/readiness predicate.
sed 's/"isDraft":false/"isDraft":true/' "$ARRIVAL/fixtures/graphql-open.json" \
  >"$ARRIVAL/fixtures/graphql-open.json.tmp"
mv "$ARRIVAL/fixtures/graphql-open.json.tmp" "$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
draft_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    ISSUEFLOW_NOW="$INOW" REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
check "a draft Refs-bodied PR suppresses stale reclaim identically" 1 "" \
  grep -qF '#41: stale claim reclaimed -> ready' <<<"$draft_out"

# D2 preserved: only the deliberate stand-downs changed; a genuine failure on
# the arrival path still kills the run loudly.
: >"$ARRIVAL/fixtures/repos_owner_repo_issues_91.json.error"
err_out="$(arrival_run 2>&1)"
err_rc=$?
check "a dead API on the arrival path still fails the run (D2)" 0 "" \
  test "$err_rc" -eq 1
check "...and the sweep does not run over a lying arrival" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$err_out"

# ---------------------------------------------------------------------------
# The whole sweep over an unreadable board (#247), executed. The sourced
# probes above drive one issue's pass; only this path exercises the loop, the
# counting and the tail — and only this path reproduces crew#329's log, which
# ended `issueflow: reconciled.` with rc=0 over a label it should never have
# written. Its own fixture directory: the arrival fixtures above are stateful
# across their cases.
# ---------------------------------------------------------------------------
SWEEP="$TMP/sweep"
mkdir -p "$SWEEP"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$SWEEP/graphql-open.json"
cp "$SWEEP/graphql-open.json" "$SWEEP/graphql-merged.json"
# 70: the 504 with a JSON error body on the per-issue read.
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$SWEEP/repos_owner_repo_issues_70.json.http-error"
# 71: healthy, and carrying no queue label — so if the sweep reaches it, it
# writes needs-triage. That write is the evidence the loop continued.
printf '%s\n' \
  '{"number":71,"user":{"login":"triage-one"},"labels":[{"name":"enhancement"}],"assignees":[]}' \
  >"$SWEEP/repos_owner_repo_issues_71.json"
# 72: HTTP 200 whose body is `null` — exit 0, and the label set empties just
# as it does on the 504. The shape check is the only thing that catches it.
printf 'null\n' >"$SWEEP/repos_owner_repo_issues_72.json"

sweep_board() { printf '%s\n' "$1" >"$SWEEP/repos_owner_repo_issues_state_open_per_page_100.json"; }
sweep_run() {
  : >"$SWEEP/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$SWEEP" ISSUEFLOW_NOW="$INOW" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
}

# The board read is a precondition for the whole pass (#257). A failed read
# cannot be inferred from an empty result: its status is the only fact that
# separates an unreadable board from a clean one. Drive both through main(),
# including gh's partial-pagination shape where stdout is non-empty on error.
board_fixture="$SWEEP/repos_owner_repo_issues_state_open_per_page_100.json"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$board_fixture.http-error"
board_504_out="$(sweep_run)"
board_504_rc=$?
check "an issue-list 504 aborts the whole pass" 0 "" test "$board_504_rc" -eq 1
check "...names the board read's stderr" 0 \
  "issueflow: could not read the issue board: $GH_STUB_STDERR" \
  printf '%s\n' "$board_504_out"
check "...writes no issue edit or comment" 1 "" test -s "$SWEEP/edits"
check "...never reports the pass reconciled" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$board_504_out"

board_silent_out="$(GH_STUB_STDERR="" sweep_run)"
board_silent_rc=$?
check "a silent issue-list failure still aborts" 0 "" test "$board_silent_rc" -eq 1
check "...renders the empty stderr as a fact" 0 \
  'issueflow: could not read the issue board: no error output' \
  printf '%s\n' "$board_silent_out"
check "...also writes nothing" 1 "" test -s "$SWEEP/edits"

printf '[{"number":71}]\n' >"$board_fixture.http-error"
partial_board_out="$(sweep_run)"
partial_board_rc=$?
check "partial pagination aborts the whole pass" 0 "" \
  test "$partial_board_rc" -eq 1
check "...does not reconcile the returned first page" 1 "" \
  grep -qF 'issue edit 71' "$SWEEP/edits"
check "...does not report the truncated pass reconciled" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$partial_board_out"

rm -f "$board_fixture.http-error"
sweep_board '[]'
empty_board_out="$(sweep_run)"
empty_board_rc=$?
check "a successful empty board stays green" 0 "" test "$empty_board_rc" -eq 0
check "...writes nothing" 1 "" test -s "$SWEEP/edits"
check "...names the empty-board outcome" 0 'issueflow: no open issues.' \
  printf '%s\n' "$empty_board_out"
check "...still ends with byte-identical reconciled." 0 \
  'issueflow: reconciled.' printf '%s\n' "$(tail -n1 <<<"$empty_board_out")"

sweep_board '[{"number":70},{"number":71}]'
sweep_out="$(sweep_run)"
sweep_rc=$?
check "an unreadable issue does not red the sweep (D7)" 0 "" test "$sweep_rc" -eq 0
check "the 504's JSON error body is skipped, with the reason named" 0 \
  "issueflow: #70: skipped this pass — could not read the issue: $GH_STUB_STDERR" \
  printf '%s\n' "$sweep_out"
check "...and crew#329's label is never written" 1 "" \
  grep -qF '#70: needs-triage (no queue state)' <<<"$sweep_out"
check "...nor any edit at all on the unreadable issue" 1 "" \
  grep -qF 'issue edit 70' "$SWEEP/edits"
check "...while the readable issue beside it is reconciled as before" 0 "" \
  grep -qxF 'issue edit 71 -R owner/repo --add-label needs-triage' "$SWEEP/edits"
check "...and the partial pass names its count and its issue" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #70' \
  printf '%s\n' "$sweep_out"
check "...after a byte-identical reconciled. line" 0 "" \
  grep -qxF 'issueflow: reconciled.' <<<"$sweep_out"

sweep_board '[{"number":72}]'
null_out="$(sweep_run)"
null_rc=$?
check "an HTTP 200 whose body is null exits 0 and writes nothing" 0 "" \
  test "$null_rc" -eq 0
check "...because the shape check refuses it, on its own line" 0 \
  'issueflow: #72: skipped this pass — the issue read answered a payload that is not issue #72 carrying a label array' \
  printf '%s\n' "$null_out"
check "...so no label is derived from an empty label set" 1 "" \
  grep -qF 'issue edit 72' "$SWEEP/edits"
check "...and the tail names it too" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #72' \
  printf '%s\n' "$null_out"

sweep_board '[{"number":70},{"number":72}]'
both_out="$(sweep_run)"
check "two skipped issues are both named, in the plural" 0 \
  'issueflow: 2 issues skipped this pass on unreadable facts: #70 #72' \
  printf '%s\n' "$both_out"

sweep_board '[{"number":71}]'
whole_out="$(sweep_run)"
whole_rc=$?
check "a whole pass still exits 0" 0 "" test "$whole_rc" -eq 0
check "...ends on the byte-identical reconciled. line, with no tail after it" 0 \
  "issueflow: reconciled." printf '%s\n' "$(tail -n1 <<<"$whole_out")"
check "...and says nothing about skipping" 1 "" \
  grep -q 'skipped this pass' <<<"$whole_out"

# ---------------------------------------------------------------------------
# The ordering invariant (#247 D1): a skip implies ZERO writes, wherever in
# the pass the failed read lives. Round 1 measured what the per-read guards
# alone left standing — a pass could remove `stale`, or mint `needs-triage`,
# and only then reach a guarded read, fail it, and report the issue as
# skipped. The sweep said it had touched nothing while a write had landed:
# the same false report #247 exists to close, one layer along.
#
# Every composition is driven TWICE against identical fixtures, differing
# only in whether the late read answers. The healthy run is the control — it
# proves the mutation is genuinely on this path, so the failing run's "no
# edit" is a fact about the guard and not about a branch that never fired.
# Executed through the sweep, because staging is a property of the pass.
# ---------------------------------------------------------------------------
ORDER="$TMP/order"
mkdir -p "$ORDER"
cp "$SWEEP/graphql-open.json" "$SWEEP/graphql-merged.json" "$ORDER/"
order_board() { printf '%s\n' "$1" >"$ORDER/repos_owner_repo_issues_state_open_per_page_100.json"; }
order_fixture() { # $1 issue, $2 labels JSON, $3 body
  jq -n --argjson n "$1" --argjson labels "$2" --arg body "${3:-}" \
    --arg at "$(iso_at $((INOW - 10 * 86400)))" \
    '{number: $n, created_at: $at, user: {login: "triage-one"},
      labels: $labels, assignees: [], body: $body}' \
    >"$ORDER/repos_owner_repo_issues_$1.json"
}
order_run() {
  : >"$ORDER/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ORDER" ISSUEFLOW_NOW="$INOW" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
}
# The late read fails, or answers. `guarded_read` is what turns either into a
# skip, so which endpoint carries the sentinel is what picks the composition.
order_breaks() { printf '%s\n' "$GH_STUB_ERROR_BODY" >"$ORDER/repos_owner_repo_issues_$1_$2.json.http-error"; }
order_heals() { rm -f "$ORDER/repos_owner_repo_issues_$1_$2.json.http-error"; }
# A skip must leave no trace of the staged effect: not the write, and not the
# log line that would have announced it. Both halves, because a landed write
# under a "skipped" line and a "reconciled" line over no write are the same
# lie told from opposite ends.
order_wrote() { grep -qF "issue $2 $1" "$ORDER/edits"; }

# -- 1. unstale, then a failed activity read (the round's first composition) -
# `needs-ruling` heals an applied `stale` off before the tail reads the
# issue's activity. The read is two statements later; the write is already
# gone.
order_fixture 80 '[{"name":"ready"},{"name":"needs-ruling"},{"name":"stale"}]'
order_board '[{"number":80}]'
order_heals 80 comments
healthy_unstale="$(order_run)"
check "the control: a healthy pass really does unstale a pending ruling" 0 "" \
  order_wrote 80 edit
check "...and says so" 0 "issueflow: #80: unstale (a ruling is pending)" \
  printf '%s\n' "$healthy_unstale"
order_breaks 80 comments
broken_unstale="$(order_run)"
check "a failed activity read skips the unstale composition" 0 \
  "issueflow: #80: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_unstale"
check "...and the stale label is still on the issue" 1 "" order_wrote 80 edit
check "...and nothing claims it came off" 1 "" \
  grep -qF 'unstale (a ruling is pending)' <<<"$broken_unstale"

# -- 2. ADD_NEEDS_TRIAGE, then a failed activity read (the second) -----------
# The mint falls through — unlike FLAG_CONFLICT, which returns — into the
# same tail. crew#329's own label, written and then disowned by the log.
order_fixture 81 '[{"name":"enhancement"},{"name":"needs-ruling"}]'
order_board '[{"number":81}]'
order_heals 81 comments
healthy_mint="$(order_run)"
check "the control: a healthy pass really does mint needs-triage here" 0 "" \
  order_wrote 81 edit
check "...and says so" 0 "issueflow: #81: needs-triage (no queue state)" \
  printf '%s\n' "$healthy_mint"
order_breaks 81 comments
broken_mint="$(order_run)"
check "a failed activity read skips the needs-triage composition" 0 \
  "issueflow: #81: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_mint"
check "...and crew#329's label is not written on the way out" 1 "" \
  order_wrote 81 edit
check "...and nothing claims it was" 1 "" \
  grep -qF '#81: needs-triage (no queue state)' <<<"$broken_mint"

# -- 3. the blockers->ready flip, then a failed COMMENTS read ----------------
# The read that guards this branch is the marker check ahead of the parse
# echo: a broken comments endpoint skips there, before the echo or the flip
# is staged. The timeline is no longer an input on this path at all (#284
# D1 — the ruling clock reads comments alone), so the unreadable-timeline
# case moved from "skips everything" to its own pin below.
printf '%s\n' '{"number":82,"state":"closed"}' \
  >"$ORDER/repos_owner_repo_issues_82.json"
order_fixture 83 '[{"name":"blocked"},{"name":"needs-ruling"}]' 'Blocked by #82.'
order_board '[{"number":83}]'
order_heals 83 comments
order_heals 83 timeline
healthy_flip="$(order_run)"
check "the control: a healthy pass really does flip cleared blockers to ready" 0 \
  "issueflow: #83: blockers closed -> ready" printf '%s\n' "$healthy_flip"
check "...writing the label edit" 0 "" order_wrote 83 edit
check "...and posting the blockers-cleared comment" 0 "" order_wrote 83 comment
order_breaks 83 comments
broken_flip="$(order_run)"
check "a failed comments read skips the blockers->ready composition" 0 \
  "issueflow: #83: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_flip"
check "...leaving the issue blocked" 1 "" order_wrote 83 edit
check "...with no comment posted about it" 1 "" order_wrote 83 comment
check "...and nothing claiming the flip happened" 1 "" \
  grep -qF 'blockers closed -> ready' <<<"$broken_flip"
# The read this path no longer takes cannot skip it (#284): with comments
# healthy and the timeline broken, the flip commits, and only the ruling
# ladder's own soft-failing read goes without — no verdict is invented, and
# no unrelated write is held hostage by an input the clocks stopped reading.
order_heals 83 comments
order_breaks 83 timeline
narrowed_flip="$(order_run)"
check "a failed timeline read no longer skips the flip" 1 "" \
  grep -qF 'skipped this pass' <<<"$narrowed_flip"
check "...the flip commits" 0 "" order_wrote 83 edit
check "...and the ruling ladder says what it could not read" 0 \
  "issueflow: #83: ruling timeline unreadable — no verdict invented this pass" \
  printf '%s\n' "$narrowed_flip"

# -- 4. a posted nudge, then a failed COMMENTS read -------------------------
# The comment-only half of the class: the epic nudge's own marker check is
# the read that fails, so the nudge is never staged and the skip reports the
# truth. A comment is as much a mutation as a label — it is the thing
# markers exist to make idempotent.
order_fixture 84 '[{"name":"epic"},{"name":"needs-ruling"}]' \
  '## Task list

- [x] #82'
order_board '[{"number":84}]'
order_heals 84 comments
order_heals 84 timeline
healthy_nudge="$(order_run)"
check "the control: a healthy pass really does nudge a completed epic" 0 \
  "issueflow: #84: completed epic nudged" printf '%s\n' "$healthy_nudge"
check "...by posting a comment" 0 "" order_wrote 84 comment
order_breaks 84 comments
broken_nudge="$(order_run)"
check "a failed comments read skips the epic-nudge composition" 0 \
  "issueflow: #84: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_nudge"
check "...and the nudge comment is never posted" 1 "" order_wrote 84 comment
check "...and nothing claims it was" 1 "" \
  grep -qF 'completed epic nudged' <<<"$broken_nudge"
# The narrowed surface again (#284): a broken timeline neither skips nor
# suppresses the nudge; the ruling ladder alone goes without a verdict.
order_heals 84 comments
order_breaks 84 timeline
narrowed_nudge="$(order_run)"
check "a failed timeline read no longer skips the epic nudge" 1 "" \
  grep -qF 'skipped this pass' <<<"$narrowed_nudge"
check "...the nudge commits" 0 "" order_wrote 84 comment

# -- the skip is still just a skip: counted, tailed, and green (D4, D6, D7) --
check "a mutation-bearing composition that skips is still not a crash" 1 "" \
  grep -qF 'reconcile failed' <<<"$broken_flip"
check "...is still counted in the D6 tail" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #83' \
  printf '%s\n' "$broken_flip"
order_board '[{"number":83}]'
order_run >/dev/null
check "...and still leaves the job green (D7)" 0 "" test $? -eq 0

# -- the invariant is enforced at the source, not remembered ----------------
# Staging only holds while every mutation goes through run(). A future call
# site reaching gh directly would reopen this hole silently, so it is pinned
# here rather than left to review — the shape lib/ruling.sh already uses for
# #50 D9. reconcile_opened_issue is deliberately exempt: it runs outside the
# per-issue subshell, under live errexit, and stages nothing (#247 D8).
mutation_calls() {
  grep -nE '(^|[^_[:alnum:]])gh issue (edit|comment)' \
    "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" "$ROOT/lib/ruling.sh" \
    | grep -vE '^\S+:[0-9]+: *#' || true
}
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "every issue mutation on this surface goes through run()" 0 "" \
  bash -c 'while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *"run gh issue "*) ;; *) printf "unstaged mutation: %s\n" "$line"; exit 1 ;; esac
  done <<<"$1"' _ "$(mutation_calls)"
check "...and the pin sees the call sites it is guarding" 0 "" \
  test "$(mutation_calls | wc -l)" -ge 8

summary
