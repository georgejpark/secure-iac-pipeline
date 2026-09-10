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
        I clone the repository
                 |
        I make a branch
                 |
        I change one number
                 |
        I commit  ------------> a hook checks for passwords first
                 |
        I push
                 |
        I open a pull request
                 |
   +-------------+-------------+
   |             |             |
 secrets      terraform     write a
  check        checks       comment
   |             |             |
   +-------------+-------------+
                 |
        anything blocking?  ---- yes ----> STOPPED. fix it.
                 |
                 no
                 |
        somebody approves it
                 |
        I merge to main
                 |
   +-------------+-------------+
   |             |             |
  DEV          STAGE         PROD
 goes out     waits for     waits for
  on its       someone       someone
   own        to approve    to approve
   |             |             |
   +-------------+-------------+
                 |
        terraform builds the server
                 |
        the deploy step installs
        the application on it
                 |
        the new server answers
```

---

# Step by step

## 1. Get the code

```bash
git clone git@github.com:georgejpark/secure-iac-pipeline.git
```

## 2. Make a branch

```bash
git checkout -b demo/TM-118-third-production-server
```

Never work directly on `main`.

## 3. Change one number

File: `terraform/deploy/prod/main.tf`

```
replica_count = 2      becomes      replica_count = 3
```

Development and staging have their own files. They aren't affected.

## 4. Commit

```bash
git commit -m "TM-118: add a third production server"
```

Before this saves, a hook runs. It looks for passwords and API keys.

If it finds one, the commit doesn't happen. Nothing has left my laptop.

## 5. Push and open a pull request

```bash
git push -u origin demo/TM-118-third-production-server
gh pr create --base main
```

This is what starts the pipeline.

## 6. The pipeline looks for passwords

It reads **every commit ever made**, not just mine.

That matters. A password committed last year and deleted since would be invisible if it only looked
at today's files.

If it finds one, the pull request stops here.

## 7. The pipeline checks the infrastructure code

This is **Checkov**. It reads Terraform and looks for unsafe settings.

Examples of what it stops:

- A storage bucket anyone on the internet can read
- SSH open to the whole world
- A database with no encryption

It runs three times. Once per environment.

- Development blocks **10** things
- Staging blocks **14**
- Production blocks **14**

The extra four are things development is allowed to skip.

## 8. The pipeline writes a comment

It finds 24 problems in 110 lines of code.

Nobody reads 24 findings. They turn the tool off instead.

So a script sorts them:

- **10** stop the merge
- **5** are advice
- **9** are noted

Then it writes a comment in plain English.

## 9. The pull request is blocked

It says:

```
BLOCKED - Review required
```

## 10. Somebody approves it

I cannot approve my own pull request. GitHub refuses:

```
Can not approve your own pull request
```

Someone else has to look at it.

## 11. I merge

Merging is what allows a deployment. Nothing deploys before this.

## 12. Development deploys by itself

No approval needed. It goes.

## 13. Staging waits

GitHub says *Waiting for review*. Someone clicks approve.

## 14. Production waits

Same again. Someone clicks approve.

## 15. Terraform builds a new server

The file said two production servers. It now says three. Terraform works out that one is missing and
creates it.

```
proxmox_virtual_environment_container.app[2]: Creation complete
```

That machine is empty. Terraform talks to the Proxmox API to build machines. It never logs into
them.

## 16. The deploy step installs the application

```bash
/root/install-app.sh prod
```

```
environment=prod  version=1.1.0  containers=3
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
  app-prod-3 (323)  installing 1.1.0 ...
    app-prod-3 serving {"version": "1.1.0"}
done
```

Two things worth noticing.

**It skipped the servers that were already working.** It asks each one what it is serving before it
touches anything, so running it twice changes nothing.

**It waits for the health check.** The application answers 503 for the first two seconds on purpose.
A check that fires immediately after a restart would race it and report a failure that isn't real.

On each container it does seven things: creates a service account so the app does not run as root,
installs Python if missing, copies the release into its own folder, builds a virtual environment,
moves the `current` symlink, installs a systemd unit that points at `current` rather than at a version
number, and waits for health to pass. Moving that symlink *is* the release, which is why a rollback
is a symlink move and not a redeploy.

## 17. The new server answers

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

# Why each environment is separate

Development, staging and production are on separate networks.

They cannot reach each other. Tested in both directions.

If somebody breaks into development, they have reached development. Nothing else.

Each one also has its own encryption key and its own database. The development machine physically
cannot read production's passwords.
