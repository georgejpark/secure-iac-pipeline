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
- Terraform building real servers, Ansible installing the application
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
a person approves, Terraform builds Linux servers and Ansible installs a web application on them.

Right now there are four servers running:

- 1 for development
- 1 for staging
- 2 for production

By the end of this demo there will be five.

---

# How the next thirty minutes go

```
 4 min    the story, no screen
 2 min    set up the demo
 6 min    prove a deleted password is still there
 3 min    show the checks blocking bad code
 4 min    show the pull request, blocked
 2 min    merge it
 4 min    watch it deploy, approve staging and production
 4 min    show the new server answering
 2 min    close
```

They told me they will ask questions while I go. Good. Every interruption is a conversation.

---

# Before I start

Two windows open:

```
iTerm2      ssh root@192.168.1.132
Browser     github.com/georgejpark/secure-iac-pipeline
```

---

# STEP 1  -  Tell the story          (4 min)

**No screen yet.**

I was cataloguing repositories. I searched for key files.

**112 private keys.** All committed. 21 production hostnames. Nine months old.

The first commit was called "Starting up the repository". It already had 63 keys.

**Then:**

The deploy scripts read the key out of the folder you'd cloned. So the key had to be in the
repository.

Nobody cut corners. They followed the process. **The process was the problem.**

---

# STEP 2  -  The fix that fails      (2 min)

**Still no screen.**

A second repository had 74 passwords in one file.

They caught it. The next commit was "Add utility for encrypting/decrypting .env files".

They deleted it. Ignored it. Encrypted it.

> "Let me show you what that achieved."

---

# STEP 3  -  Prove it                (6 min)

**iTerm2:**

```bash
/root/demo-secret-persistence.sh
```

Press enter through it.

**Stop talking when `git show` runs.** Let them read the passwords.

> "Git keeps every version of every file. Deleting removes the pointer, not the file."

> "Change the password first. That takes minutes. Cleaning the history takes days."

---

# STEP 4  -  Show the checks working  (3 min)

**iTerm2, on my Mac:**

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline
make scan-insecure
```

```
dev      10 blocking
stage    14 blocking
prod     14 blocking
```

> "Same code. Development blocks 10 things. Production blocks 14. Development is allowed to be
> cheaper."

> "The scanner finds 24 problems in 110 lines. Nobody reads 24 findings. Choosing which 10 matter is
> the actual job."

---

# STEP 5  -  Show the pull request    (4 min)

**Browser. Pull requests. PR #4.**

Point at:

1. **BLOCKED - Review required**
2. Green ticks
3. The comment the pipeline wrote

> "The change is one number. Production goes from 2 servers to 3."

> "I can't approve my own pull request. GitHub refuses. In a real team someone else approves."

---

# STEP 6  -  Merge it                 (2 min)

**iTerm2:**

```bash
cd /root/secure-iac-pipeline
gh pr merge 4 --squash --admin --delete-branch
```

> "Merging is what allows a deployment."

---

# STEP 7  -  Watch it deploy          (4 min)

**Browser. Actions tab. Refresh.**

- **Deploy (dev)** runs on its own
- **Deploy (stage)** says *Waiting for review*
- **Deploy (prod)** says *Waiting for review*

Click **Review deployments**. Approve staging. Then production.

> "Development goes out on its own. Staging and production each need a person to say yes."

---

# STEP 8  -  Show the new server      (4 min)

**iTerm2:**

```bash
pct list
```

There's a new one: **app-prod-3**.

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

> "That server did not exist five minutes ago. The pipeline built it."

---

# STEP 9  -  Close                    (2 min)

**Three things:**

**1.** Deleting a password from git doesn't remove it. Change the password first.

**2.** When something is wrong for nine months and nobody notices, the system made it easy to get
wrong. Fix the system.

**3.** The hard part isn't running the scanner. It's choosing what to block, and defending that
choice.

> "Happy to go anywhere you'd like."

---

**Total: 31 minutes**

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
