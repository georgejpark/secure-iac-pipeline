# What I'm showing you today

---

## Part 1. How this started

A few weeks ago I was doing housekeeping. Going through repositories, writing down what each one did.
Boring work.

I ran a search for key files. Just to fill in a section of a document.

It came back with 112 private keys.

All of them committed. All in one repository. They covered 21 production hostnames. The oldest had
been sitting there for nine months.

I looked at the first commit in that repository. It was called "Starting up the repository." It
already had 63 keys in it.

So nobody made a mistake one day. The keys were there from the beginning.

---

## Part 2. Why it happened

I expected to find carelessness. That's not what I found.

The deployment scripts read the key straight out of the folder you'd just cloned. Something like:

```
kubectl create secret tls my-app --key=./config/prod/certs/host.key.pem
```

Look at what that means:

- To run the deploy, you need the key on your disk
- To have it on your disk, it has to be in the repository
- So adding a new service meant committing its private key

Nobody was cutting corners. **They were following the process.** The process was the problem.

Sixteen commits added keys over nine months. Every one passed code review. The messages said things
like "Add TLS certs for reporting-ui." Which is a perfectly normal thing to write.

---

## Part 3. The part that surprised me

There was a second repository. Different team, same estate. It had a `.env` file with 74 passwords
in it.

Here's the thing: **they caught it.**

The very next commit after the leak was called "Add utility for encrypting/decrypting .env files."

They did everything you'd want:

1. They deleted the file
2. They added it to `.gitignore`
3. They wrote an encryption tool

If you looked at that repository afterwards, it was clean. No `.env`. Encryption in place. The commit
log showed someone had handled it.

Then I typed one command:

```
git show <the-old-commit>:.env
```

And every password came back.

---

## Part 4. Why that happens

Deleting a file in git doesn't remove it. It only stops pointing at it.

The file is still in the repository's storage. It comes along with:

- every clone
- every fork
- every CI cache
- every copy anyone ever made

Encrypting the file afterwards doesn't help either. The old, unencrypted version is still sitting
there in the history.

**So the fix that feels most thorough is the one that leaves you exposed.**

And it's worse than doing nothing, because now the commit log says you dealt with it.

---

## Part 5. What actually works

Two things, and the order matters more than the steps.

**First: change the password.**

Takes minutes. It's the only thing that reduces your risk today.

**Second: rewrite the history.**

Takes days. You have to reach every fork, every open pull request, and every laptop that already has
a copy.

Most people do these backwards. Rewriting history feels like the real fix, so they start there. But
while they're organising that, the password is still live.

---

## Part 6. So I built something

I wanted to know what would have caught this. So I built it, and I brought it with me. It's running
right now.

Here's what happens when I change something.

**1. I make a change on my laptop**

I create a branch. I edit a file. I commit.

Before the commit is saved, a hook scans it for passwords. If it finds one, the commit doesn't
happen. Nothing has left my laptop yet, so there's nothing to clean up.

**2. I open a pull request**

I push the branch and open a PR. That's what starts everything else.

**3. It scans the whole history for secrets**

Not just my change. Every commit ever made in that repository.

This matters. If someone committed a password last year and deleted it, a scan of today's files
finds nothing. You have to look at the history.

**4. It scans the infrastructure code**

Three times, once for each environment. Same code, different rules.

Development gets 10 blocking rules. Staging and production get 14. The extra four are things
development is allowed to skip.

**5. It writes me a comment**

Plain English. What it found, what to change, and which findings probably don't matter.

**6. It stops the merge if anything is wrong**

The pull request says BLOCKED until it's fixed.

**7. Someone has to approve it**

I can't approve my own pull request. GitHub won't let me. Someone else has to look at it.

**8. Merging deploys it**

Development goes out straight away.

Staging waits. Someone has to click approve.

Production waits too. Someone has to click approve again.

---

## Part 7. What's actually running

Four Linux containers on a server in my house.

- One for development
- One for staging
- Two for production, because production runs two

Each one is on its own network. They can't reach each other. I tested that in both directions.

Each one runs a small Python web service. You can ask it two questions:

```
/health    is it alive?
/version   which version is running?
```

---

## Part 8. The thing I'd tell you if you only remember one

I'll show you a moment from building this.

The very first time I pushed this repository, the security scan failed. When I read the log, it said
two things one after the other:

```
scanned ~0 bytes (0)
no leaks found
```

It scanned nothing. And then it told me everything was fine.

The tool I was using only checks the commits you just pushed. On a brand new repository, that range
doesn't exist. Git threw an error, the scan looked at nothing, and it still reported a pass.

I got lucky. It happened to exit with an error, so I noticed.

If it had scanned *some* of the history instead of none, it would have said "no leaks found" and I
would have believed it.

**A security tool that passes while doing nothing is worse than not having one.** At least without
one you know you're not covered.

So now I check what a scan actually looked at, not just whether it passed.

---

## Part 9. What I'd tell a team

If I were rolling this out here, I'd do it in this order:

**Week 1: measure, don't block**

Run everything in report-only mode. You can't decide what to block until you know how much there is.

**Week 2: secrets only**

Turn on the secret blocking. Expect to find real things. Change those passwords first, clean up
second.

**Weeks 3 and 4: agree the rules**

Sit down with security and pick the rules that block. Ten is a good number. Write down why for each
one. Everything else gets reported but doesn't stop anyone.

**Week 5: the local hook**

Once people trust the list is short and fair, add the hook that runs before commit.

Do this first and people work around it. Do it last and they're glad of it.

---

## The three things I'd want you to take away

**1. Deleting a secret doesn't remove it.**

Change the password first. Clean up the history second.

**2. When something's wrong for nine months and nobody notices, the system made it easy to get
wrong.**

Fix the system. Not the people.

**3. The hard part isn't running the scanner.**

It's deciding what's worth stopping someone's work over, and being able to explain that choice to
both an engineer and an auditor.
