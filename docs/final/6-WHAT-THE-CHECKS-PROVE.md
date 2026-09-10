<!-- title -->
# The Password You Already Deleted

### Secrets in git, and a pipeline that stops them reaching production

George Park  ·  Senior DevSecOps  ·  Texas Mutual  ·  10 September 2026

*Document 6 of 7 — What each check proves, and what it does not.*

---

# What the checks prove

A walk through `validate.sh`. Thirty eight checks, nine groups. Written for the state after the demo has built the servers.

---

# Why this document exists

I make a number of claims during the demo. Each environment is isolated. The application does not run
as root. Rolling back is a symlink move. Production cannot be reached from development.

Claims are cheap. This script is how I check every one of them before I say it out loud, and it is
how I would check them on a Monday morning in a real job.

It is also honest about something. A check that tests *something adjacent* to what you need is worse
than having no check at all, because it reports success. That happened to me while building this, and
I have written it up in group 9.

---

# Running it

```bash
ssh root@192.168.1.132
/root/validate.sh
```

About one minute. Every line prints `PASS` or `FAIL`. A failure prints what it expected next to it,
so the output tells you what to look at rather than just that something is wrong.

The last line is a count:

```
38 passed, 0 failed
```

The script exits non-zero if anything failed, so it can be run by something else later without a
person reading the output.

---

# The layout it is checking

```
Proxmox host  192.168.1.132   pve2

  CI runners                      Applications
  201  ci-dev                     301  app-dev-1     10.10.10.20
  202  ci-stage                   311  app-stage-1   10.20.10.20
  203  ci-prod                    321  app-prod-1    10.30.10.20
  204  tf-state                   322  app-prod-2    10.30.10.21

  dev      10.10.10.0/24    vmbr1
  stage    10.20.10.0/24    vmbr2
  prod     10.30.10.0/24    vmbr3
  state    10.40.10.0/24    vmbr4
```

Each environment is a separate network on a separate bridge. That is the thing groups 6, 7 and 8
exist to prove.

---

# GROUP 1  -  Infrastructure          (3 checks)

## 1.1  Nine containers exist

```bash
pct list | tail -n +2 | wc -l
```

**Proves:** nothing has been deleted since the last run.

**Why it matters:** after the demo there are four CI containers and five application containers. If one is
gone, a later check fails in a confusing way. Better to find out here.

## 1.2  All nine are running

```bash
pct list | tail -n +2 | grep -c running
```

**Proves:** none of them are stopped or paused.

**Why it matters:** a stopped container still appears in `pct list`. Counting containers is not the
same as counting working containers, so this is checked separately rather than assumed.

## 1.3  VMID 323 exists

```bash
pct list | grep "^323 "
```

**Proves:** the container the demo's pull request added is really there.

**Why it matters:** this is the one that would have stopped the demo the other way round. Before the
demo the check was "323 is free", because if anything was sitting on that ID the apply would have
failed in front of the audience - I had created a test container at 323 while building the deploy
step and had to remember to destroy it. After the demo the check flips: 323 must exist, because that
is what the pull request built.

---

# GROUP 2  -  Each application answers        (4 checks)

One check per application: dev, stage, prod-1, prod-2.

```bash
curl -s --max-time 5 http://10.10.10.20:8080/health
```

Expected:

```json
{"status": "ok"}
```

**Proves:** the process is alive, listening on port 8080, and past its startup grace period.

**Why it matters:** it is the cheapest possible signal that the thing is working, and it is what the
deploy step waits on before reporting success.

## The detail worth knowing

The application deliberately answers **503** for the first two seconds after it starts:

```python
if (time.monotonic() - _started_at) < STARTUP_GRACE_S:
    self._json(503, {"status": "starting"})
```

That is not a bug. It is there because a health check that fires immediately after a restart will
race the process and report a failure that is not real. Anything checking this has to retry rather
than ask once. The deploy step retries for twenty seconds.

## A trap to avoid

These addresses are the **containers**. Nothing listens on the Proxmox host itself, so this at the
host prompt will always refuse the connection:

```bash
curl http://127.0.0.1:8080/health        # connection refused, and that is correct
```

I made this mistake myself while testing. It reads like an outage and it is not one.

---

# GROUP 3  -  Each application knows who it is    (4 checks)

```bash
curl -s http://10.30.10.20:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-1",
  "version": "1.1.0"
}
```

Each check confirms three things, and fails if any one of them is wrong:

1. The greeting text is exactly right
2. `host` matches the container it was asked
3. `environment` matches the environment it belongs to

**Why all three:** the greeting alone would pass even if every server returned identical output. Then
I could not tell five servers from one server answering five times. Checking the hostname is what
makes "there are five separate machines" a demonstrated fact rather than an assertion.

## How the application knows

Nothing configures this. It reads its own hostname and splits it:

```python
host = socket.gethostname()
env = host.split("-")[1] if "-" in host else "unknown"
```

`app-prod-1` becomes environment `prod`. This is why a freshly built container reports itself
correctly the moment the application starts, with no per-environment configuration file to get wrong.

---

# GROUP 4  -  Version, service account, restart on boot   (12 checks)

Three checks on each of the four applications.

## 4.1  It is running 1.1.0

```bash
curl -s http://10.10.10.20:8080/version
```

```json
{"version": "1.1.0"}
```

**Proves:** the running process is serving the version we think it is.

**Why it matters:** the version is read from a `VERSION` file inside the release directory, not
compiled in. So this answer changes when the `current` symlink moves. That makes it the honest way to
confirm a deploy or a rollback actually took effect, rather than trusting that a command succeeded.

## 4.2  It runs as `rapta`, not root

```bash
pct exec 321 -- ps -eo user,args | grep [a]pp.py
```

```
rapta    /opt/rapta/inspection/current/venv/bin/python /opt/rapta/inspection/current/app.py
```

**Proves:** the process is running as an unprivileged service account.

**Why it matters:** if the application is compromised, the attacker gets whatever the application
account has. Running as root means they get the container. Combined with the containers being
unprivileged, a root escape inside one would otherwise be root on the hypervisor, which is why
Terraform sets `unprivileged = true` and the policy check enforces it.

The account is created by the deploy step and cannot log in:

```bash
useradd --system --create-home --home-dir /home/rapta --shell /usr/sbin/nologin rapta
```

## 4.3  It comes back after a reboot

```bash
pct exec 321 -- systemctl is-enabled inspection-service
```

```
enabled
```

**Proves:** systemd will start the service automatically on boot.

**Why it matters:** `is-active` and `is-enabled` answer different questions. A service can be running
right now and still be gone after a power cut, because nobody enabled it. That is the kind of thing
you find out at the worst possible moment, so it is checked explicitly.

Production containers also have `start_on_boot = true` set by Terraform, so the container itself
comes back as well as the service inside it. Two different layers, both needed.

---

# GROUP 5  -  Both releases are on disk       (4 checks)

```bash
pct exec 301 -- ls /opt/rapta/inspection/releases/
```

```
1.0.0
1.1.0
```

**Proves:** the previous version is still present, so a rollback has somewhere to go.

## Why the layout is like this

```
/opt/rapta/inspection/
    current  ->  releases/1.1.0
    releases/
        1.0.0/   app.py  VERSION  requirements.txt  venv/
        1.1.0/   app.py  VERSION  requirements.txt  venv/
```

Each release lives in its own directory with its own virtual environment. Deploying means adding a
directory and moving the `current` symlink. That symlink move **is** the release.

The systemd unit points at `current`, never at a version number:

```
ExecStart=/opt/rapta/inspection/current/venv/bin/python /opt/rapta/inspection/current/app.py
```

So a rollback is two commands and needs no file edited:

```bash
ln -sfn /opt/rapta/inspection/releases/1.0.0 /opt/rapta/inspection/current
systemctl restart inspection-service
```

**Why it matters:** the alternative is a rollback that means running a deploy of the old version,
which needs the old artifact to still be available, the network to work, and the package index to be
up. A rollback should be the most reliable operation you have, because you only reach for it when
something is already wrong. Making it a local symlink move is what achieves that.

Tested on all four containers, rolling to 1.0.0 and back to 1.1.0. All four returned the expected
version both ways.

---

# GROUP 6  -  Environments cannot reach each other    (6 checks)

Every direction, both ways, for all three environments.

```bash
pct exec 301 -- ping -c1 -W2 10.30.10.20      # dev  -> prod
pct exec 321 -- ping -c1 -W2 10.10.10.20      # prod -> dev
```

All six must fail:

```
dev   -> stage     blocked
dev   -> prod      blocked
stage -> dev       blocked
stage -> prod      blocked
prod  -> dev       blocked
prod  -> stage     blocked
```

**Proves:** the three environments are on separate networks with no route between them.

**Why both directions:** a one way test proves less than it looks. Blocking dev to prod but leaving
prod to dev open still gives an attacker who lands in production a path into the other environments,
and it is exactly the sort of asymmetry a hand written firewall rule produces. So all six are
checked.

## How it is enforced

Each environment is a separate bridge with its own subnet, and the host forwarding policy does not
route between them. It is not enforced by the container firewall.

That is deliberate, and it is worth being able to explain. I tried the container firewall first. On
this Proxmox version it drops return traffic regardless of the inbound policy, which breaks the
application without adding protection. So the module sets `firewall = false` and the separation is
done at the bridge instead.

There is a policy in the deploy gate for the container firewall, `PVE-2`, and it is deliberately
enforced in no environment, with the reason recorded next to it. A control that is switched off with
a written reason is honest. A control that is switched on and does nothing is worse than not having
it.

---

# GROUP 7  -  Development cannot open production's secrets   (1 check)

```bash
pct exec 201 -- su - runner -c \
  "SOPS_AGE_KEY_FILE=/home/runner/.config/sops/age/keys.txt sops --decrypt /tmp/prod.enc.yaml"
```

Expected:

```
Recovery failed because no master key was able to decrypt the file.
```

**Proves:** the development runner holds a key that cannot open production's encrypted file.

## How it works

Every environment's secrets are encrypted with SOPS using a separate age key. The encrypted files are
committed to the repository, so anyone can read them. Only the matching runner holds the private key
that opens one.

```
terraform/envs/dev/secrets.enc.yaml     opened only by the key on ci-dev
terraform/envs/stage/secrets.enc.yaml   opened only by the key on ci-stage
terraform/envs/prod/secrets.enc.yaml    opened only by the key on ci-prod
```

**Why it matters:** this is what stops a change to a development pipeline from becoming a route to
production credentials. The file being public is the point. The security is in key distribution, not
in hiding the file, which means it survives someone cloning the repository.

Note what the check does: it copies production's encrypted file **onto the development machine** and
tries to open it there. That is a stronger test than checking a file is absent, because it assumes
the attacker already has the file.

---

# GROUP 8  -  Right password, wrong network, still refused   (1 check)

```bash
PW=$(pct exec 204 -- cat /root/creds/prod.pw)
pct exec 201 -- bash -c "PGPASSWORD='$PW' psql -h 10.40.10.10 -U tf_prod -d tfstate_prod -c 'SELECT 1'"
```

Expected:

```
FATAL:  no pg_hba.conf entry for host "10.10.10.10", user "tf_prod", database "tfstate_prod"
```

**One trap in this check.** If `/root/creds/prod.pw` were missing, `PW` would be empty and the
connection would *still* be refused, because Postgres checks the source address before it looks
at the password. The check would pass while proving nothing. So `validate.sh` treats an empty
password as a failure, and the file is confirmed present on 204 before the demo.

**Proves:** production's Terraform state database refuses the development machine even when the
correct password is supplied.

**Why it matters:** this is the clearest demonstration of defence in depth in the whole build. The
check deliberately hands development the real production password, which is the worst case you are
usually trying to prevent, and the connection is still refused because the request came from the
wrong network.

Postgres decides this in `pg_hba.conf` before authentication happens. The rule is per source address
per database per user, so a leaked password on its own is not enough.

The state database matters because Terraform state contains resource identifiers and can contain
secrets. Write access to production state is close to control of production infrastructure.

## Why this one is worth showing live

Most security controls are hard to demonstrate because success looks like nothing happening. This one
produces a specific error message naming the source address that was refused. It is visible, it is
unambiguous, and the audience can read it.

---

# GROUP 9  -  The deploy step is staged and repeatable    (3 checks)

## 9.1  The script is present

```bash
test -x /root/install-app.sh
```

## 9.2  Its source files are staged

```bash
ls /opt/app-source/
```

```
app.py    requirements.txt    VERSION    inspection-service.service
```

**Why it matters:** the deploy step copies these onto each container. If they are missing the deploy
fails halfway, leaving a container built but not serving.

## 9.3  Re-running it leaves healthy servers alone

```bash
/root/install-app.sh prod
```

Expected:

```
environment=prod  version=1.1.0  containers=2
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
done
```

**Proves:** the deploy is safe to run at any time, including twice by accident.

The check fails if the output contains the word `installing`, because that would mean it reinstalled
onto a server that was already working.

**Why it matters:** a deploy you can only run during a window is a deploy people put off. The script
asks each container what version it is serving before deciding to act, so running it again changes
nothing and restarts nothing.

## The failure I found by testing this, and what it cost

The first version of the script decided whether to install Python by running:

```bash
python3 -m venv --help
```

On a stock Debian 13 container that command **succeeds**. Actually creating a virtual environment
then **fails**, because the help text ships in the standard library while the machinery that builds
the environment ships in a separate package.

So the check passed, the install was skipped, and the deploy broke two steps later with an error
about `ensurepip` that had nothing obvious to do with the real cause.

The fix was to test for the thing that is actually needed:

```bash
python3 -c "import ensurepip"
```

I found this because I built a throwaway container matching what Terraform produces and ran the
deploy against it, rather than assuming it would work. Had I not, it would have failed live, on the
one container the audience was watching.

**The general lesson, and it is the same one as the main story:** a check that tests something
adjacent to what you need is worse than no check at all. No check leaves you knowing you are
uncovered. A check that reports success on the wrong thing leaves you believing you are covered. That
is how a scanner reads zero bytes and reports no leaks found, and it is how this script skipped an
install it needed to do.

---

# What this does not check

Being clear about the edges, because being asked about them is likely.

**It does not check the GitHub side.** Branch protection, required reviewers and the pipeline runs are
visible in the browser and are not tested here.

**It does not check runtime security.** Nothing here watches what the application does once it is
running. No intrusion detection, no anomaly detection, no audit of what the process touches.

**It does not test the isolation from outside.** All six network checks run from inside containers on
this host. A determined test would come from somewhere else on the network.

**It does not check restore.** It confirms the previous release is on disk and that rolling to it
works. It does not test recovery from a lost container or a lost host.

**It does not load test.** The applications answer. Nothing here says how many requests they would
survive.

---

# Summary

```
GROUP 1   Infrastructure                              3
GROUP 2   Each application answers                    4
GROUP 3   Each application knows who it is            4
GROUP 4   Version, service account, restart on boot  12
GROUP 5   Both releases on disk                       4
GROUP 6   Environments cannot reach each other        6
GROUP 7   Dev cannot open prod secrets                1
GROUP 8   Right password, wrong network, refused      1
GROUP 9   Deploy staged and repeatable                3
                                                    ---
                                                     38
```

Three isolation boundaries, tested separately, because any one of them can fail on its own:

**Network.** Different subnets, no route between them. Group 6.

**Cryptographic.** Different keys, so the encrypted file is useless on the wrong machine. Group 7.

**Database.** Source address checked before the password. Group 8.

A single boundary is a single point of failure. Someone who defeats the network still has to defeat
the key, and someone holding a leaked password still has to be on the right network.
