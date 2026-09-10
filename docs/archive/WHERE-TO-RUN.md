# Where to run each command

**The single most likely way to trip yourself up live.** Two machines are involved and they are not
interchangeable.

| | Your Mac | The Proxmox host |
|---|---|---|
| Address | `192.168.1.144` | `192.168.1.132` |
| Repo lives at | `~/Desktop/interview-texas-mutual/secure-iac-pipeline` | `/root/secure-iac-pipeline` |
| Can reach `10.x.x.x` segments | **no** | **yes** |
| Get there | already there | `ssh root@192.168.1.132` |

---

## Run on YOUR MAC

```bash
cd ~/Desktop/interview-texas-mutual/secure-iac-pipeline

make scan-insecure       # the gate blocks: 10 dev / 14 stage / 14 prod
make scan                # the gate passes: 0 blocking
unset ANTHROPIC_API_KEY && make scan     # identical result, no API key
git log --oneline | head
```

Anything that only reads the repository works here.

---

## Run on the PROXMOX HOST

```bash
ssh root@192.168.1.132
```

### The secret-persistence demo

```bash
/root/demo-secret-persistence.sh
```

**Not from your Mac.** Endpoint protection has quarantined the local copy three times. The Proxmox
copy is Linux, unaffected, and uses real `AWS_` variable names which read better on screen.

### The running application

```bash
for h in 10.10.10.20 10.20.10.20 10.30.10.20 10.30.10.21; do
  echo -n "$h  "; curl -s http://$h:8080/health
  echo -n "  "; curl -s http://$h:8080/version; echo
done
```

**This will never work from your Mac.** Those segments have no route from the LAN — that is the
isolation, working. If you try it from the Mac it hangs for 75 seconds and then fails, which is a bad
thing to do in front of an audience.

### What is running

```bash
pct list
```

### The isolation proof

```bash
pct exec 301 -- ping -c2 -W2 10.30.10.20     # dev -> prod: blocked
pct exec 321 -- ping -c2 -W2 10.10.10.20     # prod -> dev: blocked
```

### Deploy production live

```bash
cd /root/secure-iac-pipeline
gh workflow run "Security Pipeline" --ref main -f environment=prod -f deploy=true
gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

`gh` is already authenticated as `georgejpark` on the host.

### Log into a container

```bash
pct exec 301 -- bash                  # root shell, no password
ssh opsadmin@10.10.10.20              # key-based, sudo needs the password
```

---

## The four mistakes to avoid

| Mistake | What happens | Do instead |
|---|---|---|
| `curl 10.10.10.20` from the Mac | hangs 75s, then fails | ssh to Proxmox first |
| `cd /root/secure-iac-pipeline` on the Mac | "no such file or directory" | that path is on Proxmox |
| `./scripts/demo_secret_persistence.sh` on the Mac | may be quarantined | run the Proxmox copy |
| `make scan` on Proxmox | no `.venv` there | run it on the Mac |

---

## Two terminals, labelled

Open both before you start and know which is which:

```
Terminal 1  →  MAC       ~/Desktop/interview-texas-mutual/secure-iac-pipeline
Terminal 2  →  PROXMOX   ssh root@192.168.1.132
```

Almost everything visual — the demo, the app, the containers, the live deploy — happens in
**Terminal 2**. The scanning demos happen in **Terminal 1**.
