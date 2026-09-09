# Simple answers

One page. If you only read one thing about tools, read this.

---

## What you built (say exactly this)

> "Terraform creates Linux containers on a Proxmox host. Ansible installs a small Python web service
> into them. GitHub Actions scans everything before it's allowed to merge."

**No Docker. No Kubernetes.** That's the true answer and it's a good one.

---

## The three tool questions, answered

### "Could we use Colima?"

**No.** Colima is a *Mac* tool. It gives a Mac a Linux machine to run containers in.
Your servers are already Linux. You'd be adding a Linux VM to reach Linux.

### "What about DaemonSets for autoscaling?"

**A DaemonSet cannot autoscale.** It runs exactly **one copy per server**. More copies means more
servers.

| You want | Use |
|---|---|
| More copies of the app when busy | **Deployment + HPA** |
| One agent on every server (logs, metrics) | **DaemonSet** |

### "What is 'unicon'?"

**Not a real tool.** You may mean **Lima** or **Podman**. Don't say "unicon" in the room.

---

## If you added Kubernetes later, here's the order

| # | Do this | Why |
|---|---|---|
| 1 | Add **Trivy** image scanning | Works today. No Kubernetes needed. |
| 2 | Build a **Docker image** | `requirements.txt` goes inside it. No more drift. |
| 3 | Install **k3s** | One command. A real Kubernetes. |
| 4 | Write a **Helm chart** | One chart, three value files — like your tfvars today. |
| 5 | Move **dev only** | Leave stage and prod alone until dev is boring. |
| 6 | Add **admission control** | Before autoscaling, not after. |
| 7 | Turn on **autoscaling** | Last. |

**Steps 1 and 2 are worth doing even if you stop there.**

---

## Who does what

| Tool | Its one job |
|---|---|
| **Terraform** | makes the machines |
| **Ansible** | installs the app *(today)* |
| **Docker** | packages the app *(if you add it)* |
| **Helm** | installs the app on Kubernetes *(if you add it)* |
| **Kubernetes** | runs and restarts the app |
| **HPA** | adds copies when busy |
| **DaemonSet** | one agent per server — **not** the app |

---

## The line to say if they ask about Kubernetes

> "Moving this to Kubernetes changes **one thing** — the deploy command. The secret scanning, the
> Terraform scanning, the blocking rules, the approvals, the isolation all stay exactly the same.
> That's why I built it this way. The real reason to want containers isn't scale — it's that an
> image can be **scanned for vulnerabilities before it runs**."

That's the whole answer. Stop there.

---

## My recommendation for tomorrow

**Don't build anything else. Present what works.**

You have:

- A pull request that **cannot merge** without review and passing checks
- Merge → **dev deploys automatically**
- **Stage and prod each wait** for your approval
- **Four containers** serving traffic
- **Three isolation boundaries**, all tested
- **46 validation checks**, all green

That is a complete, honest, working demonstration. Adding a container runtime tonight risks every bit
of it to show something your talk isn't about.
