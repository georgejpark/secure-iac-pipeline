# My demo

Everything I run, in order. This is the only document I need open.

---

# PART 1. What I'm showing

Four things:

1. A GitHub pipeline that checks code before it can be merged
2. What's in the repository, and what each part builds
3. The servers I run it on, instead of AWS
4. A change going out, and how I prove it worked

---

# PART 2. What's in the repository

One repository. Four folders that matter.

## `terraform/` - builds the machines

```
terraform/
├── modules/workload/       one description of a container
├── deploy/dev/             1 container,  1 CPU,  512 MB
├── deploy/stage/           1 container,  2 CPU,  1 GB
├── deploy/prod/            2 containers, 2 CPU,  2 GB
└── insecure/               deliberately bad code, to prove the checks work
```

**What Terraform does here:** creates Linux containers on my server. How many, how big, which network.

Production says 2 containers. Development says 1. That number lives in one file, nowhere else.

## `.github/workflows/` - the pipeline

One file: `security-pipeline.yml`

It runs four jobs whenever I open a pull request:

1. Look for passwords in the code
2. Check the Terraform for unsafe settings
3. Sort the findings and write me a comment
4. Stop the merge if anything is wrong

## `scripts/` - two small programs I wrote

- `ai_triage.py` sorts findings and writes the comment
- `policy_check.py` checks the plan before Terraform runs it

## `docs/` - the documents and diagrams

---

# PART 3. The servers

## What I have

One physical server running Proxmox. 104 CPUs, 62 GB of memory.

On it, eight Linux containers:

**Four run the pipeline:**

```
201  ci-dev      runs the checks and deploys for development
202  ci-stage    runs the checks and deploys for staging
203  ci-prod     runs the checks and deploys for production
204  tf-state    a database holding what Terraform has built
```

**Four run the application:**

```
301  app-dev-1     development
311  app-stage-1   staging
321  app-prod-1    production
322  app-prod-2    production, second copy
```

## Why three separate machines for the pipeline

If one machine ran everything, then code from a development pull request would run on the same
machine that deploys production.

Somebody could put something in a development branch and reach production with it.

Three machines. Development code never touches the production machine.

## Why Proxmox and not AWS

I don't have an AWS account for personal projects.

Everything I'm showing works the same way on AWS. The only thing that changes is the last command.
`terraform apply` still runs. It just creates EC2 instead of containers.

## The networks

Each environment is on its own network.

```
Development   10.10.10.x
Staging       10.20.10.x
Production    10.30.10.x
```

They cannot reach each other. I tested it in both directions and both are blocked.

---

# PART 4. The demo

## Before I start

Two terminals open:

```
Terminal 1     my Mac
Terminal 2     ssh root@192.168.1.132
```

---

## Step 1. Show what's running now

**Terminal 2 (the server):**

```bash
pct list
```

Eight containers.

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  curl -s http://$h:8080/ ; echo
done
```

Each one answers:

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-1",
  "version": "1.1.0"
}
```

Four machines. Each knows which environment it is.

---

## Step 2. Show that deleting a secret doesn't remove it

**Terminal 2:**

```bash
/root/demo-secret-persistence.sh
```

Press enter to move through it. It takes about 90 seconds.

It makes a repository, puts a password in, then deletes the file, ignores it, and encrypts it. Then
it shows the password is still there.

**Stop talking when `git show` runs.** Let them read it.

---

## Step 3. Show the checks catching bad code

**Terminal 1 (my Mac):**

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline
make scan-insecure
```

```
dev      exit=1   blocking=10
stage    exit=1   blocking=14
prod     exit=1   blocking=14
```

Same code. Development blocks 10 things. Production blocks 14.

The extra four are things development is allowed to skip.

**Then show it passing:**

```bash
make scan
```

```
No blocking findings.
```

---

## Step 4. Show it works without the AI

**Terminal 1:**

```bash
unset ANTHROPIC_API_KEY && make scan
```

Same result. The AI writes the explanation. It doesn't decide anything.

If the AI service is down, the pipeline works exactly the same.

---

## Step 5. Show the pull request waiting

Open this in a browser:

```
https://github.com/georgejpark/secure-iac-pipeline/pull/2
```

Point at three things:

1. **BLOCKED - Review required**
2. All six checks passed (green ticks)
3. The comment the pipeline wrote, listing what it found

**Then say:**

> "I can't approve this myself. GitHub won't let me. In a real team a second engineer approves here.
> I'm the only account, so I'll merge with an override, and GitHub records that."

---

## Step 6. Merge it and watch it deploy

**Terminal 2:**

```bash
cd /root/secure-iac-pipeline
gh pr merge 2 --squash --admin --delete-branch
```

Then watch:

```bash
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

What happens:

- Development deploys straight away
- Staging stops and waits for approval
- Production stops and waits for approval

---

## Step 7. Approve staging and production

In the browser, on the Actions page, click **Review deployments**, tick the box, approve.

Do it for staging. Then production.

**Say:**

> "Development goes out on its own. Staging and production each need somebody to say yes."

---

## Step 8. Prove it actually changed

**Terminal 2:**

```bash
pct config 321 | grep memory
```

Production now has 3 GB instead of 2 GB.

```bash
for h in 10.30.10.20 10.30.10.21; do curl -s http://$h:8080/ ; echo; done
```

Both production machines still answering.

---

## Step 9. Show the machines can't reach each other

**Terminal 2:**

```bash
pct exec 301 -- ping -c2 -W2 10.30.10.20
```

Development trying to reach production. It fails.

```bash
pct exec 321 -- ping -c2 -W2 10.10.10.20
```

Production trying to reach development. Also fails.

---

## Step 10. Show a rollback

**Terminal 2:**

```bash
pct exec 301 -- ln -sfn /opt/rapta/inspection/releases/1.0.0 /opt/rapta/inspection/current
pct exec 301 -- systemctl restart inspection-service
curl -s http://10.10.10.20:8080/version
```

Back to 1.0.0 in about two seconds.

**Put it back:**

```bash
pct exec 301 -- ln -sfn /opt/rapta/inspection/releases/1.1.0 /opt/rapta/inspection/current
pct exec 301 -- systemctl restart inspection-service
```

**Say:**

> "The old version never left the disk. Rolling back is pointing at the old folder again."

---

# If something goes wrong

**The pipeline fails:** good. Read the error out loud. A pipeline that stops a bad change in front of
an audience is better than one that quietly works.

**A container doesn't answer:** check you're on the server, not your Mac. Those networks don't exist
from your Mac.

**The demo script is missing:** run the copy on the server. My Mac's antivirus keeps deleting it,
because a script that writes AWS keys into a file looks exactly like a real attack.

**You get asked something you don't know:** say so. "I don't know, I'd check X" is a better answer
than a guess.

---

# The three things to leave them with

1. **Deleting a password from git doesn't remove it.** Change the password first. Clean up second.

2. **When something's wrong for nine months and nobody notices, the system made it easy to get
   wrong.** Fix the system.

3. **The hard part isn't running the scanner.** It's choosing what's worth blocking, and being able
   to defend that choice.
