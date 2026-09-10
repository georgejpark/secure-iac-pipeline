# Self-hosted runner infrastructure

How the three CI runners are built, and why they are built this way. Reproducible from a bare
Proxmox host.

![Architecture](img/system-architecture.png)

---

## What exists

| | dev | stage | prod |
|---|---|---|---|
| Container | `ci-dev` (201) | `ci-stage` (202) | `ci-prod` (203) |
| Bridge | `vmbr1` | `vmbr2` | `vmbr3` |
| Subnet | `10.10.10.0/24` | `10.20.10.0/24` | `10.30.10.0/24` |
| Address | `10.10.10.10` | `10.20.10.10` | `10.30.10.10` |
| Runner label | `dev` | `stage` | `prod` |
| Resources | 4 vCPU / 4 GB / 20 GB | same | same |

Host: `pve2`, Proxmox 9.2, Debian 13, 104 vCPU, 62 GB RAM.

The subnets sit inside the `/16` blocks the Terraform declares as `trusted_cidr` for each
environment, so the lab addressing and the infrastructure code agree.

---

## The design decisions

### Unprivileged containers, not the hypervisor

A CI runner executes arbitrary code from the repository. It must not have root on the machine that
runs everything else. Each runner is an **unprivileged** LXC container, so a compromised build is
confined to its own filesystem and process namespace.

### One runner per environment

With a single shared runner, a pull request touching dev executes on the same machine that later
deploys production — a **privilege escalation path from dev to prod**. Separate containers on
separate segments remove it.

Secret scanning deliberately runs on the **dev** runner: it only reads source, so it is given no
cloud access at all.

### Isolated segments, NAT egress

Each bridge has **no physical port**. The host provides NAT so runners can reach GitHub, and drops
every cross-segment path. Runners connect **outbound only** — GitHub never connects in, so no port
forward or inbound firewall exception exists.

---

## Build from scratch

### 1. Containers

```bash
pveam update && pveam download local debian-13-standard_13.6-1_amd64.tar.zst

i=0
for env in dev stage prod; do
  i=$((i+1)); ID=$((200+i))
  pct create $ID local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
    --hostname ci-$env --unprivileged 1 --features nesting=1 \
    --cores 4 --memory 4096 --swap 1024 --rootfs local-zfs:20 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1
  pct start $ID
done
```

### 2. Isolated bridges

Append to `/etc/network/interfaces`, then `ifreload -a`:

```
auto vmbr1
iface vmbr1 inet static
	address 10.10.10.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
```

Repeat for `vmbr2` (`10.20.10.1/24`) and `vmbr3` (`10.30.10.1/24`).

### 3. NAT and isolation

`/usr/local/sbin/runner-net.sh`, run by `runner-net.service` at boot. Uses its own iptables chains so
it never flushes rules it did not create:

```bash
for NET in 10.10.10.0/24 10.20.10.0/24 10.30.10.0/24; do
  iptables -t nat -A RUNNER_NAT -s $NET -o vmbr0 -j MASQUERADE
done
# deny every cross-segment path, both directions
iptables -A RUNNER_FWD -s 10.10.10.0/24 -d 10.30.10.0/24 -j DROP
# ... and so on for each ordered pair
iptables -A RUNNER_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 4. Move containers onto their segments

```bash
pct set 201 --net0 name=eth0,bridge=vmbr1,ip=10.10.10.10/24,gw=10.10.10.1
pct set 201 --nameserver "1.1.1.1 8.8.8.8"
```

### 5. Tooling, pinned

Terraform 1.5.7 and gitleaks 8.30.1 are installed **into the container image**, not per job, so a
build cannot silently pick up a different toolchain than the one that was reviewed.

### 6. Register the runner

```bash
TOKEN=$(gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)
./config.sh --unattended --url https://github.com/OWNER/REPO \
  --token "$TOKEN" --name ci-dev --labels dev --work _work
./svc.sh install runner && ./svc.sh start
```

---

## The workload containers

Separate from the runners. Provisioned by Terraform, configured by Ansible.

| | dev | stage | prod |
|---|---|---|---|
| Container | `app-dev-1` (301) | `app-stage-1` (311) | `app-prod-1` (321), `app-prod-2` (322) |
| Address | `10.10.10.20` | `10.20.10.20` | `10.30.10.20`, `10.30.10.21` |
| Segment layout | `.1` gateway · `.10` runner · `.20+` workloads | | |

### Three networking bugs worth recording

| Problem | Cause | Lesson |
|---|---|---|
| Workload on the gateway address | Host octet derived from VMID; `301 % 100 = 1` | Derive addresses explicitly, never from an unrelated identifier |
| No DNS at all | The module set no resolvers | A container with no resolver fails everything with "Temporary failure resolving" |
| Containers unreachable after a NIC edit | `pct set --net0` without `hwaddr=` regenerates the MAC, leaving stale ARP on the host | Always pass `hwaddr=`, and flush ARP after a NIC change |

The last one is a repeat of a mistake already recorded in this file. Writing a lesson down does not
prevent it; checking does.

### Why the per-container firewall is off

The Proxmox per-container firewall inserts a bridge in front of the NIC and drops return traffic for
outbound connections regardless of `policy_in`, which broke DNS and apt. Environment isolation never
depended on it — the **host forward policy** enforces that, and it is verified in both directions.
The flag is off, and the reasoning is recorded in the module and the policy table rather than the
policy being quietly deleted.

---

## Verification

Both halves matter. Isolation that also blocks GitHub is not isolation, it is a broken runner.

```bash
# egress works
pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' https://api.github.com     # 200

# lateral movement does not
pct exec 201 -- ping -c2 -W2 10.30.10.10                                          # blocked
pct exec 201 -- bash -c '</dev/tcp/10.30.10.10/22'                                # blocked
pct exec 202 -- ping -c2 -W2 10.30.10.10                                          # blocked
pct exec 203 -- ping -c2 -W2 10.10.10.10                                          # blocked
```

Last verified 2026-09-09: all three runners `online`, full pipeline green.

---

## Things that went wrong building this

Recorded because each cost real time and each has a general lesson.

| Problem | Cause | Lesson |
|---|---|---|
| Gateways reported unreachable | `ping -c 1 -W 1` against a cold ARP cache | A single probe with a short timeout is not a test. The gateways were fine. |
| Containers lost all networking | `pct set --net0` without `hwaddr=` regenerates the MAC; the consumer gateway stopped issuing leases after a dozen new MACs | Always pass `hwaddr=` when editing a NIC, or use static addressing |
| Firewall broke DHCP | Proxmox container firewall with `policy_in: DROP` also drops the DHCP offer | A default-deny inbound policy must explicitly permit the protocols that bring the interface up |
| VLANs looked usable | The site VLAN gateways answer ICMP but do not forward to the internet | Reachable is not the same as routable. Test the actual path, not the first hop. |

The fix for the last three was the same: stop depending on the consumer gateway, and build
self-contained NATed segments on the host.
