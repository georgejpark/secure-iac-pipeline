<!-- title -->
# The Password You Already Deleted

### Secrets in git, and a pipeline that stops them reaching production

George Park  ·  Senior DevSecOps  ·  Texas Mutual  ·  10 September 2026

*Document 2 of 7 — How a change reaches production, end to end.*

---

# How a change reaches production

A handout. Follow along.

---

# The change

Production is running out of room during month-end close.

I'm adding a third server.

That's it. One number in one file goes from `2` to `3`.

---

# The path it takes

```
        1.  clone the repository
                 |
        2.  make a branch
                 |
        3.  change one number
                 |
        4.  commit  ------------> a hook checks for passwords first
                 |
        5.  push
                 |
        6.  open a pull request
                 |
   +-------------+-------------+
   |             |             |
 7. gitleaks  8. Checkov   9. ai_triage.py
 secrets,     terraform,   sorts, decides,
 whole        once per     writes the
 history      environment  comment
   |             |             |
   +-------------+-------------+
                 |
        10. anything blocking?  ---- yes ----> STOPPED. fix it.
                 |
                 no
                 |
        11. somebody approves it
                 |
        12. merge to main
                 |
   +-------------+-------------+
   |             |             |
 13. DEV      14. STAGE     15. PROD
 goes out     waits for     waits for
  on its       someone       someone
   own        to approve    to approve
   |             |             |
   +-------------+-------------+
                 |
        16. policy_check.py checks the plan
            (unprivileged, boot, delete protection)
                 |
        17. terraform builds the server
                 |
        18. the deploy step installs
            the application on it
                 |
        19. the new server answers
```

---

# Step by step

## 1. Get the code

```bash
git clone git@github.com:georgejpark/secure-iac-pipeline.git
```

**What is happening:** a full copy of the repository lands on my laptop - every file, and every
version of every file that has ever been committed.

**Why it matters for this story:** that second part is the point of the whole demo. A clone is not
a snapshot of today. It is the entire history. Anything that was ever committed comes with it,
including things that were later deleted.

**What to notice:** there are no credentials in this clone. No cloud keys, no database passwords.
The encrypted secrets files are here, but nothing on my laptop can open them.

## 2. Make a branch

```bash
git checkout -b demo/TM-118-third-production-server
```

**What is happening:** my change gets its own name. `TM-118` is the ticket. Everything I do next
happens on this branch, and `main` does not move.

**Why:** `main` is what production is built from. If nobody can commit to it directly, then
everything that reaches production has been through the pull request, and the pull request is where
every check and every approval lives. Branch protection enforces this - even I, as the
administrator, get a warning when I bypass it, and GitHub records that I did.

Never work directly on `main`.

## 3. Change one number

File: `terraform/deploy/prod/main.tf`

```
replica_count = 2      becomes      replica_count = 3
```

**What is happening:** the file describes what production should look like. Not how to build it -
what it should be. Two servers becomes three. Terraform's job is to make reality match the file.

**Why it is one number:** all three environments use the same module - the same definition of what
a server is. Each environment passes in only the things allowed to differ: how many, how big, which
network, whether it restarts after a reboot, whether it can be deleted. A security setting cannot be
on in production and quietly off in development, because there is only one place it is written.

**What to notice:** the diff the reviewer sees is one line. That is deliberate. A change that is easy
to read is a change that gets reviewed properly.

Development and staging have their own files. They aren't affected.

## 4. Commit

```bash
git commit -m "TM-118: add a third production server"
```

**What is happening:** before Git records the change, a pre-commit hook runs on my laptop. It runs
gitleaks - the same secret scanner the pipeline uses, with the same configuration - plus
`terraform fmt` and `terraform validate`.

**Why here, and not only in the pipeline:** this is the cheapest gate there is. A password caught
here has never been committed. There is nothing to rotate, no history to rewrite, no incident. The
same password caught one step later, in the pipeline, is already in a commit that has been pushed to
GitHub, and that is a different day.

If it finds one, the commit doesn't happen. Nothing has left my laptop.

**What to notice:** the hook and the pipeline run the same tool. "It passed on my machine" means the
same thing as "it passed in CI".

## 5. Push

```bash
git push -u origin demo/TM-118-third-production-server
```

**What is happening:** the branch is copied to GitHub. The change has left my laptop and is now
visible to the team.

**What has not happened:** nothing has run. The pipeline is triggered by pull requests and by
merges to `main`, not by pushes to a branch. A push is publishing a draft; nothing has been asked
to judge it yet.

## 6. Open a pull request

```bash
gh pr create --base main
```

**What is happening:** I am asking for this branch to be merged into `main`. That request is the
pull request, and it is the unit everything else attaches to: the checks, the comments, the review,
the approval, and the record of who merged it.

**Why this is the trigger:** opening a pull request is a statement that the change is ready to be
judged. From this moment the pipeline runs on every push to the branch, and the merge button stays
disabled until every required check is green and a reviewer has approved.

This is what starts the pipeline.

## 7. The pipeline looks for passwords

**The tool:** gitleaks 8.30.1. Open source. Pinned to that version on the runner.

**Where it runs:** the development runner, container 201. It only reads source code, so it gets no
keys and no access to anything.

**What it reads:** **every commit ever made**, not just mine. The checkout line says
`fetch-depth: 0`. Without that line it would see one commit.

That matters. A password committed last year and deleted since would be invisible if it only looked
at today's files.

**What it does:**

```
gitleaks detect --source . --config .gitleaks.toml --redact --exit-code 1
```

- `--config .gitleaks.toml` - the patterns that count as a secret, and one allow-listed fake key
  the demo uses on purpose
- `--redact` - a found secret is never printed in full in the log
- `--exit-code 1` - a finding fails the job. That is what makes this a gate and not a report

**What happens on a finding:** the job goes red, and nothing else in the pipeline starts. The
result is also uploaded to the repository's **Security** tab as a code-scanning alert.

**Check it yourself:**

```bash
# on a laptop with the repository: the same scan, the same config, the whole history
make secrets

# on GitHub: the most recent pipeline run on this pull request, and its jobs
RUN=$(gh run list --workflow "Security Pipeline" --event pull_request --limit 1 \
      --json databaseId --jq '.[0].databaseId')
gh run view $RUN

# the gitleaks result, straight from that run's log
JOB=$(gh run view $RUN --json jobs --jq '.jobs[] | select(.name=="Secrets") | .databaseId')
gh run view --job $JOB --log | grep -E "Runner name|commits scanned|leaks found"
#   Runner name: 'ci-dev'
#   54 commits scanned.
#   no leaks found

# the Security tab, by API: every scan gitleaks uploaded, and how many findings each had
gh api "repos/georgejpark/secure-iac-pipeline/code-scanning/analyses?tool_name=gitleaks" \
  --jq '.[] | "\(.created_at)  \(.ref)  findings=\(.results_count)  rules=\(.rules_count)"'
#   ...  refs/pull/4/merge  findings=0  rules=225

# on the runner: the pinned version
pct exec 201 -- gitleaks version
```

In the browser: on the pull request, click **Secrets**, then expand **Scan the entire repository
history**. The log names the runner it landed on and ends with `no leaks found`. Or **Security →
Code scanning**, filter by tool `gitleaks`.

## 8. The pipeline checks the infrastructure code

**The tool:** Checkov. Open source. It reads Terraform and looks for unsafe settings.

**Where it runs:** three times, on three different machines. Development on 201, staging on 202,
production on 203. A job for one environment cannot land on another environment's runner; that is
decided by one line, `runs-on: [self-hosted, <environment>]`.

**What it reads:** `terraform/envs/<environment>/`. Same code, three copies, and only the settings
that are allowed to differ between environments differ.

**What it does, in order, on each runner:**

```
terraform fmt -check          formatting is a gate, not a suggestion
sops --decrypt                the state database password, with a key only this runner has
terraform init                connects to this environment's own state database
terraform validate            the code is well formed
checkov -d terraform/envs/<environment> --soft-fail
```

`--soft-fail` means **Checkov itself never fails the job.** It reports. The decision is made in
step 9. That is deliberate: a scanner that fails the build on every finding gets switched off.

**Examples of what Checkov finds:**

- A storage bucket anyone on the internet can read
- SSH open to the whole world
- A database with no encryption
- A database anyone on the internet can connect to

**What the numbers mean.** Against the deliberately broken copy of the code in
`terraform/insecure/`, the pipeline blocks:

- Development: **10** things
- Staging: **14**
- Production: **14**

The extra four are things development is allowed to skip: deletion protection, multi-AZ, log
export, enhanced monitoring. Losing a development box costs an afternoon.

Against the real code in this pull request, Checkov still reports findings - 9 in production, 11 in
development - but **none is on the blocking list**. That is why the checks are green, and why step 9
exists.

**Check it yourself:**

```bash
# on a laptop: the broken code, all three environments. Non-zero exit is the correct result
make scan-insecure
#   dev    exit=1  blocking=10
#   stage  exit=1  blocking=14
#   prod   exit=1  blocking=14

# on a laptop: the real code. Expect "No blocking findings" three times
make scan

# on GitHub: the Checkov result and the triage verdict, from the production job's log
RUN=$(gh run list --workflow "Security Pipeline" --event pull_request --limit 1 \
      --json databaseId --jq '.[0].databaseId')
JOB=$(gh run view $RUN --json jobs --jq '.jobs[] | select(.name=="IaC (prod)") | .databaseId')
gh run view --job $JOB --log | grep -E "Runner name|Passed checks|blocking="
#   Runner name: 'ci-prod'
#   Passed checks: 63, Failed checks: 9, Skipped checks: 0
#   blocking=0 advisory=8 other=1

# the Security tab, by API: one Checkov upload per environment
gh api "repos/georgejpark/secure-iac-pipeline/code-scanning/analyses?tool_name=Checkov&per_page=3" \
  --jq '.[] | "\(.created_at)  \(.category)  findings=\(.results_count)"'
#   checkov-prod   findings=9
#   checkov-stage  findings=9
#   checkov-dev    findings=11

# open alerts, by tool
gh api "repos/georgejpark/secure-iac-pipeline/code-scanning/alerts?state=open&per_page=100" \
  --jq 'group_by(.tool.name)[] | "\(.[0].tool.name): \(length) open"'
```

In the browser: on the pull request, click **IaC (prod)**, expand **Checkov** and read the counts.
Then open **IaC (dev)** and compare the runner name in the log header. Different machine. Or
**Security → Code scanning**, filter by tool `Checkov`, and note the three categories.

## 9. The pipeline writes a comment

**The tool:** `scripts/ai_triage.py`. Ours. About 300 lines of Python.

**Why it exists:** Checkov finds 24 problems in 110 lines of code. Nobody reads 24 findings. They
turn the tool off instead.

**What it reads:** Checkov's JSON output from step 8.

**What it does:**

1. Compares every finding against three lists that live in the script and are version controlled:
   - **blocking** - 10 policy IDs. Any one of these fails the job
   - **promotion-gated** - 4 policy IDs. Advice in development, blocking in staging and production
   - **advisory** - the rest. Noted, never blocking
2. Fails the job if anything on the blocking list is present. That is the gate.
3. Writes a Markdown report, ordered by severity, in plain English.
4. Posts it as a comment on the pull request. One comment per environment, updated on every push.

**Where the AI comes in, and where it does not:** with an API key, a language model writes the
explanation and the ordering. Without one, the script produces the same report from local rules.
**The model never decides pass or fail.** The lists do. If the model is unavailable the gate still
works.

**On the broken code**, the same 24 findings sort differently per environment:

- Development: **10** stop the merge, **5** are advice, **9** are noted
- Staging and production: **14** stop the merge, **5** are advice, **5** are noted

The four that move from *noted* to *blocking* are the promotion-gated list.

**Check it yourself:**

```bash
# on a laptop: run the triage by hand on the broken code, once for dev and once for prod
.venv/bin/checkov -d terraform/insecure -o json --quiet > .scan/insecure.json
.venv/bin/python scripts/ai_triage.py --input .scan/insecure.json --environment dev
#   blocking=10 advisory=5 other=9
.venv/bin/python scripts/ai_triage.py --input .scan/insecure.json --environment prod
#   blocking=14 advisory=5 other=5

# the three lists the decision comes from
grep -nE '^(BLOCKING|PROMOTION_GATED|ADVISORY)_POLICIES' scripts/ai_triage.py

# on GitHub: the comments the pipeline wrote on this pull request
gh pr view 4 --comments
```

On the pull request page, scroll to the comments. Three, one per environment, each starting with
the environment name and the counts.

## 10. The pull request is blocked

It says:

```
BLOCKED - Review required
```

**What is happening:** every check is green - secrets, and the infrastructure scan for all three
environments - and the merge button is still disabled.

**Why:** the checks are not the only gate. Branch protection on `main` requires four green checks
*and* one approving review from someone who is not the author. A scanner can tell you the code is
not obviously dangerous. It cannot tell you the change is the right one.

**What to notice:** the four required checks are named in the repository settings, not in the
workflow file. A pull request cannot edit its own gate.

## 11. Somebody approves it

I cannot approve my own pull request. GitHub refuses:

```
Can not approve your own pull request
```

Someone else has to look at it.

**What the reviewer has in front of them:** a one-line diff, three pipeline comments explaining
what the scanner found and why none of it blocks, and four green checks. The review is a
five-minute job because the pipeline did the reading.

**In this demo:** I am the only account on the repository, so I merge with an administrator
override, and GitHub records that a rule was bypassed and by whom. In a real team that override is
the thing an auditor asks about, and the answer is "here is every time it happened".

## 12. I merge

Merging is what allows a deployment. Nothing deploys before this.

**What is happening:** the branch is squashed into one commit and lands on `main`. `main` is now
different from what is running in production, and the pipeline's job is to close that gap.

**Why merging is the trigger and not something else:** because it is the one moment that has
every safeguard behind it. Checks passed, a person approved, and the change is recorded with a ticket
number and an author. Deploying from anywhere else - a laptop, a manual command - would skip all of
that. Nobody on this pipeline can deploy without a merge, because nothing else holds the keys.

## 13. Development deploys by itself

No approval needed. It goes.

**What is happening:** the deploy job for development runs on the development runner the moment
the checks on `main` pass. It decrypts the development credentials, plans, checks the plan, applies.

**Why no approval:** the cost of being wrong in development is an afternoon. Putting a person in
front of every development deploy teaches the team that the pipeline is slow, and a team that thinks
the pipeline is slow finds a way around it. Development is where the pipeline should be invisible.

## 14. Staging waits

GitHub says *Waiting for review*. Someone clicks approve.

**What is happening:** the staging deploy job has been scheduled and has stopped before running a
single step. A GitHub Environment named `stage` has a required reviewer, and the job cannot start
until that person approves.

**Why staging exists:** it has the same security settings as production and is smaller. A control
that is missing in staging is a control nobody has tested. The approval is the moment a person says
"this is ready to be tried against production's rules".

**What to notice:** the deploy jobs run one at a time, in order. Production does not even ask for
approval until staging has finished.

## 15. Production waits

Same again. Someone clicks approve.

**Why a second, separate approval:** staging passing is evidence. It is not permission. The person
who approves production is answering a different question - not "does it work" but "do we want this
in production now, during month-end close, with these people on call". That is a business decision,
and the pipeline puts it in front of a human rather than making it a side effect of a merge.

**Where the gate lives:** in the repository's Environment settings, not in the workflow file. So a
pull request cannot remove it. Changing who can approve production is itself a settings change with
an audit trail.

## 16. The plan is checked before anything is built

Checkov has no rules for Proxmox, so the deploy job runs its own check, `scripts/policy_check.py`,
against the Terraform **plan** - what will actually be created, with every variable resolved.

Three rules. Unprivileged. Restarts after a reboot. Cannot be deleted by accident. Production must
pass all three; development is allowed to skip the last two.

If it fails, nothing is built.

## 17. Terraform builds a new server

The file said two production servers. It now says three. Terraform compares the file with what it
built last time and creates only the difference.

```
proxmox_virtual_environment_container.app[2]: Creation complete
```

**How it knows what exists:** it keeps a record - the state - in a PostgreSQL database on its own
management network, one database per environment. Without that record it would build duplicates on
every run. The database also locks the record while an apply is running, so two deploys cannot race
each other and corrupt it.

**What it builds:** an unprivileged Linux container, on production's own network, at the next
address in the layout, with the admin SSH keys installed and DNS configured, set to restart after a
reboot and protected against accidental deletion. All of that comes from the module; the production
file only said "three".

**In today's demo** every environment was torn down before we started, so this run builds all five
servers rather than one. On an ordinary day it would build only the one that is missing.

That machine is empty. Terraform talks to the Proxmox API to build machines. It never logs into
them.

## 18. The deploy step installs the application

```bash
/root/install-app.sh prod
```

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

**Why this is a separate step and not part of the pipeline:** Terraform builds machines through
the Proxmox API and never logs into them. Installing software is a different job with a different
blast radius. Keeping them apart means rebuilding a server does not mean redeploying the
application, and redeploying the application does not mean touching infrastructure. This step runs
on the host, where it can reach every container.

Run it a second time and every line says `already serving 1.1.0 - skipped`. Two things worth
noticing.

**It skips the servers that are already working.** It asks each one what it is serving before it
touches anything, so running it twice changes nothing. That is what makes it safe to run after any
failure, without working out where it got to.

**It waits for the health check.** The application answers 503 for the first two seconds on purpose.
A check that fires immediately after a restart would race it and report a failure that isn't real.

On each container it does seven things: creates a service account so the app does not run as root,
installs Python if missing, copies the release into its own folder, builds a virtual environment,
moves the `current` symlink, installs a systemd unit that points at `current` rather than at a version
number, and waits for health to pass. Moving that symlink *is* the release, which is why a rollback
is a symlink move and not a redeploy.

## 19. The new server answers

```bash
curl http://10.30.10.22:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-3",
  "version": "1.1.0"
}
```

It knows it is production because it reads that from its own hostname. Nothing had to tell it.

**What this proves:** not that a web page loads. That five separate machines exist, each reporting
its own name and its own environment, three of them in production because a file says three. The
greeting is the one from the start of the session, coming back out of a machine that did not exist
when it was said.

**What to ask, if you want to test it:** ask for a different one. `10.10.10.20` answers `dev`,
`10.20.10.20` answers `stage`. Ask for a fourth production server and the answer is a one-line pull
request, and this whole path again.

---

# The tools, in one line each

**gitleaks** looks for passwords and API keys in your code. It knows what they look like.

**Checkov** reads Terraform and finds unsafe settings.

**terraform fmt** tidies up formatting so code reviews aren't arguments about spacing.

**terraform validate** catches typos before anything is built.

**SOPS** encrypts passwords so they can be stored in the repository safely.

**Terraform** creates the servers.

**The deploy script** installs the application onto servers that already exist. It creates a
service account, copies the release into its own folder, and moves one symlink. That symlink move is
the release, which is why rolling back is a symlink move too.

---

---

---

# The four machines that ARE the pipeline

Before any application server exists, four Linux containers are already running. They were built by
hand, once, and nothing in Terraform manages them. **They are the pipeline itself.**

If you only remember one thing from this section: **GitHub does not run any of this.** GitHub decides
*what* should run and *when*. These four machines are *where* it runs.

## Why they exist at all

A GitHub-hosted runner is a machine in Microsoft's cloud. It cannot reach a Proxmox API or a database
on a private network in my house without me exposing both to the internet. That is a worse trade than
running the compute myself.

So instead: three containers connect **outbound** to GitHub over HTTPS, ask "is there any work for
me", and pull it down. **Nothing on the internet ever connects in.** There is no inbound firewall
rule, no port forward, and no public address.

## How a job finds the right machine

Every runner registers with a **label**. Every job declares which label it wants.

```yaml
runs-on: [self-hosted, "${{ matrix.environment }}"]
```

When the matrix runs the `prod` copy of a job, `matrix.environment` is `prod`, so the job can only
land on the runner labelled `prod`. **That single line is the isolation boundary.**

## 201 - ci-dev - 10.10.10.10 - label `dev`

| | |
|---|---|
| **What it is** | GitHub Actions runner for development |
| **Holds** | The **dev** age key, dev database credentials, Terraform 1.5.7, gitleaks 8.30.1 |
| **Cannot** | Decrypt stage or prod secrets. Reach the stage or prod networks |
| **Runs** | The **secrets job for every environment**, the dev IaC scan, and the dev deploy |

**Why the secret scan runs here specifically.** Scanning source needs no credentials, so it is given
none. The job that reads the most code runs on the machine with the least privilege. Least privilege
applied to a job, not just to a user.

## 202 - ci-stage - 10.20.10.10 - label `stage`

| | |
|---|---|
| **What it is** | GitHub Actions runner for staging |
| **Holds** | The **stage** age key and stage database credentials, and nothing else |
| **Cannot** | Open the dev or prod encrypted files, even though it has a copy of both |
| **Runs** | The stage IaC scan, and the stage deploy after somebody approves |

## 203 - ci-prod - 10.30.10.10 - label `prod`

| | |
|---|---|
| **What it is** | GitHub Actions runner for production |
| **Holds** | The **prod** age key. This is the only machine on earth that can decrypt production |
| **Cannot** | Receive a dev or stage job. GitHub will not route one to it |
| **Runs** | The prod IaC scan, and the prod deploy after somebody approves and after stage finished |

## 204 - tf-state - 10.40.10.10 - PostgreSQL 17, not a runner

| | |
|---|---|
| **What it is** | A database. It runs no pipeline code and answers only queries |
| **Holds** | Three separate databases: `tfstate_dev`, `tfstate_stage`, `tfstate_prod` |
| **Roles** | `tf_dev`, `tf_stage`, `tf_prod`, one per database |
| **Reachable on** | Port 5432 only, and only from the three environment networks |

**What Terraform state is, and why it needs a database.** Terraform has to remember what it built last
time. Without that record it would build duplicates on every run, and it would have no idea which
container corresponds to which line of code.

That record could be a file. It is a database here for one reason: **locking.** The Postgres backend
takes an advisory lock for the duration of an apply. Two deploys running at once against the same
state file corrupt it, and that is not theoretical.

**How it is protected.** `pg_hba.conf` pins each role to its own subnet:

```
host    tfstate_dev     tf_dev      10.10.10.0/24    scram-sha-256
host    tfstate_stage   tf_stage    10.20.10.0/24    scram-sha-256
host    tfstate_prod    tf_prod     10.30.10.0/24    scram-sha-256
```

Hand the dev runner the correct production password and it is **still refused**, because the source
address is checked before the password is.

## How they map onto the workflow

| Workflow step | Machine | Why that one |
|---|---|---|
| Secrets job, gitleaks over full history | **201 ci-dev** | Needs no credentials, so it gets none |
| IaC scan (dev) | **201 ci-dev** | Only machine that can decrypt dev |
| IaC scan (stage) | **202 ci-stage** | Only machine that can decrypt stage |
| IaC scan (prod) | **203 ci-prod** | Only machine that can decrypt prod |
| Terraform init, any environment | that env's runner to **204** | Port 5432, its own database, from its own subnet |
| Deploy (dev), automatic | **201 ci-dev** | Calls the Proxmox API with token `terraform@pve!ci-dev` |
| Deploy (stage), after approval | **202 ci-stage** | Token `terraform@pve!ci-stage` |
| Deploy (prod), after approval | **203 ci-prod** | Token `terraform@pve!ci-prod` |
| Install the application | **the Proxmox host** | Not a runner at all. See below |

## Why three runners rather than one

With one runner, a pull request that touches development executes on the machine holding the
production key. Anyone who can open a pull request can then run arbitrary code next to that key.
**That is a privilege escalation path from dev to prod**, and it is removed by having three machines
rather than by writing a policy asking people not to do it.

## What the runners deliberately cannot do

They cannot install the application. Terraform calls the Proxmox API to build a machine and stops
there; it never logs in, and the runner holds no SSH key for a workload.

**Be precise about this one, because it is easy to overclaim.** The runner sits on the **same /24**
as its own environment's containers, so at the network level it could reach them. What the host
forward policy blocks is reaching **another** environment: all six ordered pairs between dev, stage
and prod are dropped. So this is a **separation of duties**, not a network impossibility.

Keeping install separate means rebuilding a server is not redeploying the application, and
redeploying the application is not rebuilding a server.

## What breaks if you collapse them

| Collapse | What you lose |
|---|---|
| Three runners into one | The dev-to-prod escalation path comes back |
| Three age keys into one | A compromised dev build can decrypt production |
| Three databases into one | One role can read or corrupt another environment's state |
| The database into a state file | No locking. Two concurrent applies corrupt state |
| Self-hosted back to GitHub-hosted | The Proxmox API and the database have to face the internet |

Each of those four containers exists because removing it removes a specific control, and the table
above is the answer to "why is this not simpler".

---

# The pipeline in detail: the YAML, gitleaks and Checkov

Everything above describes what happens. This section is how it is actually wired, for anyone who
wants to read the configuration rather than take my word for it.

## The workflow file

One file: `.github/workflows/security-pipeline.yml`. Three jobs.

### When it runs

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        description: "Environment to deploy"
        required: true
        default: dev
        type: choice
        options: [dev, stage, prod]
      deploy:
        description: "Apply, not just scan"
        required: false
        default: true
        type: boolean
```

| Trigger | What runs | Why |
|---|---|---|
| Pull request against `main` | Secrets, IaC x3 | Every proposed change is scanned before anyone reviews it |
| Push to `main` (a merge) | Secrets, IaC x3, then Deploy dev, stage, prod in order | A merge is the only path to a deploy |
| Manual (`workflow_dispatch`) | Secrets, IaC x3, then Deploy for **one** chosen environment | Re-apply a single environment cleanly, which is what a live demo needs |

### Two settings at the top that matter

```yaml
permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

`permissions: contents: read` means the workflow token can read code and nothing else by default.
Each job then adds only what it needs: `security-events: write` to upload scan results,
`pull-requests: write` to comment.

`cancel-in-progress: true` means a second push to the same branch cancels the run already going.
Two applies from the same branch cannot race each other.

### Where each tool is called

| Tool | Job | Step | Gate or advice |
|---|---|---|---|
| **gitleaks** | `secret-scan` | Scan the entire repository history | **Gate.** `--exit-code 1` fails the job |
| terraform fmt | `iac-scan` | Terraform format | Gate |
| SOPS | `iac-scan`, `deploy` | Decrypt credentials | Fails the job if the key is wrong |
| terraform validate | `iac-scan` | Terraform validate | Gate |
| **Checkov** | `iac-scan` | Checkov | **Advice.** Runs `--soft-fail`, `continue-on-error` |
| **ai_triage.py** | `iac-scan` | AI triage | **Gate.** `--fail-on-blocking` decides |
| **policy_check.py** | `deploy` | Policy check against the plan | **Gate.** Proxmox rules Checkov cannot see |
| terraform apply | `deploy` | Applies the saved plan | Builds the servers |

The important line in that table is that **Checkov does not fail the build**. It reports. The
decision is made one step later, by a script with a short, version-controlled list. That distinction
is the whole design and it is explained below.

---

## gitleaks

### What it is

A secret scanner. It reads source code, and every historical version of that source code, looking
for things that are shaped like credentials: API keys, tokens, private keys, passwords in connection
strings.

### What problem it solves

A Terraform misconfiguration is a proposal. A leaked credential is already an incident by the time CI
sees it. They do not deserve the same urgency, which is why this job runs **first and alone**, and
why nothing else runs if it fails.

### How it works

1. **Pattern rules.** Each rule is a regex plus keywords that must be present. The keywords are a
   cheap pre-filter so it does not run hundreds of regexes over every line.
2. **Entropy.** Some rules also score how random a string looks, which catches generated keys that
   match no vendor's specific format.
3. **Every commit, not just the current files.** It walks git history. This is the part that matters
   and the part most setups get wrong.
4. **Allowlisting** by path, by regex, or by commit, so documented exceptions do not become noise.
5. **SARIF output**, which GitHub renders in the Security tab as annotated findings.

### Features and functions

| Feature | What it does here |
|---|---|
| `detect` mode | Scans git history, every commit |
| `protect` mode | Scans uncommitted changes, which is what the pre-commit hook uses |
| Default ruleset | ~170 upstream rules for vendor tokens: AWS, GitHub, Stripe, Slack, GCP |
| Custom rules | Three added here, below |
| Allowlist | Paths, regexes and commits |
| `--redact` | Prints that a secret was found without printing the secret |
| `--exit-code 1` | Non-zero on a finding, which is what makes it a gate |
| SARIF report | Uploaded to the GitHub Security tab under category `gitleaks` |

### How it is configured

`.gitleaks.toml`, in the repository root.

```toml
title = "secure-iac-pipeline"

[extend]
useDefault = true
```

**Extending rather than replacing** means new upstream rules arrive with each release instead of
having to be maintained here.

Then three rules are added, because the default set is good on vendor-issued tokens and weaker on
what actually leaks inside an enterprise:

```toml
[[rules]]
id = "private-key-pem"
description = "Private key in PEM format"
regex = '''-----BEGIN\s?(RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED)?\s?PRIVATE KEY( BLOCK)?-----'''
keywords = ["BEGIN", "PRIVATE KEY"]

[[rules]]
id = "db-connection-string-with-password"
description = "Database connection string containing an inline password"
regex = '''(?i)(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqp)://[a-z0-9_\-\.]+:[^\s:@/]{6,}@'''
keywords = ["postgres", "mysql", "mongodb", "redis", "amqp"]

[[rules]]
id = "internal-jwt-signing-key"
description = "JWT signing secret assigned to a literal"
regex = '''(?i)(jwt|token|signing)[_\-]?(secret|key|passphrase)\s*[:=]\s*['"][^'"\s]{16,}['"]'''
keywords = ["jwt", "signing", "secret"]
```

The first rule is the one that would have caught the 112 private keys in the story.

The allowlist is deliberately narrow, because **a broad allowlist is how a scanner quietly stops
working**:

| Allowlisted | Why |
|---|---|
| `terraform/insecure/.*` | Deliberately vulnerable demo material. No real credentials; the password is a variable |
| `scripts/demo_secret_persistence.sh` | Generates its fake credentials at runtime; nothing committed |
| `docs/.*\.md` | Documentation quotes policy IDs and redacted examples |
| `\.env\.example$` | Placeholder values. Allowlisted **by path**, not by loosening the rule, so the rule still protects a real `.env` if one is ever staged by mistake |
| `changeme`, `example`, `placeholder`, `xxxx+` | Placeholders used in examples |

### How the pipeline calls it

```yaml
  secret-scan:
    name: Secrets
    runs-on: [self-hosted, dev]        # LOWEST-trust runner. It needs no cloud access, so it has none
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0               # REQUIRED

      - name: Confirm the pinned gitleaks is present
        run: gitleaks version

      - name: Scan the entire repository history
        run: |
          gitleaks detect \
            --source . \
            --config .gitleaks.toml \
            --redact \
            --verbose \
            --report-format sarif \
            --report-path gitleaks.sarif \
            --exit-code 1
```

**Two decisions in there worth pointing at.**

**`fetch-depth: 0`.** The default checkout fetches one commit. A password committed last week and
deleted yesterday is invisible to a one-commit scan and fully visible to a full-history scan. That
deleted-but-still-there case is the one that actually matters, and it is the demo. **This single line
is the difference between a working secret scanner and a decorative one.**

**Running the binary, not `gitleaks-action`.** On a push the action scans only the pushed commit
*range*. On a repository's first push that range is `<first-commit>^..HEAD`, and the first commit has
no parent. git errors, the scan covers zero bytes, and the action still prints "no leaks found". A
scanner that reports a pass while scanning nothing is worse than no scanner, because it manufactures
confidence. So the version is pinned into the runner image, the whole repository is scanned every
time, and it is allowed to be slightly slower. This was found by testing it.

---

## Checkov

### What it is

A static analysis tool for infrastructure as code. It reads Terraform, CloudFormation, Kubernetes
manifests, Dockerfiles and more, and checks them against a library of policies about unsafe settings.

### What problem it solves

Terraform will happily build a publicly readable S3 bucket holding claims data, an unencrypted
database, or a security group open to the world. None of that is a syntax error. `terraform validate`
passes. Checkov is the thing that reads intent rather than syntax.

### How it works

1. **Parses** the Terraform into an internal graph, resolving variables and expanding modules where
   it can.
2. **Runs policies** against that graph. Each has an ID like `CKV_AWS_20`, a description, and a
   resource type it applies to.
3. **Graph checks** (`CKV2_*`) span more than one resource, for example "this bucket has no public
   access block attached anywhere".
4. **Reports** in JSON, SARIF, CLI, JUnit and more.

### Features and functions

| Feature | What it does here |
|---|---|
| Built-in policy library | ~1,000 policies across providers |
| `-d <dir>` | Scan a directory tree |
| `--output json` | Machine-readable, which is what the triage script consumes |
| `--output sarif` | For the GitHub Security tab, category `checkov-<env>` |
| `--soft-fail` | Always exit zero. **Report, do not decide** |
| Custom policies | Supported, in Python or YAML. Not used here, see the Proxmox gap below |
| Secrets detection | Also has one. Not relied on here; gitleaks does that job properly, over history |

### How the pipeline calls it

```yaml
      - name: Checkov
        continue-on-error: true
        run: |
          checkov -d terraform/envs/${{ matrix.environment }} \
            --output json --output-file-path checkov-report \
            --soft-fail
          checkov -d terraform/envs/${{ matrix.environment }} \
            --output sarif --output-file-path . --soft-fail
```

**It is invoked twice on purpose**, once for JSON and once for SARIF, because the two outputs go to
different consumers: the JSON to the triage script, the SARIF to GitHub.

**Both `--soft-fail` and `continue-on-error: true`** so that a finding does not kill the job before
triage has had a chance to explain it. The gate is the next step, not this one.

One footnote from actually running it: Checkov names the SARIF file `results_sarif.sarif`, not
`results.sarif`. Getting that wrong makes the upload step fail silently and leaves a red annotation
on an otherwise green run.

---

## gitleaks versus Checkov

They are often lumped together as "the security scanners". They are not the same kind of tool and
they do not fail for the same reasons.

| | **gitleaks** | **Checkov** |
|---|---|---|
| **Looks at** | Text, in every version of every file | Infrastructure code, parsed into a resource graph |
| **Reads history?** | **Yes.** That is the point | No. Only the current working tree |
| **Finds** | Credentials that exist | Configurations that are unsafe |
| **A finding means** | Something has already leaked. Rotate it now | Something would be built badly. Fix before merge |
| **Urgency** | Incident | Proposal |
| **False positive looks like** | A placeholder or test fixture | A control satisfied somewhere it cannot see |
| **Config file** | `.gitleaks.toml` | none here; policy lives in `ai_triage.py` |
| **Exit behaviour here** | `--exit-code 1`, it *is* the gate | `--soft-fail`, it never gates |
| **Runs on** | ci-dev only, the lowest-trust runner | all three runners, one each |
| **Job order** | First, alone. Blocks everything | Second, needs `secret-scan` to pass |
| **Language** | Go | Python |
| **In pre-commit?** | Yes | No, too slow for a commit hook |

> The one-line version: **gitleaks tells you something already went wrong. Checkov tells you
> something is about to.**

---

## Why a scanner is not a gate: `ai_triage.py`

Checkov reports **24 findings against 110 lines of Terraform**. Nobody reads 24 findings. They turn
the tool off. So the scanner reports and a separate script decides, against a hardcoded list that is
version controlled and fits on a screen.

Findings sort into three tiers.

**Always blocking**, in every environment:

| Policy | Means |
|---|---|
| `CKV_AWS_20` | S3 bucket readable by anyone on the internet |
| `CKV2_AWS_6` | S3 bucket has no public access block |
| `CKV_AWS_24` | SSH (22) open to `0.0.0.0/0` |
| `CKV_AWS_260` | HTTP (80) open to `0.0.0.0/0` |
| `CKV_AWS_17` | RDS instance publicly accessible |
| `CKV_AWS_16` | RDS storage not encrypted at rest |
| `CKV_AWS_145` | S3 bucket holding claims data not encrypted with a CMK |
| `CKV_AWS_161` | RDS IAM database auth disabled, so long-lived DB passwords |
| `CKV_AWS_21` | S3 versioning off, so no tamper or ransomware recovery |
| `CKV_AWS_18` | S3 access logging off, so no audit trail of who read claims data |

**Promotion-gated** — a deliberate cost tradeoff in dev, a release blocker in stage and prod:

| Policy | Means |
|---|---|
| `CKV_AWS_293` | Database deletion protection disabled |
| `CKV_AWS_157` | Database not Multi-AZ, so an AZ outage takes the service down |
| `CKV_AWS_129` | Database logs not exported to CloudWatch, so nothing to alert on |
| `CKV_AWS_118` | Enhanced monitoring disabled |

**Advisory** — reported, never blocking, with the reason written down:

| Policy | Why it does not block |
|---|---|
| `CKV_AWS_144` | Cross-region replication is a DR and cost decision, not a vulnerability |
| `CKV2_AWS_61` | Lifecycle configuration is a retention policy decision |
| `CKV2_AWS_62` | Event notifications are observability, nice to have |
| `CKV2_AWS_5` | Security group not attached — a false positive when reviewing module code |
| `CKV_AWS_23` | Security group rule has no description — hygiene, not a vulnerability |
| `CKV_AWS_111/356/109` | KMS root-account admin statement is the AWS-recommended default |

That is **10 blocking in dev, 14 in stage and prod**. The extra four are the promotion-gated ones.

```python
def blocking_set(environment: str) -> dict[str, str]:
    policies = dict(BLOCKING_POLICIES)
    if environment in ("stage", "prod"):
        policies.update(PROMOTION_GATED_POLICIES)
    return policies
```

**Dev is allowed to be cheaper, and the pipeline says so out loud** instead of pretending every
environment is equal. That is the difference between a policy engine people respect and one they
route around.

The language model is optional and only ever **explains and orders**. It never decides. Without
`ANTHROPIC_API_KEY` the script produces the same report from local rules, so the gate never depends
on an external API being up.

---

## The Proxmox gap: `policy_check.py`

**Checkov has no rules for the Proxmox provider.** Scanned with Checkov alone, the deploy code passes
every check *by being unrecognised*. A tool that passes because it does not understand the input is
the same failure mode as the gitleaks action scanning zero bytes.

So the policy for the container tier is written directly, and runs against the **JSON of the
Terraform plan** rather than the source, so variables are resolved and modules expanded.

| ID | Rule | dev | stage | prod | Why |
|---|---|---|---|---|---|
| **PVE-1** | Container must be unprivileged | enforced | enforced | enforced | A privileged container shares the host user namespace. Root inside it is effectively root on the hypervisor |
| **PVE-2** | Network interface firewall enabled | **nowhere** | **nowhere** | **nowhere** | See below |
| **PVE-3** | Must restart after a host reboot | advisory | enforced | enforced | Otherwise the next maintenance window is an unplanned outage |
| **PVE-4** | Must have delete protection | advisory | advisory | **enforced** | Blocks an accidental destroy of a running production workload |

**PVE-2 is enforced nowhere, deliberately, and it is left in the table rather than deleted.** Enabling
the per-container firewall breaks return traffic for outbound connections on this platform, and
segment isolation is enforced by the host forward policy instead, verified in both directions. A
policy silently removed looks like an oversight. A policy that says why it is not enforced is a
decision.

**PVE-4 is the one that fires in real life.** A `terraform destroy` against production stops the
containers and then fails with `Error: Container delete`, because `protection: 1` is set. A human has
to clear it on purpose. That is the guardrail working.

---

## The same checks run in three places

| Where | What runs | Cost of a catch |
|---|---|---|
| **Laptop**, pre-commit hook | gitleaks, terraform fmt, terraform validate, merge-conflict and private-key checks | Seconds. The secret never becomes a commit |
| **Laptop**, `make scan` | Checkov + triage for all three environments | A minute |
| **CI**, on every pull request | All of it, on three isolated runners | Minutes, and it is the record |

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.99.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
```

> The pre-commit hook is the cheapest gate in the pipeline. A secret caught there never becomes a
> commit, which means it never needs a history rewrite, a rotation, or an incident report. Everything
> downstream is a more expensive version of that same check.

Every version is pinned: gitleaks `v8.30.1`, pre-commit-terraform `v1.99.0`, Terraform `1.5.7`. A
build cannot silently pick up a newer toolchain than the one that was reviewed.

**`make scan-insecure`** points the same gate at `terraform/insecure/`, a deliberately vulnerable
tree, and proves it blocks: `dev exit=1 blocking=10`, `stage exit=1 blocking=14`,
`prod exit=1 blocking=14`. A non-zero exit is the correct result there.

---

---

# Terraform, the scripts, and the application itself

The sections above cover the machines and the scanners. This one covers everything else in the
repository, and follows one change all the way to a container answering **"Hello World, Hello Guys
This is George and nice to meet you"**.

## Every file in the repository, and what it does

| File | What it is |
|---|---|
| `.github/workflows/security-pipeline.yml` | The whole pipeline. One file, three jobs |
| `.gitleaks.toml` | Secret-scanner rules and allowlist |
| `.pre-commit-config.yaml` | The same checks, on the laptop, before a commit exists |
| `.sops.yaml` | Which age key encrypts which environment's secrets |
| `Makefile` | Local equivalents of what CI runs. If these pass, CI passes |
| `scripts/ai_triage.py` | Turns Checkov findings into a decision. **The AWS gate** |
| `scripts/policy_check.py` | Proxmox policy against the Terraform plan. **The container gate** |
| `scripts/install_app.sh` | Installs the application onto containers that already exist |
| `scripts/validate.sh` | Every host-side check, including the three isolation boundaries |
| `scripts/demo_secret_persistence.sh` | The STEP 3 proof that deleting a secret does not remove it |
| `terraform/bootstrap/github-oidc.tf` | The OIDC trust so GitHub can assume an AWS role with no stored key |
| `terraform/envs/{dev,stage,prod}/` | The **AWS platform tier**. Scanned by Checkov, not applied in this demo |
| `terraform/modules/claims-platform/` | The AWS module those environments call |
| `terraform/deploy/{dev,stage,prod}/` | The **Proxmox application tier**. This is what actually applies |
| `terraform/modules/workload/` | The module that builds a container |
| `terraform/insecure/main.tf` | Deliberately bad Terraform, to prove the gate blocks |

## Two Terraform trees, and why

This trips people up, so say it before they ask.

| | `terraform/envs/` | `terraform/deploy/` |
|---|---|---|
| Builds | AWS: VPC, RDS, S3, security groups | Proxmox LXC containers |
| Provider | `hashicorp/aws` | `bpg/proxmox` |
| Applied in this demo? | **No.** Scanned only | **Yes.** This is what builds the servers |
| Gated by | Checkov + `ai_triage.py` | `policy_check.py` |
| Why it exists | The realistic target. It is what an insurer's platform looks like, and it is what Checkov has rules for | The thing I can actually build in front of you on hardware I own |

> "The AWS tree is the shape of the real thing and it is fully scanned. The Proxmox tree is the part I
> can build live. The pipeline is identical; only the last command differs."

## What the workload module actually creates

`terraform/modules/workload/main.tf`, one resource, `count = var.replica_count`:

```hcl
resource "proxmox_virtual_environment_container" "app" {
  count     = var.replica_count
  vm_id     = var.vmid_base + count.index

  unprivileged  = true              # policy PVE-1, every environment
  start_on_boot = var.start_on_boot # policy PVE-3, stage and prod
  protection    = var.protect       # policy PVE-4, prod only
  started       = true

  initialization {
    hostname = "app-${var.environment}-${count.index + 1}"
    user_account { keys = var.admin_ssh_keys }
    dns         { servers = var.dns_servers }
    ip_config { ipv4 {
      address = "${var.subnet_prefix}.${var.host_octet_base + count.index}/24"
      gateway = var.gateway
    } }
  }

  operating_system { template_file_id = var.template, type = "debian" }
  cpu    { cores     = var.cores }
  memory { dedicated = var.memory_mb }
  disk   { size      = var.disk_gb }

  network_interface { name = "eth0", bridge = var.bridge, firewall = false }
}
```

Per environment, only these differ:

| | dev | stage | prod |
|---|---|---|---|
| `vmid_base` | 301 | 311 | 321 |
| `replica_count` | 1 | 1 | 2, **3 after this change** |
| `start_on_boot` | false | true | true |
| `protect` | false | false | **true** |
| Bridge / subnet | vmbr1 / 10.10.10 | vmbr2 / 10.20.10 | vmbr3 / 10.30.10 |

**Two comments in that file are worth reading aloud if anyone asks about them.**

**The host octet is a fixed offset, not derived from the VMID.** Deriving it put `app-dev-1` on
`10.10.10.1`, which is the gateway, because `301 % 100 = 1`. The layout is now explicit: `.1` is the
bridge, `.10` is the CI runner, `.20` upward are workloads.

**`firewall = false` is deliberate.** The Proxmox per-container firewall inserts an extra bridge in
front of the NIC, and with it on the container loses return traffic for outbound connections. DNS and
apt both break, regardless of policy. Isolation does not depend on that flag; it is enforced by the
host forward policy and verified in both directions. It bought nothing and broke the workload, so it
is off, **and the reason is written in the file rather than left for the next person to rediscover.**

## The application

Four files. They live on the Proxmox host at `/opt/app-source/`.

**`app.py`** — a standard-library HTTP server, no framework, about 80 lines. Three endpoints:

| Endpoint | Returns |
|---|---|
| `/health` | `{"status": "ok"}`, or **503 `{"status": "starting"}` for the first 2 seconds** |
| `/version` | `{"version": "1.1.0"}`, read from the `VERSION` file next to the script |
| `/` and `/hello` | The greeting, plus environment, host and version |

```python
host = socket.gethostname()
env  = host.split("-")[1] if "-" in host else "unknown"
self._json(200, {
    "message": "Hello World, Hello Guys This is George and nice to meet you",
    "environment": env,
    "host": host,
    "version": _read_version(),
})
```

**That is how a container knows it is production.** Terraform sets the hostname to
`app-prod-3`; the application splits on the hyphen and reads `prod`. Nothing is passed in, no config
file is templated, and there is no environment variable to get wrong.

**The startup grace is deliberate.** For two seconds after start, `/health` answers 503. A deploy
check that fires immediately after a restart would race and report a false failure. The install
script waits for a real 200.

**`VERSION`** — one line, `1.1.0`. Read at request time, so `/version` reflects what is on disk.

**`requirements.txt`** — intentionally empty. The app uses only the standard library. **A venv is
still built**, so the deploy mirrors the shape of a real service that does have dependencies.

**`inspection-service.service`** — the systemd unit:

```ini
[Service]
User=rapta
WorkingDirectory=/opt/rapta/inspection/current
ExecStart=/opt/rapta/inspection/current/venv/bin/python /opt/rapta/inspection/current/app.py
Restart=on-failure
```

**Every path says `current`, never a version number.** That is the whole rollback design: the unit
never changes, so rolling back is moving one symlink and restarting.

## `install_app.sh` — from empty container to serving

Terraform builds machines and stops. This script puts the application on them. It is run from the
**host**, and it is safe to run as many times as you like.

For each container matching `app-<env>-*` that is **not already serving the target version**:

| # | Step | Why it is that way |
|---|---|---|
| 1 | Create the `rapta` service account | The application never runs as root |
| 2 | Install `python3`, `curl`, `python3-venv` if missing | Tests for `import ensurepip`, not for `python3 -m venv --help`, because the help text ships in the stdlib while the machinery is a separate package |
| 3 | Copy the release to `releases/1.1.0` | The previous release stays on disk |
| 4 | Build a venv **inside that release folder** | Two releases can need different packages without fighting |
| 5 | Move one symlink, `current` to `releases/1.1.0` | **That pointer move is the release** |
| 6 | Install the systemd unit and enable it | It points at `current`, never a version |
| 7 | Poll `/health` until it returns 200 | Honours the two-second grace instead of racing it |

The skip check is a real HTTP call, not a file marker:

```bash
if pct exec "$VMID" -- curl -fsS --max-time 3 http://127.0.0.1:8080/version 2>/dev/null \
     | grep -q "\"${VERSION}\""; then
  echo "  ${NAME} (${VMID})  already serving ${VERSION}  - skipped"
  continue
fi
```

> "It asks each machine what it is serving before deciding to touch it. That is why running it twice
> is safe, and why it only ever acts where something is actually missing."

## The whole chain, one change end to end

| # | Where | What happens |
|---|---|---|
| 1 | Laptop | Edit `replica_count` 2 to 3. **pre-commit** runs gitleaks and `terraform fmt` before the commit exists |
| 2 | GitHub | Push, open a pull request |
| 3 | ci-dev | **gitleaks** reads every commit ever made. `--exit-code 1`. Nothing else runs until it passes |
| 4 | all three runners | **Checkov** scans the AWS tree, `--soft-fail`, reporting only |
| 5 | all three runners | **`ai_triage.py`** decides: 10 blocking in dev, 14 in stage and prod |
| 6 | GitHub | Three PR comments. Four checks green. **Merge still blocked**, review required |
| 7 | GitHub | Approve, then merge. **The merge is what authorises a deploy** |
| 8 | ci-dev | Deploy dev, automatic. SOPS decrypt, init, plan, **`policy_check.py`**, apply |
| 9 | Proxmox API | **Terraform** creates CT 301 from the Debian template, on vmbr1, at 10.10.10.20 |
| 10 | GitHub | Deploy stage pauses. A person approves. CT 311 |
| 11 | GitHub | Deploy prod pauses, and cannot start until stage finished. A person approves |
| 12 | Proxmox API | Terraform creates CT 321, 322 and **323**, because the file now says three |
| 13 | Host | **`install_app.sh prod`** — service account, venv, release folder, symlink, unit, health check |
| 14 | Anywhere on that segment | `curl http://10.30.10.22:8080/` |

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-3",
  "version": "1.1.0"
}
```

**Six tools, in order: gitleaks, Checkov, ai_triage.py, Terraform, policy_check.py, install_app.sh.**
Two of them are gates that stop a merge. One is a gate that stops a deploy. One builds machines. One
installs software. One only ever reports.

## One honest gap

**The application source is not in this repository.** `app.py`, `VERSION`, `requirements.txt` and the
systemd unit live on the Proxmox host at `/opt/app-source/` and are copied from there.

That means the application is not version controlled alongside the infrastructure that runs it, it
gets no code review, and gitleaks never scans it. In a real system it would be its own repository
with its own pipeline, and this pipeline would consume a built artefact with a version number rather
than copying files off a disk.

It is called out here rather than left for someone to notice, because a pipeline that scans its
infrastructure and not its application is only half a pipeline. Doc 6 has the fuller list of what
this demo does not cover.

---

# Why each environment is separate

Development, staging and production are on separate networks.

They cannot reach each other. Tested in both directions.

If somebody breaks into development, they have reached development. Nothing else.

Each one also has its own encryption key and its own database. The development machine physically
cannot read production's passwords.
