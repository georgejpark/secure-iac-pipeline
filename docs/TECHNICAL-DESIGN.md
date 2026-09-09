# Secure IaC Pipeline — Technical Design

**Author:** George Park
**Date:** September 2026
**Audience:** Engineering panel, Texas Mutual
**Status:** Implemented and verified. Every figure in this document was produced by running the pipeline.

---

## 1. The problem this solves

### 1.1 What I found

While inventorying a platform's repositories for a migration, a routine coverage check turned up
credential material committed to source control. The final count:

| What | Count |
|---|---|
| Unencrypted private key files in one cluster-bootstrap repository | 112 |
| Distinct private keys among them | 104 |
| Certificates still valid at the time of the finding | 98 |
| **Distinct production hostnames affected** | **21** |
| Kubernetes `Secret` manifests committed to the same repository | 50 |
| Credential values inside those manifests | 98 |
| JWT signing private keys among them | 12 |
| Months the earliest key had been exposed | 9 |

The first commit in that repository — titled *"Starting up the repository"* — already contained
63 private keys.

### 1.2 Why it happened

Not carelessness. The repository's own setup scripts created Kubernetes TLS secrets by reading
private keys **directly out of the checked-out working tree**:

```bash
kubectl create secret tls my-app-tls \
  --cert="$repo/config/my-app/prod/certs/my-app.example.com.fullchain.pem" \
  --key="$repo/config/my-app/prod/certs/my-app.example.com.key.pem"
```

For that command to succeed from a clone, the key has to be in the clone. **Onboarding a service
required committing its private key.** The exposure was not a mistake in the process; it *was* the
process.

Three things let it run for nine months:

1. **No `.gitignore` at all.** Nothing was ever excluded from tracking.
2. **No pre-commit or CI secret scanning.** Sixteen commits adding key material passed review.
3. **The commit messages read as ordinary work.** *"Add TLS certs for reporting-ui
   (dev/uat/stage/prod)"* describes a legitimate task. Nothing in the log signalled a problem.

### 1.3 The part that changed how I think about this

A different repository in the same estate had a `.env` file with 74 credentials committed. The team
**noticed**, and responded. The very next commit was:

> *"Add utility for encrypting/decrypting .env files"*

They added encryption. They gitignored the file. They deleted it from the working tree. By every
code-review standard the repository now looked correct.

The plaintext was still one command away:

```bash
$ git show b549cb9:.env
DATABASE_URL=postgresql://claims_app:...@db.internal:5432/claims
AWS_SECRET_ACCESS_KEY=...
JWT_SIGNING_KEY=...
```

**Deleting a file from git does not remove it. It only unlinks it from the tip of the branch.** The
blob stays in the object store, travels with every clone, every fork, and every CI cache, and is
retrievable by anyone with read access.

This is the single most important idea in this document, because the *remediation instinct is wrong*.
The fix that feels thorough — delete, ignore, encrypt — produces a repository that scans clean and is
still fully compromised. Only two things actually work, and they must happen in this order:

1. **Rotate the credential.** Minutes. The only step that reduces risk today.
2. **Rewrite history** with `git filter-repo`, then force-push and have the platform team run
   garbage collection. Days, because forks, open PR refs and existing clones all hold the blob.

---

## 2. Design goals

| Goal | How it is met |
|---|---|
| Catch secrets before they are committed at all | `pre-commit` hook running gitleaks locally |
| Catch secrets already in history | gitleaks in CI with `fetch-depth: 0` |
| Catch insecure infrastructure before it is applied | Checkov against every environment |
| Keep findings actionable rather than noisy | A short, defensible blocking list; everything else advisory |
| Never let an AI outage become a security bypass | Detection is deterministic; the model only explains |
| Hold no long-lived cloud credentials | GitHub OIDC federation to short-lived AWS roles |
| Let dev move faster than prod without weakening prod | Environment-tiered policy |

---

## 3. Architecture

![Figure 1](img/pipeline-flow.png)

**Figure 1 — Security Pipeline control flow.** Four gates, ordered by cost.

Four gates, ordered by cost. The earlier a finding is caught, the cheaper it is to fix.

### Gate 0 — pre-commit (local)

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks: [{ id: gitleaks }]
```

The cheapest gate in the system. A secret caught here never becomes a commit, which means it never
needs a rotation, a history rewrite, or an incident report. Everything downstream is a more expensive
version of this check.

### Gate 1 — secret scanning (CI)

Runs **first and alone**, before any other job. A leaked credential is already an incident by the
time CI sees it; a Terraform misconfiguration is still only a proposal. They do not deserve the same
urgency.

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # not optional
```

`fetch-depth: 0` is the most important line in the pipeline. GitHub's default checkout fetches a
single commit. A secret that was committed and later deleted — the case that actually matters — is
invisible to a shallow scan. **This one default is the most common reason a secret-scanning pipeline
silently does nothing.**

### Gate 2 — infrastructure as code

Checkov runs as a matrix across `dev`, `stage` and `prod`.

### Gate 3 — triage

Findings are classified, then explained. Detail in §5.

### Deploy — OIDC

`terraform plan` on every PR, `apply` to dev on merge, `apply` to stage and prod behind a required
reviewer on a GitHub Environment. Authentication is OIDC federation; see §6.

---

## 3a. Where it actually runs

![Figure 2](img/system-architecture.png)

**Figure 2 — System architecture.**

CI does not run on GitHub-hosted runners. It runs on three self-hosted runners on a Proxmox host
(`pve2`, 104 vCPU, 62 GB, Debian 13), one per environment, each in its own unprivileged LXC container
on its own isolated network segment.

| | dev | stage | prod |
|---|---|---|---|
| Container | `ci-dev` (201) | `ci-stage` (202) | `ci-prod` (203) |
| Bridge | `vmbr1` | `vmbr2` | `vmbr3` |
| Subnet | `10.10.10.0/24` | `10.20.10.0/24` | `10.30.10.0/24` |
| Runner labels | `self-hosted, dev` | `self-hosted, stage` | `self-hosted, prod` |
| Resources | 4 vCPU / 4 GB | 4 vCPU / 4 GB | 4 vCPU / 4 GB |

### Why three runners rather than one

This is the part worth defending in a design review.

With a single shared runner, a pull request touching **dev** executes arbitrary code on the same
machine that later deploys **production**. A malicious or merely compromised dev change can leave
something behind that fires during the prod job, or read credentials that job obtains. That is a
**privilege escalation path from dev to prod**, and it is the main reason GitHub advises against
sharing self-hosted runners across trust levels.

Three runners remove it. The prod runner only ever executes prod jobs and is the only one entitled to
the prod role. Secret scanning runs on the **dev** runner deliberately — it only reads source and
needs no cloud access, so it is given none.

### The isolation is real, and it was tested

Each segment is an internal bridge with no physical port. The host provides NAT egress so runners can
reach GitHub, and a forwarding policy (`runner-net.service`) drops every cross-segment path:

```
-A RUNNER_NAT -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
-A RUNNER_FWD -s 10.10.10.0/24 -d 10.30.10.0/24 -j DROP
-A RUNNER_FWD -s 10.20.10.0/24 -d 10.30.10.0/24 -j DROP
-A RUNNER_FWD -s 10.30.10.0/24 -d 10.10.10.0/24 -j DROP
```

Verified in both directions:

```
dev  -> prod  ICMP     BLOCKED
dev  -> prod  tcp/22   BLOCKED
stage-> prod  ICMP     BLOCKED
prod -> dev   ICMP     BLOCKED
each -> api.github.com HTTP 200
```

### No inbound port is open

The runners **poll GitHub outbound**; GitHub never connects in. There is no port forward, no exposed
service, and no inbound firewall exception. That property is what makes self-hosting CI acceptable
without putting a listener on the public internet.

### Why self-host at all

For a regulated insurer this is not a cost decision. It is data residency and auditability: being
able to answer "where was this code built, on whose hardware, and who could reach that machine" with
something more specific than "a shared cloud runner". The gates are identical either way — only the
execution location changes, which is a one-line `runs-on` difference.

---

## 3b. State, secrets and real deploys

### Terraform state — PostgreSQL, not S3

There is no cloud account, so the `backend "s3"` block was never usable. State lives in the native
`pg` backend: one database and one role per environment, on a dedicated management segment.

Postgres advisory locks give **real state locking**, which is precisely what S3 + DynamoDB provides on
AWS. Without locking, two applies racing each other corrupt state — not a theoretical risk.

`pg_hba.conf` restricts each role to its own subnet:

```
host  tfstate_dev    tf_dev    10.10.10.0/24   scram-sha-256
host  tfstate_stage  tf_stage  10.20.10.0/24   scram-sha-256
host  tfstate_prod   tf_prod   10.30.10.0/24   scram-sha-256
```

Verified: the dev runner, supplied with the **correct prod password**, is still refused —

```
FATAL: no pg_hba.conf entry for host "10.10.10.10", user "tf_prod", database "tfstate_prod"
```

A leaked credential on its own is not sufficient.

### Secrets — SOPS with per-environment age keys

One age keypair per environment. The **private key exists only on the matching runner**, so the prod
runner is the only thing that can decrypt prod credentials. This is not a new control; it is the
network isolation of §3a extended into cryptography.

Encrypted files are committed **deliberately**. `encrypted_regex` encrypts values but leaves keys
readable, so a reviewer can see *which* secret changed in a diff without seeing what it changed to:

```yaml
username: tf_prod                    # readable
database: tfstate_prod               # readable
password: ENC[AES256_GCM,data:...]   # encrypted
pve_token_id: terraform@pve!ci-prod  # readable
pve_token_secret: ENC[AES256_GCM,...]# encrypted
```

Verified: dev and stage runners both fail to decrypt the prod file —
*"no master key was able to decrypt the file."*

### Real deployments

`terraform/deploy/{dev,stage,prod}` provision LXC containers on Proxmox through the `bpg/proxmox`
provider, applied by the pipeline on each environment's own runner:

```
301  app-dev-1                       1 replica,  no boot persistence, no protection
311  app-stage-1                     1 replica,  boot persistence
321  app-prod-1                      2 replicas, boot persistence + delete protection
322  app-prod-2
```

The AWS definitions in `terraform/envs/` remain as the **scanned artifact** — public-S3 and
unencrypted-RDS are the findings worth demonstrating, and Proxmox has no equivalent failure modes.

### The deploy policy gate, and why it had to be written by hand

**Checkov ships no rules for the Proxmox provider.** The deploy code therefore passed every scan —
not because it was safe, but because nothing recognised it. That is the same class of failure as the
zero-byte scan in §7a: a control that inspects nothing and reports success.

Custom Checkov policies were the obvious fix and do not work: `--external-checks-dir` silently loads
nothing in Checkov 3.3.16. This was verified against `aws_s3_bucket` — a resource type Checkov
definitely scans — so it is not a Proxmox-specific problem.

The policy therefore lives in `scripts/policy_check.py` and runs against `terraform show -json` of
the **plan** rather than the source. The plan is what will actually be created, with variables
resolved and modules expanded; source-level checks can be defeated by a default changing elsewhere.

| Policy | Requirement | Enforced in |
|---|---|---|
| `PVE-1` | Container must be unprivileged | dev, stage, prod |
| `PVE-2` | Network interface firewall enabled | dev, stage, prod |
| `PVE-3` | Restart after host reboot | stage, prod |
| `PVE-4` | Delete protection | prod |

Verified: clean prod passes 8 checks across 2 containers; prod with `protect = false` fails 2 and
exits 1.

---


## What is actually running

**Say what this is, precisely.** Terraform provisions **LXC containers** on a Proxmox host. Ansible
installs a small **Python HTTP service** into them under systemd. There is **no Docker, no Kubernetes
and no FastAPI** in this stack.

```
app-dev-1    10.10.10.20:8080   {"status":"ok"}  {"version":"1.0.0"}
app-stage-1  10.20.10.20:8080   {"status":"ok"}  {"version":"1.0.0"}
app-prod-1   10.30.10.20:8080   {"status":"ok"}  {"version":"1.0.0"}
app-prod-2   10.30.10.21:8080   {"status":"ok"}  {"version":"1.0.0"}
```

Production runs two containers because production specifies two.

### Terraform provisions the machine; Ansible installs the application

Keeping those separate is deliberate — rebuilding a container should not mean redeploying the app,
and redeploying the app should not mean touching infrastructure.

The Ansible role uses a release directory with a symlink:

```
/opt/rapta/inspection/releases/1.0.0/
/opt/rapta/inspection/current -> releases/1.0.0
```

**Rollback is a symlink flip, not a redeploy.**

### The healthcheck asserts the version, not just liveness

A deploy that silently left the old code running **fails** rather than reporting success. That is the
same principle as everything else here: a control that passes while doing nothing is worse than no
control, because it manufactures confidence.


## Deployment approval

| Environment | Gate |
|---|---|
| `dev` | applies automatically on merge |
| `stage` | **waits for a named reviewer** |
| `prod` | **waits for a named reviewer** |

Configured as GitHub Environment protection rules. Verified end to end: the run pauses, the approver
is notified, and the deploy only proceeds once approved.

Note a GitHub constraint worth knowing: **you cannot approve your own pull request.** Environment
approvals are different and do permit self-approval, which is why the promotion gate sits there
rather than on the PR.

---

## 4. Environment model

Three environments, one module. The environments differ only in the variables they pass, so they
cannot drift apart in security posture — only in scale and cost.

```
terraform/
├── modules/claims-platform/    one definition of every resource
├── envs/dev/                   thin root: calls the module
├── envs/stage/
├── envs/prod/
├── bootstrap/                  the GitHub OIDC trust, applied once per account
└── insecure/                   deliberately vulnerable, for the demo
```

| Setting | dev | stage | prod |
|---|---|---|---|
| Multi-AZ database | no | **yes** | **yes** |
| Deletion protection | no | **yes** | **yes** |
| Backup retention | 7 days | 14 days | 30 days |
| Instance class | `db.t3.medium` | `db.t3.large` | `db.r6g.xlarge` |
| Trusted CIDR | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| Encryption at rest (CMK) | **yes** | **yes** | **yes** |
| Public access blocked | **yes** | **yes** | **yes** |
| IAM database auth | **yes** | **yes** | **yes** |

The bottom three rows never vary. Security controls are identical in all three environments;
resilience and cost controls are what change.

### Why stage matters

Stage mirrors production's **security posture exactly** and differs only in scale. A control that is
absent in stage is a control that has never been tested. That is the entire reason stage exists.

---

## 5. Triage: the part that decides whether anyone uses this

### 5.1 The real problem

Checkov reports **24 findings against 110 lines of Terraform**.

That ratio is the actual engineering problem, and it is why most scanning initiatives quietly fail.
A tool that reports 24 issues on a small file gets muted within a week — and once a team learns to
ignore the tool, they ignore the finding that mattered along with the other 23.

So the pipeline sorts findings into three tiers.

### 5.2 Blocking — ten policies

Each is a plausible incident report on its own.

| Policy | What it means |
|---|---|
| `CKV_AWS_20` | S3 bucket readable by anyone on the internet |
| `CKV2_AWS_6` | S3 bucket has no public access block |
| `CKV_AWS_24` | SSH open to `0.0.0.0/0` |
| `CKV_AWS_260` | HTTP open to `0.0.0.0/0` |
| `CKV_AWS_17` | RDS instance publicly accessible |
| `CKV_AWS_16` | RDS storage not encrypted at rest |
| `CKV_AWS_145` | Claims bucket not encrypted with a customer-managed key |
| `CKV_AWS_161` | IAM database authentication disabled — long-lived passwords |
| `CKV_AWS_21` | S3 versioning off — no tamper or ransomware recovery |
| `CKV_AWS_18` | S3 access logging off — no audit trail of who read claims data |

### 5.3 Promotion-gated — four policies

Blocking in **stage and prod**, advisory in **dev**.

| Policy | What it means |
|---|---|
| `CKV_AWS_293` | Database deletion protection disabled |
| `CKV_AWS_157` | Database not Multi-AZ |
| `CKV_AWS_129` | Database logs not exported — nothing to alert on |
| `CKV_AWS_118` | Enhanced monitoring disabled |

Dev is *allowed* to be cheaper. Losing a dev database costs an afternoon; losing a production one
costs a regulator conversation. A pipeline that refuses to acknowledge that difference is one people
route around.

The advisory message in dev still says the finding **will block on promotion**, so nobody is
surprised later.

### 5.4 Advisory — reported, never blocking

| Policy | Why not blocking |
|---|---|
| `CKV_AWS_144` | Cross-region replication — a DR and cost decision, not a vulnerability |
| `CKV2_AWS_61` | Lifecycle configuration — a retention policy decision |
| `CKV2_AWS_62` | Event notifications — observability, nice to have |
| `CKV2_AWS_5` | Security group not attached — a false positive when scanning module code |
| `CKV_AWS_23` | Security-group rule has no description — **untidy, not unsafe** |

`CKV_AWS_23` is deliberately not blocking, and I would defend that in a design review. Blocking a
merge because a rule lacks a description is exactly how a team learns that the security pipeline is
an obstacle rather than a safeguard. Spend that credibility on `CKV_AWS_20`.

### 5.5 Documented false positives

Three findings (`CKV_AWS_111`, `CKV_AWS_356`, `CKV_AWS_109`) fire on the KMS key policy. Checkov is
technically correct: the statement grants `kms:*` on `*`. It is also practically wrong — that is
AWS's **documented default key policy**, and removing it makes the key unmanageable and the data
unrecoverable.

It is suppressed **in code, with the reason written next to it**, rather than silently in a config
file where the next engineer will never find it. A suppression without a reason is indistinguishable
from an oversight six months later.

### 5.6 Where the AI sits, and where it does not

The model **explains and orders** findings. It **never decides pass/fail**.

```python
BLOCKING_POLICIES = { ... }          # the policy, in version control, human-reviewed
def blocking_set(environment): ...   # deterministic, testable, no network call
```

Design constraints, and the reason for each:

| Constraint | Why |
|---|---|
| Detection stays deterministic | If an LLM decides pass/fail, an API outage becomes a security bypass |
| Pre-filter before the API call | Findings are deduplicated and capped, so cost is bounded regardless of repo size |
| Never fail the build on an AI error | A triage outage must not block a deploy |
| Full offline fallback | With no API key it emits the same report from local rules |

The fallback is not a degraded mode bolted on afterwards — it is the primary path, and the model
improves the wording when it is available.

---

## 6. Authentication: no stored cloud credentials

There is **no AWS access key anywhere in this repository or its GitHub secrets.**

GitHub Actions requests a signed OIDC token; AWS validates it against a trust policy and returns
credentials that expire in an hour. There is nothing static for an attacker to steal from `secrets`,
and nothing to rotate on a schedule.

The security of the arrangement rests entirely on the trust policy conditions:

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:${var.github_org}/${var.github_repo}:environment:${var.environment}"]
}
```

Scoped to one repository **and** one GitHub Environment, so a workflow in a fork — or a job targeting
dev — cannot assume the production role.

> **The most common mistake in GitHub OIDC setups** is writing this as
> `repo:my-org/*`. That grants every repository in the organisation, including one an attacker can
> create. The condition must name the repository, and for production it should name the environment
> too.

---

## 7. Verified results

Reproduce all of it with `make scan` and `make scan-insecure`.

### Clean configuration passes

```
terraform/envs/dev     0 blocking   10 advisory    exit 0
terraform/envs/stage   0 blocking    8 advisory    exit 0
terraform/envs/prod    0 blocking    8 advisory    exit 0
```

63 Checkov checks pass against the module.

### Vulnerable configuration is blocked, and blocked harder on promotion

The **same** Terraform, scanned for each environment:

```
dev      exit 1    10 blocking
stage    exit 1    14 blocking
prod     exit 1    14 blocking
```

The extra four are the promotion-gated controls. This is the environment model working: code that is
acceptable in dev is stopped on the way to production, by the same pipeline, with no separate
configuration to maintain.

### The gate caught a real defect during development

While building this, I set `multi_az = false` in stage. The stage gate failed — correctly, since my
own policy requires Multi-AZ from stage upward. **I fixed the configuration rather than the policy.**
That is the choice the pipeline exists to force, and it is worth noting that it caught its author.

---

## 7a. The pipeline's first run failed, and the reason matters

The first push of this repository failed CI. The cause is worth recording, because it is the exact
failure this document argues against.

`gitleaks-action@v2` scans only the **pushed commit range**. On a repository's first push, that range
is `<first-commit>^..HEAD` — and the first commit has no parent. Git rejected the revision, the scan
covered nothing, and the action printed this:

```
ERR  [git] fatal: ambiguous argument 'd0c7705^..cc5aa75': unknown revision
WRN  scanned ~0 bytes (0)
WRN  no leaks found in partial scan
```

**"Scanned ~0 bytes" and "no leaks found" on consecutive lines.** The job happened to exit non-zero
here, so it was noticed. Had the range resolved to something valid but incomplete — a force-push, a
squashed history, a shallow clone — it would have reported a clean pass having examined almost
nothing, and nobody would have looked again.

That is worse than having no scanner, because it manufactures confidence. A control that cannot fail
loudly is not a control.

The fix was to stop using the range-scanning action and pin the gitleaks binary directly:

```yaml
- name: Scan the entire repository history
  run: |
    gitleaks detect --source . --config .gitleaks.toml \
      --redact --verbose --exit-code 1
```

Slightly slower. Scans everything, every run, with no dependence on what a commit range resolves to.

**The generalisable rule: verify that a security control actually inspected something.** A pass is
only meaningful alongside a count of what was examined. This is the same class of error as
`fetch-depth: 0` in §3 — in both cases the tool is installed, configured, reporting success, and
looking at nothing.

---

## 8. What this deliberately does not do

Stated so the gaps are deliberate rather than discovered later.

| Not covered | Where it would go |
|---|---|
| Container image scanning | Trivy or Grype as a third CI gate, same pattern |
| Dependency / SCA scanning | Dependabot plus `pip-audit` in the same job |
| Runtime and cloud posture | AWS Config, Security Hub, or a CSPM — this is pre-deployment only |
| Custom organisational policy | OPA/Rego, or a Checkov custom policy directory |
| Drift detection | A scheduled `terraform plan` with an alert on non-empty diff |

The blocking list is tuned for regulated data. It is a starting point for a conversation with a
security team, not a universal default.

---

## 9. If I were rolling this out for real

Ordered by what actually reduces risk soonest, which is not the same as what is easiest to demo.

1. **Week 1 — measure, do not block.** Run both scanners across every repository in report-only mode.
   You cannot negotiate a blocking list without knowing the true finding count.
2. **Week 2 — secrets only, and rotate what you find.** Turn on gitleaks blocking. Expect real
   findings in history. Rotate first, rewrite second.
3. **Week 3–4 — agree the blocking list with the security team.** Ten policies, each with a written
   justification. Everything else advisory. Resist the urge to block on all of them.
4. **Week 5 — pre-commit hooks.** Once developers trust that the list is short and fair, they will
   accept a local hook. Doing this first, before trust exists, produces workarounds.
5. **Ongoing — review the advisory tier quarterly.** Findings that stay advisory forever are either
   noise to be suppressed with a reason, or real work to be scheduled. Leaving them in limbo is how
   the list rots.

The order matters more than the tooling. Every step above is cheap; the expensive part is the
credibility of the blocking list, and that is spent the first time you block someone's merge for a
missing description.
