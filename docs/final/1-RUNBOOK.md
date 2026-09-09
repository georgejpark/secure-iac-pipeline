# RUNBOOK

The document I read while I present.

---

# Why I'm here

Companies leak passwords into their code. Then they delete the file and think they've fixed it.

They haven't.

I'm going to show you that, then show you a pipeline that stops it happening.

---

# What I'm going to prove

1. A password deleted from git is still there
2. Bad infrastructure code gets blocked before it merges
3. Nothing reaches production without a person approving it
4. All of it is running right now, and I can change it in front of you

---

# What I built

A GitHub repository with Terraform in it.

When I change that code, a pipeline checks it. If it passes, and a person approves, it builds Linux
servers.

Right now there are five servers running a small web application.

- 1 for development
- 1 for staging
- 3 for production

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
