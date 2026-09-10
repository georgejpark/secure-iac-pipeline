<!-- title -->
# The Password You Already Deleted

### Secrets in git, and a pipeline that stops them reaching production

George Park  ·  Senior DevSecOps  ·  Texas Mutual  ·  10 September 2026

*Document 5 of 7 — Every machine, what it holds, and what it does.*

---

# The servers

Eight Linux containers on one Proxmox host.

They split into two groups. The 20X group runs the pipeline. The 30X group runs the web application.

---

# Why two groups

The pipeline machines and the application machines do completely different jobs.

The **20X machines** check code and build things. They hold keys and can create servers.

The **30X machines** just serve web pages. They hold nothing and can create nothing.

Keeping them apart means a problem in the web application cannot reach the machines that build
production.

---

# The 20X group: the pipeline

These four were built by hand, before any Terraform ran. They **are** the pipeline.

---

## 201  ci-dev

**What it is:** a GitHub Actions runner for development.

**How it was made:** by hand. I created the container, installed the GitHub runner software, and
registered it with the repository under the label `dev`.

**What it holds:**

- The GitHub runner agent
- Terraform 1.5.7 and gitleaks 8.30.1, pinned versions
- The **development** encryption key, and only that one

**What it does when a pull request opens:**

1. Scans the entire git history for passwords
2. Runs Checkov against the development Terraform
3. Sorts the findings and writes the pull request comment
4. After a merge, deploys development

**Why it runs the password scan for every environment:** that job only reads source code. It needs no
keys and no access to anything. So it runs on the machine with the least privilege.

**Address:** 10.10.10.10

---

## 202  ci-stage

**What it is:** a GitHub Actions runner for staging.

**How it was made:** the same way as 201, registered with the label `stage`.

**What it holds:** the **staging** encryption key. It cannot open the development or production
files.

**What it does:**

1. Runs Checkov against the staging Terraform
2. After a merge, and after somebody approves, deploys staging

**It never runs development or production jobs.** GitHub only sends it jobs labelled `stage`.

**Address:** 10.20.10.10

---

## 203  ci-prod

**What it is:** a GitHub Actions runner for production.

**How it was made:** the same way, labelled `prod`.

**What it holds:** the **production** encryption key. This is the only machine that can decrypt
production passwords.

**What it does:**

1. Runs Checkov against the production Terraform
2. After a merge, and after somebody approves, deploys production

**Address:** 10.30.10.10

---

## 204  tf-state

**What it is:** a PostgreSQL database. Not a runner.

**How it was made:** by hand. Installed PostgreSQL, created three databases.

**What it holds:** three separate databases.

```
tfstate_dev      what Terraform has built in development
tfstate_stage    what Terraform has built in staging
tfstate_prod     what Terraform has built in production
```

**Why this exists:** Terraform needs to remember what it created last time, otherwise it would build
duplicates. It also locks the record while a deploy runs, so two people cannot deploy at once and
corrupt it.

**How it is protected:** each environment has its own username and password, and PostgreSQL only
accepts each username from its own network. The development machine is refused production's database
even with the correct password, because the request comes from the wrong network.

**Address:** 10.40.10.10, on its own management network.

**It never runs pipeline code.** It only answers database queries.

---

# The 30X group: the web application

These were **not** built by hand. Terraform created them.

That is the point of the demo. When you merge a change, Terraform builds these.

---

## 301  app-dev-1

**What it is:** the development web server.

**How it was made:** `terraform apply` in the development deploy job.

**What runs on it:** a small Python web service, started by systemd, running as a user called
`rapta`. Not root.

```
/opt/rapta/inspection/current/venv/bin/python app.py
```

**What it answers:**

```
GET /          the greeting, plus which machine you reached
GET /health    is it alive
GET /version   which version is running
```

**Its size:** 2 CPU, 2 GB. The same as every other environment. Dev is cheaper in what it lacks, not in what it is given.

**What it does not have:** restart on reboot, delete protection. Development is allowed to be cheap.
Losing it costs an afternoon.

**Address:** 10.10.10.20

---

## 311  app-stage-1

**What it is:** the staging web server.

**How it was made:** `terraform apply` in the staging deploy job, after somebody approved it.

**What runs on it:** the same application as development.

**Its size:** 2 CPU, 2 GB. The same as development and production.

**What it has that development does not:** it restarts automatically after a reboot.

**Why staging exists:** it has the same security settings as production but is smaller. A setting that
is missing in staging is a setting nobody has tested.

**Address:** 10.20.10.20

---

## 321 and 322  app-prod-1 and app-prod-2

**What they are:** the production web servers. Two of them.

**How they were made:** `terraform apply` in the production deploy job, after somebody approved it.

**Why there are two:** one line in one file says so.

```
replica_count = 2
```

Change that number and the pipeline builds more. That is the demo.

**Their size:** 2 CPU, 2 GB each.

**What they have that the others do not:**

- **Restart on reboot.** A production server that stays down after a power cut is an outage.
- **Delete protection.** Terraform cannot destroy them. I tried, and Proxmox refused. You have to
  turn the protection off deliberately first.

**Addresses:** 10.30.10.20 and 10.30.10.21

---

# How the networks are laid out

Each environment has its own network. Nothing crosses between them.

```
Development     10.10.10.x
Staging         10.20.10.x
Production      10.30.10.x
Management      10.40.10.x
```

Inside each one, the numbering is always the same:

```
.1      the gateway
.10     the pipeline machine
.20+    the web servers
```

So `10.30.10.21` reads as: production network, second web server.

**They cannot reach each other.** Development cannot ping production. Production cannot ping
development. Tested in both directions.

---

# Which machine does what during a deploy

When you merge a change, this happens:

```
201 ci-dev      scans for passwords
                runs Checkov for development
                deploys development  ->  builds 301

202 ci-stage    runs Checkov for staging
                waits for approval
                deploys staging      ->  builds 311

203 ci-prod     runs Checkov for production
                waits for approval
                deploys production   ->  builds 321, 322

204 tf-state    answers all three, from three separate databases
```

Each runner talks only to its own database and its own environment.

---

# Getting into any of them

You cannot reach these from your laptop. Those networks only exist on the Proxmox host.

```bash
ssh root@192.168.1.132
```

Then either:

```bash
pct exec 301 -- bash              # straight in, no password
ssh opsadmin@10.10.10.20          # or over ssh
```

Or use the Proxmox web console: click the container, then **Console**.

Log in as `opsadmin`. The password is in `/root/creds/opsadmin-dev.pw` on the host.

---

# The quick version

| | | |
|---|---|---|
| 201 | ci-dev | checks and deploys development |
| 202 | ci-stage | checks and deploys staging |
| 203 | ci-prod | checks and deploys production |
| 204 | tf-state | remembers what has been built |
| 301 | app-dev-1 | development web server |
| 311 | app-stage-1 | staging web server |
| 321 | app-prod-1 | production web server |
| 322 | app-prod-2 | production web server |

**201 to 204 were built by hand. 301 to 322 were built by the pipeline.**
