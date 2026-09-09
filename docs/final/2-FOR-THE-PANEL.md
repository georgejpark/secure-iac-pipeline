# How a change reaches production

A handout. Follow along.

---

# The change

Production is running out of room during month-end close.

I'm adding a third server.

That's it. One number in one file goes from `2` to `3`.

---

# The path it takes

```
        I clone the repository
                 |
        I make a branch
                 |
        I change one number
                 |
        I commit  ------------> a hook checks for passwords first
                 |
        I push
                 |
        I open a pull request
                 |
   +-------------+-------------+
   |             |             |
 secrets      terraform     write a
  check        checks       comment
   |             |             |
   +-------------+-------------+
                 |
        anything blocking?  ---- yes ----> STOPPED. fix it.
                 |
                 no
                 |
        somebody approves it
                 |
        I merge to main
                 |
   +-------------+-------------+
   |             |             |
  DEV          STAGE         PROD
 goes out     waits for     waits for
  on its       someone       someone
   own        to approve    to approve
   |             |             |
   +-------------+-------------+
                 |
        terraform builds the server
                 |
        the deploy step installs
        the application on it
                 |
        the new server answers
```

---

# Step by step

## 1. Get the code

```bash
git clone git@github.com:georgejpark/secure-iac-pipeline.git
```

## 2. Make a branch

```bash
git checkout -b demo/TM-118-third-production-server
```

Never work directly on `main`.

## 3. Change one number

File: `terraform/deploy/prod/main.tf`

```
replica_count = 2      becomes      replica_count = 3
```

Development and staging have their own files. They aren't affected.

## 4. Commit

```bash
git commit -m "TM-118: add a third production server"
```

Before this saves, a hook runs. It looks for passwords and API keys.

If it finds one, the commit doesn't happen. Nothing has left my laptop.

## 5. Push and open a pull request

```bash
git push -u origin demo/TM-118-third-production-server
gh pr create --base main
```

This is what starts the pipeline.

## 6. The pipeline looks for passwords

It reads **every commit ever made**, not just mine.

That matters. A password committed last year and deleted since would be invisible if it only looked
at today's files.

If it finds one, the pull request stops here.

## 7. The pipeline checks the infrastructure code

This is **Checkov**. It reads Terraform and looks for unsafe settings.

Examples of what it stops:

- A storage bucket anyone on the internet can read
- SSH open to the whole world
- A database with no encryption

It runs three times. Once per environment.

- Development blocks **10** things
- Staging blocks **14**
- Production blocks **14**

The extra four are things development is allowed to skip.

## 8. The pipeline writes a comment

It finds 24 problems in 110 lines of code.

Nobody reads 24 findings. They turn the tool off instead.

So a script sorts them:

- **10** stop the merge
- **5** are advice
- **9** are noted

Then it writes a comment in plain English.

## 9. The pull request is blocked

It says:

```
BLOCKED - Review required
```

## 10. Somebody approves it

I cannot approve my own pull request. GitHub refuses:

```
Can not approve your own pull request
```

Someone else has to look at it.

## 11. I merge

Merging is what allows a deployment. Nothing deploys before this.

## 12. Development deploys by itself

No approval needed. It goes.

## 13. Staging waits

GitHub says *Waiting for review*. Someone clicks approve.

## 14. Production waits

Same again. Someone clicks approve.

## 15. Terraform builds a new server

The file said two production servers. It now says three. Terraform works out that one is missing and
creates it.

```
proxmox_virtual_environment_container.app[2]: Creation complete
```

That machine is empty. Terraform talks to the Proxmox API to build machines. It never logs into
them.

## 16. The deploy step installs the application

```bash
/root/install-app.sh prod
```

```
environment=prod  version=1.1.0  containers=3
  app-prod-1 (321)  already serving 1.1.0  - skipped
  app-prod-2 (322)  already serving 1.1.0  - skipped
  app-prod-3 (323)  installing 1.1.0 ...
    app-prod-3 serving {"version": "1.1.0"}
done
```

Two things worth noticing.

**It skipped the servers that were already working.** It asks each one what it is serving before it
touches anything, so running it twice changes nothing.

**It waits for the health check.** The application answers 503 for the first two seconds on purpose.
A check that fires immediately after a restart would race it and report a failure that isn't real.

On each container it does seven things: creates a service account so the app does not run as root,
installs Python if missing, copies the release into its own folder, builds a virtual environment,
moves the `current` symlink, installs a systemd unit that points at `current` rather than at a version
number, and waits for health to pass. Moving that symlink *is* the release, which is why a rollback
is a symlink move and not a redeploy.

## 17. The new server answers

```bash
curl http://10.30.10.22:8080/
```

```json
{
  "message": "Hello World, Hello Guys This is George and nice to meet you",
  "environment": "prod",
  "host": "app-prod-3",
  "version": "1.1.0"
}
```

It knows it is production because it reads that from its own hostname. Nothing had to tell it.

---

# The tools, in one line each

**gitleaks** looks for passwords and API keys in your code. It knows what they look like.

**Checkov** reads Terraform and finds unsafe settings.

**terraform fmt** tidies up formatting so code reviews aren't arguments about spacing.

**terraform validate** catches typos before anything is built.

**SOPS** encrypts passwords so they can be stored in the repository safely.

**Terraform** creates the servers.

**The deploy script** installs the application onto servers that already exist. It creates a
service account, copies the release into its own folder, and moves one symlink. That symlink move is
the release, which is why rolling back is a symlink move too.

---

# Why each environment is separate

Development, staging and production are on separate networks.

They cannot reach each other. Tested in both directions.

If somebody breaks into development, they have reached development. Nothing else.

Each one also has its own encryption key and its own database. The development machine physically
cannot read production's passwords.
