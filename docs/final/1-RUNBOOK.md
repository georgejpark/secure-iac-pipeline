# RUNBOOK

The document I read while I present.

---

# Introduction

I am George Park. I work in operations and platform engineering. Kubernetes, Terraform, CI/CD,
observability, across AWS and GCP.

For the last few years my job has been keeping platforms running and making the path to production
safe for other people to use.

Today I want to teach you something I learned by accident, and then show you what I built because of
it.

---

# The problem

Companies leak passwords into their code.

That part is not surprising. What surprised me is what happens next.

They notice. They delete the file. They add it to gitignore. Some of them go further and add
encryption.

And the password is still there.

The repository looks clean afterwards. The commit history says somebody handled it. Nobody handled
it.

That is what I want you to walk away knowing.

---

# What I am trying to achieve today

Four things.

**1. Show you the problem is real.**

Not a slide about it. I will show you a password surviving every fix people normally apply.

**2. Show you a pipeline that stops it.**

Running right now, on hardware in my house. Not a diagram.

**3. Show you the judgment, not just the tools.**

Anyone can install a scanner. The hard part is deciding what should stop somebody's work, and being
able to defend that list to an engineer and to an auditor.

**4. Make a change in front of you.**

I will change one number, push it, and you will watch it go through the checks, wait for an approval,
and build a new server. About six minutes end to end.

---

# What this demo covers

**In scope:**

- Secret scanning across the whole git history
- Infrastructure code scanning, with different rules per environment
- A pull request that cannot merge without a review and passing checks
- Development deploying automatically, staging and production waiting for a person
- Terraform building real servers, a separate deploy step installing the application
- Each environment isolated from the others

**Out of scope, and I will say so if asked:**

- **No Docker, no Kubernetes.** These are Linux containers built by Terraform. I will explain why, and
  what would change if you ran Kubernetes.
- **No cloud account.** This runs on a Proxmox server at home instead of AWS. The pipeline is
  identical; only the last command differs.
- **No runtime security.** This stops bad things before deployment. It does not watch what happens
  afterwards.
- **One person.** I am the only account on this repository, so I cannot approve my own work. In a real
  team that is a second engineer.

---

# What I built

A GitHub repository with Terraform in it.

When I change that code and open a pull request, four checks run on machines I own. If they pass, and
a person approves, Terraform builds Linux servers and a deploy script installs a web application
on them.

Right now there are four servers running:

- 1 for development
- 1 for staging
- 2 for production

By the end of this demo there will be five.

---

# How the next thirty minutes go

```
 4 min    STEP 1   the story, no screen
 2 min    STEP 2   the fix that fails
 6 min    STEP 3   prove a deleted password is still there
 3 min    STEP 4   show the checks blocking bad code
 4 min    STEP 5   show the pull request, blocked
 2 min    STEP 6   merge it
 5 min    STEP 7   watch it deploy, approve staging and production
 6 min    STEP 8   install and show the new server
 2 min    STEP 9   close
--------
34 min    leaves time for questions inside the 40
```

They told me they will ask questions while I go. Good. Every interruption is a conversation.

---

# Before I start

## Set up at 1:45

Open three windows and leave them open.

**Window 1 - iTerm2, my Mac**

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline
clear
```

**Window 2 - iTerm2, the server**

```bash
ssh root@192.168.1.132
clear
```

**Window 3 - Browser**

```
https://github.com/georgejpark/secure-iac-pipeline
```

Open three tabs in it:

1. **Code**
2. **Pull requests** then click **PR #4**
3. **Actions**

## Check before I start

Run all four. Each one takes seconds and each one has bitten me.

**1. The containers are up.**

```bash
pct list
```

8 containers, every one `running`.

**2. The four applications answer.**

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  printf "%-14s " $h; curl -s --max-time 5 http://$h:8080/health; echo
done
```

Four `{"status": "ok"}`.

> Note for me: these addresses are the *containers*. Nothing listens on the Proxmox host itself, so
> `curl 127.0.0.1:8080` at the host prompt refuses the connection. That is correct, not a fault.
> Do not panic if I fat-finger it live.

**3. The deploy script is there and its source files are staged.**

```bash
ls -l /root/install-app.sh /opt/app-source/
```

Expect the script plus four files: `app.py`, `requirements.txt`, `VERSION`, `inspection-service.service`.

**4. VMID 323 is free.**

```bash
pct list | grep 323 || echo "323 free - good"
```

Must say **323 free**. Terraform creates that container during the demo; if something is already
sitting on that ID the apply fails.

## Last things

- Terminal font at 18pt or bigger
- Do Not Disturb on
- Slack and Mail closed
- This document on a second screen, not the one I share

---

# STEP 1  -  Tell the story          (4 min)

**Nothing shared yet. Just talk.**

I was cataloguing repositories. Housekeeping. I searched for key files to fill in a document.

**112 private keys.** All committed. 21 production hostnames. The oldest nine months old.

The first commit in that repository was called *"Starting up the repository"*. It already had 63 keys
in it.

**Pause here.**

Then:

I expected carelessness. That is not what I found.

The deploy scripts read the key out of the folder you had just cloned. So for a deploy to work, the
key had to be in the repository. Adding a service meant committing its private key.

Nobody cut corners. They followed the process. **The process was the problem.**

Sixteen commits added keys over nine months. Every one passed code review.

> "When something is wrong for nine months and nobody catches it, it is almost never carelessness.
> The system made the wrong thing easy."

---

# STEP 2  -  The fix that fails      (2 min)

**Still nothing shared.**

There was a second repository. A `.env` file with 74 passwords in it.

**They caught it.** The very next commit was called *"Add utility for encrypting/decrypting .env
files"*.

They deleted the file. Added it to gitignore. Wrote an encryption tool.

Afterwards the repository looked clean.

> "Let me show you what that achieved."

---

# STEP 3  -  Prove it                (6 min)

**Share the SERVER window now.**

```bash
/root/demo-secret-persistence.sh
```

It stops after each step and waits. **Press enter to move on.**

Talk over the first four steps:

- **Setup** - "an ordinary repository, with a .env in it"
- **Fix 1** - "first instinct, delete the file"
- **Fix 2** - "then make sure it cannot come back"
- **Fix 3** - "then add encryption. This is the real commit message from the real team"

**When `git show` runs, stop talking.** Let them read the passwords on the screen.

Then:

> "Every password still there. One command. No special access."

> "Git keeps every version of every file. Deleting removes the pointer, not the file. And it travels
> with every clone."

The script then shows it surviving a fresh clone. Let that land too.

**Finish with the order:**

> "Two things work, and the order matters more than the steps. Change the password first, that takes
> minutes. Rewriting the history takes days, because you have to reach every fork and every laptop.
> Most people do it backwards."

---

# STEP 4  -  Show the checks working  (3 min)

**Switch to the MAC window.**

```bash
make scan-insecure
```

Takes about 40 seconds. Expect:

```
dev      exit=1  blocking=10
stage    exit=1  blocking=14
prod     exit=1  blocking=14
```

> "This is deliberately bad Terraform. Same code, checked three times."

> "Development blocks 10 things. Staging and production block 14. The extra four are things
> development is allowed to skip. Losing a development box costs an afternoon."

**Then show it passing:**

```bash
make scan
```

```
No blocking findings.
```

**Then the number that matters:**

> "The scanner finds 24 problems in 110 lines of code. Nobody reads 24 findings, they turn the tool
> off. So 10 stop the merge, 5 are advice, 9 are noted. Choosing which 10 is the actual job."

---

# STEP 5  -  Show the pull request    (4 min)

**Switch to the BROWSER. The Pull requests tab, PR #4.**

**Point at these, in order:**

**1. The title**

> "The change is one number. Production goes from two servers to three."

**2. Scroll to the bottom. The red box.**

```
Merging is blocked
Review required
```

**3. The green ticks above it**

> "Every check passed. Secrets, and the infrastructure scan for all three environments. It is still
> blocked, because the checks are not the only gate."

**4. Scroll up to the comments**

There are three, one per environment.

> "The pipeline wrote these. It sorts the findings and explains them in plain English, so the person
> reviewing does not have to read raw scanner output."

**5. Then say:**

> "I cannot approve this myself. GitHub refuses outright. In a real team a second engineer approves
> here. I am the only account on this repository, so I will merge with an admin override, and GitHub
> records that I did."

---

# STEP 6  -  Merge it                 (2 min)

**Switch to the SERVER window.**

```bash
cd /root/secure-iac-pipeline
gh pr merge 4 --squash --admin --delete-branch
```

Expect a short confirmation.

> "Merging is what authorises a deployment. Nothing deploys before this."

---

# STEP 7  -  Watch it deploy          (5 min)

**Switch to the BROWSER. The Actions tab. Refresh.**

A new run appears at the top. Click it.

**First 90 seconds:** the checks run again on main.

```
Secrets        running, then green
IaC (dev)      green
IaC (stage)    green
IaC (prod)     green
```

**Then the three deploy jobs appear:**

```
Deploy (dev)     runs on its own
Deploy (stage)   Waiting for review
Deploy (prod)    Waiting for review
```

> "Development went out by itself. Staging and production stopped."

**Approve staging:**

A yellow bar appears near the top saying **Review pending deployments**.

Click it. Tick **stage**. Click **Approve and deploy**.

Wait about 30 seconds. Staging goes green.

**Then approve production the same way.**

> "Development goes out on its own. Staging and production each need a person to say yes. That is the
> whole promotion model."

---

# STEP 8  -  Install and show the new server   (6 min)

**Switch to the SERVER window.**

```bash
pct list
```

> "There is a new one. app-prod-3. That did not exist six minutes ago."

It is an empty machine. Terraform built it; nothing has installed the application on it yet.
**Say that out loud before anyone asks:**

> "Terraform talks to the Proxmox API to build machines. It never logs into them. Installing the
> application is a separate stage, and I keep it separate on purpose, so rebuilding a server does not
> mean redeploying the application, and redeploying does not mean rebuilding."

**Then install it:**

```bash
/root/install-app.sh prod
```

Takes about 25 seconds. Expect exactly this:

```
environment=prod  version=1.1.0  containers=3
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
  app-prod-3 (323)  installing 1.1.0 ...
    app-prod-3 serving {"version": "1.1.0"}
done
```

**Point at the two skipped lines:**

> "The two servers that were already running were left alone. It checks what each one is serving
> before it touches it. I can run this as many times as I like and it only acts where something is
> actually missing."

## What that script does

Seven steps, in this order, on any container that is not already serving:

1. **Creates a service account** called `rapta`. The application does not run as root.
2. **Installs Python and curl** if they are missing.
3. **Copies the release** into its own folder, `releases/1.1.0`. The old release stays on disk.
4. **Builds a virtual environment** inside that release folder, so two releases can need different
   packages without fighting.
5. **Moves one symlink**, `current` → `releases/1.1.0`. That single pointer move *is* the release.
6. **Installs the systemd unit**, which points at `current`, never at a version number. That is why a
   rollback needs no file edited. You move the symlink back and restart.
7. **Waits for the health check to pass** before reporting success. The application deliberately
   answers 503 for the first two seconds, so a check that fires immediately would report a false
   failure.

**Then ask the new server who it is:**

```bash
curl -s http://10.30.10.22:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-3",
  "version": "1.1.0"
}
```

**Then show all five together:**

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21 10.30.10.22; do
  curl -s --max-time 5 http://$h:8080/ ; echo
done
```

> "Five machines. Each one knows which environment it is, because it reads it from its own hostname.
> Three in production, because the file now says three."

## If something goes wrong here

**"Connection refused" on the curl.** Check you are using the container address, not the host.
The applications run *inside* the containers on `10.x.10.20+`. Nothing listens on the Proxmox host
itself, so `curl 127.0.0.1:8080` from the host prompt will always refuse. That is correct behaviour,
not a fault.

**The install script reports DID NOT COME UP.** It prints the service status underneath. Run it
again. It is safe to repeat and will retry only the container that failed.

# STEP 9  -  Close                    (2 min)

**Stop sharing. Face them.**

**Three things:**

**1.** Deleting a password from git does not remove it. Change the password first, clean up second.

**2.** When something is wrong for nine months and nobody notices, the system made it easy to get
wrong. Fix the system, not the people.

**3.** The hard part is not running the scanner. It is choosing what is worth blocking, and being able
to defend that choice to an engineer and to an auditor.

> "Happy to go anywhere you would like with it."

---

# If I run out of time

Drop **Step 4**. Say instead: *"the checks block 10 things in development and 14 in production."*

Drop the **production approval** in Step 7. Approve staging only.

# Never drop

- Step 3, the `git show` moment
- Step 5, the blocked pull request
- Step 9, the three closing points

# If something breaks

**No answer from a server:** I'm on my Mac. Those networks only exist on the Proxmox host.

**Command not found:** wrong machine. Step 4 is my Mac. Everything else is the server.

**The pipeline fails:** read the error out loud. A pipeline that stops a bad change in front of you
is better than one that quietly works.

**I don't know:** say so.
