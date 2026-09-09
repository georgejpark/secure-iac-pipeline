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
