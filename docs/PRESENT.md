# PRESENT

The only document open during the demo.

Each step says where to be, what to say, and what to run.

**Two windows:**

```
TERMINAL    ssh root@192.168.1.132
BROWSER     github.com/georgejpark/secure-iac-pipeline
```

---

# STEP 1
## Tell them what happened

**No screen. Just talk.**   `4 minutes`

I was cataloguing repositories. Boring housekeeping.

I searched for key files, to fill in a document.

**112 private keys.** All committed. 21 production hostnames. The oldest nine months old.

The first commit in that repository was called *"Starting up the repository"*. It already had 63 keys.

**The turn:**

I expected carelessness. The deploy scripts read the key straight out of the folder you'd cloned. To
deploy, the key had to be in the repository. Adding a service meant committing its private key.

Nobody cut corners. They followed the process. **The process was the problem.**

> "When something is wrong for nine months and nobody catches it, the system made the wrong thing
> easy."

---

# STEP 2
## The fix that doesn't work

**Still no screen.**   `2 minutes`

Second repository. A `.env` with 74 passwords.

**They caught it.** The next commit was *"Add utility for encrypting/decrypting .env files"*.

Deleted the file. Added it to gitignore. Wrote encryption.

> "Let me show you what that achieved."

---

# STEP 3
## Show the password is still there

**TERMINAL**   `6 minutes`

```bash
/root/demo-secret-persistence.sh
```

Press enter through it. **Stop talking when `git show` runs.**

**What the code does:**

```bash
git add .env && git commit          # password is now in history
git rm --cached .env                # "deleted"
echo ".env" > .gitignore            # "ignored"
git show <first-commit>:.env        # still there
```

Git keeps every version as an object. Deleting removes the pointer, not the object.

> "Change the password first. That takes minutes. Rewriting history takes days."

---

# STEP 4
## Show them the repository

**BROWSER** - the Code tab   `2 minutes`

Point at three folders:

```
terraform/        builds the machines
.github/workflows/  the pipeline
scripts/          two programs I wrote
```

> "One repository. Terraform describes the machines. The workflow file checks the code. Two small
> scripts do the sorting."

---

# STEP 5
## Show the checks blocking bad code

**TERMINAL**   `3 minutes`

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline    # your Mac
make scan-insecure
```

```
dev      10 blocking
stage    14 blocking
prod     14 blocking
```

**What the code does:**

Checkov finds problems and returns JSON. My script compares each one against a list:

```python
BLOCKING_POLICIES = {
    "CKV_AWS_20": "bucket readable by anyone on the internet",
    "CKV_AWS_24": "SSH open to the world",
}
```

If anything matches, it exits 1. **That exit code is the gate.**

> "Same code. Development blocks 10, production blocks 14. Development is allowed to be cheaper."

> "The scanner finds 24 problems in 110 lines. Nobody reads 24 findings, they mute the tool.
> Choosing which 10 matter is the actual job."

---

# STEP 6
## Show the pull request

**BROWSER** - Pull requests, PR #2   `4 minutes`

Point at:

1. **BLOCKED - Review required**
2. Six green checks
3. The comment the pipeline wrote

**What the code does:**

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0        # the whole history, not one commit

strategy:
  matrix:
    environment: [dev, stage, prod]     # checks three times

runs-on: [self-hosted, "${{ matrix.environment }}"]   # my machines
```

> "`fetch-depth: 0` is the line that matters. Without it GitHub downloads one commit, and a password
> deleted last year is invisible."

> "I can't approve my own pull request. GitHub refuses. In a real team a second engineer approves
> here."

---

# STEP 7
## Merge it

**TERMINAL**   `2 minutes`

```bash
cd /root/secure-iac-pipeline
gh pr merge 2 --squash --admin --delete-branch
```

> "Merging is what authorises a deployment. Nothing deploys before this."

---

# STEP 8
## Watch it deploy

**BROWSER** - Actions tab   `4 minutes`

Refresh. Watch the jobs appear.

- **Deploy (dev)** runs
- **Deploy (stage)** says *Waiting for review*
- **Deploy (prod)** says *Waiting for review*

**What each deploy job does:**

```bash
sops --decrypt secrets.enc.yaml     # only this machine has the key
terraform init                       # this environment's own database
terraform plan -out=tfplan
python3 scripts/policy_check.py --plan plan.json    # check before running
terraform apply tfplan
```

> "Each environment has its own key and its own database. The production machine cannot open the
> development file."

---

# STEP 9
## Approve staging, then production

**BROWSER** - click **Review deployments**   `3 minutes`

Approve staging. Watch it deploy.

Approve production. Watch it deploy.

> "Development goes out on its own. Staging and production each need a person."

---

# STEP 10
## Prove the machines changed

**TERMINAL**   `2 minutes`

```bash
pct config 321 | grep memory
```

> "Production now has 3 GB. It had 2."

**What made that happen:**

```hcl
module "workload" {
  replica_count = 2
  memory_mb     = 3072      # was 2048
}
```

One description, three sets of numbers. Production says 2 containers, development says 1.

---

# STEP 11
## Show what's running

**TERMINAL**   `2 minutes`

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  curl -s http://$h:8080/ ; echo
done
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-1",
  "version": "1.1.0"
}
```

> "Four machines. Each knows which environment it is. Two in production, because production says
> two."

---

# STEP 12
## Close

`2 minutes`

**Three things:**

**1.** Deleting a password from git doesn't remove it. Change the password first.

**2.** When something's wrong for nine months, the system made it easy to get wrong. Fix the system.

**3.** The hard part isn't running the scanner. It's choosing what's worth blocking, and defending
that choice.

> "Happy to go anywhere you'd like with it."

---

# Total: 36 minutes

---

# If you're running late

Cut in this order:

**1. Step 4** (showing the repository). Say instead: *"the repository has Terraform, a workflow file
and two small scripts."*

**2. Step 10** (proving memory changed). The deploy going green is proof enough.

**3. Step 9's production approval.** Approve staging only, say production works the same way.

That gets you to **28 minutes**.

---

# Never cut

- **Step 3** - the `git show` moment
- **Step 6** - the pull request BLOCKED
- **Step 12** - the three closing points

---

# If something breaks

**A container doesn't answer:** you're on your Mac. Those networks only exist on the server.

**A command isn't found:** wrong machine. Step 5 is your Mac. Everything else is the server.

**The pipeline fails:** read the error out loud. A pipeline that stops a bad change in front of an
audience is a better advert than one that quietly works.

**You don't know the answer:** say so. "I don't know, I'd check X."
