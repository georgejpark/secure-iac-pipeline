# What we built — read this first

You built a lot in two days. This is the honest inventory, in order, so you can explain it without
guessing.

---

## The one-paragraph answer

> A GitHub repository holds Terraform. When you change it and open a pull request, a pipeline running
> **on your own hardware** scans the whole git history for secrets, scans the infrastructure code
> against three different policy sets — one per environment — writes you a plain-English explanation
> of what it found, and blocks the merge if anything matters. After a reviewer approves and it
> merges, **Terraform creates Linux containers** on a Proxmox host and **Ansible installs a small
> Python web service** into them. Dev deploys automatically; staging and production wait for a human
> to approve.

---

## First: what we did NOT use

You asked whether it's Docker or Kubernetes. **It is neither.** Verified on the running system:

```
docker containers running:  0
kubernetes binaries:        0   (host and every container)
fastapi / flask in the app: 0 matches
```

| You might assume | What it actually is |
|---|---|
| Docker image | **LXC container** — an OS-level Linux container, native to Proxmox |
| Kubernetes pod | Nothing. There is no orchestrator. |
| FastAPI / Flask | Python's built-in **`http.server`** |
| Container registry | None. Ansible copies files onto the machine. |
| `kubectl apply` | `terraform apply`, then `ansible-playbook` |

**If they ask why not Kubernetes:**

> "Containers-in-containers would have added a registry, image builds and an orchestrator in order to
> demonstrate a security pipeline that needs none of them. If you run Kubernetes, I'd put the same
> gates in front of your manifests — same pattern, different apply step."

That is a strong answer. **Do not say Docker or Kubernetes.** "Show me the Dockerfile" is a bad
moment to discover there isn't one.

---

## The eight containers

All on one Proxmox host, `pve2`. Two groups, built two different ways.

### Group 1 — the CI machines (four, built by hand)

These existed before any Terraform ran. They *are* the pipeline.

| ID | Name | Address | Job |
|---|---|---|---|
| 201 | `ci-dev` | `10.10.10.10` | GitHub Actions runner, dev only |
| 202 | `ci-stage` | `10.20.10.10` | GitHub Actions runner, stage only |
| 203 | `ci-prod` | `10.30.10.10` | GitHub Actions runner, prod only |
| 204 | `tf-state` | `10.40.10.10` | PostgreSQL holding Terraform state |

**Why three runners rather than one:** with a shared runner, a pull request touching dev executes
code on the same machine that later deploys production. That is a privilege escalation path. Three
separate containers on three separate networks remove it.

### Group 2 — the application (four, built by Terraform)

These are what the pipeline creates.

| ID | Name | Address | Environment |
|---|---|---|---|
| 301 | `app-dev-1` | `10.10.10.20` | dev |
| 311 | `app-stage-1` | `10.20.10.20` | stage |
| 321 | `app-prod-1` | `10.30.10.20` | prod |
| 322 | `app-prod-2` | `10.30.10.21` | prod |

Production has **two** because production specifies two. That number lives in one place:
`terraform/deploy/prod/main.tf`.

### What each container does in the pipeline

This is the table to have in your head. Left column is what you see in the Proxmox tree; right
column is what it does when a pull request lands.

| Container | What it is | Its job when CI runs |
|---|---|---|
| **201 `ci-dev`** | GitHub Actions runner | Runs the **secret scan** for every PR, and the **dev** IaC scan and deploy. Holds the dev age key. |
| **202 `ci-stage`** | GitHub Actions runner | Runs the **stage** IaC scan and deploy. Holds the stage age key. Nothing else. |
| **203 `ci-prod`** | GitHub Actions runner | Runs the **prod** IaC scan and deploy. Holds the prod age key. Only ever executes prod jobs. |
| **204 `tf-state`** | PostgreSQL 17 | Holds Terraform state — one database per environment, each reachable only from its own subnet. Never runs pipeline code. |
| **301 `app-dev-1`** | The application, dev | Created by `terraform apply` in the dev deploy job. Ansible then installs the service. |
| **311 `app-stage-1`** | The application, stage | Same, from the stage job — which waits for a reviewer. |
| **321 `app-prod-1`** | The application, prod | Same, from the prod job. Delete protection on. |
| **322 `app-prod-2`** | The application, prod | The second replica. Production specifies two. |

### Which GitHub Actions job runs where

| Workflow job | Runner | What it does |
|---|---|---|
| `secret-scan` | `ci-dev` | gitleaks over the **entire history** (`fetch-depth: 0`) |
| `iac-scan (dev)` | `ci-dev` | Checkov + AI triage + the blocking gate |
| `iac-scan (stage)` | `ci-stage` | same, with 4 extra promotion-gated policies |
| `iac-scan (prod)` | `ci-prod` | same as stage |
| `deploy (dev)` | `ci-dev` | SOPS → terraform init → plan → policy gate → apply |
| `deploy (stage)` | `ci-stage` | same, **after a reviewer approves** |
| `deploy (prod)` | `ci-prod` | same, **after a reviewer approves** |

**Secret scanning runs on the dev runner deliberately.** It only reads source code, so it is given
the least privilege of the three.

### The network layout

Each environment is its own isolated bridge with no physical port:

```
.1    the gateway
.10   the CI runner
.20+  the application containers
```

There is **no route between environments** — verified in both directions.

---

## The flow, in six phases

### Phase 1 — You change code (on your laptop)

```bash
git clone git@github.com:georgejpark/secure-iac-pipeline.git
git checkout -b feat/TM-104-encrypt-claims-bucket
$EDITOR terraform/envs/prod/main.tf
git commit -m "TM-104: encrypt the claims bucket"
```

A **pre-commit hook** runs gitleaks and `terraform fmt` before the commit exists. A secret caught here
never becomes a commit — no rotation, no history rewrite, no incident.

### Phase 2 — You open a pull request

```bash
git push -u origin feat/TM-104-encrypt-claims-bucket
gh pr create --base main --title "..." --body "..."
```

There is **no branch per environment.** One branch, `main`. Environments are separated by
**approval**, not by branch.

### Phase 3 — CI scans it (on your runners)

| Order | What | Blocks? |
|---|---|---|
| 1 | **gitleaks** — entire history, `fetch-depth: 0` | yes |
| 2 | **Checkov** — dev, stage and prod in parallel | on the blocking list |
| 3 | **AI triage** — explains findings in a PR comment | never |
| 4 | **the gate** — any blocking finding stops the merge | yes |

Same Terraform, three results: **dev blocks 10, stage and prod block 14.** The extra four are
controls dev may skip.

### Phase 4 — A human reviews and merges

GitHub will not let you approve your own pull request. Merging authorises a deploy.

### Phase 5 — Terraform creates the machines

One deploy job per environment, in order: **dev, then stage, then prod.**

| Environment | Gate |
|---|---|
| dev | applies automatically |
| stage | **waits for a reviewer** |
| prod | **waits for a reviewer** |

Inside each job, four things happen in order:

1. **`sops --decrypt`** — the age key exists only on *that* environment's runner
2. **`terraform init`** — state from *that* environment's PostgreSQL database
3. **`policy_check.py`** — runs against the **plan**, not the source
4. **`terraform apply`** — creates the LXC containers

**What Terraform actually creates, per environment:**

| | dev | stage | prod |
|---|---|---|---|
| Containers | 1 | 1 | **2** |
| vCPU each | 1 | 2 | 2 |
| Memory each | 512 MB | 1 GB | 2 GB |
| Restart on boot | no | **yes** | **yes** |
| Delete protection | no | no | **yes** |

### Phase 6 — Ansible installs the application

```bash
ansible-playbook -i inventory/hosts.ini playbooks/deploy.yml
```

**Terraform provisions the machine. Ansible installs the application.** Kept separate deliberately:
rebuilding a container shouldn't mean redeploying the app, and vice versa.

The app lands in a release directory with a symlink:

```
/opt/rapta/inspection/releases/1.0.0/
/opt/rapta/inspection/current -> releases/1.0.0
```

**Rollback is a symlink flip, not a redeploy.**

Then systemd runs it:

```
/opt/rapta/inspection/current/venv/bin/python /opt/rapta/inspection/current/app.py
```

The healthcheck **asserts the version, not just liveness** — so a deploy that silently left the old
code running fails instead of reporting success.

---

## The result

```bash
curl http://10.10.10.20:8080/health     {"status": "ok"}
curl http://10.10.10.20:8080/version    {"version": "1.0.0"}
```

Four containers, four environments' worth of isolation, one pipeline.

---

## Which tool does what

| Tool | Does | Does NOT |
|---|---|---|
| **GitHub Actions** | schedules jobs, holds the workflow | hold any cloud or deploy credential |
| **gitleaks** | finds secrets in the full history | fix them |
| **Checkov** | finds insecure Terraform | know anything about Proxmox |
| **`ai_triage.py`** | explains and orders findings | decide pass/fail — ever |
| **`policy_check.py`** | enforces Proxmox rules against the plan | replace Checkov |
| **SOPS + age** | encrypts secrets, one key per environment | store anything outside git |
| **Terraform** | creates the containers | install the application |
| **Ansible** | installs the application | create machines |
| **PostgreSQL** | holds Terraform state with real locking | run anything else |
| **systemd** | runs the service | orchestrate across hosts |

---

## Three isolation boundaries

Each independently verified. Any one failing does not open the door.

| Boundary | Control | Proof |
|---|---|---|
| **Network** | no route between segments | `dev → prod` blocked, ICMP and TCP |
| **Cryptographic** | one age key per environment | dev cannot decrypt prod secrets |
| **Database** | `pg_hba` restricts by subnet | dev refused **holding the correct prod password** |

---

## Verify it all yourself, in one minute

```bash
ssh root@192.168.1.132

pct list                                    # 8 containers
docker ps 2>/dev/null | wc -l               # 0 — no Docker
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  curl -s http://$h:8080/version; echo
done                                        # four services responding

pct exec 301 -- ping -c2 -W2 10.30.10.20    # dev -> prod: blocked
```
