# Master Script — the full 90 minutes

**Texas Mutual · Senior DevSecOps Engineer · Thursday 10 September 2026, 2:00 PM**

Read this top to bottom. It runs in the order the interview runs.

| Marker | Meaning |
|---|---|
| **[SAY]** | Words you can say more or less as written |
| **[SHOW]** | Put something on screen |
| **[RUN]** | Type this command |
| **[PAUSE]** | Stop talking. Let it land. |
| **[EXPECT]** | What you should see — so you know it worked |

**Timing:** 5 min intro · 30 min presentation · 30 min Q&A · 25 min open discussion.

---

# PART 0 — Setup, at 1:45 PM

- [ ] Terminal font **18pt or larger**, high-contrast theme
- [ ] `cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline`
- [ ] Run `make demo` once to warm it, then `clear`
- [ ] Check runners: `gh api repos/georgejpark/secure-iac-pipeline/actions/runners --jq '.runners[].status'` → three × `online`
- [ ] Browser tab 1: the repo's **Actions** tab, green run visible
- [ ] Browser tab 2: `docs/img/pipeline-flow.png`
- [ ] Browser tab 3: `docs/img/system-architecture.png`
- [ ] Do Not Disturb on. Slack and Mail closed.
- [ ] **This document open on a second screen or printed** — never on the screen you share

**If a runner is offline:** do not debug it live. Edit `runs-on:` to `ubuntu-latest`, push, and mention
it as a one-line change. That is a better answer than a working runner.

---

# PART 1 — Introductions (0:00 – 0:05)

Keep this to **90 seconds**. They have your resume. The presentation is the real introduction.

### [SAY]

> "Thanks for the time. Quick version of me: I'm an Ops and Platform engineer — I've spent most of my
> career on the infrastructure side, Kubernetes, Terraform, CI/CD, observability, across both AWS and
> GCP.
>
> Most of my recent work has been platform reliability and security: cluster operations, incident
> response, deployment pipelines, and the kind of infrastructure documentation that lets someone
> other than me operate the thing at 3am.
>
> What I want to teach you today comes out of something I found by accident a few weeks ago. It
> changed how I think about secrets in source control, and I think it's genuinely useful whether or
> not you ever run the pipeline I built. Happy to jump straight in."

### Two guardrails

- **On naming your employer:** fine to say where you work if asked. **Do not** connect your employer to
  the specific vulnerability, and never say a real hostname. "A platform I worked on" carries the
  story completely, and the discretion reads as professionalism.
- **Do not** oversell in the intro. The demo does the work.

---

# PART 2 — The presentation (0:05 – 0:35)

Thirty minutes, but **plan for 22 minutes of material.** They told you they will interrupt. Every
interruption is a conversation, and a conversation is what gets you hired.

**If you are at 20 minutes and only on Step 12, skip Steps 20–22 and go straight to Step 23.**

---

## STEP 1 — Open with the thesis (1 min)

**Do not share your screen yet.** Let them look at you.

### [SAY]

> "I want to teach you something about secrets in source control — specifically, why the fix that
> feels most thorough is the one that leaves you completely exposed.
>
> I'll show you what I found, why it happened, why the obvious remediation doesn't work, and then a
> pipeline that actually prevents it. I'll demo all of it live."

---

## STEP 2 — The finding (2 min)

### [SAY]

> "A few weeks ago I was doing inventory work on a platform — cataloguing repositories ahead of a
> migration. Nothing security-related. Completely routine.
>
> I ran a check for key-shaped files, mostly to fill in a documentation section. It came back with
> **a hundred and twelve private keys** committed to one repository."

### [PAUSE] — let the number land.

> "A hundred and four distinct keys. Ninety-eight certificates still valid. **Twenty-one production
> hostnames.**
>
> And the very first commit in that repository — the one literally titled *'Starting up the
> repository'* — already had sixty-three of them in it. So this wasn't drift over time. It was there
> from day one."

---

## STEP 3 — The turn: it wasn't carelessness (2 min)

This is the most important idea in the first half. Do not rush it.

### [SAY]

> "Now, the easy read is that somebody was careless. That's not what happened — and if you stop
> there, you fix the wrong problem.
>
> The setup scripts created Kubernetes TLS secrets by reading the private key straight out of the
> checked-out repository. Roughly:
>
> `kubectl create secret tls --cert=./config/svc/prod/host.pem --key=./config/svc/prod/host.key.pem`
>
> For that command to work from a clone, the key has to **be** in the clone. So onboarding a new
> service **required** committing its private key. The exposure wasn't a mistake in the process —
> it *was* the process.
>
> Sixteen commits added key material over nine months. Every one passed code review. And the messages
> were things like *'Add TLS certs for reporting-ui, dev uat stage prod'* — which is a perfectly
> reasonable description of a perfectly reasonable task. Nothing in the log looked wrong."

### [SAY] — land it

> "So the first thing I'd leave you with: **when something is wrong for nine months across sixteen
> commits and nobody catches it, it's almost never carelessness. It's that the system made the wrong
> thing the easy thing.** You don't fix that with training. You fix what's easy."

**Likely interruption:** *"What did you do about it?"*
> "Wrote it up with reproducible evidence and handed it to their security team. I'll come to the
> remediation order in a moment, because the order turns out to matter more than the steps."

---

## STEP 4 — Set up the demo, in words (1 min)

### [SHOW] Share your screen now. Terminal only.

### [SAY]

> "Here's the part that changed how I think about this.
>
> A different repository in the same estate had a `.env` file with **seventy-four credentials** in it.
> And the team *noticed*. They responded. The very next commit was titled
> **'Add utility for encrypting and decrypting .env files.'**
>
> They added encryption. They gitignored the file. They deleted it. By every code review standard,
> that repository now looks correct.
>
> Let me show you what that actually accomplished."

---

## STEP 5 — [RUN] The secret persistence demo (4 min)

```bash
./scripts/demo_secret_persistence.sh
```

Press enter to advance between steps. **Narrate while it runs:**

| Screen shows | [SAY] |
|---|---|
| Setup | "Ordinary repo. A `.env` with a database URL, an AWS key, a JWT signing key." |
| Fix 1 — delete | "First instinct: remove the file. Working tree is clean." |
| Fix 2 — gitignore | "Second: make sure it can't come back." |
| Fix 3 — encrypt | "Third: add encryption. This is the real commit message from the real team." |

### [PAUSE] — when `git show` runs, **stop talking entirely.**

### [EXPECT]

```
$ git show <commit>:.env
DATABASE_URL=postgresql://claims_app:...@db.internal:5432/claims
AWS_SECRET_ACCESS_KEY=...
JWT_SIGNING_KEY=...
```

### [SAY]

> "All three fixes applied. Every credential still there. One command, no special access.
>
> **Deleting a file from git doesn't remove it.** It unlinks it from the tip of the branch. The blob
> is still in the object store — and it travels with every clone, every fork, and every CI cache."

Then the clone step: *"Fresh clone. Working tree clean. History still has it."*

---

## STEP 6 — What actually works, and the order (2 min)

### [SAY]

> "So the fix that feels most thorough — delete, ignore, encrypt — gives you a repository that scans
> clean, is still completely compromised, and has a commit log saying you handled it.
>
> Two things actually work, and **the order matters more than the steps.**
>
> **One: rotate the credential.** Minutes. It's the only step that reduces risk today.
>
> **Two: rewrite history** with `git filter-repo`, force-push, have the platform team garbage
> collect. Days — because you have to reach every fork, every open PR ref, and every clone already
> sitting on someone's laptop.
>
> Most people do those in the opposite order, because rewriting history feels like the *real* fix.
> But while you're coordinating a history rewrite, that credential is still live."

---

## STEP 7 — Transition to the pipeline (30 sec)

### [SAY]

> "So if that's the failure mode — what stops it? I built the pipeline I'd actually want. Let me show
> you what it does, and more importantly the judgment calls in it, because the tools are the easy
> part."

---

## STEP 8 — [SHOW] The pipeline diagram (1.5 min)

**Browser tab 2: `pipeline-flow.png`.**

### [SAY]

> "Four gates, ordered by cost.
>
> **Gate zero** is a pre-commit hook. Cheapest of all — a secret caught here never even becomes a
> commit, so there's no rotation, no history rewrite, no incident.
>
> **Gate one** is secret scanning in CI, and it runs *first and alone*. A leaked credential is
> already an incident by the time CI sees it. A Terraform misconfiguration is still only a proposal.
> They don't deserve the same urgency.
>
> One detail on that gate — `fetch-depth: 0`. GitHub's default checkout fetches a single commit. So a
> secret that was committed and later deleted, which is *exactly* the case that matters, is invisible
> to the scan. That one default is the most common reason a secret scanning pipeline silently does
> nothing.
>
> **Gate two** is Checkov against the infrastructure code, across all three environments.
> **Gate three** explains the findings."

---

## STEP 9 — [RUN] Prove it blocks (2 min)

```bash
make scan-insecure
```

### [EXPECT]

```
dev      exit=1   blocking=10
stage    exit=1   blocking=14
prod     exit=1   blocking=14
```

### [SAY]

> "Same Terraform, scanned for three environments. Dev blocks ten things. Stage and prod block
> fourteen.
>
> The extra four are controls dev is allowed to skip — Multi-AZ, deletion protection. Because **dev
> should be cheaper.** Losing a dev database costs an afternoon; losing a production one costs a
> regulator conversation.
>
> A pipeline that pretends every environment is identical is a pipeline people route around."

---

## STEP 10 — [RUN] Prove it passes (1 min)

```bash
make scan
```

### [EXPECT] `0 blocking` for dev, stage and prod. 63 Checkov checks passing.

### [SAY]

> "Corrected configuration. Zero blocking across all three."

---

## STEP 11 — The number that matters most (3 min)

**This is the heart of the talk. Slow down here.**

### [SAY]

> "Here's the number I actually want to talk about. Checkov reports **twenty-four findings against a
> hundred and ten lines of Terraform.**
>
> That ratio is the real engineering problem. A tool that gives you twenty-four findings on a small
> file gets muted inside a week — and once a team learns to ignore the tool, they ignore number
> twenty along with the other twenty-three.
>
> So: **ten of them block.** Four more block only on promotion to stage or prod. Five are advisory —
> real, but they're cost and retention *decisions*, not vulnerabilities.
>
> And one I deliberately **un-blocked**."

### [SHOW] the line in `scripts/ai_triage.py`:

```python
"CKV_AWS_23": "security group rule has no description — hygiene, not a vulnerability",
```

### [SAY]

> "A security group rule with no description. It's untidy. It is not unsafe.
>
> If I block someone's merge over a missing description, I've taught them the security pipeline is an
> obstacle — and I've spent the credibility I need for the finding that says *this bucket is readable
> by the entire internet.*
>
> **That's the job, really. Not running the scanner — deciding which six of the twenty-four are worth
> stopping someone's afternoon over,** and being able to defend that list to an engineer and to an
> auditor."

---

## STEP 12 — Documented false positives (1 min)

### [SAY]

> "Related — three findings fire on the KMS key policy. Checkov is technically right: it grants
> `kms:*` on `*`. It's also practically wrong, because that's AWS's own documented default key policy,
> and removing it makes the key unrecoverable.
>
> So it's suppressed **in the code, with the reason written next to it** — not in a central ignore
> file where the next engineer will never find it. A suppression without a reason is
> indistinguishable from an oversight six months later."

---

## STEP 13 — Where the AI sits, and where it doesn't (3 min)

### [SAY]

> "There's an AI component, and I want to be precise about where it sits, because I think most people
> put it in the wrong place.
>
> The model does **not** decide pass/fail. Detection is Checkov, which is deterministic. The blocking
> list is a hardcoded dictionary in version control that humans review. The model takes findings
> that have *already* been classified and writes the explanation — what to change, in what order,
> which ones look like false positives for this context."

### [RUN]

```bash
unset ANTHROPIC_API_KEY && make scan
```

### [EXPECT] Same exit codes, same blocking counts.

### [SAY]

> "No API key. Same gate, same exit code, same blocking list — it just explains itself less well.
>
> Because if you let a language model decide whether a merge is safe, you've built a system where an
> **API outage is a security bypass.** That's not a trade I'd make."

---

## STEP 14 — [SHOW] Where it runs (3 min)

**Browser tab 3: `system-architecture.png`.** Give them a few seconds to read before you speak.

### [SAY]

> "This doesn't run on GitHub's runners. It runs on three self-hosted runners on a box I control —
> one per environment, each in its own unprivileged container, each on its own isolated network
> segment.
>
> And I want to explain **why three**, because it's the most interesting decision in the whole thing.
>
> With one shared runner, a pull request that touches **dev** executes arbitrary code on the same
> machine that later deploys **production**. So a malicious change — or honestly just a compromised
> dependency on a dev branch — can leave something behind that fires during the prod job, or read the
> credentials that job obtains.
>
> That's a **privilege escalation path from dev straight to prod.** It's the main reason GitHub
> themselves advise against sharing self-hosted runners across trust levels.
>
> Three runners removes it. The prod runner only ever executes prod jobs, and nothing on the dev
> segment can even route to it."

### [SHOW] the verification:

```
dev   -> prod   ICMP     BLOCKED
dev   -> prod   tcp/22   BLOCKED
stage -> prod   ICMP     BLOCKED
prod  -> dev    ICMP     BLOCKED
each  -> api.github.com  HTTP 200
```

### [SAY]

> "Isolated, but each still reaches GitHub — because isolation that also breaks your runner isn't
> isolation, it's an outage.
>
> And note the direction: the runners connect **outbound**. GitHub never connects in. No port
> forward, no exposed service, no inbound rule. That's what makes self-hosting CI acceptable without
> putting a listener on the internet."

### [SAY] — why this matters to **them**

> "For an insurer this isn't a cost decision. It's data residency and auditability — being able to
> answer 'where was this built, on whose hardware, who could reach that machine' with something more
> specific than 'a shared cloud runner somewhere'.
>
> And the gates are identical either way. Moving between hosted and self-hosted is a one-line change."

---

## STEP 15 — No stored credentials (2 min)

### [SAY]

> "Last technical piece: there is **no AWS access key** anywhere in this repository or in its GitHub
> secrets.
>
> It's OIDC federation. GitHub mints a short-lived signed token, AWS trusts it for one specific
> repository and one specific environment, and the credentials expire in an hour. Nothing static to
> steal, nothing to rotate on a schedule.
>
> The whole thing rests on one condition block — and there's a classic mistake here. People write it
> as `repo:my-org/*`, which grants **every repository in the organisation**, including one an
> attacker can create. It has to name the repository, and for production it should name the
> environment too."

---

## STEP 16 — The story that proves the point (3 min)

**Your strongest moment. Do not cut this.**

### [SAY]

> "One more thing, because it happened to me while building this and it makes the point better than
> anything I planned.
>
> The very first time I pushed this repository, CI failed. And when I read the log, here's what the
> secret scanner said —"

### [SHOW] these two lines. Read them **out loud, slowly.**

```
WRN  scanned ~0 bytes (0)
WRN  no leaks found in partial scan
```

### [SAY]

> "It scanned **zero bytes**. And it reported **no leaks found**.
>
> The action I was using only scans the range of commits you just pushed. On a first push, that range
> is 'the commit before the first commit' — which doesn't exist. Git threw an error, the scan covered
> nothing, and the tool still printed a pass.
>
> Now, I got lucky — it happened to exit non-zero, so I noticed. If that range had resolved to
> something *valid but incomplete* — a force-push, a squashed branch, a shallow clone — it would have
> said 'no leaks found' having looked at almost nothing, and I'd never have checked again.
>
> **That's worse than having no scanner at all, because it manufactures confidence.**
>
> So I threw the action away and pinned the binary, scanning full history every run. It's slightly
> slower. It looks at everything."

### [PAUSE]

> "And the rule I'd take from it: **check that your security control actually inspected something.**
> A green check mark is not a result. A green check mark next to a byte count is a result."

---

## STEP 17 — Benefits, briefly (2 min)

### [SAY]

> "To put it plainly, what this buys you:
>
> **It moves detection left.** A secret caught by the pre-commit hook costs nothing. The same secret
> caught after it's pushed costs a rotation, a history rewrite across every fork, and an incident
> report. Same finding, wildly different cost.
>
> **It makes the security decision explicit and reviewable.** The blocking list is ten policies in
> version control, each with a written justification. Anybody can read it, argue with it, or show it
> to an auditor.
>
> **It gives environments proportionate rigour.** Dev moves fast; prod doesn't. Same pipeline.
>
> **It removes standing cloud credentials.** Nothing static to steal, nothing to rotate.
>
> **And it degrades safely.** No API key, no problem. Runner down, one-line change. The gate never
> depends on something outside my control."

---

## STEP 18 — The honest trade-offs (2 min)

**Say this unprompted.** Volunteering the weaknesses is what makes the strengths believable.

### [SAY]

> "I should be honest about the costs, because there are real ones.
>
> **Self-hosted runners are machines you now own** — patching, disk, uptime. I'd want them ephemeral
> in production, rebuilt per job, so patching becomes rebuilding.
>
> **The blocking list is a judgment call, and mine isn't universal.** It's tuned for regulated data.
> It should be a conversation with your security team, not something I impose.
>
> **The pipeline adds about a minute per pull request.** That's real, and worth it, but it's not free.
>
> **And it only covers pre-deployment.** It says nothing about runtime, containers, dependencies, or
> drift after apply. Those are separate gates I'd add in the same pattern — I just didn't want to
> claim coverage I don't have."

---

## STEP 19 — Rollout, if you have time (2 min)

**Cut this first if running long.**

### [SAY]

> "If I were rolling this out here, the order would be about credibility, not tooling.
>
> **Week one: measure, don't block.** Report-only across every repo. You can't negotiate a blocking
> list without knowing the real number.
>
> **Week two: secrets only — and rotate what you find.** Expect real findings in history.
>
> **Weeks three and four: agree the blocking list with security.** Ten policies, each justified in
> writing. Everything else advisory.
>
> **Week five: pre-commit hooks** — only once people trust that the list is short and fair. Do this
> first and you get workarounds instead of adoption.
>
> Every step there is cheap. The expensive thing is the credibility of the blocking list, and you
> spend that the first time you block someone's merge for a missing description."

---

## STEP 20 — Close (1 min)

### [SAY]

> "So — three things.
>
> **One: deleting a secret from git doesn't remove it,** and the fix that feels thorough leaves you
> exposed while looking handled. Rotate first, rewrite second.
>
> **Two: when something goes wrong for nine months and nobody catches it, the system made the wrong
> thing easy.** Fix what's easy, not the people.
>
> **Three: the hard part of security tooling isn't running the scanner. It's deciding what's worth
> blocking** — and being able to defend that list to both an engineer and an auditor.
>
> Happy to go wherever you'd like with it."

---

# PART 3 — Q&A (0:35 – 1:05)

Short answers. They have thirty minutes and will follow up. **Do not over-explain.**

### On the solution

**"How long did this take to build?"**
> "About a day for the pipeline. The judgment about what to block came from having found the real
> thing."

**"What if the AI gives bad advice?"**
> "It can't change the outcome — it only writes the explanation. The gate is a hardcoded list. Worst
> case is a poorly worded comment on a correctly blocked PR."

**"Why Checkov over tfsec, Terrascan, Snyk?"**
> "Broadest Terraform policy coverage and clean SARIF output for the GitHub Security tab. I'd happily
> run tfsec alongside it — they catch slightly different things. The architecture doesn't depend on
> the choice; it's swapping one job."

**"How do you handle false positives at scale?"**
> "Suppress in code, next to the resource, with the reason written down. Never in a central ignore
> file — that's where suppressions go to become invisible. And review the advisory tier quarterly:
> anything sitting there forever is either noise to suppress or work to schedule."

**"What about repos that already have secrets in history?"**
> "Rotate first — the only step that reduces risk today. Then `git filter-repo`, force-push, ask the
> platform team to garbage collect. And be honest that forks and existing clones still have it, which
> is exactly why rotation comes first."

**"Has anything actually gone wrong with it?"** — *hope for this one*
> "Yes, on the first push. The scanner reported 'no leaks found' after scanning zero bytes." Then tell
> the Step 16 story. Best answer available to you.

### On the infrastructure

**"Why self-hosted runners instead of GitHub's?"**
> "Data residency and auditability for a regulated business. The gates are identical — it's a one-line
> `runs-on` change — so I'd start hosted and move only if compliance asked."

**"What if a runner gets compromised?"**
> "That's what the segmentation is for. A compromised dev runner has no route to stage or prod and no
> standing cloud credentials — only a short-lived token scoped to dev. Blast radius is one
> environment. I'd rebuild the containers regularly; they're disposable by design."

**"Who patches those boxes?"**
> "In a lab, me. In production I'd want them ephemeral — rebuilt per job or autoscaled — so patching
> becomes rebuilding. Long-lived runners accumulating state is a real operational smell."

### On you

**"Have you used this in production?"** — *answer straight*
> "This specific repo is a reference implementation I built to show the pattern cleanly. The problem
> it solves is one I found in production, and the remediation order comes from working through it for
> real. I'd want to tune the blocking list with your security team before turning it on anywhere."

**"What would you do in your first 90 days?"**
> "Mostly the rollout I described — but I'd start by asking what's already in place and what's
> already been tried. A scanner that got muted last year tells you more about the real constraints
> than any greenfield plan I could write in advance."

**"What's your biggest weakness / a mistake you've made?"**
> Use a real one. The `ping -c 1 -W 1` mistake is good: *"I concluded a set of network gateways were
> unreachable based on a single probe with a one-second timeout against a cold ARP cache. They were
> fine. I'd asserted it as fact in my notes before testing the test. Now I treat a negative result
> from an untested method as unverified, not as evidence."*

### If you don't know

> "I don't know — I'd check X."

A senior engineer who says that is more credible than one who improvises. **Do not bluff.** There is
likely a security specialist on this panel.

---

# PART 4 — Open discussion (1:05 – 1:30)

**They explicitly said you can ask anything.** Coming with real questions is itself an assessment, and
most candidates waste this. Pick **five or six**, not all of them.

### About the work

1. "What does the deployment path look like today — who can push to production, and what has to
   happen between a merge and it being live?"
2. "Is there anything like this in place already? And if something was tried and didn't stick, I'd
   genuinely rather know what went wrong with it."
3. "How much of the infrastructure is code today, and how much is click-ops that nobody's had time to
   codify?"
4. "Where does secrets management sit right now — Vault, cloud secret manager, something else?"
5. "AWS, Azure, on-prem, or a mix? And is that settled or still moving?"

### About the team

6. "Who would I be working most closely with day to day — is security a separate team, or embedded?"
7. "How does the team decide what to block versus what to just report? Is there a forum for that?"
8. "What does on-call look like for this role?"

### About the role itself

9. "What's the thing you'd most want fixed in the first six months?"
10. "Is this role backfilling someone, or is it new? Either is fine — it just tells me what to expect."
11. "For an insurer there's a compliance dimension to all of this. How much of the work is driven by
    audit requirements versus engineering judgment?"

### The one worth ending on

12. **"What would make you look back in a year and say this hire went really well?"**

That question makes them describe success concretely, and it gives you the closing line.

### Closing

> "This was genuinely enjoyable — thanks for making the format something I could actually build for.
> Is there anything you'd want from me as a next step?"

---

# APPENDIX A — Benefits, in one page

| Benefit | Why it matters | Evidence |
|---|---|---|
| **Detection moves left** | A secret caught pre-commit costs nothing. Caught after push it costs rotation + history rewrite across every fork + an incident. | Four gates, ordered by cost |
| **The security decision is explicit** | Ten blocking policies in version control, each justified. Reviewable by an engineer or an auditor. | `BLOCKING_POLICIES` in `ai_triage.py` |
| **Noise is managed, not ignored** | 24 findings → 10 blocking, 5 advisory, 9 reported. One deliberately un-blocked with a defence. | `make scan-insecure` |
| **Environments get proportionate rigour** | Dev moves fast, prod doesn't, one pipeline. | 10 blocking in dev vs 14 in prod |
| **No standing cloud credentials** | Nothing static to steal, nothing to rotate. | OIDC trust policy |
| **Blast radius is contained** | A compromised dev build cannot reach the prod runner. | Isolation verified both directions |
| **Nothing inbound is exposed** | Runners poll outbound; no port forward exists. | Architecture diagram |
| **It degrades safely** | No API key → same gate. Runner down → one-line change. | `unset ANTHROPIC_API_KEY && make scan` |
| **Findings land where people look** | SARIF into the GitHub Security tab, plus a plain-English PR comment. | Security tab |

---

# APPENDIX B — Pros and cons, honestly

Volunteer the right-hand column. It is what makes the left-hand column believable.

### The pipeline

| Pro | Con |
|---|---|
| Catches secrets and IaC flaws before deployment | Pre-deployment only — nothing about runtime, drift, containers or dependencies |
| Short, defensible blocking list keeps the tool credible | The list is a judgment call; mine is tuned for regulated data and needs negotiating locally |
| Deterministic gate, so results are reproducible | Deterministic also means it cannot catch novel or context-specific problems a human would |
| Adds ~1 minute per PR | It is still a minute, on every PR, forever |
| False positives suppressed in code with reasons | Requires discipline; a lazy team will still drift to a central ignore file |

### The AI triage layer

| Pro | Con |
|---|---|
| Turns 24 raw findings into a ranked, plain-English comment | Costs money per run, and adds a dependency |
| Cannot affect pass/fail, so an outage is not a bypass | Which also caps how much value it can add |
| Full offline fallback | The fallback is plainer; people may come to rely on the nicer output |
| Explains findings to non-specialists | Output must still be reviewed — it can be confidently wrong in wording |

### Self-hosted runners

| Pro | Con |
|---|---|
| Data residency and auditability — you know where code was built | You now own machines: patching, disk, uptime |
| Environment isolation removes the dev→prod escalation path | Three runners is three times the maintenance of one |
| No inbound exposure; outbound polling only | A runner outage blocks CI until you fail back to hosted |
| Cheap on hardware you already have | Not free — it is operational load, which is the expensive kind |
| Pinned toolchain baked into the image | Pinned versions rot; someone must own upgrading them |

### The honest summary line

> "It's a real improvement with real costs. The biggest risk isn't technical — it's that the blocking
> list loses credibility and people start routing around it. That's why the list is short, why it's
> justified in writing, and why dev is allowed to be cheaper than prod."

---

# APPENDIX C — If something breaks

| Problem | Do this |
|---|---|
| Demo script errors | `make scan-insecure` instead — one command, same point |
| No network | Everything runs offline; the AI fallback is the default path. Say so — it's a feature |
| A runner is offline | Do not debug live. `runs-on: ubuntu-latest`, push, mention it's a one-line change |
| Screen share fails | The two diagrams and this narrative stand alone. Talk through Steps 1–6 with no visuals |
| Running long | Cut Steps 19 and 12. **Never** cut Step 5 (`git show`) or Step 16 (zero bytes) |
| Asked something you don't know | "I don't know — I'd check X." Do not bluff |

---

# APPENDIX D — The whole talk in eight lines

If you forget everything else:

1. 112 private keys, 21 production hostnames, nine months, first commit.
2. Not carelessness — the setup scripts *required* committing keys.
3. The team added encryption. `git show` still returns the plaintext.
4. Rotate first, rewrite second. Order matters more than steps.
5. 24 findings, 10 block. One deliberately un-blocked, and I'll defend that.
6. The AI explains; it never decides. No key, same gate.
7. Three runners because one is a dev→prod escalation path.
8. My own scanner reported "no leaks found" after scanning zero bytes.
