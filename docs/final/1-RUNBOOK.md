<!-- title -->
# The Password You Already Deleted

### Secrets in git, and a pipeline that stops them reaching production

George Park  ·  Senior DevSecOps  ·  Texas Mutual  ·  10 September 2026

**Document 1 of 7 — PRIVATE. My runbook. Not shared with the panel.**

---

# MASTER RUNBOOK

**Private. This document is for me. It is not shared with the panel.**

Ordered in the sequence I actually use it, top to bottom. Parts A to D are live.
Part E is reference I do not read aloud.

Last verified against the live host: **10 September 2026, 11:45 CDT**.

| Part | When | What |
|---|---|---|
| **A** | T-15 min | Set up the windows, run the five pre-flight checks |
| **B** | 0-6 min | What I say: the introduction and the goal |
| **C** | 6-34 min | The demo: running order, panic card, STEP 1 to STEP 9 |
| **D** | 34-36 min | The close, and the questions I expect |
| **E** | not live | Reference: architecture, per-environment testing, teardown |

**Diagrams**, draw.io source in `docs/diagrams/`:
`01-system-architecture.drawio` - `02-pipeline-workflow.drawio` - `03-destroy-flow.drawio`

---

# PART A  -  BEFORE I START          (T-15 min)

Do this before anyone joins. Nothing here is spoken.

## Set up at 1:45

Three windows, left open.

**Window 1 - iTerm2, my Mac**

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline
clear
```

**Window 2 - iTerm2, the server**

```bash
ssh root@192.168.1.132
clear
```

**Window 3 - Browser** at `https://github.com/georgejpark/secure-iac-pipeline`, three tabs:
**Code**, **Pull requests** then **PR #4**, and **Actions**.

## Pre-flight - run all five

**1. The state database is listening on its network address.**

```bash
pct exec 204 -- ss -tlnp | grep 5432
```

Must show **`10.40.10.10:5432`**, not only `127.0.0.1`. If it shows loopback alone:

```bash
pct exec 204 -- systemctl restart postgresql@17-main
```

> Postgres only binds `10.40.10.10` if that interface is already up when it starts. After a tf-state
> reboot it can come back on loopback alone, and then **every `terraform init` in the demo fails**
> with `connection refused`. This is the single most likely thing to kill the demo. Check it first.

**2. The platform containers are up.**

```bash
pct list
```

Four containers, all `running`: 201, 202, 203, 204. **No 3xx containers. That is correct today.**

**3. All five application VMIDs are free.**

```bash
for v in 301 311 321 322 323; do pct list | grep -q "^$v " && echo "$v IN USE" || echo "$v free"; done
```

All five must say **free**. The demo builds every one of them.

**4. Terraform state is empty in all three schemas.**

```bash
for c in 201:dev 202:stage 203:prod; do id=${c%%:*}; env=${c##*:}
  printf "%-6s " "$env"
  pct exec $id -- su - runner -c "cd /home/runner/actions-runner/_work/secure-iac-pipeline/secure-iac-pipeline/terraform/deploy/$env && terraform state list 2>/dev/null | wc -l"
done
```

Three zeros.

**5. The deploy script and its source files are staged.**

```bash
ls -l /root/install-app.sh /opt/app-source/
```

The script plus four files: `app.py`, `requirements.txt`, `VERSION`, `inspection-service.service`.

## Last things

- Terminal font at 18pt or bigger
- Do Not Disturb on, Slack and Mail closed
- This document on a second screen, not the one I share

---


---

# PART B  -  WHAT I SAY               (0-6 min)

Sections 1 and 2 spoken. Nothing shared on screen yet.


They asked for a short introduction before the presentation. About ninety seconds, which leaves room
for them to ask something. Do not read it word for word, but do not improvise it either.

## What I say

Hi, I'm George Park.

I work in operations and platform engineering. Day to day that means Kubernetes, Terraform, CI/CD
pipelines, and monitoring, across AWS and GCP.

Most of my career has been the same job in different shapes: keep the platform running, and make the
safe path the easy path for the engineers using it. If doing the right thing is slower than doing the
wrong thing, people will do the wrong thing. That is not a discipline problem, it is a design problem.

Most recently I have been the platform lead on a retail analytics product. Backend services, a data
warehouse behind them, an LLM service alongside. I owned the clusters, the deployment path, the
observability, and the incident response.

Two things from that job are why I am sitting here.

The first is that I spent a lot of time on the boundary between security and delivery. Access
control, secret handling, what gets to block a deployment and what does not. That boundary is where
most of the friction lives, and it is the part I actually enjoy.

The second is an outage. Our ingress controller was running a single replica. Nobody had decided
that; it was just the default nobody revisited. When the node under it stalled, the whole environment
went dark. Everything was green right up until it was not.

That taught me the thing I keep coming back to. The dangerous problems are rarely the ones somebody
did wrong. They are the ones the system quietly made easy to get wrong, and nobody had a reason to
look.

Today I want to show you one of those. It is about secrets in git, and I found it by accident during
routine housekeeping.

I have built a working pipeline to demonstrate it. It runs on hardware in my house, it is running
right now, and I will build production in front of you from nothing.

## If they ask "why Texas Mutual" or "why this role"

> "It is a senior DevSecOps role at a company where security is not a side quest. Workers comp means
> regulated data, real audit requirements, and a real cost when it goes wrong. I would rather build
> guardrails somewhere the guardrails matter."

## If they ask what I am like to work with

> "I write things down. Runbooks, incident notes, decision records. Partly so the next person does not
> have to reconstruct it, and partly because writing it down is how I find out whether I actually
> understand it."

---


## The problem, in one line

Companies leak passwords into their code, they notice, they delete the file, and the password is
still there.

The repository looks clean afterwards. The commit history says somebody handled it. Nobody handled
it. **That is what I want them to walk away knowing.**

## What I am trying to achieve

**1. Show the problem is real.** Not a slide about it. A password surviving every fix people
normally apply.

**2. Show a pipeline that stops it.** Running right now, on hardware in my house. Not a diagram.

**3. Show the judgment, not just the tools.** Anyone can install a scanner. The hard part is deciding
what should stop somebody's work, and being able to defend that list to an engineer and to an
auditor.

**4. Build infrastructure in front of them.** I change one number, push it, and they watch it go
through the checks, wait for an approval, and build real servers.

## In scope

- Secret scanning across the whole git history
- Infrastructure code scanning, with different rules per environment
- A pull request that cannot merge without a review and passing checks
- Development deploying automatically, staging and production waiting for a person
- Terraform building real servers, a separate deploy step installing the application
- Each environment isolated from the others, three independent ways

## Out of scope, and I say so if asked

- **No Docker, no Kubernetes.** These are Linux containers built by Terraform. I will explain why,
  and what would change if you ran Kubernetes.
- **No cloud account.** This runs on a Proxmox server at home instead of AWS. The pipeline is
  identical; only the last command differs.
- **No runtime security.** This stops bad things before deployment. It does not watch what happens
  afterwards.
- **One person.** I am the only account on this repository, so I cannot approve my own work. In a
  real team that is a second engineer.

## The starting state today

**This matters and I should say it early.** There are **no application servers running at all**.
Every one was destroyed with Terraform before the demo started. The platform is up; the thing the
platform builds is gone.

| Running now | Built during the demo |
|---|---|
| 201 ci-dev, 202 ci-stage, 203 ci-prod, 204 tf-state | 301 app-dev-1 |
| the four bridges and the forward policy | 311 app-stage-1 |
| the Proxmox API tokens, the age keys | 321, 322, 323 app-prod-1, -2, -3 |

> "Right now there are zero application servers. By the end of this you will have watched the
> pipeline build five, and production will be three of them because the file says three."

---


---

# PART C  -  THE DEMO                 (6-34 min)

## How the next thirty minutes go

```
 4 min    STEP 1   the story, no screen
 2 min    STEP 2   the fix that fails
 6 min    STEP 3   prove a deleted password is still there
 3 min    STEP 4   show the checks blocking bad code
 4 min    STEP 5   show the pull request, blocked
 2 min    STEP 6   merge it
 6 min    STEP 7   watch it build dev, stage and prod
 5 min    STEP 8   install the app and show all five servers
 2 min    STEP 9   close
--------
34 min    leaves time for questions inside the 40
```

They said they will ask questions while I go. Good. Every interruption is a conversation.

---


---

## PANIC CARD  -  read this before STEP 1, keep it in view

## If something breaks live

**Read the error out loud.** A pipeline that stops a bad change in front of you is better than one
that quietly works.

**If I do not know:** say so.


## If I run out of time

Drop **Step 4**. Say instead: *"the checks block 10 things in development and 14 in production."*

Drop the **production approval** in Step 7. Approve staging only, and show dev and stage.


## Never drop

- Step 3, the `git show` moment
- Step 5, the blocked pull request
- Step 9, the three closing points

---


## STEP 1  -  Tell the story          (4 min)

**Nothing shared. Just talk.**

I was cataloguing repositories. Housekeeping. I searched for key files to fill in a document.

**112 private keys.** All committed. 21 production hostnames. The oldest nine months old.

The first commit in that repository was called *"Starting up the repository"*. It already had 63 keys
in it.

**Pause here.**

I expected carelessness. That is not what I found.

The deploy scripts read the key out of the folder you had just cloned. So for a deploy to work, the
key had to be in the repository. Adding a service meant committing its private key.

Nobody cut corners. They followed the process. **The process was the problem.**

Sixteen commits added keys over nine months. Every one passed code review.

> "When something is wrong for nine months and nobody catches it, it is almost never carelessness.
> The system made the wrong thing easy."

## STEP 2  -  The fix that fails      (2 min)

**Still nothing shared.**

A second repository. A `.env` file with 74 passwords in it.

**They caught it.** The very next commit was called *"Add utility for encrypting/decrypting .env
files"*. They deleted the file, added it to gitignore, wrote an encryption tool.

Afterwards the repository looked clean.

> "Let me show you what that achieved."

## STEP 3  -  Prove it                (6 min)

**Share the SERVER window.**

```bash
/root/demo-secret-persistence.sh
```

It stops after each step and waits. **Press enter to move on.**

Talk over the first four steps:

- **Setup** - "an ordinary repository, with a .env in it"
- **Fix 1** - "first instinct, delete the file"
- **Fix 2** - "then make sure it cannot come back"
- **Fix 3** - "then add encryption. This is the real commit message from the real team"

**When `git show` runs, stop talking.** Let them read the passwords on the screen.

> "Every password still there. One command. No special access."

> "Git keeps every version of every file. Deleting removes the pointer, not the file. And it travels
> with every clone."

The script then shows it surviving a fresh clone. Let that land too.

**Finish with the order:**

> "Two things work, and the order matters more than the steps. Change the password first, that takes
> minutes. Rewriting the history takes days, because you have to reach every fork and every laptop.
> Most people do it backwards."

## STEP 4  -  Show the checks working  (3 min)

**Switch to the MAC window.**

```bash
make scan-insecure
```

About 40 seconds. Expect:

```
dev      exit=1  blocking=10
stage    exit=1  blocking=14
prod     exit=1  blocking=14
```

> "This is deliberately bad Terraform. Same code, checked three times."

> "Development blocks 10 things. Staging and production block 14. The extra four are things
> development is allowed to skip. Losing a development box costs an afternoon."

**Then show it passing:**

```bash
make scan
```

```
No blocking findings.
```

**Then the number that matters:**

> "The scanner finds 24 problems in 110 lines of code. Nobody reads 24 findings, they turn the tool
> off. So 10 stop the merge, 5 are advice, 9 are noted. Choosing which 10 is the actual job."

## STEP 5  -  Show the pull request    (4 min)

**Switch to the BROWSER, PR #4.**

**1. The title.** "The change is one number. Production goes from two servers to three."

**2. Scroll to the bottom. The red box.**

```
Merging is blocked
Review required
```

**3. The green ticks above it.**

> "Every check passed. Secrets, and the infrastructure scan for all three environments. It is still
> blocked, because the checks are not the only gate."

**4. Scroll up to the comments.** Three, one per environment.

> "The pipeline wrote these. It sorts the findings and explains them in plain English, so the person
> reviewing does not have to read raw scanner output."

**5. Then say:**

> "I cannot approve this myself. GitHub refuses outright. In a real team a second engineer approves
> here. I am the only account on this repository, so I will merge with an admin override, and GitHub
> records that I did."

## STEP 6  -  Merge it                 (2 min)

**Switch to the SERVER window.**

```bash
cd /root/secure-iac-pipeline
gh pr merge 4 --squash --admin --delete-branch
```

> "Merging is what authorises a deployment. Nothing deploys before this."

## STEP 7  -  Watch it build           (6 min)

**Switch to the BROWSER, Actions tab. Refresh.**

A new run appears at the top. Click it.

**First 90 seconds:** the checks run again on main.

```
Secrets        running, then green
IaC (dev)      green
IaC (stage)    green
IaC (prod)     green
```

**Then the three deploy jobs appear:**

```
Deploy (dev)     runs on its own
Deploy (stage)   Waiting for review
Deploy (prod)    Waiting for review
```

> "Development went out by itself. Staging and production stopped."

**Approve staging.** A yellow bar appears: **Review pending deployments**. Click it, tick **stage**,
click **Approve and deploy**. About 30 seconds, then green.

**Then approve production the same way.**

> "Development goes out on its own. Staging and production each need a person to say yes. That is the
> whole promotion model."

**Because everything was torn down before we started, this run builds all five containers, not one.**
Dev builds 301, stage builds 311, prod builds 321, 322 and 323 together. Prod takes the longest.

> "Production is building three machines because the file now says three. It would have built two
> this morning."


### Walk the pipeline in detail  -  do this while the jobs run

The jobs take time. Do not stand there watching a spinner. **Click into them and narrate.** This is
where the automation gets explained, and it costs no extra minutes because it happens during the wait.

**1. The job graph, before clicking anything.**

Point at the shape: Secrets alone at the top, then three IaC jobs side by side, then three Deploy jobs
in a line.

> "Three jobs. Secrets runs first and alone, and nothing else starts until it passes. Then the
> infrastructure scan runs three times in parallel, once per environment. Then deploy, one at a time."

**2. Show that these are my machines, not GitHub's.**

Click the **Secrets** job. In the log header it names the runner it landed on.

> "That is a container in my house. GitHub scheduled the job; my hardware ran it. The runner connected
> outbound and pulled the work down. There is no inbound firewall rule and no public address."

**3. Inside the Secrets job - gitleaks.**

Expand **Scan the entire repository history**.

> "This is gitleaks reading every commit ever made, not just the current files. That is the
> `fetch-depth: 0` line in the workflow. Without it the scan sees one commit, and the password that
> was committed last week and deleted yesterday is invisible. That is the exact case I showed you in
> step 3."

Point at `--exit-code 1`.

> "That flag is what makes this a gate rather than a report."

**4. Inside an IaC job - Checkov and the triage.**

Go back and click **IaC (prod)**. Expand **Checkov**, then **AI triage**.

> "Checkov just found two dozen things. Notice the job did not fail. It runs with `--soft-fail` on
> purpose. Checkov reports; it does not decide."

> "The decision is the next step. That script reads Checkov's JSON and checks it against a list of
> ten policy IDs in development, fourteen in staging and production. The list is in the repository, so
> changing what blocks a merge is itself a reviewed change."

If they ask about the fourteen versus ten:

> "The extra four are things development is allowed to skip: deletion protection, Multi-AZ, log
> export, enhanced monitoring. Development is allowed to be cheaper, and the pipeline says so out
> loud instead of pretending every environment is equal."

**5. Show the isolation, using the runner names.**

Open **IaC (dev)** and **IaC (prod)** in turn and point at the two different runner names.

> "Same code, three copies, three different machines. The production job can only land on the
> production runner, because of one line: `runs-on: [self-hosted, matrix.environment]`. A pull request
> that touches development never executes on the machine that holds the production key."

**6. Inside a Deploy job - the part that builds something.**

Once **Deploy (dev)** is running, click it and walk the steps in order.

| Step to expand | What to say |
|---|---|
| Decrypt credentials (SOPS) | "It decrypted with a key that exists only on this runner. Notice the values are masked, even in a log only I can see." |
| Terraform init | "Connecting to its own database on the state machine. Its own schema, its own role." |
| Terraform plan | "One to add. This is the plan, saved to a file." |
| Policy check | "Checkov has no rules for Proxmox, so this checks the plan directly. Unprivileged, boot on, delete protection. Production has to pass all three." |
| Terraform apply | "It applies the saved plan file, not a fresh one. What was checked is what gets built, with no window in between." |

**7. The approval gate itself.**

When staging pauses, point at **Review pending deployments** before clicking it.

> "That is a GitHub Environment with a required reviewer. It is configured in repository settings, not
> in the workflow file, which means a pull request cannot change it."

**If they interrupt at any point, stop the walkthrough.** A question is worth more than the rest of
this list, and the jobs keep running while you talk.


## STEP 8  -  Install and show the servers   (5 min)

**Switch to the SERVER window.**

```bash
pct list
```

> "Five machines that did not exist ten minutes ago."

They are empty machines. Terraform built them; nothing has installed the application yet.
**Say that out loud before anyone asks:**

> "Terraform talks to the Proxmox API to build machines. It never logs into them. Installing the
> application is a separate stage, and I keep it separate on purpose, so rebuilding a server does not
> mean redeploying the application, and redeploying does not mean rebuilding."

**Then install, one environment at a time:**

```bash
/root/install-app.sh dev
/root/install-app.sh stage
/root/install-app.sh prod
```

Production takes about 60 seconds for three containers. Expect:

```
environment=prod  version=1.1.0  containers=3
  app-prod-1 (321)  installing 1.1.0 ...
    app-prod-1 serving {"version": "1.1.0"}
  app-prod-2 (322)  installing 1.1.0 ...
    app-prod-2 serving {"version": "1.1.0"}
  app-prod-3 (323)  installing 1.1.0 ...
    app-prod-3 serving {"version": "1.1.0"}
done
```

**Then run it a second time** and let them see the idempotency:

```bash
/root/install-app.sh prod
```

```
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
  app-prod-3 (323)  already serving 1.1.0  - skipped
```

> "It checks what each one is serving before it touches it. I can run this as many times as I like
> and it only acts where something is actually missing."

### What that script does

Seven steps, on any container not already serving:

1. **Creates a service account** called `rapta`. The application does not run as root.
2. **Installs Python and curl** if missing.
3. **Copies the release** into its own folder, `releases/1.1.0`. The old release stays on disk.
4. **Builds a virtual environment** inside that release folder, so two releases can need different
   packages without fighting.
5. **Moves one symlink**, `current` to `releases/1.1.0`. That single pointer move *is* the release.
6. **Installs the systemd unit**, which points at `current`, never at a version number. That is why a
   rollback needs no file edited. Move the symlink back and restart.
7. **Waits for the health check to pass** before reporting success. The application deliberately
   answers 503 for the first two seconds, so a check that fires immediately would report a false
   failure.

### Then ask the machines who they are

```bash
curl -s http://10.30.10.22:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-3",
  "version": "1.1.0"
}
```

**All five together:**

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21 10.30.10.22; do
  curl -s --max-time 5 http://$h:8080/ ; echo
done
```

> "Five machines. Each one knows which environment it is, because it reads it from its own hostname.
> Three in production, because the file now says three."

## STEP 9  -  Close                    (2 min)

**Stop sharing. Face them.**

**1.** Deleting a password from git does not remove it. Change the password first, clean up second.

**2.** When something is wrong for nine months and nobody notices, the system made it easy to get
wrong. Fix the system, not the people.

**3.** The hard part is not running the scanner. It is choosing what is worth blocking, and being able
to defend that choice to an engineer and to an auditor.

> "Happy to go anywhere you would like with it."

---


---

# PART D  -  THE CLOSE


## What they just watched

| They saw | It proved |
|---|---|
| A deleted, gitignored, later-encrypted password recovered with one `git show` | The fix everyone applies does not work |
| 24 findings sorted into 10 blocking, 5 advisory, 9 noted | Choosing what blocks is the job, not installing the scanner |
| The same code scanned three times with three different verdicts | Policy can be per environment without being three codebases |
| A pull request with every check green and the merge still blocked | Checks are not the only gate |
| Dev deploying itself while stage and prod waited for a person | The gate sits where the cost of being wrong changes |
| Five containers built from nothing, production being three of them | The pipeline builds real infrastructure, not a diagram |
| The install script skipping what was already correct | Idempotency, and why rebuild and redeploy are separate |

## The three things to land

**1.** Deleting a password from git does not remove it. **Change the password first, clean up
second.** The order matters more than the steps, because rotation takes minutes and history rewriting
takes days.

**2.** When something is wrong for nine months and nobody notices, **the system made it easy to get
wrong.** Sixteen commits added private keys and every one passed code review. Fix the system, not the
people.

**3.** The hard part is not running the scanner. It is **choosing what is worth blocking**, and being
able to defend that choice to an engineer who wants to ship and to an auditor who wants evidence.

## Questions I expect, and the short answer

| Question | Answer |
|---|---|
| "Why not Kubernetes?" | Nothing here needs it. The pipeline is identical; the last command would be `kubectl` or a Helm release instead of the Proxmox API. Adding Kubernetes would add a control plane to secure without changing anything I showed you. |
| "Why not AWS?" | No cloud account in the demo. The Terraform for the AWS platform tier is in the repo under `terraform/envs/`. Only the provider and the final call differ. |
| "What stops dev reaching prod?" | Three independent boundaries: network, cryptography, database. Each is tested in `validate.sh` groups 6, 7 and 8, and I can run it now. |
| "What if GitHub is compromised?" | They can schedule jobs. They get encrypted files they cannot open. Every credential lives on a runner behind NAT with no inbound path. |
| "Why is teardown not automated?" | An accidental apply rebuilds a server. An accidental destroy is an outage. Destruction is a deliberate act on the runner that owns that environment. |
| "How do you pick the blocking list?" | Start from what an auditor will ask for, remove anything a developer cannot act on, and keep it short enough that people read it. Ten in dev, fourteen in stage and prod. It is version controlled, so changing it is a reviewed change. |
| "What is missing?" | Runtime security, image and dependency scanning, disaster recovery of the host itself, and a second engineer to approve. Doc 6 has the honest list. |

## The closing line

> "Happy to go anywhere you would like with it."

---


---

# PART E  -  REFERENCE  (not read live)

Everything below is for answering questions, for teardown afterwards, and for
rehearsal. None of it is part of the spoken flow.

---

## E1  -  System design and architecture


**Open `docs/diagrams/01-system-architecture.drawio` on the second screen.**

### The shape of it in one sentence

GitHub schedules the work and holds the approval gate; three Linux containers on a Proxmox box in my
house pull that work down over an outbound connection and do it; nothing on the internet can reach in.

### The layers, top to bottom

```
  Developer laptop
     pre-commit: gitleaks + terraform fmt
        |  git push
        v
  GitHub.com                                 ORCHESTRATION ONLY
     Actions schedules jobs                  holds NO cloud credential
     Environments hold the approval gate     NO deploy credential
     Branch protection blocks the merge      NO network path to anything
     Security tab shows SARIF
        |  runners poll OUTBOUND over HTTPS; nothing connects in
        v
  Proxmox VE host  pve2  192.168.1.132
     vmbr0  uplink
     NAT + forward policy  (runner-net.service)  -- drops every cross-segment packet
        |
        +-----------------------+-----------------------+
        v                       v                       v
  vmbr1  10.10.10.0/24    vmbr2  10.20.10.0/24    vmbr3  10.30.10.0/24
  DEV                     STAGE                   PROD
   .10  ci-dev (201)       .10  ci-stage (202)     .10  ci-prod (203)
   .20  app-dev-1 (301)    .20  app-stage-1 (311)  .20  app-prod-1 (321)
                                                    .21  app-prod-2 (322)
                                                    .22  app-prod-3 (323)
        |                       |                       |
        +-----------------------+-----------------------+
                                |  port 5432 only, own database only
                                v
                     vmbr4  10.40.10.0/24  MANAGEMENT
                       .10  tf-state (204)  PostgreSQL 17
```

### The GitHub side, and how it is set up

All of this is repository settings, not the workflow file. If they ask "where does that live", it is
Settings, not code, and that is worth saying because it means it cannot be changed by a pull request.

| Setting | Value | What it enforces |
|---|---|---|
| Branch protection on `main` | 4 required checks: Secrets, IaC dev, IaC stage, IaC prod | Nothing merges with a failed scan |
| | 1 approving review | Nobody merges their own change |
| | Branch must be up to date | The checks ran against the code that will actually merge |
| Environments | `dev`, `stage`, `prod`, reviewers on stage and prod | The approval pause in the deploy job |
| Repository secrets | `ANTHROPIC_API_KEY` only, and it is optional | Triage explains findings in plain English with it, falls back to local rules without it |
| Runners | three, self-hosted, labels `dev` / `stage` / `prod` | Job routing |

**The absence is the point of the last two rows.** GitHub holds nothing that could create or destroy
infrastructure. If my GitHub account were compromised, an attacker could schedule jobs. Every
credential that matters is on a runner behind NAT, on a network they cannot reach.

### The three runners

| Runner | CT | Label | Address | Holds |
|---|---|---|---|---|
| ci-dev | 201 | `dev` | 10.10.10.10 on vmbr1 | dev age key, dev database credentials |
| ci-stage | 202 | `stage` | 10.20.10.10 on vmbr2 | stage age key, stage database credentials |
| ci-prod | 203 | `prod` | 10.30.10.10 on vmbr3 | prod age key, prod database credentials |

Every job says which runner it wants:

```yaml
runs-on: [self-hosted, "${{ matrix.environment }}"]
```

The prod job can only ever land on ci-prod, and ci-prod never receives a dev job. **That one line is
the isolation boundary.** A pull request that touches dev never executes on the machine that can
deploy production.

Terraform 1.5.7 and gitleaks 8.30.1 are baked into the container, not downloaded per job, so a build
cannot silently pick up a newer toolchain than the one that was reviewed.

### Three isolation boundaries, not one

They will ask what stops dev reaching prod. Three answers, each tested in `validate.sh`.

**1. Network.** Each environment is an isolated bridge with no physical port. The host forward policy
drops every cross-segment packet. `pct exec 201 -- ping 10.30.10.20` fails. Group 6 tests all six
ordered pairs.

**2. Cryptography.** Each environment's secrets file is encrypted to that environment's age public
key, and the private key exists only on that runner. Group 7 copies the **prod** encrypted file onto
the **dev** runner and tries to decrypt it there: `no master key`. That assumes the attacker already
has the file, which is the stronger test.

**3. Database.** `pg_hba.conf` accepts `tf_prod` only from 10.30.10.0/24. Group 8 hands the dev
runner the correct prod password and it is still refused, because the source address is checked
before the password.

> "A single boundary is one mistake away from nothing. Three independent ones mean an attacker needs
> three independent mistakes."

### Per environment, side by side

| | dev | stage | prod |
|---|---|---|---|
| Scanned and deployed by | ci-dev | ci-stage | ci-prod |
| Deploy trigger | automatic on merge | approval | approval, after stage |
| State schema | `deploy_dev` | `deploy_stage` | `deploy_prod` |
| Database, role | `tfstate_dev`, `tf_dev` | `tfstate_stage`, `tf_stage` | `tfstate_prod`, `tf_prod` |
| Proxmox API token | `terraform@pve!ci-dev` | `terraform@pve!ci-stage` | `terraform@pve!ci-prod` |
| Replicas | 1 | 1 | 2, becomes 3 today |
| PVE-1 unprivileged | enforced | enforced | enforced |
| PVE-3 start on boot | advisory | enforced | enforced |
| PVE-4 delete protection | advisory | advisory | **enforced** |

### Built by hand versus built by the pipeline

| Built by hand, once | Built by the pipeline, every time |
|---|---|
| The four bridges and the forward policy | Every application container |
| The three runners, their tools, their age keys | Its address, size, boot and protection settings |
| The state database, its roles, its `pg_hba.conf` | Its SSH keys and resolvers |
| The Proxmox API tokens | The state record of all of the above |
| The GitHub Environments and branch protection | |

The left column is the platform. The right column is what the platform exists to build.

### Design decisions I should be ready to defend

**Self-hosted runners.** The infrastructure is on a private network. A GitHub-hosted runner cannot
reach the Proxmox API or the state database without exposing them to the internet.

**Three runners rather than one.** With one runner, a pull request touching dev executes on the
machine holding the prod key. That is a privilege escalation path from dev to prod, removed by
having three.

**State in PostgreSQL, not a file or S3.** The `pg` backend gives real locking through advisory
locks. Two applies racing each other corrupt state, and that is not theoretical.

**SOPS with age rather than GitHub Secrets.** GitHub Secrets are decrypted by GitHub and injected
into any job that asks. SOPS files are decrypted by the runner with a key GitHub never sees. A
compromised GitHub account gets encrypted files it cannot open.

**Policy against the plan, not the source.** The plan has variables resolved and modules expanded. A
source-level check can be defeated by a default changing in a file it did not look at.

**The saved plan is what gets applied.** `terraform apply tfplan`, not `terraform apply`. What was
checked is what is built, with no window in between.

**Dev applies automatically; stage and prod wait.** Blocking dev on production-grade controls is how
a team learns to route around the pipeline. Letting prod apply on merge is how an incident starts.
The gate goes where the cost of being wrong changes.

**Terraform never logs into a container.** It calls the Proxmox API and stops. The install is a
separate step run from the host. Narrower than a runner that can do everything, and honest about
where the boundary is today.

---


---

## E2  -  The automation workflow in one picture

### The workflow in one picture

```
  PHASE A  -  PULL REQUEST  (nothing deploys)
  ------------------------------------------------------------------
  edit replica_count 2 -> 3, open PR
        |
        +--> JOB 1  Secrets      on ci-dev
        |      checkout fetch-depth: 0   <- the WHOLE history
        |      gitleaks detect --source .
        |      upload SARIF
        |
        +--> JOB 2  IaC matrix   fail-fast: false
               +----------------+----------------+----------------+
               | IaC (dev)      | IaC (stage)    | IaC (prod)     |
               | on ci-dev      | on ci-stage    | on ci-prod     |
               | fmt / decrypt / init / validate / checkov /      |
               | ai_triage.py                                     |
               | blocking = 10  | blocking = 14  | blocking = 14  |
               +----------------+----------------+----------------+
                        |
                        v
               3 PR comments, one per environment
                        |
                        v
               BRANCH PROTECTION: 4 checks green + 1 review
               MERGE STAYS BLOCKED
  ------------------------------------------------------------------

  PHASE B  -  MERGE TO main  (the only path to a deploy)
  ------------------------------------------------------------------
  gh pr merge --squash --admin
        |
        v
  Secrets + IaC x3 run again on main            (~90 seconds)
        |
        v
  JOB 3  Deploy   max-parallel: 1   dev, then stage, then prod

  every deploy job, on its own runner:
     1 checkout
     2 SOPS decrypt          -> DB creds AND Proxmox API token
     3 terraform init        -> schema deploy_<env>
     4 terraform plan -out=tfplan
     5 terraform show -json tfplan > plan.json
     6 policy_check.py --plan plan.json    <- PVE-1/3/4 against the PLAN
     7 terraform apply tfplan              <- the exact plan that was checked
       terraform output

  Deploy (dev)    -> NO approval, applies immediately     -> CT 301
  Deploy (stage)  -> PAUSES, a person approves            -> CT 311
  Deploy (prod)   -> PAUSES, after stage, person approves -> CT 321, 322, 323
        |
        v
  SEPARATE STAGE, run from the HOST:  /root/install-app.sh <env>
  ------------------------------------------------------------------
```

**Why plan, then check, then apply the saved plan.** Checkov has no rules for the Proxmox provider.
Scanned with Checkov alone, the deploy code passes every check *by being unrecognised*. So the policy
for it lives in `scripts/policy_check.py` and runs against the JSON of the plan, with variables
resolved and modules expanded. Then `apply` is handed that same saved file.

---


---

## E3  -  Testing, validation and troubleshooting


### The one command that checks everything

```bash
ssh root@192.168.1.132 '/root/validate.sh'
```

Groups 6, 7 and 8 are the three isolation boundaries from section 3. If a panellist asks "how do you
know dev cannot reach prod", this is the answer, and it runs in front of them.

### Per environment, by hand

| Environment | Container | Address | Health | Identity |
|---|---|---|---|---|
| dev | 301 app-dev-1 | 10.10.10.20 | `curl -s http://10.10.10.20:8080/health` | `curl -s http://10.10.10.20:8080/` |
| stage | 311 app-stage-1 | 10.20.10.20 | `curl -s http://10.20.10.20:8080/health` | `curl -s http://10.20.10.20:8080/` |
| prod | 321 app-prod-1 | 10.30.10.20 | `curl -s http://10.30.10.20:8080/health` | `curl -s http://10.30.10.20:8080/` |
| prod | 322 app-prod-2 | 10.30.10.21 | `curl -s http://10.30.10.21:8080/health` | `curl -s http://10.30.10.21:8080/` |
| prod | 323 app-prod-3 | 10.30.10.22 | `curl -s http://10.30.10.22:8080/health` | `curl -s http://10.30.10.22:8080/` |

**All five at once:**

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21 10.30.10.22; do
  printf "%-14s " $h; curl -s --max-time 5 http://$h:8080/health || echo "NO ANSWER"; echo
done
```

**The three endpoints each container serves:**

| Endpoint | Returns | Note |
|---|---|---|
| `/health` | `{"status": "ok"}` | 503 for the first two seconds after start, on purpose |
| `/version` | `{"version": "1.1.0"}` | what `install-app.sh` reads to decide whether to skip |
| `/` | the greeting, environment, host, version | reads its environment from its own hostname |

### Inside a container, when one is misbehaving

```bash
pct exec 321 -- systemctl status inspection-service --no-pager -l
pct exec 321 -- journalctl -u inspection-service -n 50 --no-pager
pct exec 321 -- ls -l /opt/rapta/inspection/
pct exec 321 -- curl -s http://127.0.0.1:8080/health
```

### Troubleshooting

| Symptom | Almost always | Fix |
|---|---|---|
| `terraform init` fails, `connection refused` on 10.40.10.10:5432 | Postgres bound loopback only after a tf-state restart | `pct exec 204 -- systemctl restart postgresql@17-main`, then confirm with `ss -tlnp \| grep 5432` |
| `curl` refused from the **host** prompt on 127.0.0.1:8080 | Wrong machine. Nothing listens on the Proxmox host | Use the container address, `10.x.10.20` |
| `curl` refused from my **Mac** | Those networks only exist on the Proxmox host | Run it over `ssh root@192.168.1.132` |
| Install script says `DID NOT COME UP` | The service failed, or the health check fired too early | It prints the status underneath. Run it again; it is safe to repeat and retries only the failed container |
| `Error: Container delete` on a destroy | `protection: 1` on a prod container | Section 6. Clear it, then re-run the destroy |
| Deploy job never starts | The runner for that environment is offline | `pct exec 20X -- systemctl status "actions.runner.*"` |
| A job lands on the wrong runner | A label is missing on a runner | Check labels in GitHub Settings, Actions, Runners |
| A flaky check in Actions | Pre-existing, unrelated to the change | Re-run the failed job from the Actions UI |
| Command not found | Wrong machine. Step 4 is my Mac, everything else is the server | |


---

## E4  -  Destroying every environment


**Open `docs/diagrams/03-destroy-flow.drawio`.**

This is how the environment was reset before today's demo, and how to reset it again afterwards.

### There is no destroy button in the pipeline, and that is deliberate

`security-pipeline.yml` only ever runs `terraform apply`. Destruction is not something CI should be
able to do as a side effect of a merge. **Teardown is a deliberate, manual act, performed on the
runner that already owns that environment's key, state and API token.**

If a panellist asks why teardown is not automated: the blast radius of an accidental `apply` is a
rebuilt server. The blast radius of an accidental `destroy` is an outage.

### Before you start

```bash
pct exec 204 -- ss -tlnp | grep 5432        # must show 10.40.10.10:5432
```

### The procedure, per environment

Run each on its own runner. dev on 201, stage on 202, prod on 203.

There is a helper on the host at `/root/tf-destroy.sh`, pushed into each runner at
`/home/runner/tf-destroy.sh`. It takes the environment and either `plan` or `destroy`:

```bash
pct exec 201 -- su - runner -c "/home/runner/tf-destroy.sh dev   plan"
pct exec 202 -- su - runner -c "/home/runner/tf-destroy.sh stage plan"
pct exec 203 -- su - runner -c "/home/runner/tf-destroy.sh prod  plan"
```

Expect exactly:

```
dev     Plan: 0 to add, 0 to change, 1 to destroy.
stage   Plan: 0 to add, 0 to change, 1 to destroy.
prod    Plan: 0 to add, 0 to change, 2 to destroy.
```

**If the counts differ, stop and find out why before destroying anything.**

```bash
pct exec 201 -- su - runner -c "/home/runner/tf-destroy.sh dev   destroy"
pct exec 202 -- su - runner -c "/home/runner/tf-destroy.sh stage destroy"

pct set 321 --protection 0
pct set 322 --protection 0
pct set 323 --protection 0        # only if 323 exists

pct exec 203 -- su - runner -c "/home/runner/tf-destroy.sh prod destroy"
```

### Why step 3 exists

Production sets `protect = true`, which is policy **PVE-4**. Without clearing it, Terraform stops the
containers and then fails:

```
Error: Container delete
```

The provider does not clear that attribute for itself on destroy. **This is the guardrail doing
exactly its job**, and it is worth saying out loud if it happens in front of anyone:

> "Production refused to be deleted by automation. A human had to disarm it on purpose. That is the
> difference between dev and prod in one error message."

### What the helper script does

Same shape as the pipeline's deploy job, with `destroy` on the end:

```
cd terraform/deploy/<env>
SOPS decrypt ../../envs/<env>/secrets.enc.yaml   -- with THIS runner's age key only
build conn_str from the decrypted values
terraform init -reconfigure -backend-config=...  -- schema deploy_<env>
export TF_VAR_pve_endpoint / pve_token_id / pve_token_secret
terraform plan -destroy      or      terraform destroy -auto-approve
```

It never echoes a decrypted value.

### Verify the teardown

```bash
for c in 201:dev 202:stage 203:prod; do id=${c%%:*}; env=${c##*:}
  printf "%-6s " "$env"
  pct exec $id -- su - runner -c "cd /home/runner/actions-runner/_work/secure-iac-pipeline/secure-iac-pipeline/terraform/deploy/$env && terraform state list | wc -l"
done

pct list
for v in 301 311 321 322 323; do pct list | grep -q "^$v " && echo "$v IN USE" || echo "$v free"; done
```

Three zeros, four platform containers, five free VMIDs.

### What teardown does not touch

The four bridges and the forward policy. The three runners, their tools and their age keys. The state
database, its roles and `pg_hba.conf`. The Proxmox API tokens. The GitHub Environments and branch
protection. `/opt/app-source` and `/root/install-app.sh` on the host.

That is the platform column from section 3. **Teardown only ever removes what the pipeline built.**

### Rebuilding after a teardown

**Through the pipeline**, which is what the demo does: merge to `main`, or use **workflow_dispatch**
in the Actions tab and pick one environment. That is the lever for re-applying a single environment
cleanly.

**Directly on a runner**, for a rehearsal when you do not want to burn a merge: same decrypt and init
as the helper script, then `terraform apply -auto-approve`. Then install the application from the
host with `/root/install-app.sh <env>`.

---


---

## E5  -  Post-demo reset

### Post-demo reset

1. Tear everything down, section 6.
2. Re-open the pull request, or create a new branch that changes `replica_count` back to 2 and then
   to 3 again.
3. Re-run the five pre-flight checks.

The whole cycle is about fifteen minutes.
