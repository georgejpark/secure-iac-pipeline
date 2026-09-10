# secure-iac-pipeline

A working GitHub Actions pipeline that blocks two classes of change from
reaching a cloud environment: **leaked credentials** and **insecure
infrastructure-as-code**. Findings are triaged by an LLM into a plain-English
pull-request comment, with a deterministic fallback so the gate keeps working
when the model does not.

Built as a reference implementation, not a toy. Every number in this README was
produced by running the pipeline, not estimated.

---

## Why this exists

I was inventorying a platform's repositories when a routine check turned up
**112 unencrypted private keys committed to a cluster-bootstrap repository**,
covering 21 production hostnames. The earliest had been there nine months. The
first commit in the repository — literally titled "Starting up the repository" —
already contained 63 of them.

None of it was carelessness. The setup scripts created Kubernetes TLS secrets by
reading keys **directly out of the checked-out repository**:

```bash
kubectl create secret tls my-app-tls \
  --cert="$repo/config/my-app/prod/certs/my-app.example.com.fullchain.pem" \
  --key="$repo/config/my-app/prod/certs/my-app.example.com.key.pem"
```

For that command to work from a clone, the key has to be in the clone. Onboarding
a service *required* committing its private key. The repository had no
`.gitignore` at all, and no pre-commit or CI scanning. Sixteen commits adding key
material passed code review, each with a message as ordinary as
"Add TLS certs for reporting-ui (dev/uat/stage/prod)".

In a separate repository I found a `.env` with 74 credentials. The team had
noticed and responded — the very next commit was
*"Add utility for encrypting/decrypting .env files"*. It did not help. The
plaintext blob was still one `git show` away, because **adding encryption after
the fact does not remove what is already in history**.

That is what this pipeline is built to prevent, in the order that actually
matters.

---

## What it does

| Gate | Tool | Catches | Blocks merge |
|---|---|---|---|
| 0 | `pre-commit` + gitleaks | secrets, before they become a commit | locally |
| 1 | gitleaks in CI, `fetch-depth: 0` | secrets anywhere in **history** | yes |
| 2 | Checkov | insecure Terraform | only on the blocking list |
| 3 | AI triage | explains findings, orders them, flags false positives | reports only |

Gate 1 runs first and alone. A leaked credential is already an incident by the
time CI sees it; a Terraform misconfiguration is still only a proposal.

---

## Verified results

Reproduce all of this locally with `make demo`.

```
terraform/insecure/   24 findings  →  10 blocking  →  exit 1  →  merge blocked
terraform/secure/     63 passed     →   0 blocking  →  exit 0  →  merge allowed
```

**24 findings from 110 lines of Terraform.** That ratio is the real engineering
problem. A scanner that reports 24 issues on a small file gets muted within a
week, and once a team learns to ignore it they ignore the one that mattered
too. So the pipeline splits them three ways:

- **10 blocking** — each one is a plausible incident report. Public S3 bucket,
  SSH open to the world, unencrypted database, credentials in a variable.
- **5 advisory** — real, but a cost or retention *decision*: cross-region
  replication, lifecycle rules. Tracked so the choice is deliberate, not gated.
- **9 other** — reported, not enforced.

One finding is deliberately **not** blocking: `CKV_AWS_23`, a security-group
rule with no description. It is untidy, not unsafe. Blocking a merge on it is
exactly how a team learns to ignore the scanner.

Three more (`CKV_AWS_111`, `CKV_AWS_356`, `CKV_AWS_109`) fire on the KMS key
policy. Checkov is technically right and practically wrong: that statement is
AWS's documented default key policy, and removing it makes the key
unrecoverable. It is suppressed **in code, with the reason attached** — not
silently in a config file where the next engineer will never find it.

---

## Where CI runs

Not on GitHub-hosted runners. Three self-hosted runners on a Proxmox host, one per environment, each
in an unprivileged LXC container on its own isolated network segment.

| | dev | stage | prod |
|---|---|---|---|
| Container | `ci-dev` | `ci-stage` | `ci-prod` |
| Segment | `10.10.10.0/24` | `10.20.10.0/24` | `10.30.10.0/24` |

**Why three and not one.** With a shared runner, a pull request touching dev executes on the same
machine that later deploys production — a privilege escalation path from dev to prod. Three runners
remove it: the prod runner only ever runs prod jobs, and nothing on the dev segment can route to it.

Verified in both directions:

```
dev   -> prod  ICMP/tcp22   BLOCKED
stage -> prod  ICMP         BLOCKED
prod  -> dev   ICMP         BLOCKED
each  -> api.github.com     HTTP 200
```

Runners connect **outbound only** — no inbound port is open. Full build in
[`docs/archive/RUNNER-INFRASTRUCTURE.md`](docs/archive/RUNNER-INFRASTRUCTURE.md).


## What is actually running

**Say what this is, precisely.** Terraform provisions **LXC containers** on a Proxmox host. A
shell script on the host, `scripts/install_app.sh`, installs a small **Python HTTP service** into
them under systemd. There is **no Docker, no Kubernetes, no Ansible and no FastAPI** in this stack.

```
app-dev-1    10.10.10.20:8080   {"status":"ok"}  {"version":"1.1.0"}
app-stage-1  10.20.10.20:8080   {"status":"ok"}  {"version":"1.1.0"}
app-prod-1   10.30.10.20:8080   {"status":"ok"}  {"version":"1.1.0"}
app-prod-2   10.30.10.21:8080   {"status":"ok"}  {"version":"1.1.0"}
```

Production runs two containers because production specifies two.

### Terraform provisions the machine; the install script installs the application

Keeping those separate is deliberate — rebuilding a container should not mean redeploying the app,
and redeploying the app should not mean touching infrastructure. Terraform talks to the Proxmox API
and never logs into a container; the install runs from the host, where `pct exec` can reach every
container, and skips any that is already serving the right version.

It is a shell script rather than Ansible because the job is seven steps on one machine type. Ansible
earns its place with an inventory and many machine types; here it would be a dependency to install
and a playbook to maintain for the same seven steps.

The script uses a release directory with a symlink:

```
/opt/rapta/inspection/releases/1.0.0/
/opt/rapta/inspection/releases/1.1.0/
/opt/rapta/inspection/current -> releases/1.1.0
```

**Rollback is a symlink flip, not a redeploy.**

### The healthcheck asserts the version, not just liveness

A deploy that silently left the old code running **fails** rather than reporting success. That is the
same principle as everything else here: a control that passes while doing nothing is worse than no
control, because it manufactures confidence.

## Quick start

```bash
make install     # pre-commit hooks + python tooling
make scan        # checkov + AI triage against both terraform trees
make demo        # the secret-persistence demo (see below)
make secrets     # gitleaks across full history
```

### The demo worth watching

```bash
./scripts/demo_secret_persistence.sh
```

Builds a throwaway repo, commits a credential, then applies the three fixes
every team reaches for — delete the file, add `.gitignore`, add encryption —
and shows the credential is still retrievable after all three. Then shows it
surviving a fresh clone. Runs in about 90 seconds, touches only a temp
directory, and generates its fake credentials at runtime so nothing sensitive
is ever committed to this repository.

---

## Repository layout

```
.github/workflows/security-pipeline.yml   the pipeline
.gitleaks.toml                            secret rules + a narrow allowlist
.pre-commit-config.yaml                   the cheapest gate
.gitignore                                the file whose absence caused all this
terraform/insecure/                       deliberately vulnerable, for the demo
terraform/secure/                         the corrected version
scripts/ai_triage.py                      LLM triage, deterministic fallback
scripts/demo_secret_persistence.sh        the live demo
docs/                                     design, runbook, findings reference
```

---

## Design decisions worth defending

**Detection is deterministic; only explanation is AI.** The merge gate is a
hardcoded list in `scripts/ai_triage.py`, reviewed by humans and
version-controlled. The model cannot add to it or remove from it. If the API is
down, rate-limited, or the key is absent, the gate still works — it just
explains itself less well. Any design where an LLM decides pass/fail is a design
where an outage becomes a security bypass.

**`fetch-depth: 0` is not optional.** The default checkout fetches one commit,
so a secret committed earlier and deleted later — the case that actually
matters — is invisible. This is the single most common way a secret-scanning
pipeline silently does nothing.

**The allowlist is narrow, and by path.** `.env.example` is allowlisted by
filename, not by loosening the rule, so the rule still fires on a real `.env`.
Verified both ways.

**Rotate before you rewrite.** History rewriting needs coordination across
forks, PR refs and every existing clone. Revoking a credential takes minutes and
is the only step that reduces risk today.

---

## What this does not do

Stated so the gaps are deliberate rather than discovered later.

- No runtime or cloud-posture scanning. This is pre-deployment only.
- No container image or dependency scanning. Trivy or Grype would slot in as a
  third gate on the same pattern.
- No policy-as-code beyond Checkov's built-ins. Custom org policy would live in
  OPA/Rego or a Checkov custom policy directory.
- The blocking list is tuned for a regulated-data context. It is a starting
  point for a conversation with a security team, not a universal default.
