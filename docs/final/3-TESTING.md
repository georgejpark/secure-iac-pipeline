# Testing and checking

How to prove the thing works, and what all the servers are.

---

# The servers

There are nine containers on one Proxmox host. Two groups.

## The 20X group runs the pipeline

These are the machines that do the checking and the building.

**201  ci-dev**

Runs the checks for development. Also runs the password scan for every pull request, because that job
only reads code and needs no access to anything.

**202  ci-stage**

Runs the checks and the deployment for staging. Nothing else.

**203  ci-prod**

Runs the checks and the deployment for production. Only ever runs production jobs.

**204  tf-state**

A PostgreSQL database. It remembers what Terraform has already built, so it knows what to change.

### Why three machines and not one

If one machine ran everything, code from a development pull request would run on the same machine that
deploys production.

Somebody could put something in a development branch and reach production with it.

Three machines means development code never touches the production machine.

## The 30X group runs the application

**301  app-dev-1**       development
**311  app-stage-1**     staging
**321  app-prod-1**      production
**322  app-prod-2**      production
**323  app-prod-3**      production

Production has three because the file says three.

---

# Where they live

Each environment is on its own network.

```
Development    10.10.10.x
Staging        10.20.10.x
Production     10.30.10.x
Management     10.40.10.x
```

Within each one:

```
.1     the gateway
.10    the pipeline machine
.20+   the application servers
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

This matters more than it looks. When Ansible deploys, it checks this number. If the new code didn't
actually start, the deploy fails instead of saying everything is fine.

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

# TEST 9  -  Roll back and forward

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

5. The container list showing all nine
6. A console session inside one of them

**From the terminal:**

7. All five applications answering with their own hostname

---

# Quick reference

```bash
ssh root@192.168.1.132              # get to the host first

pct list                            # what exists
pct exec 301 -- bash                # shell into a container
pct config 321                      # how a container is configured

curl -s http://10.30.10.20:8080/    # ask an application who it is
```
