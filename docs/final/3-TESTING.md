# Testing and checking

How to prove the thing works, and what all the servers are.

---

# The servers

See document 5, THE SERVERS, for what each one is and does.

Quick reminder:

```
201 ci-dev       checks and deploys development
202 ci-stage     checks and deploys staging
203 ci-prod      checks and deploys production
204 tf-state     remembers what has been built

301 app-dev-1    development web server
311 app-stage-1  staging web server
321 app-prod-1   production web server
322 app-prod-2   production web server
```

---

# Getting in

**You cannot reach these from your laptop.** Those networks only exist on the Proxmox host.

```bash
ssh root@192.168.1.132
```

From there:

```bash
pct exec 301 -- bash              # a shell inside app-dev-1
ssh opsadmin@10.10.10.20          # or over ssh
```

The password is in `/root/creds/opsadmin-dev.pw` on the host.

---

# Run everything at once

Before doing anything by hand, run this on the host. It is every check in this document, and it takes
about a minute.

```bash
ssh root@192.168.1.132
/root/validate.sh
```

Expect the last line to read:

```
38 passed, 0 failed
```

If anything says FAIL it prints what it expected next to it. Work that one out before carrying on.

The individual tests below are the same checks written out one at a time, so I can run any single one
in front of the panel and explain what it proves.

---

# TEST 1  -  Is every application answering?

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21 10.30.10.22; do
  echo -n "$h  "
  curl -s --max-time 5 http://$h:8080/
  echo
done
```

**What you should see:**

```
10.10.10.20  {"message": "Hello World, Hello Guys This is George and nice to meet you", "environment": "dev", "host": "app-dev-1", "version": "1.1.0"}
10.20.10.20  {"message": "Hello World, Hello Guys This is George and nice to meet you", "environment": "stage", "host": "app-stage-1", "version": "1.1.0"}
10.30.10.20  {"message": "Hello World, Hello Guys This is George and nice to meet you", "environment": "prod", "host": "app-prod-1", "version": "1.1.0"}
10.30.10.21  {"message": "Hello World, Hello Guys This is George and nice to meet you", "environment": "prod", "host": "app-prod-2", "version": "1.1.0"}
10.30.10.22  {"message": "Hello World, Hello Guys This is George and nice to meet you", "environment": "prod", "host": "app-prod-3", "version": "1.1.0"}
```

Each one names itself. That's how you know you're talking to different machines.

**If one doesn't answer:** you're probably on your laptop. Check you ran `ssh root@192.168.1.132`
first.

---

# TEST 2  -  Is the service healthy?

```bash
curl -s http://10.30.10.20:8080/health
```

```
{"status": "ok"}
```

---

# TEST 3  -  Which version is running?

```bash
curl -s http://10.30.10.20:8080/version
```

```
{"version": "1.1.0"}
```

This matters more than it looks. The deploy script checks this number before it reports success, and
it waits for the health check rather than asking once. If the new code didn't actually start, the
deploy fails instead of telling you everything is fine.

---

# TEST 4  -  Is the service set to survive a reboot?

```bash
for i in 301 311 321 322 323; do
  echo -n "$i  "
  pct exec $i -- systemctl is-enabled inspection-service
done
```

All five should say `enabled`.

---

# TEST 5  -  Is it running as a normal user, not root?

```bash
pct exec 321 -- ps -eo user,args | grep [a]pp.py
```

Should say `rapta`, not `root`.

---

# TEST 6  -  Can the environments reach each other?

They shouldn't be able to.

```bash
pct exec 301 -- ping -c2 -W2 10.30.10.20
```

Development trying to reach production. **This should fail.**

```bash
pct exec 321 -- ping -c2 -W2 10.10.10.20
```

Production trying to reach development. **This should also fail.**

---

# TEST 7  -  Can development read production's passwords?

```bash
pct exec 201 -- su - runner -c \
  "SOPS_AGE_KEY_FILE=/home/runner/.config/sops/age/keys.txt sops --decrypt /tmp/prod.enc.yaml"
```

**Should fail with:**

```
no master key was able to decrypt the file
```

The encrypted file is in the repository. Anyone can see it. Only the production machine holds the key
that opens it.

---

# TEST 8  -  Can development read production's database?

Even with the correct password:

```bash
PW=$(pct exec 204 -- cat /root/creds/prod.pw)
pct exec 201 -- bash -c "PGPASSWORD='$PW' psql -h 10.40.10.10 -U tf_prod -d tfstate_prod -c 'SELECT 1'"
```

**Should fail with:**

```
no pg_hba.conf entry for host "10.10.10.10"
```

Right password. Wrong network. Still refused.

---

# TEST 9  -  Does the deploy step leave working servers alone?

**What I am checking:** that I can run the deploy safely at any time, including twice by accident.

Run it against an environment where everything is already working:

```bash
/root/install-app.sh prod
```

```
environment=prod  version=1.1.0  containers=2
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
done
```

**Good:** every line says `skipped`. Nothing was restarted, so nothing dropped a request.

**Bad:** it reinstalls on a server that was already fine. That would mean the check at the top is
wrong, and every deploy would cause an unnecessary restart of healthy production servers.

## Why it is written this way

The script asks each container what version it is serving before deciding to act. That is the
difference between a deploy you can run confidently and one you only dare run during a window.

## The failure I found by testing this

The first version installed Python by checking `python3 -m venv --help`. That command succeeds on a
stock Debian 13 container. But actually building the virtual environment then fails, because the
help text ships in the standard library while the machinery ships in a separate package.

So the check passed, the install was skipped, and the deploy broke two steps later with a confusing
error about `ensurepip`.

The fix was to test for the thing that is genuinely needed:

```bash
python3 -c "import ensurepip"
```

Worth saying out loud if it comes up: **a check that tests something adjacent to what you need is
worse than no check at all**, because it reports success. That is the same shape as the gitleaks
problem in the main story.

---

# TEST 10  -  Roll back and forward

Go back to the old version:

```bash
pct exec 301 -- ln -sfn /opt/rapta/inspection/releases/1.0.0 /opt/rapta/inspection/current
pct exec 301 -- systemctl restart inspection-service
curl -s http://10.10.10.20:8080/version
```

Should say `1.0.0`.

Put it back:

```bash
pct exec 301 -- ln -sfn /opt/rapta/inspection/releases/1.1.0 /opt/rapta/inspection/current
pct exec 301 -- systemctl restart inspection-service
curl -s http://10.10.10.20:8080/version
```

Should say `1.1.0`.

Both versions stay on disk. Rolling back is pointing at the old folder.

---

# What to screenshot

**From GitHub:**

1. The pull request showing **BLOCKED - Review required**
2. The comment the pipeline wrote
3. The Actions page showing dev finished and stage/prod waiting
4. The approval record with your name and the time

**From Proxmox:**

5. The container list showing all nine (eight before the demo, nine after)
6. A console session inside one of them

**From the terminal:**

7. All five applications answering with their own hostname

---

# Quick reference

```bash
ssh root@192.168.1.132                # get to the host first

pct list                              # what exists
pct exec 301 -- bash                  # shell into a container
pct config 321                        # how a container is configured

curl -s http://10.30.10.20:8080/      # ask an application who it is
/root/install-app.sh prod             # install/repair an environment, safe to repeat
```

**The addresses are the containers, not the host.** Nothing listens on the Proxmox host itself, so
`curl 127.0.0.1:8080` from the host prompt will always refuse the connection. That is correct
behaviour. The applications live at:

```
dev      10.10.10.20
stage    10.20.10.20
prod     10.30.10.20 , 10.30.10.21 , and 10.30.10.22 after the demo
```
