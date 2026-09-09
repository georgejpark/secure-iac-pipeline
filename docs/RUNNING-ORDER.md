# Running order - 30 minutes

Times are cumulative. If you fall behind, cut from the bottom of the list on the last page.

Have a clock where you can see it.

---

## 0:00 - 0:05   Tell them what happened

**No screen. Just talk.**

I was doing housekeeping. Cataloguing repositories. Boring work.

I ran a search for key files. It came back with **112 private keys**. All committed. 21 production
hostnames. The oldest had been there nine months.

The first commit in that repository was called "Starting up the repository". It already had 63 keys
in it.

**Then the turn:**

I expected carelessness. That's not what I found.

The deploy scripts read the key straight out of the folder you'd just cloned. So to deploy, the key
had to be in the repository. Adding a service meant committing its private key.

Nobody cut corners. They followed the process. **The process was the problem.**

Sixteen commits over nine months. Every one passed code review.

> "So the first thing: when something is wrong for nine months and nobody catches it, it's almost
> never carelessness. The system made the wrong thing easy."

---

## 0:05 - 0:07   Set up the demo

**Still talking. No screen yet.**

There was a second repository. A `.env` file with 74 passwords.

**They caught it.** The next commit was called "Add utility for encrypting/decrypting .env files".

They deleted the file. Added it to gitignore. Wrote an encryption tool.

The repository looked clean afterwards.

> "Let me show you what that actually achieved."

---

## 0:07 - 0:13   THE SECRET DEMO

**Share your screen now. Terminal 2 (server).**

```bash
/root/demo-secret-persistence.sh
```

Talk over the first four steps. Then **stop talking** when `git show` runs.

Let them read the passwords on screen.

> "Every password still there. One command. Deleting a file in git doesn't remove it, it just stops
> pointing at it."

### What that script is actually doing

Six git commands, nothing clever:

```bash
git init demo                              # a new repository
git add .env && git commit                 # the password is now in history
git rm --cached .env && rm .env            # "deleted"
echo ".env" > .gitignore && git commit     # "ignored"
git add encrypt_env.sh && git commit       # "encrypted"
git show <first-commit>:.env               # and there it is
```

**Why the last line works:** git stores every version of every file as an object. Deleting a file
removes the *pointer*, not the object. `git show <commit>:<file>` reads the object directly.

The object is still in `.git/objects`. It gets copied on every clone.

**Then the order that matters:**

> "Change the password first. That takes minutes. Rewriting history takes days, because you have to
> reach every fork and every laptop. Most people do it backwards."

---

## 0:13 - 0:17   THE CHECKS

**Terminal 1 (Mac).**

```bash
make scan-insecure
```

```
dev      10 blocking
stage    14 blocking
prod     14 blocking
```

> "Same code. Development blocks 10 things, production blocks 14. The extra four are things
> development is allowed to skip. Losing a dev box costs an afternoon."

```bash
make scan
```

> "Corrected code. Nothing blocking."

### What that command is actually doing

`make scan-insecure` runs two programs:

```bash
checkov -d terraform/insecure -o json          # finds the problems
python3 scripts/ai_triage.py --environment prod --fail-on-blocking
```

**Checkov** reads the Terraform and matches it against about a thousand known-bad patterns. It
returns JSON with a check ID for each problem, like `CKV_AWS_20`.

**`ai_triage.py`** is 240 lines I wrote. It does three things:

```python
BLOCKING_POLICIES = {          # a plain dictionary. people review this.
    "CKV_AWS_20":  "S3 bucket readable by anyone on the internet",
    "CKV_AWS_24":  "SSH open to 0.0.0.0/0",
    ...
}

PROMOTION_GATED_POLICIES = {   # only enforced in stage and prod
    "CKV_AWS_293": "database deletion protection disabled",
    ...
}
```

1. Reads Checkov's JSON
2. Sorts each finding into blocking, advisory, or noted, based on those dictionaries
3. Exits with code 1 if anything is in the blocking list

**That exit code is the whole gate.** GitHub sees a non-zero exit and marks the job failed.

**Then the number that matters:**

> "The scanner finds 24 problems in 110 lines. Nobody reads 24 findings, they mute the tool. So 10
> stop the merge, 5 are advice, 9 are just noted. Choosing which 10 is the actual job."

---

## 0:17 - 0:23   THE PULL REQUEST

**Browser. PR #2.**

Point at three things:

1. **BLOCKED - Review required**
2. Six green ticks
3. The comment the pipeline wrote

> "I can't approve my own pull request. GitHub refuses. In a real team a second engineer approves
> here. I'm the only account, so I'll override, and GitHub records that I did."

### What is running the checks

One file, `.github/workflows/security-pipeline.yml`. The important parts:

```yaml
jobs:
  secret-scan:
    runs-on: [self-hosted, dev]        # my machine, not GitHub's
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0               # the whole history, not just this commit
      - run: gitleaks detect --exit-code 1

  iac-scan:
    strategy:
      matrix:
        environment: [dev, stage, prod]   # runs three times, in parallel
    runs-on: [self-hosted, "${{ matrix.environment }}"]
```

**`fetch-depth: 0`** is the line that matters. GitHub normally downloads one commit. That would miss
a password committed last year and deleted since.

**`matrix`** is why the same code gets checked three times with three different rule sets.

**`runs-on: [self-hosted, prod]`** means the production job only runs on the production machine.
Development code never executes there.

### What stops the merge

Not the pipeline. A GitHub setting:

```
Require a pull request before merging
Require 1 approval
Require 4 status checks to pass
```

That's why it says BLOCKED even though every check is green.

**Terminal 2:**

```bash
cd /root/secure-iac-pipeline
gh pr merge 2 --squash --admin --delete-branch
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

> "Development deploys on its own. Staging stops. Production stops."

### What each deploy job does

Four commands, in order:

```bash
# 1. unlock this environment's passwords
sops --decrypt terraform/envs/prod/secrets.enc.yaml

# 2. connect to this environment's own database
terraform init -backend-config="conn_str=postgres://...@10.40.10.10/tfstate_prod"

# 3. work out what will change
terraform plan -out=tfplan

# 4. check the plan BEFORE running it
python3 scripts/policy_check.py --plan plan.json --environment prod

# 5. do it
terraform apply tfplan
```

**Step 1** works because each machine holds one key. The production machine cannot open the
development file, and vice versa. Same encrypted files in the repository, different keys.

**Step 4** is the second program I wrote. Checkov has no rules for Proxmox, so without this the
deploy code would pass every check just by being unrecognised. It reads the plan JSON and checks
four things:

```python
"PVE-1": "container must be unprivileged"          # always
"PVE-3": "must restart after a reboot"             # stage and prod
"PVE-4": "must have delete protection"             # prod only
```

**Why the plan and not the source:** the plan has the variables filled in. Source code can be
changed by a default somewhere else.

**Browser: approve staging, then production.**

---

## 0:23 - 0:27   PROVE IT'S REAL

**Terminal 2:**

```bash
pct config 321 | grep memory
```

> "Production now has 3 GB. It had 2."

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  curl -s http://$h:8080/ ; echo
done
```

> "Four machines. Each knows which environment it is. Two in production, because production says
> two."

### What made those machines

One Terraform file, used three times:

```hcl
resource "proxmox_virtual_environment_container" "app" {
  count        = var.replica_count      # dev 1, stage 1, prod 2
  unprivileged = true
  cpu    { cores     = var.cores }
  memory { dedicated = var.memory_mb }  # this is the number the PR changed
}
```

Each environment passes different values:

```hcl
# terraform/deploy/prod/main.tf
module "workload" {
  source        = "../../modules/workload"
  replica_count = 2
  memory_mb     = 3072      # was 2048 before the merge
}
```

**One description. Three sets of numbers.** A control that is on in production cannot be quietly
missing from staging, because they share the same file.

### What put the application on them

Terraform makes the machine. **Ansible installs the application.**

```bash
ansible-playbook -i inventory/hosts.ini playbooks/deploy.yml
```

It copies the code into a folder named after the version, then points a symlink at it:

```
/opt/rapta/inspection/releases/1.1.0/
/opt/rapta/inspection/current -> releases/1.1.0
```

Then it checks the service came back **and is running the version it just installed**. Not just that
it's alive. If the old code were still running, the deploy fails.

---

## 0:27 - 0:30   CLOSE

**Three things:**

**1.** Deleting a password from git doesn't remove it. Change the password first.

**2.** When something's wrong for nine months, the system made it easy to get wrong. Fix the system,
not the people.

**3.** The hard part isn't running the scanner. It's choosing what's worth blocking, and defending
that choice to an engineer and an auditor.

> "Happy to go anywhere you'd like with it."

---

# If you're running late

Cut in this order. Top of the list goes first.

**1. The rollback demo.** Say it instead: "rolling back is pointing a symlink at the old folder,
about two seconds."

**2. The isolation test.** Say it instead: "each environment is on its own network, they can't reach
each other, I tested both directions."

**3. The no-API-key demo.** Say it instead: "the AI writes the explanation, it doesn't decide. Take
the key away and the pipeline behaves identically."

**4. Approving production.** Approve staging only, and say production works the same way.

**5. `make scan` passing.** Show only the blocking one. The passing case is less interesting.

---

# Never cut these

**The `git show` moment.** That's the whole talk.

**The pull request sitting BLOCKED.** That's what they asked you to demonstrate.

**The three closing points.** Even if you're out of time, say them.

---

# If they interrupt

Good. Answer, then say **"where was I - right, the checks"** and carry on.

They told you they'd interrupt. An interrupted talk is a conversation. Plan for 25 minutes of
material, not 30.
