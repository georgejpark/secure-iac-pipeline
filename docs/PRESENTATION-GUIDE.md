# Presentation Guide — 30 minutes

**Texas Mutual · Senior DevSecOps Engineer · Thursday 10 September 2026, 2:00 PM**

Format from Tony Trinh's email: 5 min introductions · **30 min presentation** ·
30 min Q&A · 25 min open discussion.

The brief: *"Teach us something you know a lot about. Tell us what it is, why it's important, and
what you know about it. We will ask questions while you teach."*

---

## Before you start

### The 30 minutes will not be 30 minutes

They said they will interrupt. **That is good** — an interrupted presentation is a conversation, and
a conversation is what gets you hired. Plan for 22 minutes of material in a 30-minute slot.

If you are at 20 minutes and only on Act 2, **skip Act 4 entirely** and go to the closing line. Never
rush the demo to protect the rollout slide; the demo is the thing they will remember.

### Setup checklist — do this at 1:45

- [ ] Terminal font at **18pt or larger**. Nobody can read 12pt over Teams.
- [ ] Light terminal theme, or at least high contrast. Dark themes wash out on projectors.
- [ ] `cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline`
- [ ] Run `make demo` **once** to warm it up, then `clear`
- [ ] Open the GitHub repo in a browser tab, on the Actions tab with a green run visible
- [ ] Open `docs/img/pipeline-flow.png` in a second tab
- [ ] Close Slack, Mail, and notifications. Do Not Disturb on.
- [ ] Have this file open on a **second screen or printed** — not the one you are sharing

### The one-sentence version

If you only get to say one thing:

> **"Deleting a secret from git doesn't remove it — and the fix that feels most thorough is the one
> that leaves you fully exposed. Here's how I found that out, and here's the pipeline I'd build to
> stop it."**

---

## ACT 1 — The finding (5 minutes)

**Do not share your screen yet.** Just talk. Let them look at you for the first five minutes.

### What to say

> "I want to teach you something I learned the hard way about secrets in source control.
>
> A few weeks ago I was doing inventory work on a platform — cataloguing repositories ahead of a
> migration. Nothing security-related. Routine.
>
> I ran a check for key-shaped files, mostly to fill in a documentation section. It came back with
> a hundred and twelve private keys committed to one repository."

Pause here. Let the number land.

> "A hundred and four distinct keys. Ninety-eight of the certificates were still valid.
> Twenty-one production hostnames.
>
> And the first commit in that repository — the one titled *'Starting up the repository'* — already
> had sixty-three of them in it. So this wasn't drift. It was there from the first day."

### Then the turn — this is the important part

> "Now, the easy read is that somebody was careless. That's not what happened, and if you stop there
> you fix the wrong problem.
>
> The setup scripts created Kubernetes TLS secrets by reading the key straight out of the checked-out
> repository. Something like:
>
> `kubectl create secret tls --key=./config/service/prod/certs/host.key.pem`
>
> For that command to work from a clone, the key has to be *in* the clone. So onboarding a new
> service **required** committing its private key. The exposure wasn't a mistake in the process.
> It *was* the process.
>
> Sixteen commits added key material over nine months. Every one passed code review. And the commit
> messages were things like *'Add TLS certs for reporting-ui, dev uat stage prod'* — which is a
> completely reasonable description of a completely reasonable task. Nothing in the log looked wrong."

### Land Act 1

> "So that's the first thing I want to leave you with: **when something is wrong for nine months
> across sixteen commits and nobody catches it, it's almost never carelessness. It's that the system
> made the wrong thing the easy thing.** And you don't fix that with training. You fix it by changing
> what's easy."

**Expected interruption:** *"What did you do about it?"*
Answer: *"Wrote it up with reproducible evidence and handed it to their security team — I'll come to
the remediation order in a minute, because the order turns out to matter more than the steps."*
Then continue.

---

## ACT 2 — Why the obvious fix doesn't work (8 minutes)

**Now share your screen.** Terminal only.

### Set it up first, in words

> "Here's the part that changed how I think about this.
>
> A different repository in the same estate had a `.env` file with seventy-four credentials in it.
> And the team *noticed*. They responded. The very next commit after the leak was titled
> **'Add utility for encrypting and decrypting .env files.'**
>
> They added encryption. They gitignored the file. They deleted it. By every code review standard,
> that repository now looks correct.
>
> Let me show you what that actually accomplished."

### Run the demo

```bash
./scripts/demo_secret_persistence.sh
```

It pauses between steps — press enter to advance. Roughly 90 seconds of runtime, but talk over it.

**Narrate as it goes:**

- **Setup:** *"Ordinary repo. A `.env` with a database URL, an AWS key, a JWT signing key."*
- **Fix 1, delete:** *"First instinct — remove the file. Working tree is clean."*
- **Fix 2, gitignore:** *"Second — make sure it can't come back."*
- **Fix 3, encrypt:** *"Third — add encryption. This is the real commit message from the real team."*
- **Then stop talking and let this land:**

```bash
$ git show <commit>:.env
DATABASE_URL=postgresql://claims_app:...@db.internal:5432/claims
AWS_SECRET_ACCESS_KEY=...
JWT_SIGNING_KEY=...
```

> "All three fixes applied. Every credential still there. One command, no special access.
>
> Deleting a file from git doesn't remove it. It unlinks it from the tip of the branch. The blob is
> still in the object store — and it travels with every clone, every fork, and every CI cache."

Then the clone step: *"Fresh clone. Working tree is clean. History still has it."*

### The lesson

> "So the fix that feels most thorough — delete, ignore, encrypt — produces a repository that scans
> clean and is still completely compromised. And it produces a commit log that says you handled it.
>
> Two things actually work, and the **order** matters more than the steps:
>
> **One: rotate the credential.** That takes minutes and it's the only step that reduces risk today.
>
> **Two: rewrite history** with `git filter-repo`, force-push, ask the platform team to garbage
> collect. That takes days, because you have to reach every fork, every open PR ref, and every clone
> that already exists on someone's laptop.
>
> Most people do those in the opposite order, because rewriting history feels like the *real* fix.
> But while you're coordinating a history rewrite, the credential is still live."

---

## ACT 3 — The pipeline (12 minutes)

> "So — if that's the failure mode, what stops it? I built the pipeline I'd actually want. Let me
> show you what it does, and more importantly the judgment calls in it, because the tools are the
> easy part."

**Show `docs/img/pipeline-flow.png`.** Walk the four gates in about a minute. Then go back to the
terminal.

### 3a. Prove it blocks

```bash
make scan-insecure
```

```
dev      exit=1  blocking=10
stage    exit=1  blocking=14
prod     exit=1  blocking=14
```

> "Same Terraform, scanned for three environments. Dev blocks ten things. Stage and prod block
> fourteen. The extra four are controls dev is allowed to skip — Multi-AZ, deletion protection.
>
> Because dev *should* be cheaper. Losing a dev database costs an afternoon. A pipeline that pretends
> every environment is identical is one people route around."

### 3b. Prove it passes

```bash
make scan
```

> "Corrected configuration. Zero blocking across all three. Sixty-three checks passing."

### 3c. The point that matters most

> "Here's the number I want to talk about, though. Checkov reports **twenty-four findings against a
> hundred and ten lines of Terraform**.
>
> That ratio is the actual engineering problem. A tool that gives you twenty-four findings on a small
> file gets muted inside a week — and once a team learns to ignore the tool, they ignore number
> twenty as well as the other twenty-three.
>
> So ten of them block. Four more block only when you promote to stage or prod. Five are advisory —
> real, but they're cost and retention *decisions*, not vulnerabilities.
>
> And one I deliberately un-blocked."

Show it:

```python
"CKV_AWS_23": "security group rule has no description — hygiene, not a vulnerability",
```

> "A security group rule with no description. It's untidy. It is not unsafe. If I block someone's
> merge over a missing description, I've taught them the security pipeline is an obstacle — and I've
> spent credibility I need for the one that says *this bucket is readable by the entire internet*.
>
> That's the whole job, really. Not running the scanner. Deciding which six of the twenty-four are
> worth stopping someone's afternoon over."

### 3d. Where the AI goes — and where it doesn't

> "There's an AI component, and I want to be precise about where it sits, because I think most
> people put it in the wrong place.
>
> The model does **not** decide pass/fail. Detection is Checkov, which is deterministic. The blocking
> list is a hardcoded dictionary in version control that humans review. The model takes findings that
> have already been classified and writes the explanation — what to change, in what order, and which
> ones look like false positives.
>
> And if the API is down, or rate-limited, or the key's missing, it falls back to deterministic rules
> and the gate still works. It just explains itself less well."

Demonstrate it:

```bash
unset ANTHROPIC_API_KEY && make scan
```

> "No API key. Same gate, same exit code, same blocking list.
>
> Because if you let a language model decide whether a merge is safe, you've built a system where an
> API outage is a security bypass. That's not a tradeoff I'd make."

### 3d-bis. The story that proves the whole point (use this one)

This is the strongest thing you have. It happened while building this, it is in the public Actions
log, and it demonstrates the thesis better than anything you could design.

> "I want to show you one more thing, because it happened to me while I was building this and it
> makes the point better than anything I planned.
>
> The very first time I pushed this repository, CI failed. And when I read the log, here is what the
> secret scanner said —"

Show these two lines. Read them **slowly**, and read them out loud:

```
WRN  scanned ~0 bytes (0)
WRN  no leaks found in partial scan
```

> "It scanned zero bytes. And it reported no leaks found.
>
> The action I was using only scans the range of commits you just pushed. On a first push, that range
> is 'the commit before the first commit' — which doesn't exist. Git threw an error, the scan covered
> nothing, and the tool still printed a pass.
>
> Now — I got lucky. It happened to exit non-zero, so I noticed. If that range had resolved to
> something valid but incomplete — a force-push, a squashed branch, a shallow clone — it would have
> said 'no leaks found' having looked at almost nothing, and I'd never have checked again.
>
> **That's worse than having no scanner at all, because it manufactures confidence.**
>
> So I threw the action away and pinned the binary, scanning full history every run. It's a bit
> slower. It looks at everything.
>
> And the rule I'd take from it: **check that your security control actually inspected something.** A
> green check mark is not a result. A green check mark next to a byte count is a result."

If they engage with this, let the conversation go there — this is the most senior thing in your talk,
and it is the thing a security-minded panellist will most want to discuss.

### 3e. No stored credentials

> "Last piece. There's no AWS access key anywhere in this repo or in GitHub secrets.
>
> It's OIDC federation — GitHub mints a signed token, AWS trusts it for one specific repository and
> one specific environment, and the credentials expire in an hour. Nothing static to steal, nothing
> to rotate.
>
> The whole thing rests on one condition block, and there's a classic mistake here — people write it
> as `repo:my-org/*`, which grants every repository in the org, including one an attacker can create.
> It has to name the repository, and for production it should name the environment too."

---

## ACT 4 — Rollout (5 minutes, cut this first if short on time)

> "If I were rolling this out here, I'd do it in this order — which is about credibility, not tooling.
>
> **Week one: measure, don't block.** Report-only across every repo. You can't negotiate a blocking
> list without knowing the real number.
>
> **Week two: secrets only — and rotate what you find.** Expect real findings in history. Rotate
> first, rewrite second.
>
> **Weeks three and four: agree the blocking list with security.** Ten policies, each with a written
> justification. Everything else advisory.
>
> **Week five: pre-commit hooks.** Only once people trust the list is short and fair. Do this first
> and you get workarounds instead of adoption.
>
> Every step there is cheap. The expensive thing is the credibility of the blocking list — and you
> spend that the first time you block someone's merge for a missing description."

---

## Closing line

> "So: three things.
>
> **One — deleting a secret from git doesn't remove it,** and the fix that feels thorough is the one
> that leaves you exposed while looking handled.
>
> **Two — when something goes wrong for nine months and nobody catches it, the system made the wrong
> thing easy.** Fix what's easy, not the people.
>
> **Three — the hard part of security tooling isn't running the scanner. It's deciding what's worth
> blocking**, and being able to defend that list to both an engineer and an auditor.
>
> Happy to go anywhere you want with it."

---

## Anticipated questions

Short answers. Do not over-explain — they have 30 minutes of Q&A and will follow up.

**"How long did this take to build?"**
> "About a day for the pipeline. The judgment about what to block is the part that came from having
> found the real thing."

**"What if the AI gives bad advice?"**
> "It can't change the outcome — it only writes the explanation. The gate is a hardcoded list. Worst
> case you get a poorly worded comment on a correctly blocked PR."

**"Why Checkov over tfsec / Terrascan / Snyk?"**
> "Checkov has the broadest Terraform policy coverage and clean SARIF output for the GitHub Security
> tab. I'd happily run tfsec alongside it — they catch slightly different things. The architecture
> doesn't depend on the choice; it's a swap of one job."

**"How do you handle false positives at scale?"**
> "Suppress in code, next to the resource, with the reason written down. Never in a central ignore
> file — that's where suppressions go to become invisible. And review the advisory tier quarterly:
> anything that sits there forever is either noise to suppress or work to schedule."

**"What about existing repos with secrets already in history?"**
> "Rotate first — that's the only step that reduces risk today. Then `git filter-repo`, force-push,
> ask the platform team to garbage collect. And be honest that forks and existing clones still have
> it, which is exactly why rotation comes first."

**"Has anything actually gone wrong with it?"**  — hope for this one
> "Yes, on the first push. The secret scanner reported 'no leaks found' after scanning zero bytes."
> Then tell the story in 3d-bis. It is the best answer you have to any question in this interview.

**"Have you used this in production?"**
> Be straight: *"This specific repo is a reference implementation I built to demonstrate the pattern
> cleanly. The problem it solves is one I found in production, and the remediation order comes from
> working through it for real. I'd want to tune the blocking list with your security team before
> turning it on anywhere."*

**"What would you do in your first 90 days here?"**
> "Mostly the rollout in Act 4 — but I'd start by asking what's already in place and what's already
> been tried, because a scanner that got muted last year tells you more about the constraints than
> any greenfield plan I could write in advance."

---

## If something goes wrong

| Problem | What to do |
|---|---|
| Demo script errors | `make scan-insecure` instead — it's a single command and makes the same point |
| No network | Everything runs offline. The AI fallback is the default path. Say so — it's a feature |
| Screen share fails | The flowchart PNG and this narrative stand alone. Talk through Act 1 and 2 with no visuals |
| Running long | Cut Act 4. Never cut the `git show` moment in Act 2 |
| Asked something you don't know | *"I don't know — I'd check X."* A senior engineer who says that is more credible than one who improvises. Do not bluff to a panel that will have a security specialist in it |

---

## What not to do

- **Don't name the previous employer or any real hostname.** "A platform I worked on" is enough, and
  discretion about a former employer's security posture reads as professionalism.
- **Don't oversell the AI.** The panel likely includes someone sceptical of LLMs in a security path.
  Your position — deterministic detection, AI only for explanation — is the *credible* one. Lead with
  the limitation and you'll win that person over.
- **Don't read the slides.** There are no slides. That's deliberate: a terminal and a diagram beat
  fifteen bullet points.
- **Don't apologise for the demo being small.** It's a reference implementation and it's honest.
