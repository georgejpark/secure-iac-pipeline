# Access to the environments

## Accounts on every container

| Account | Purpose | Auth |
|---|---|---|
| `root` | console access via the Proxmox web UI | password |
| `opsadmin` | day-to-day administration | **SSH key**, sudo requires a password |
| `rapta` | runs the application | no login shell of its own |
| `runner` | runs the CI agent (runner containers only) | no interactive use |

`opsadmin` is in the `sudo` group. **sudo asks for a password** — deliberately. A NOPASSWD sudo
account reachable by key means one stolen key is full root, with nothing in between.

## Where the passwords live

One password per **environment**, not per container, on the Proxmox host:

```
/root/creds/opsadmin-dev.pw
/root/creds/opsadmin-stage.pw
/root/creds/opsadmin-prod.pw
/root/creds/opsadmin-mgmt.pw
```

`chmod 600`, root-only. Read one with:

```bash
ssh root@192.168.1.132 cat /root/creds/opsadmin-prod.pw
```

**These are lab credentials on a lab host.** In a real environment they belong in the same SOPS file
as everything else, or in a secret manager, and `root` would have no password at all.

## Getting in

**By SSH, from the Proxmox host** (the host has an interface on every segment):

```bash
ssh root@192.168.1.132
ssh opsadmin@10.10.10.20      # dev
ssh opsadmin@10.20.10.20      # stage
ssh opsadmin@10.30.10.20      # prod-1
ssh opsadmin@10.30.10.21      # prod-2
```

**By console**, if the network is broken and SSH will not work:

Proxmox web UI → the container → **Console** → log in as `root` with that environment's password.

**Directly from the host**, no password needed:

```bash
pct exec 301 -- bash        # a root shell inside app-dev-1
```

## Why you cannot SSH from your laptop

The application containers sit on isolated segments with **no route from the LAN**. That is the
point. The Proxmox host is the only machine with an interface on all of them, so it is the way in —
a single, auditable entry point rather than four.

## Checking access

```bash
ssh root@192.168.1.132 'for i in 301 311 321 322; do
  echo -n "$i "; pct exec $i -- id -nG opsadmin
done'
```

Expect `opsadmin sudo` for each.
