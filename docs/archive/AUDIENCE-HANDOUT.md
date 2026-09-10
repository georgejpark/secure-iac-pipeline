# A change, from my laptop to production

Follow along. Every command here is one I actually run.

---

## What we're going to do

Production is running out of memory during month-end close.

I'm going to give it more. Two gigabytes becomes three.

That's the whole change. Watching it travel is the point.


---

# The tools, in one line each

**gitleaks**

Searches your code for passwords, API keys and private keys that shouldn't be there.

It knows what secrets look like. An AWS key has a shape. So does a GitHub token. It reads every file
and every past commit looking for those shapes.

If it finds one, it stops the build.

---

**terraform fmt**

Tidies up the formatting of Terraform files. Spacing, indentation, alignment.

It doesn't change what the code does. It just makes every file look the same.

Why bother? Because when everyone formats differently, code reviews fill up with arguments about
spacing instead of the actual change.

`terraform fmt --check` fails the build if a file is untidy.

---

**terraform validate**

Checks the Terraform is valid before anyone tries to run it.

Missing brackets. A variable that doesn't exist. A typo in a resource name.

It catches mistakes in seconds instead of halfway through creating things.

---

**Checkov**

Reads Terraform and looks for unsafe settings.

A storage bucket anyone can read. A database with no encryption. SSH open to the internet.

It knows about a thousand of these patterns. I've picked which ones stop a merge.

---

**SOPS**

Encrypts passwords so they can be kept in the repository safely.

The file is committed. Anyone can see it. But the values are scrambled, and only the machine with the
right key can unscramble them.

---

**Terraform**

Creates the machines.

You describe what you want in a file. It works out what to create, change or delete.

---

**Ansible**

Installs software onto machines that already exist.

Terraform makes the box. Ansible puts the application on it.

---

# STEP 1. Get the code

I work on the Proxmox host, because that's where everything lives.

```
ssh root@192.168.1.132
cd /root/secure-iac-pipeline
git pull
```

---

# STEP 2. Make a branch

Never work on `main`. Ever.

```
git checkout -b demo/TM-104-increase-prod-memory
```

The branch name says what it's for. Anyone can read it later.

---

# STEP 3. Change one number

Open the production file:

```
terraform/deploy/prod/main.tf
```

Find this:

```
module "workload" {
  source = "../../modules/workload"

  environment   = "prod"
  replica_count = 2
  cores         = 2
  memory_mb     = 2048     <-- change this
}
```

Change `2048` to `3072`.

That's it. One number.

**Why this is the only place I change it:** development and staging have their own files. They aren't
affected. I can't accidentally resize the wrong environment.

---

# STEP 4. Commit it

```
git add -A
git commit -m "TM-104: raise production memory to 3 GB"
```

**Something happens before the commit is saved.**

A hook runs. It checks for passwords and API keys in what I'm committing.

If it finds one, the commit doesn't happen.

```
Detect hardcoded secrets....................Passed
Terraform fmt...............................Passed
Terraform validate..........................Passed
```

This is the cheapest place to catch a mistake. Nothing has left my machine yet.

---

# STEP 5. Push and open a pull request

```
git push -u origin demo/TM-104-increase-prod-memory
gh pr create --base main --title "TM-104: raise production memory to 3 GB"
```

Opening the pull request is what starts everything else.

---

# STEP 6. The pipeline starts

A file in the repository tells GitHub what to do. It lives here:

```
.github/workflows/security-pipeline.yml
```

It runs four jobs, in order. Nothing is skipped.

---

## Job 1. Look for secrets

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- run: gitleaks detect --source . --exit-code 1
```

**That `fetch-depth: 0` line matters more than it looks.**

By default GitHub only downloads the newest commit. So if somebody committed a password last year and
deleted it, a scan finds nothing.

`fetch-depth: 0` downloads the whole history. Every commit ever made.

If it finds anything, the pull request stops here.

---

## Job 2. Check the infrastructure code

This is Checkov. It reads Terraform and looks for unsafe settings.

```yaml
- run: checkov -d terraform/envs/${{ matrix.environment }} --output json
```

It runs **three times**. Once for development, once for staging, once for production.

Same code. Different rules.

- Development blocks **10** things
- Staging blocks **14**
- Production blocks **14**

The extra four are things development is allowed to skip. Losing a development box costs an
afternoon. Losing production costs a phone call from a regulator.

**Some examples of what it blocks:**

- A storage bucket anyone on the internet can read
- SSH open to the whole world
- A database with no encryption
- A database reachable from the internet

---

## Job 3. Explain the findings

Checkov reports 24 findings against 110 lines of Terraform.

Nobody reads 24 findings. They mute the tool instead.

So a script sorts them:

- **10 stop the merge.** Each one could be an incident.
- **5 are advice.** Real, but they're cost decisions, not security holes.
- **9 are noted.** Visible, not enforced.

Then it writes a comment on the pull request in plain English.

**One thing I want to be clear about:** the AI writes the explanation. It does not decide.

The list of what blocks is a hardcoded list in the repository that people review. If the AI service is
down, the pipeline works exactly the same. It just explains itself less well.

---

## Job 4. Stop the merge if anything is wrong

The pull request now says:

```
BLOCKED - Review required
```

---

# STEP 7. Somebody has to approve it

I cannot approve my own pull request. GitHub refuses:

```
Can not approve your own pull request
```

That's not a setting I chose. GitHub won't allow it.

Somebody else has to read the change and approve it.

**This is what the rule looks like:**

- 1 approval required
- 4 checks must pass
- No force-pushing
- Stale approvals are dismissed if I push again

---

# STEP 8. Merge

Once approved:

```
gh pr merge --squash --delete-branch
```

Merging is what authorises a deployment. Nothing deploys before this.

---

# STEP 9. Development deploys by itself

The moment the merge lands, development starts deploying.

No approval. No waiting.

Here's what happens inside that job:

**1. Decrypt the passwords**

```
sops --decrypt terraform/envs/dev/secrets.enc.yaml
```

The encrypted file is in the repository. That's on purpose.

The key that opens it exists on **one machine only**. the development runner.

The production runner cannot open the development file. The development runner cannot open the
production file. I've tested both directions.

**2. Get the current state**

```
terraform init -backend-config="conn_str=postgres://...@10.40.10.10/tfstate_dev"
```

Each environment has its own database. Development cannot see production's records. I tested that
with the correct production password and it was still refused, because the request came from the
wrong network.

**3. Work out what will change**

```
terraform plan -out=tfplan
```

**4. Check the plan before running it**

```
python3 scripts/policy_check.py --plan plan.json --environment dev
```

This one I wrote myself. Checkov has no rules for Proxmox, so this code would pass every scan just by
being unrecognised. That's the worst kind of pass.

It checks four things:

- The container must be unprivileged (always)
- It must restart after a reboot (staging and production only)
- It must have delete protection (production only)

**5. Apply it**

```
terraform apply tfplan
```

The container is resized.

---

# STEP 10. Staging waits for a person

Staging does not deploy automatically.

GitHub shows:

```
Deploy (stage) - Waiting for review
```

Somebody has to click Approve.

Then it runs the same five steps, against staging's own key, staging's own database, staging's own
network.

---

# STEP 11. Production waits too

Same again.

```
Deploy (prod) - Waiting for review
```

Somebody clicks Approve. Then production gets its extra memory.

Production has one more rule the others don't: **delete protection**.

I tried to destroy production with Terraform earlier. It refused. You have to turn that protection off
deliberately first. That's the point of it.

---

# What's running when this finishes

Four Linux containers on one server.

- One for development
- One for staging
- Two for production, because production runs two

Ask any of them who they are:

```
curl http://10.30.10.20:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-1",
  "version": "1.1.0"
}
```

---

# Two things worth knowing

## They can't talk to each other

Each environment is on its own network.

Development cannot reach production. Production cannot reach development. I tested both directions and
both are blocked.

So if somebody breaks into development, they've reached development. Nothing else.

## Rolling back is fast

The application lives in a folder named after its version:

```
releases/1.0.0
releases/1.1.0
current -> releases/1.1.0
```

To roll back, point `current` at the old folder and restart. Takes seconds. The old version never left
the disk.

---

# What I'd change if I had longer

**No container images yet.** Right now Ansible installs Python onto a running machine. Two machines can
drift apart. A container image can't. That's the next thing I'd do, and it would let me scan for known
vulnerabilities before anything runs.

**No Kubernetes.** For four containers on one server, it would cost more to run than it saves. If you
already run Kubernetes, the same checks sit in front of your manifests instead of my Terraform. Only
the last command changes.

**One person is a single point of failure.** I'm the only account on this repository, so I can't
approve my own work. In a real team that's a second engineer. It's the one gap I can't close on my own.
