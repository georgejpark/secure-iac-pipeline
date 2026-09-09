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
        a new server exists
        and answers
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

## 15. A new server exists

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

---

# The tools, in one line each

**gitleaks** looks for passwords and API keys in your code. It knows what they look like.

**Checkov** reads Terraform and finds unsafe settings.

**terraform fmt** tidies up formatting so code reviews aren't arguments about spacing.

**terraform validate** catches typos before anything is built.

**SOPS** encrypts passwords so they can be stored in the repository safely.

**Terraform** creates the servers.

**Ansible** installs the application onto servers that already exist.

---

# Why each environment is separate

Development, staging and production are on separate networks.

They cannot reach each other. Tested in both directions.

If somebody breaks into development, they have reached development. Nothing else.

Each one also has its own encryption key and its own database. The development machine physically
cannot read production's passwords.
