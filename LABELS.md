# Labels

The taxonomy shared across the heavy-duty repos. Only the `scope:` set
differs per repo (each repo's `.github/labels.conf` names its actual
surfaces); everything else below is core and identical everywhere, created by
the labels workflow's dispatch (which is also the operator's manual
full-board reconcile sweep; issue #10).

Two state machines share the taxonomy: the **PR machine** (proven in
box/rig/cast, reconciled by machinery) and the **issue flow** (the
triage → build queue, reconciled by the work-queue sweep). One rule joins
everything: **states are machine-owned, intent
labels are hand-set** — a hand-moved state label is a lie waiting to happen,
and the reconciler recomputes it from GitHub's own facts.

## PR state — who is the ball with? (exactly one per open PR)

| Label | Color | Waiting on |
|---|---|---|
| `state:building` | `#FBCA04` | the builder — pre-round: no verdict stands against the head. Draft is evidence for it, not the definition of it: a draft carrying a standing non-approving verdict is a fix round and reads `state:addressing` (#205) |
| `state:bots-reviewing` | `#1D76DB` | the reviewer panel to finish the round (a request is live) |
| `state:addressing` | `#D93F0B` | the builder — round complete without full approval, or nobody was asked, or a blocker is up, or a ruling is pending |
| `state:needs-human` | `#8250DF` | the human — or, where this repository's own sweep caller passes the governing merge toggle (`auto_merge` for ordinary PRs or `auto_merge_release` for release PRs, both `off` by default and set by the consumer, not ceremony), the reconciler pressing on this same verdict — **this PR could be merged right now**: zero blockers, whole panel approved the current head |

`bots-reviewing` vs `addressing` is deliberate: staleness in the first means
*poke the reviewers*, in the second *the builder dropped the ball* — unless a
`rerun-owed` flag stands on that head, and then it means *poke whoever
services the rerun*, because the builder there owes nothing until the rerun is
made and its quiet is the flag's, not the builder's (#423). And
`state:needs-human` means exactly one thing — a human could merge this now —
so it requires zero blockers and head-current approvals; anything less and
the reconciler takes it back. The author sets it at handoff (the one
hand-set state); the `labeled` event fires the sweep that validates the
write within seconds.

**A request for the human's review outranks an unfinished round only when a
maintainer made it** — a maintainer pulling a PR to themselves early is a
deliberate act, and that is the whole of the precedence. The reconciler also
asks the human, once, when the round passes, and that ask is its own and
provisional. The two were one bit until the sweep began marking its own: it
writes `<!-- ceremony:human-requested -->` in the comment it posts with the
ask, and `<!-- ceremony:human-request-withdrawn -->` when it takes the ask
back, which it does on the first sweep where the state is no longer
`state:needs-human`. A marked request neither outranks a round with a verdict
missing nor exempts that head from `blocker:unrequested`. An unmarked one is a
maintainer's: it outranks, it exempts, and no machine withdraws it — through
every push, and when the marks cannot be read at all (#479).

## PR blockers — what is in the way? (facts, as many as apply)

| Label | Color | Means |
|---|---|---|
| `blocker:conflict` | `#B60205` | does not merge — the builder owes a **rebase** |
| `blocker:ci-red` | `#B60205` | a check failed — the builder owes a **fix**, which a rebase will not provide. Not asserted at a head carrying `rerun-owed`, where the builder owes nothing (#423) |
| `blocker:unrequested` | `#E99695` | this head has no verdict from somebody, and nobody was asked |
| `blocker:drill-pending` | `#B60205` | a `release` PR whose version has no `drills/X.Y.Z.md` record — correct but unevidenced (maintainer-created label; the bot bootstrap 403s on it) |

States answer *whose ball*; blockers answer *what's in the way*. They are
separate axes because the single-label version kept lying — independent facts
projected onto one totally-ordered label meant one always won and the losers
vanished off the board (box's `state:needs-rebase`, retired: the reconciler
strips it on sight).

## Issue flow — the work queue (exactly one per open, triaged, non-epic issue)

| Label | Color | Means | Set by |
|---|---|---|---|
| `needs-triage` | `#FBCA04` | an issue that did not come through triage — it owes normalization or conversion back to a discussion | anyone who spots one; cleared by triage |
| `ready` | `#0E8A16` | Triaged, spec complete, unblocked; its owner can start now and succeed | triage |
| `claimed` | `#1D76DB` | a builder owns it: assignee set, a draft PR expected shortly | the claiming builder |
| `blocked` | `#6A737D` | waiting on another issue or PR (`Blocked by #N` in the body names it) | triage; anyone may correct it |
| `post-merge` | `#006B75` | the Refs-linked PR merged; post-merge acceptance criteria remain; the claim is released — nothing here is buildable and nobody owes a draft | the sweep or triage |
| `epic` | `#5319E7` | organizes other issues via a dependency-ordered task list; **builders never pick an epic** | triage |

The work-queue sweep enforces the invariant a board scan relies on: every open issue is either
`needs-triage`, `epic`, or carries exactly one of `ready` / `claimed` /
`blocked` / `post-merge`. It flags conflicts rather than guessing intent. A `claimed` issue
with no open PR and no activity for 48 hours is reclaimed by the sweep: it
comments, unassigns the stale owner, and restores `ready`.

When a merged PR references a `claimed` issue with `Refs #N` and unchecked
criteria remain, the sweep moves the issue to `post-merge`, clears the
assignee, and comments with the remaining criteria verbatim. The comment says
that the claim is released and that triage owes a follow-up naming the owner
and wake condition for completion. Triage writes that full transition comment
in the same tick when it or the operator makes the move by hand. The sweep
never reclaims `post-merge`: weeks of quiet can be the state working. It does
make the quiet visible — after 7 days with no comment on the issue, the sweep
posts one nudge naming the triage actor, saying the wake evidence is owed and
linking the item. Only a comment resets that clock: label churn does not, and
neither does an assignment, which is the claim clock's fact and on this queue
state is the invalid composition flagged below. Which criterion starved is
prose the machine never judges; the link is the payload. Like the ruling nudge
it carries no idempotency marker on purpose — the comment is itself activity,
so the rule self-rate-limits to one nudge per 7 quiet days — and it writes no
label.

`operator` has the same legitimate-quiet shape and the same clock. After 7
days with no comment on an issue carrying it, the sweep posts one nudge naming
the operator, linking the issue, and saying the body's wake condition is still
owed. A plain `ready` issue never draws this nudge. Only a comment resets the
clock; the nudge carries no marker and writes no label, so its own comment
self-rate-limits it to once per 7 quiet days (#491).

`post-merge` never composes with `blocked`; the transition comment carries the
wait. It never composes with `attention`, because releasing the claim clears
the assignee and leaves nobody parked-for. An assigned `post-merge` issue is
flagged rather than repaired: a hand-assignment is intent. `needs-ruling`
still composes. When the remainder becomes buildable, triage moves
`post-merge` to `ready` or mints a fresh `ready` issue. Any builder may claim
that work from current `main`; the original builder has no special standing,
and re-entry does not set `attention`.

## Cross-cutting (PRs and issues)

| Label | Color | Meaning |
|---|---|---|
| `stale` | `#B60205` | no activity for 48h — sweep-managed, never hand-applied |
| `blocked` | `#6A737D` | (see above — same label serves PRs waiting on another PR/issue; legitimately quiet, the staleness sweep skips it). The reconciler refuses `state:needs-human` while `blocked` stands — the PR falls to `state:addressing` (#180) |
| `offsite` | `#CFD3D7` | issue deliverable is a PR in another repository; set by the builder with the draft link and cleared by the builder at handoff |
| `needs-ruling` | `#D4C5F9` | a human-owned decision is required; use BUILDER.md's ruling template and ladder. Set by triage or the builder; a state, not a signal — it clears on agreement, not on a reply |
| `operator` | `#A371F7` | issue-only: operator-owned; the body names the evidence surface, the command, and the wake condition |
| `rerun-owed` | `#D4C5F9` | PR-only: the head is red on a rerun no agent may start, so the builder owes nothing until it is made. Set by the builder with its evidence; cleared by `ci-rerun` when it starts the attempt, and by the reconciler when the head recovers or moves (#424) |
| `attention` | `#D93F0B` | issue-only demand parked for the assignee; hand-set, and never written by the machine |
| `release` | `#0E8A16` | release flow, versioning, packaging work — and the ceremony PR itself |
| `merge-next` | `#0E8A16` | head of the merge queue — merge this one next. Queue order is *intent*: never set by the reconciler, only cleared by it — and never read by it, so where a repository's own sweep caller passes either merge toggle (`auto_merge` or `auto_merge_release`, both `off` by default and set by the consumer, not ceremony), the order this label expresses is not honoured: two confirmed PRs merge in whatever order the sweep reaches them, and a real conflict then disqualifies the loser with `blocker:conflict` on the next pass |

`operator` is the human axis's third member: `needs-ruling` says a human owes
a decision, `operator` says an operator owes the work, and
`state:needs-human` says a human can merge a PR now. It composes with every
issue queue label, and the one-of-four queue invariant ignores it. An
operator-owned issue normally reads `ready` + `operator`: the work is
triaged, spec-complete and unblocked, while the second label names its owner.
The body's evidence surface, command or observation, and wake condition keep
that availability actionable (#491).

`needs-ruling` marks where the human's turn is when the pending thing is a
*decision*, not a merge ([#50 D1–D14](https://github.com/heavy-duty/ceremony/issues/50)).
It applies to any human-owned decision — org policy, published artifacts,
secrets, prod, or any choice whose cost lands outside the work. A panel
deadlock is one instance, not the definition (D11). It is not
`state:needs-human`: that label means exactly "this PR could be merged right
now", and the retired `state:needs-rebase` is the family's proof that a
label meaning two things lies about both. It is not a `blocker:*` either:
every blocker names work the *builder* owes, a ruling is owed by the human —
and the flag must live on issues too, where blockers do not exist. On issues
it coexists with the queue labels (the one-of-three invariant above ignores
it); its color is the light shade of `state:needs-human`'s, so the human
axis reads as one family. It is a state, not a signal: set only with the
[canonical escalation contract](BUILDER.md#the-ruling-ask) (D12). A bare
flag is noise. The comment carries exhaustive, mutually exclusive options
(at most three), a mandatory recommendation, what stops and what continues,
and either a default affirmatively known to be reversible inside the PR or
`none — hard block`. Unsure is a block; published artifacts, secrets, prod,
and org policy are hard blocks by construction (D13).

The ruling ladder runs from the current episode's `needs-ruling` **`labeled`
event** (D13–D14):

- **0–12h:** a clear, reversible decision may proceed when its stated default
  expires, saying out loud that it did; anything with reasonable doubt waits
  as a hard block.
- **at 12h:** the setter re-reads the default against what has landed and asks
  whether it still holds and whether doubt remains. A stale default does not
  fire; new doubt makes it a hard block.
- **at 24h:** the builder proceeds regardless, **as a PR**, stating the option
  chosen and the doubt that remains. Nothing merges by this; the human still
  gates the merge.
- **past 24h:** triage picks the option, records it as a decision, and remains
  accountable. The operator may overturn it at merge.

A re-flag starts a new ladder. The rungs apply whatever `Default:` says,
including a hard block. Active discussion still climbs the ladder; by
contrast, the separate 7-day nudge resets on real activity. The machine
observes the rungs but never sets, clears, or decides `needs-ruling`.

The flag stays up until agreement is *reached* — a human reply alone does not
clear it — and its setter closes it out: records the ruling as a decision in
one comment, removes the label, and returns the item to its flow in that same
comment, never as a side effect. If the human disagrees that agreement was
reached, the label goes back on. The reconciler refuses `state:needs-human`
while it stands (the PR falls to `state:addressing` — the ball on the PR is
the builder's, who carries the ruling in), and the staleness sweep skips it,
because waiting on a human is legitimately quiet. Quiet, but not unwatched
(#52, both surfaces): a flag set with no escalation comment from its setter
is called out by the sweep — comment-only, scoped to the labeled event, the
label never removed — and a ruling with no real activity for 7 days draws a
comment-only nudge addressed to the decider, linking the escalation. The
nudge carries no marker on purpose: the comment is itself activity, so it
resets its own window and never repeats within a quiet week. Label churn is
never activity, or the sweep would reset itself — and each surface's clock
reads what exists on it: on a pull request, comments, reviews and commits;
on an issue, comments alone. An assignment is the claim clock's fact, not
the ruling's — claiming a flagged issue does not answer it, and buys the
escalation no quiet (#284).

`offsite` is issue-only and records that a claimed issue's deliverable lives
in another repository, where a closing reference cannot make a local open PR
visible to the sweep (#68). The builder sets it in the same step that posts
the cross-repo draft link, then clears it at handoff in the same comment that
reports whether that PR merged or closed. The machine reads the flag and
never writes it. It stops only the claim-reclaim clock: missing assignees are
still flagged, queue-label conflicts and missing queue state are still
repaired, and epic-completion and PR-side stale behavior are unchanged. The
sweep tells the assignee once when every visible cross-referenced PR has
closed; it only tells, and never clears the flag or changes the claim.

`rerun-owed` is PR-only and says the head is red on a run **no agent may
restart**: a fork PR's checks live in the base repository, restarting them is a
base-repo write right, and no fleet identity holds one. It asserts that the
next move is one API call by a human and that the builder owes nothing until
that call is made. It is **not** a `blocker:*` — every blocker names work the
*builder* owes, which is that family's whole meaning — so while it stands the
reconciler does not assert `blocker:ci-red` at that head. The head is still
red: `state:needs-human` means a human could merge this now, and no red head
reads it (#423).

The **builder sets it**, in the same comment that records the check, its
failure class and the rerun that could not be started; a flag with no such
comment is noise, exactly as a bare `needs-ruling` is. That comment **opens by
naming the head it is evidence for** —

```
🔁 rerun owed at head <full-sha>
```

— because the head is the label's whole subject and the machine has to read it.
The marker is read only on comments by the pull request's **author**, which on
a fleet PR is the builder the previous sentence names: a reviewer quoting the
line back is quoting it, not raising a second flag.
**Two machines clear it and nobody's memory does.** `actions/ci-rerun` clears
it the moment it starts the attempt, and comments that attempt's URL: the
flag's whole subject is a rerun nobody could start, and one now has (#424). The
**reconciler** clears it on the first sweep where the head's checks are no
longer failing *or* the named head is no longer this PR's head — the backstop
for every other ending, including the refusal below. They do not fight: the
reconciler only ever removes this label and never writes it, so a start that
clears it early is a no-op to the next sweep. It is the one hand-set label
these machines remove, because its subject is a head and a head moves.

**A refusal leaves the flag standing, and that is the one case where it
deliberately outlives a service.** `actions/ci-rerun` measures four gates at
service time — the actor is a fleet identity in `.github/labels.conf`, the head
is still the one the evidence names, the run concluded `failure`, and it is on
its first attempt — and where one refuses it comments which gate and what a
human would have to do, and clears nothing. A service that dropped the state it
declined to act on would be the stall again, with a robot in it (#424).

The moved-head test is **identity, never recency**: it asks whether the
evidenced SHA is still the head, not whether the head commit is newer than the
flag. A commit's date is a field its author writes, so dating the two against
each other would discard a valid flag under clock skew and keep a stale one
after a reset onto an older red commit — and neither is a fact about which
commit the branch points at. A head nobody named, or one the sweep could not
read, leaves the question unjudged and the label standing: a label wrongly kept
asks a human to look at a PR that is fine, a label wrongly cleared tells a
builder to fix a tree that is not broken.

It is **not exempt from the 48-hour staleness clock**, and that is the
decision rather than an omission: the sweep's exemption is `blocked` and
`needs-ruling` only, so a head standing under this flag draws `stale` like any
other. The rule that decides it, written here so the next label does not have
to re-derive it: **a flag is exempt from the 48-hour clock when it carries an
escalation clock of its own.** `needs-ruling` has the ladder and the 7-day
nudge; `blocked` has the sweep that flips it the moment its named dependency
lands. Their silence is not merely legitimate, it is already watched.
`rerun-owed` has neither. `actions/ci-rerun` answers it within seconds of the
label event, so a flag still standing hours later is one that service
**refused** — and a refusal is exactly the state nothing else watches, since
the four gates are conditions no push of the builder's resolves. So `stale` at
48h is the only thing in this system that says a flag has stood unserviced too
long, and exempting it would buy silence on a stalled PR, which is the precise
defect this label exists to end. What the resulting `stale` **asks for is a
poke of whoever services the rerun** — the refusal comment names them and what
they owe — never a fix from the builder, who owes nothing at a head carrying
this flag. `stale` names no actor of its own; the actor is this row's to
supply, and so it does (#423).

It is a label although a park is otherwise declared by comment, because this
park's reader is a **queue** and a queue cannot read prose — the same reason
`needs-ruling` and `offsite` are labels, and its color puts it in the same
human axis they share.

The bound is narrow and stated in both directions. A red head is the builder's
by default: a deterministic failure is a fix round and carries
`blocker:ci-red` as it always has, and a rerun that *could* be started is one
the builder starts. The one rerun allowed per head is untouched — a second red
at the same head after a serviced rerun is no longer retryable-unknown, so the
flag does not go back up there — and a red head that follows a push is a new
question the builder owns until it is freshly evidenced.

`attention` is issue-only and says a demand is parked on an issue for its
assignee. Anyone who needs that assignee's hands — triage, the operator, or a
sibling agent — sets it. The assignee alone clears it, as the first act of
pickup together with a short comment; that removal is the acknowledgement
and re-arms the flag for the next demand. If the session dies before the ack,
the still-visible flag launches the next pickup instead. An unanswered flag
is auditable evidence on the board.

The flag is additive: it composes with `ready`, `claimed`, or `blocked` and
with `needs-ruling`, and never substitutes for queue state. It pauses no
clock. Unlike `offsite` and `needs-ruling`, which make silence legitimate,
unanswered `attention` is exactly the silence the 48-hour reclaim should
take. It is hand-set: the machine never sets `attention`, never assigns
anyone to receive one, and never decides that one has been answered — the
assignee's removal is the only ack. It writes the label in exactly one
place, the derived `claimed` → `post-merge` transition below, and nowhere
else; where it reads the flag it reads it to diagnose. The PR sweep comments
when `attention` is put on a pull request, and the issue sweep comments when
it is put on an issue with no assignee. Both diagnoses leave the label and
assignees alone; the machine never infers the claim issue, decides that the
demand was answered, or repairs either malformed shape.
An `attention` issue without an assignee is therefore a board bug, not a
demand; anyone may assign it or remove the flag. It never composes with
`post-merge`, whose released claim has no assignee to answer the demand. The
one machine-clear exception is the derived `claimed` → `post-merge`
transition: releasing the assignee clears a carried `attention` in the same
edit. A hand-created `post-merge` + `attention` composition is flagged, not
rewritten.

The three signals are mutually distinct: `attention` means an assignee owes
a move; `needs-ruling` means a human owes a decision under
[the escalation contract and ladder](BUILDER.md#the-ruling-ask); and a bare
`@`-mention is an FYI that demands nothing and remains perfectly fine. A
demand that is itself a human decision carries `needs-ruling`, never both.
This distinction records the
[#16 missed-ruling incident](https://github.com/heavy-duty/ceremony/issues/16#issuecomment-5061051198)
and why the rejected mention poll is not returning: ordinary thread traffic
re-arms mentions, but only the writer can declare that a move is owed (#83).

## Scope — which surface? (PRs and issues, any number)

All scopes share one calm color, `#C5DEF5` — scopes locate, states alert. The
set is per-repo: PRs get theirs from changed paths via the labels workflow's
scope job — an additive write only, so a label applied by hand or by an agent
while the machine runs always survives it (#130) — and issues get theirs from
triage. This file never enumerates a set — it is mirrored
byte-identically into every governed repo, and any list it carried would be
true in one repo and false in the rest (#104). The set for the repo you are
standing in lives in the two places that are true wherever you read them: its
`.github/labels.conf` (the definitions, one `name|color|description` row per
scope) and its own `CONTRIBUTING.md`, beside the other repo-specific facts.

## Issue types

`bug`, `enhancement`, `documentation` — issues only, set by triage. PRs carry
their type in the conventional title (`feat:`, `fix:`, `docs:`); a type label
on a PR would say the same thing twice and drift.

## Maintenance

The labels workflow (issue #10) recomputes PR state statelessly on subscribed
events plus a consumer-owned scheduled discovery sweep. Hourly is the
recommended default when no other engine drives board state; relax it only as
the transition classes with no other writer shrink. Manual dispatch both
bootstraps this taxonomy idempotently and runs the operator's on-demand
full-board reconcile. The sweep warns when the core taxonomy declares a label
the repository lacks. The same workflow reconciles issue-flow labels on issue
events and during the scheduled sweep. Default GitHub labels (`duplicate`,
`invalid`, `question`, `wontfix`, `help wanted`, `good first issue`) are
deleted at bootstrap — a `question` is a discussion, not an issue.
