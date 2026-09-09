# GitOps runbook — a code change to four running containers

**Read this alongside `diagrams/gitops-flow.drawio`.** Every step is a real command.

> **What this is, precisely.** Terraform provisions **LXC containers** on a Proxmox host. Ansible
> installs a small **Python HTTP service** into them under systemd. There is **no Docker, no
> Kubernetes and no FastAPI** anywhere in this stack. Say what it is — a panel that asks to see a
> Dockerfile should not find there isn't one.

---

## Part 1 — On your laptop

### 1. Clone

```bash
git clone git@github.com:georgejpark/secure-iac-pipeline.git
cd secure-iac-pipeline
make install          # venv + pre-commit hooks. Once per clone.
```

### 2. Branch — never commit to `main`

```bash
git checkout -b feat/TM-104-encrypt-claims-bucket
```

**Naming:** `feat/` new capability · `fix/` defect · `chore/` housekeeping.
There is **no branch per environment.** One branch, `main`, deploys everywhere; environments are
separated by **approval**, not by branch. Fewer long-lived branches, fewer merge conflicts, and the
audit trail is the approval record.

### 3. Change the infrastructure code

```bash
$EDITOR terraform/envs/prod/main.tf
```

### 4. Commit — the first gate fires here

```bash
git add -A
git commit -m "TM-104: encrypt the claims bucket with a CMK"
```

`pre-commit` runs **gitleaks** and **terraform fmt** before the commit exists.
A secret caught here needs no rotation, no history rewrite and no incident report.
**If it fails, nothing has left your laptop.**

---

## Part 2 — Push and open the pull request

### 5. Push

```bash
git push -u origin feat/TM-104-encrypt-claims-bucket
```

### 6. Open the PR

```bash
gh pr create --base main \
  --title "TM-104: encrypt the claims bucket with a CMK" \
  --body "What changed, why, and what I tested."
```

Opening the PR is what starts the pipeline.

---

## Part 3 — What CI does, in order

**All of this runs on your own runners** — one per environment, each in its own container on its own
network segment.

### 7. Secret scan — first, and alone

```
gitleaks detect --source . --config .gitleaks.toml --exit-code 1
```

`fetch-depth: 0` — the whole history, not just the pushed commits.
**Fails the PR.** A leaked credential is already an incident; rotate first, rewrite second.

### 8. Checkov — three environments in parallel

```
checkov -d terraform/envs/dev      → 10 blocking
checkov -d terraform/envs/stage    → 14 blocking
checkov -d terraform/envs/prod     → 14 blocking
```

Same code, three policy sets. The extra four in stage and prod are controls dev may skip —
Multi-AZ, deletion protection, log export, enhanced monitoring.

### 9. AI triage → a PR comment

`scripts/ai_triage.py` orders the findings, explains each in plain English, and flags likely false
positives. **It never decides pass/fail.** Remove the API key and the gate behaves identically.

### 10. The gate

Blocking findings → **PR blocked**. Fix, commit, push; the pipeline re-runs on the same PR.

---

## Part 4 — Review and merge

### 11. Reviewer approves

GitHub will not let you approve your own pull request. That is a hard constraint, not a setting.

### 12. Merge to `main`

Squash merge. The branch is deleted. **Merging is what authorises a deploy.**

---

## Part 5 — Deploy, per environment

One job per environment, `max-parallel: 1` — **dev, then stage, then prod.**

| Environment | Gate |
|---|---|
| `dev` | applies automatically |
| `stage` | **waits for a reviewer** on the GitHub Environment |
| `prod` | **waits for a reviewer** |

### 13. Inside each deploy job — four things, in order

**a. Decrypt the credentials**

```bash
sops --decrypt terraform/envs/prod/secrets.enc.yaml
```

The age private key exists **only on that environment's runner**. The prod runner is the only thing
that can open prod secrets. A compromised dev runner can read the encrypted file — it is committed,
in the open, deliberately — and cannot decrypt it.

**b. Initialise state**

```bash
terraform init -backend-config="conn_str=postgres://tf_prod:...@10.40.10.10/tfstate_prod"
```

One PostgreSQL database per environment. Advisory locks give real state locking — what S3 plus
DynamoDB buys you on AWS. `pg_hba` restricts each role to its own subnet, so the dev runner is
refused prod's database **even holding the correct password**.

**c. Plan, then check the plan**

```bash
terraform plan -out=tfplan
terraform show -json tfplan > plan.json
python3 scripts/policy_check.py --plan plan.json --environment prod
```

Checkov has **no rules for the Proxmox provider**, so this code would pass every scan by being
unrecognised. The policy is written by hand and runs against the **plan** — what will actually be
created, with variables resolved.

| Policy | Requirement | Enforced in |
|---|---|---|
| `PVE-1` | container must be unprivileged | dev, stage, prod |
| `PVE-3` | restart after a host reboot | stage, prod |
| `PVE-4` | delete protection | prod |

**d. Apply**

```bash
terraform apply tfplan
```

### 14. What Terraform actually creates

Per environment, from `terraform/modules/workload`:

| Setting | dev | stage | prod |
|---|---|---|---|
| Containers | 1 | 1 | **2** |
| vCPU each | 1 | 2 | 2 |
| Memory each | 512 MB | 1 GB | 2 GB |
| Disk | 8 GB | 12 GB | 20 GB |
| Bridge / subnet | `vmbr1` `10.10.10.0/24` | `vmbr2` `10.20.10.0/24` | `vmbr3` `10.30.10.0/24` |
| Unprivileged | yes | yes | yes |
| Restart on boot | no | **yes** | **yes** |
| Delete protection | no | no | **yes** |

Production runs **two** containers because production specifies two. That is the only place the
replica count lives.

---

## Part 6 — The application

### 15. Ansible installs the service

```bash
ansible-playbook -i inventory/hosts.ini playbooks/deploy.yml
```

Terraform provisions the **machine**. Ansible installs the **application**. Keeping those separate is
deliberate: rebuilding a container should not mean redeploying the app, and vice versa.

The role uses a release directory with a symlink:

```
/opt/rapta/inspection/releases/1.0.0/
/opt/rapta/inspection/current -> releases/1.0.0
```

**Rollback is a symlink flip, not a redeploy.**

### 16. The healthcheck asserts the version

Not just liveness — the **version**. A deploy that silently left the old code running **fails**
instead of reporting success.

That is the same idea as everything else here: a control that passes while doing nothing is worse
than no control, because it manufactures confidence.

---

## The result

```bash
curl http://10.10.10.20:8080/health    {"status": "ok"}
curl http://10.10.10.20:8080/version   {"version": "1.0.0"}
```

| Container | Environment | Address |
|---|---|---|
| `app-dev-1` | dev | `10.10.10.20` |
| `app-stage-1` | stage | `10.20.10.20` |
| `app-prod-1` | prod | `10.30.10.20` |
| `app-prod-2` | prod | `10.30.10.21` |

Each on its own isolated segment, with **no route between environments** — verified in both
directions.
