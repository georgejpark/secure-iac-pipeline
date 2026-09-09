# Secrets don't leave git

### A security pipeline for infrastructure as code

**George Park** · Senior DevSecOps Engineer candidate · Texas Mutual · September 2026

> **What you're about to see.** A working pipeline that blocks two kinds of change from
> reaching an environment: leaked credentials, and insecure infrastructure. Everything in this
> document was produced by running it — no figure here is an estimate.
>
> Repository: **github.com/georgejpark/secure-iac-pipeline**

---

## 1. The problem, in one page

While inventorying a platform's repositories ahead of a migration, a routine check turned up
credential material committed to source control:

| | |
|---|---|
| Private keys committed to one repository | **112** |
| Distinct keys among them | 104 |
| Certificates still valid | 98 |
| **Production hostnames affected** | **21** |
| Months exposed before anyone noticed | **9** |
| Private keys in the repository's *first* commit | **63** |

**It was not carelessness.** The repository's setup scripts created Kubernetes TLS secrets by
reading private keys directly out of the checked-out working tree:

```bash
kubectl create secret tls my-app-tls \
  --cert="$repo/config/my-app/prod/certs/host.fullchain.pem" \
  --key="$repo/config/my-app/prod/certs/host.key.pem"
```

For that command to work from a clone, the key has to *be* in the clone. Onboarding a service
**required** committing its private key. The exposure was not a mistake in the process — it was the
process.

Sixteen commits added key material over nine months. Every one passed code review, with messages as
ordinary as *"Add TLS certs for reporting-ui (dev/uat/stage/prod)"*.

---

## 2. Why the obvious fix doesn't work

A second repository had a `.env` with 74 credentials. The team **noticed and responded** — the very
next commit was titled *"Add utility for encrypting/decrypting .env files."*

They added encryption. They gitignored the file. They deleted it. By every code-review standard the
repository then looked correct.

The plaintext was still one command away:

```
$ git show <commit>:.env
DATABASE_URL=postgresql://claims_app:...@db.internal:5432/claims
AWS_SECRET_ACCESS_KEY=...
JWT_SIGNING_KEY=...
```

**Deleting a file from git does not remove it.** It unlinks it from the tip of the branch. The blob
stays in the object store and travels with every clone, every fork, and every CI cache.

### What actually works — and the order matters more than the steps

| | Action | Time | Effect |
|---|---|---|---|
| **1** | **Rotate the credential** | minutes | The only step that reduces risk *today* |
| **2** | Rewrite history (`git filter-repo`), force-push, garbage collect | days | Must reach every fork, PR ref and existing clone |

Most people do these in the opposite order, because rewriting history feels like the real fix. While
that coordination happens, the credential is still live.

---

## 3. The pipeline

![Pipeline control flow](img/pipeline-flow.png)

Four gates, ordered by cost. The earlier a finding is caught, the cheaper it is to fix.

| Gate | Tool | Catches | Blocks? |
|---|---|---|---|
| **0** | pre-commit + gitleaks | Secrets, before a commit exists | locally |
| **1** | gitleaks in CI (`fetch-depth: 0`) | Secrets anywhere in **history** | yes |
| **2** | Checkov | Insecure Terraform | on the blocking list only |
| **3** | AI triage | Explains, orders, flags false positives | reports only |
| **4** | Deploy policy gate | Proxmox deploy safety | yes |

### One line that decides whether gate 1 works at all

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0        # not optional
```

GitHub's default checkout fetches **one commit**. A secret committed earlier and deleted later — the
case that actually matters — is invisible without this. It is the most common reason a secret
scanning pipeline silently does nothing.

---

## 4. The number worth discussing

Checkov reports **24 findings against 110 lines of Terraform.**

That ratio is the real engineering problem. A tool reporting 24 issues on a small file gets muted
within a week — and once a team ignores the tool, they ignore the finding that mattered too.

| Tier | Count | Meaning |
|---|---|---|
| **Blocking** | 10 | Each is a plausible incident report on its own |
| **Promotion-gated** | 4 | Blocking in stage and prod, advisory in dev |
| **Advisory** | 5 | Real, but cost and retention *decisions* |
| **Reported** | 5 | Visible, not enforced |

### One finding deliberately **not** blocking

```python
"CKV_AWS_23": "security group rule has no description — hygiene, not a vulnerability"
```

It is untidy. It is not unsafe. Blocking a merge over a missing description teaches a team that the
security pipeline is an obstacle — and spends the credibility needed for *"this bucket is readable by
the entire internet."*

### Three documented false positives

`CKV_AWS_111`, `CKV_AWS_356`, `CKV_AWS_109` fire on the KMS key policy. Checkov is technically right
and practically wrong: it is AWS's own documented default key policy, and removing it makes the key
unrecoverable. Suppressed **in code with the reason attached** — never in a central ignore file where
the next engineer will not find it.

---

## 5. Where the AI sits — and where it does not

| Deterministic | The model |
|---|---|
| Checkov detection | Orders the findings |
| The blocking list (version-controlled) | Writes the explanation |
| The pass/fail gate | Flags likely false positives |

**With no API key, the gate behaves identically** — same exit code, same blocking list, plainer
wording. If a language model decides whether a merge is safe, an API outage becomes a security bypass.

---

## 6. Where it runs

![System architecture](img/system-architecture.png)

CI does not run on GitHub-hosted runners. It runs on three self-hosted runners on a Proxmox host,
**one per environment**, each in an unprivileged container on its own isolated network segment.

### Why three runners rather than one

With a shared runner, a pull request touching **dev** executes arbitrary code on the same machine
that later deploys **production**. A compromised dev change can leave something behind for the prod
job, or read the credentials that job obtains. That is a **privilege escalation path from dev to
prod**.

### Three isolation boundaries, not one

| Boundary | Control | Proven by |
|---|---|---|
| **Network** | No route between environment segments | `dev → prod` blocked on ICMP and TCP |
| **Cryptographic** | One age key per environment, private key only on its own runner | dev and stage cannot decrypt prod secrets |
| **Database** | `pg_hba` restricts each role to its own subnet | dev runner refused **even holding the correct prod password** |

That last row is the one worth pausing on: a leaked credential alone is not enough.

---

## 7. State and secrets, without a cloud account

| Concern | Solution | Why |
|---|---|---|
| **Terraform state** | PostgreSQL `pg` backend, one database per environment | Advisory locks give real state locking — what S3 + DynamoDB buys on AWS |
| **Secrets** | SOPS with one age key per environment | Encrypted files are committed deliberately; only the matching runner can open them |
| **Cloud auth** | GitHub OIDC federation | No long-lived credential exists to steal |

`encrypted_regex` encrypts **values only**, so a reviewer can see *which* secret changed in a diff
without seeing what it changed to.

---

## 8. Verified results

Reproduce with `make scan`, `make scan-insecure`.

**Clean configuration passes:**

```
dev     0 blocking   10 advisory   exit 0
stage   0 blocking    8 advisory   exit 0
prod    0 blocking    8 advisory   exit 0
```

**The same insecure Terraform, blocked harder on promotion:**

```
dev     exit 1   10 blocking
stage   exit 1   14 blocking
prod    exit 1   14 blocking
```

The extra four are controls dev is allowed to skip. Dev *should* be cheaper — losing a dev database
costs an afternoon. A pipeline pretending every environment is identical is one people route around.

**Real infrastructure, deployed by the pipeline:**

```
301  app-dev-1
311  app-stage-1
321  app-prod-1
322  app-prod-2      ← two replicas, delete protection, boot persistence
```

---

## 9. Benefits

| Benefit | Why it matters |
|---|---|
| Detection moves left | A secret caught pre-commit costs nothing; caught after push it costs a rotation, a history rewrite across every fork, and an incident |
| The security decision is explicit | Ten blocking policies in version control, each justified — reviewable by an engineer or an auditor |
| Noise is managed, not ignored | 24 findings sorted into four tiers, with one deliberately un-blocked |
| Environments get proportionate rigour | Dev moves fast, prod does not, one pipeline |
| No standing cloud credentials | Nothing static to steal, nothing to rotate on a schedule |
| Blast radius is contained | Three independent isolation boundaries, each verified |
| It degrades safely | No API key, runner down — the gate still works |

---

## 10. Honest trade-offs

Stated because the strengths are only believable alongside the costs.

| | Pro | Con |
|---|---|---|
| **Pipeline** | Catches secrets and IaC flaws before deployment | Pre-deployment only — nothing about runtime, drift, containers or dependencies |
| | Short, defensible blocking list keeps the tool credible | The list is a judgment call, tuned for regulated data, and needs negotiating locally |
| | ~1 minute per pull request | Still a minute, on every PR, forever |
| **AI triage** | Turns 24 raw findings into a ranked plain-English comment | Costs money per run and adds a dependency |
| | Cannot affect pass/fail, so an outage is not a bypass | Which also caps how much value it can add |
| **Self-hosted runners** | Data residency and auditability | You now own machines: patching, disk, uptime |
| | Isolation removes the dev→prod escalation path | Three runners is three times the maintenance of one |
| | No inbound exposure | A runner outage blocks CI until you fail back to hosted |

**The honest summary.** The biggest risk here is not technical. It is that the blocking list loses
credibility and people route around it. That is why the list is short, why every entry is justified
in writing, and why dev is allowed to be cheaper than prod.

---

## 11. What this deliberately does not do

| Not covered | Where it would go |
|---|---|
| Container image scanning | Trivy or Grype as another gate, same pattern |
| Dependency / SCA scanning | Dependabot plus `pip-audit` |
| Runtime and cloud posture | AWS Config, Security Hub, or a CSPM |
| Custom organisational policy | OPA/Rego, or Checkov custom policies |
| Drift detection | Scheduled `terraform plan`, alert on a non-empty diff |

---

## 12. Three things to take away

1. **Deleting a secret from git does not remove it.** The fix that feels thorough leaves you exposed
   while looking handled. Rotate first, rewrite second.

2. **When something is wrong for nine months and nobody catches it, the system made the wrong thing
   easy.** Fix what is easy, not the people.

3. **The hard part is not running the scanner. It is deciding what is worth blocking** — and being
   able to defend that list to an engineer and to an auditor.

---

*Questions welcome at any point.*
