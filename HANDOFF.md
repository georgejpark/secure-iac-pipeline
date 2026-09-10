# HANDOFF — read this first

**Demo: "The Password You Already Deleted" — Texas Mutual interview, 10 Sep 2026, 2:00 PM CT.**
Written 12:47 CT. Working dir: `~/Desktop/interview-texas-mutual/secure-iac-pipeline`.

---

## Where things stand: READY. Nothing is blocking.

Pre-flight passed at 12:40. The build path was proven at 12:46 with a dev-only
`workflow_dispatch` (run `34510038607`, all five jobs green including `Deploy (dev)`),
then dev was destroyed again so the slate is clean.

| Check | State |
|---|---|
| State DB listening on `10.40.10.10:5432` | yes |
| Platform containers 201-204 | all running |
| App VMIDs 301, 311, 321, 322, 323 | all **free** |
| Terraform state, all three schemas | **0 resources** |
| `/root/install-app.sh` + `/opt/app-source/` | staged, 4 files |
| PR #4 | **OPEN, MERGEABLE, REVIEW_REQUIRED** — do not merge before the demo |
| Build path (dispatch → deploy) | **proven working at 12:46** |
| Destroy path | proven working |

## The demo builds everything from nothing

There are **zero application servers** on purpose. During the demo the pipeline builds
all five: dev 301, stage 311, prod 321 + 322 + 323 (prod is 3 because PR #4 changes
`replica_count` 2 → 3).

## What to read

- **`docs/final/1-RUNBOOK.md`** — the master runbook, PRIVATE, ordered in use sequence.
  Part A before I start · Part B what I say · Part C STEP 1-9 · Part D close · Part E reference.
  Panic card sits at the top of Part C, right before STEP 1.
- `docs/final/2-FOR-THE-PANEL.md` — audience technical doc, 1057 lines.
- `docs/word/` — .docx exports of all 7 docs + README.
- `docs/diagrams/` — three draw.io files: system architecture, GitOps flow, teardown.

## Two known gotchas

1. **Postgres on tf-state binds loopback-only after a reboot.** Then every `terraform init`
   fails with `connection refused`. This broke everything this morning.
   Check: `pct exec 204 -- ss -tlnp | grep 5432` must show `10.40.10.10:5432`.
   Fix: `pct exec 204 -- systemctl restart postgresql@17-main`
2. **Prod containers have `protection: 1`.** A `terraform destroy` on prod fails with
   `Error: Container delete` until you run `pct set 321 --protection 0` (and 322, 323).
   That is the PVE-4 guardrail working — worth saying out loud if it happens.

## Teardown / reset after the demo

`docs/final/1-RUNBOOK.md` Part E4. Helper is `/root/tf-destroy.sh <env> plan|destroy`,
pushed into each runner at `/home/runner/tf-destroy.sh`. Run each on its own runner:
dev on 201, stage on 202, prod on 203. Plan first, always.

## Host access

`ssh root@192.168.1.132` (pve2). Key auth from this Mac already works.

## Open items, none blocking

- The application source (`app.py`, `VERSION`, `requirements.txt`, the systemd unit) is
  **not in this repo** — it lives on the host at `/opt/app-source/`. Documented as an
  honest gap in doc 2.
- `.scan/*.json` build artifacts are committed. Cosmetic.
- Separate from the demo: `~/Desktop/pve2-HOST-diag-20260909-2125/` holds a Proxmox host
  audit from last night. Top items: no backups configured, ZFS pool never scrubbed,
  92 unsafe shutdowns on the NVMe. **Not urgent, do not touch before the interview.**

## Recent commits

```
dae697c  Add Word exports, and stop the text hooks corrupting binaries
43b3fe1  Give the runbook a spoken opening, and use the greeting as a callback
36e8bef  Give the demo a title, and put it on every document and diagram
5194895  Document Terraform, the scripts, and the application end to end
3e4457a  Explain the four platform containers, and correct a network claim
3d68b4b  Reorder the runbook into the sequence it is used in
```

## Next action

Rehearse the talk track. Do **not** merge PR #4 until STEP 6 of the live demo.
