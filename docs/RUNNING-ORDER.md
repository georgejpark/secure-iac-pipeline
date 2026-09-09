# Running order - 30 minutes

Times are cumulative. If you fall behind, cut from the bottom of the list on the last page.

Have a clock where you can see it.

---

## 0:00 - 0:05   Tell them what happened

**No screen. Just talk.**

I was doing housekeeping. Cataloguing repositories. Boring work.

I ran a search for key files. It came back with **112 private keys**. All committed. 21 production
hostnames. The oldest had been there nine months.

The first commit in that repository was called "Starting up the repository". It already had 63 keys
in it.

**Then the turn:**

I expected carelessness. That's not what I found.

The deploy scripts read the key straight out of the folder you'd just cloned. So to deploy, the key
had to be in the repository. Adding a service meant committing its private key.

Nobody cut corners. They followed the process. **The process was the problem.**

Sixteen commits over nine months. Every one passed code review.

> "So the first thing: when something is wrong for nine months and nobody catches it, it's almost
> never carelessness. The system made the wrong thing easy."

---

## 0:05 - 0:07   Set up the demo

**Still talking. No screen yet.**

There was a second repository. A `.env` file with 74 passwords.

**They caught it.** The next commit was called "Add utility for encrypting/decrypting .env files".

They deleted the file. Added it to gitignore. Wrote an encryption tool.

The repository looked clean afterwards.

> "Let me show you what that actually achieved."

---

## 0:07 - 0:13   THE SECRET DEMO

**Share your screen now. Terminal 2 (server).**

```bash
/root/demo-secret-persistence.sh
```

Talk over the first four steps. Then **stop talking** when `git show` runs.

Let them read the passwords on screen.

> "Every password still there. One command. Deleting a file in git doesn't remove it, it just stops
> pointing at it."

**Then the order that matters:**

> "Change the password first. That takes minutes. Rewriting history takes days, because you have to
> reach every fork and every laptop. Most people do it backwards."

---

## 0:13 - 0:17   THE CHECKS

**Terminal 1 (Mac).**

```bash
make scan-insecure
```

```
dev      10 blocking
stage    14 blocking
prod     14 blocking
```

> "Same code. Development blocks 10 things, production blocks 14. The extra four are things
> development is allowed to skip. Losing a dev box costs an afternoon."

```bash
make scan
```

> "Corrected code. Nothing blocking."

**Then the number that matters:**

> "The scanner finds 24 problems in 110 lines. Nobody reads 24 findings, they mute the tool. So 10
> stop the merge, 5 are advice, 9 are just noted. Choosing which 10 is the actual job."

---

## 0:17 - 0:23   THE PULL REQUEST

**Browser. PR #2.**

Point at three things:

1. **BLOCKED - Review required**
2. Six green ticks
3. The comment the pipeline wrote

> "I can't approve my own pull request. GitHub refuses. In a real team a second engineer approves
> here. I'm the only account, so I'll override, and GitHub records that I did."

**Terminal 2:**

```bash
cd /root/secure-iac-pipeline
gh pr merge 2 --squash --admin --delete-branch
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

> "Development deploys on its own. Staging stops. Production stops."

**Browser: approve staging, then production.**

---

## 0:23 - 0:27   PROVE IT'S REAL

**Terminal 2:**

```bash
pct config 321 | grep memory
```

> "Production now has 3 GB. It had 2."

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  curl -s http://$h:8080/ ; echo
done
```

> "Four machines. Each knows which environment it is. Two in production, because production says
> two."

---

## 0:27 - 0:30   CLOSE

**Three things:**

**1.** Deleting a password from git doesn't remove it. Change the password first.

**2.** When something's wrong for nine months, the system made it easy to get wrong. Fix the system,
not the people.

**3.** The hard part isn't running the scanner. It's choosing what's worth blocking, and defending
that choice to an engineer and an auditor.

> "Happy to go anywhere you'd like with it."

---

# If you're running late

Cut in this order. Top of the list goes first.

**1. The rollback demo.** Say it instead: "rolling back is pointing a symlink at the old folder,
about two seconds."

**2. The isolation test.** Say it instead: "each environment is on its own network, they can't reach
each other, I tested both directions."

**3. The no-API-key demo.** Say it instead: "the AI writes the explanation, it doesn't decide. Take
the key away and the pipeline behaves identically."

**4. Approving production.** Approve staging only, and say production works the same way.

**5. `make scan` passing.** Show only the blocking one. The passing case is less interesting.

---

# Never cut these

**The `git show` moment.** That's the whole talk.

**The pull request sitting BLOCKED.** That's what they asked you to demonstrate.

**The three closing points.** Even if you're out of time, say them.

---

# If they interrupt

Good. Answer, then say **"where was I - right, the checks"** and carry on.

They told you they'd interrupt. An interrupted talk is a conversation. Plan for 25 minutes of
material, not 30.
