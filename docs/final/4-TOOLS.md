<!-- title -->
# The Password You Already Deleted

### Secrets in git, and a pipeline that stops them reaching production

George Park  ·  Senior DevSecOps  ·  Texas Mutual  ·  10 September 2026

*Document 4 of 7 — Every tool in the pipeline, and what it is for.*

---

# The tools

Everything used to build this, and what each one is for.

---

# The short version

Four checks run before anything is allowed to merge.

**1. gitleaks** looks for passwords in the code.

**2. Checkov** looks for unsafe settings in the infrastructure code.

**3. A sorting script** decides which findings actually stop the merge.

**4. A policy script** checks the plan before anything is built.

Then a person approves it, and Terraform builds the servers.

---

# What each one does

## gitleaks

**Looks for passwords and keys in your code.**

It knows what secrets look like. An AWS key has a shape. So does a GitHub token, a Slack token, a
private key.

It reads every file and every past commit looking for those shapes.

Two things make it useful:

- It reads the **whole history**, not just today's files
- It runs before the commit is even saved, on your own machine

If it finds something, the build stops.

## Checkov

**Reads Terraform and finds unsafe settings.**

It knows about a thousand patterns. Things like:

- A storage bucket anyone on the internet can read
- SSH open to the whole world
- A database with no encryption
- A database reachable from the internet

It doesn't look for passwords. That's gitleaks' job.

## terraform fmt

**Tidies up formatting.** Spacing, indentation, alignment.

It doesn't change what the code does. It makes every file look the same.

Without it, code reviews fill up with arguments about spacing instead of the actual change.

## terraform validate

**Catches typos before anything is built.**

Missing brackets. A variable that doesn't exist. A misspelled resource name.

Seconds, instead of finding out halfway through creating things.

## SOPS

**Encrypts passwords so they can live in the repository.**

The file is committed. Anyone can read it. But the values are scrambled.

Each environment has its own key, and each key lives on one machine only. The development machine
cannot open the production file.

## Terraform

**Creates the servers.**

You describe what you want. It works out what to create, change or remove.

## The deploy script

**Installs the application onto servers that already exist.**

Terraform makes the box. The deploy script puts the application on it.

They are kept separate on purpose. Rebuilding a server shouldn't mean redeploying the application, and
redeploying the application shouldn't touch the server.

It is a shell script, not Ansible. At this size Ansible would be a dependency to install and a
playbook to maintain for work that is seven steps long. Ansible earns its place when you have many
machine types and need the inventory and the module library. Say that plainly if asked. The honest
answer is "not yet worth it", not "I didn't know about it".

## PostgreSQL

**Remembers what Terraform has already built.**

Each environment has its own database. Two people can't run Terraform at the same time and corrupt
each other, because the database locks it.

---

# The GitHub parts

## Actions

Runs the jobs. Holds no passwords and no cloud credentials.

## Self-hosted runners

The jobs run on my machines, not GitHub's.

Three of them, one per environment. Development jobs never run on the production machine.

## Branch protection

Stops anyone merging to `main` without:

- 1 approval
- 4 passing checks

## Environments

Development deploys on its own.

Staging and production each wait for somebody to approve.

---

# The order it runs in

```
1. pre-commit hook          on my laptop, before the commit exists
2. gitleaks                 the whole history
3. Checkov                  three times, one per environment
4. the sorting script       writes the comment
5. the gate                 stops the merge if needed
6. a person                 approves the pull request
7. merge                    this authorises a deployment
8. SOPS                     unlock this environment's passwords
9. Terraform                work out what changes
10. the policy script       check the plan before running it
11. Terraform apply         build it
12. the deploy script       install the application
```

**Steps 1 to 5 are free.** They cost nothing and catch most things.

**Steps 6 and 7 are a person.** No tool replaces that.

**Steps 8 to 12 are the deployment.** Nothing here runs until the steps above have passed.

---

# What each thing costs

**gitleaks** free, open source

**Checkov** free, open source

**Terraform** free

**The deploy script** free, it is our own code

**SOPS** free, open source

**PostgreSQL** free

**GitHub Actions** free for public repositories

**The AI comment** a few cents per run, and optional. Remove it and the pipeline behaves the same.

The whole thing runs on hardware I already had.

---

# What I would add next

In the order I would actually do it. The first two are worth doing whether or not the rest ever happens,
which is usually the sign of a sensible order.

1. **Trivy as a fifth check.** Scans container images and dependencies for known vulnerabilities.
   Works today, no Kubernetes required, real value immediately.
2. **Containerise the application.** Not for scale. For a scannable artifact that step 1 can inspect
   before it runs.
3. **Dependabot.** Watches for out-of-date libraries with known problems.
4. **A second person.** I am the only account on this repository, so I cannot approve my own work.
   That is the one gap I cannot close on my own.
5. **k3s on the host, development only.** One node, prove the manifests, leave staging and production
   on the current path until development is boring.
6. **Admission control - Gatekeeper or Kyverno.** The same policies the pipeline enforces before a
   merge, enforced by the cluster when a workload appears. This has to come *before* autoscaling.
7. **Autoscaling, last.** On queue depth or latency, not CPU, and only once step 6 exists.

# What I would not do

- **Kubernetes for four containers on one host.** The operational cost exceeds the benefit until
  there is a real scheduling or multi-tenancy problem to solve.
- **Autoscaling before admission control.** Workloads appearing without a human, with no runtime
  policy, is strictly worse than what exists now: CI-time policy becomes insufficient the moment a
  workload can appear without a merge.
- **`imagePullPolicy: Always` with `:latest`.** It reintroduces exactly the "what is actually running"
  ambiguity the version-asserting health check was built to remove.
