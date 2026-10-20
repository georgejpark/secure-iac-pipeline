# secure-iac-pipeline on Proxmox

| | |
|---|---|
| Upstream | George's own repository (georgejpark/secure-iac-pipeline — GitHub path to verify; no LICENSE file in the clone) |
| Kind | infra-as-code (GitHub Actions pipeline + Terraform + OPA/Rego policy + Python triage) |
| Cloud verdict | OPTIONAL |
| GPU | none |
| Target host | pve2 (runner CTs 201-204 verified alive on 2026-10-20; pve5 only as the fallback Plan B) |
| Effort | M |

## What it is
A GitHub Actions security pipeline that scans every change with gitleaks (full history), Checkov and a hand-written Proxmox policy gate before Terraform applies anything. The only thing it actually deploys is LXC containers on a Proxmox host (`bpg/proxmox` provider); the AWS tree under `terraform/envs/` is scanned but never applied. CI runs on three self-hosted runners (`ci-dev`, `ci-stage`, `ci-prod`), one unprivileged LXC per environment on its own NAT-ed bridge, with Terraform state in a PostgreSQL container and secrets in SOPS/age files whose private keys live only on the matching runner. The runners show "offline" in GitHub only because Actions was disabled on this repo on 2026-10-20; the containers themselves are running on pve2 (verified the same day).

## Cloud dependency evidence
| File:line | What | Needed for core use? |
|---|---|---|
| `terraform/envs/dev/main.tf:14-19` (same in `stage`, `prod`) | `required_providers aws = { source = "hashicorp/aws", version = "~> 5.0" }` | No — scanned by Checkov and `terraform validate` only; `.github/workflows/security-pipeline.yml:14-16` states it is never applied |
| `terraform/envs/dev/main.tf:37-38` | `provider "aws" { region = var.aws_region }` | No — `terraform validate` needs the provider plugin download, not AWS credentials |
| `terraform/modules/claims-platform/main.tf:72-238` | `aws_kms_key`, `aws_s3_bucket*`, `aws_security_group`, `aws_db_instance` demo resources | No — demo input for the scanner |
| `terraform/insecure/main.tf` | deliberately vulnerable AWS Terraform (24 findings) | No — demo input (`Makefile:42-51`) |
| `terraform/bootstrap/github-oidc.tf:35-80` | `aws_iam_openid_connect_provider` + `aws_iam_role` for GitHub OIDC | No — only if AWS is ever funded |
| `.env.example:3` | `AWS_REGION=us-east-2` | No — unused on Proxmox |
| `.github/workflows/security-pipeline.yml:109,200` | `github/codeql-action/upload-sarif` (GitHub Advanced Security) | No — `continue-on-error: true` |
| `.github/workflows/security-pipeline.yml:63,123,242` | `runs-on: [self-hosted, dev]` / `"${{ matrix.environment }}"` — GitHub.com orchestrates, runners poll outbound | Yes for the pipeline as designed (GitHub SaaS, free; no inbound port) |
| `scripts/ai_triage.py:202,211-216` | `os.environ.get("ANTHROPIC_API_KEY")`, `anthropic.Anthropic(api_key=api_key)`, `client.messages.create(model="claude-sonnet-5")` | No — external API; `offline_report()` at `:224` is the deterministic fallback |
| `terraform/deploy/dev/main.tf:16-21,46-50` | `bpg/proxmox ~> 0.112.0`, `provider "proxmox" { endpoint, api_token, insecure = true }` (locked at 0.112.0 in `terraform/deploy/dev/.terraform.lock.hcl:4-6`) | Yes — this is the on-prem target, not a cloud |

No Azure or GCP SDKs, no Terraform cloud backend (state is `backend "pg"`, `terraform/envs/dev/main.tf:32-34`, `terraform/deploy/dev/main.tf:25-27`).

## Runtime requirements
- Toolchain pinned into the runner image, not per job: Terraform **1.5.7** (`.github/workflows/security-pipeline.yml:52`, `docs/RUNNER-INFRASTRUCTURE.md:110`), gitleaks **8.30.1** (`.pre-commit-config.yaml:10`), sops **3.9.4** (`terraform/envs/dev/secrets.enc.yaml:30`) + age, Python **3.12** venv with `checkov anthropic` (`security-pipeline.yml:143-148`), `opa` + `conftest` for `make opa` (`Makefile:53-57`), GitHub Actions runner agent, `gh` CLI (on the Mac) for registration tokens.
- State DB: PostgreSQL 17 (`docs/final/2-FOR-THE-PANEL.md:650`), databases `tfstate_dev`/`tfstate_stage`/`tfstate_prod`, roles `tf_dev`/`tf_stage`/`tf_prod`, schemas `terraform_<env>` and `deploy_<env>` (`terraform/envs/dev/main.tf:33`, `terraform/deploy/dev/main.tf:26`), port 5432, `pg_hba.conf` pins each role to its subnet (`2-FOR-THE-PANEL.md:671-675`).
- Networks: `vmbr1 10.10.10.0/24` dev, `vmbr2 10.20.10.0/24` stage, `vmbr3 10.30.10.0/24` prod, `vmbr4 10.40.10.0/24` management/state DB (`docs/final/7-HOW-IT-IS-BUILT.md:305-325`). Layout per segment: `.1` gateway, `.10` runner, `.20+` workloads (`terraform/modules/workload/main.tf:166-173`).
- Ports: 5432 (tf-state), 8080 (workload `/`, `/health`, `/version`), 8006 (Proxmox API), 443 outbound to github.com.
- Env var names: `TF_VAR_pve_endpoint`, `TF_VAR_pve_token_id`, `TF_VAR_pve_token_secret` (`security-pipeline.yml:288-290`), `SOPS_AGE_KEY_FILE=/home/runner/.config/sops/age/keys.txt` (`:161,:265`), `ANTHROPIC_API_KEY` (`:211`), `TF_VERSION`, `PYTHON_VERSION`.
- Secret names: GitHub repository secret `ANTHROPIC_API_KEY` (optional). Everything else is in SOPS files: keys `username`, `database`, `host`, `password`, `pve_endpoint`, `pve_token_id`, `pve_token_secret` (`terraform/envs/dev/secrets.enc.yaml:4-10`); `encrypted_regex` in `.sops.yaml:14`.
- External APIs: GitHub.com (required), Anthropic Messages API (optional). The script passes no `base_url`, so a local substitute only works through the Anthropic SDK's own `ANTHROPIC_BASE_URL` environment variable pointed at an Anthropic-compatible proxy (e.g. LiteLLM in front of vLLM/Ollama on pve2) — to verify, not supported by this code explicitly.
- Not in the repo but required: `/opt/app-source/` on the Proxmox host with `app.py`, `requirements.txt`, `VERSION`, `inspection-service.service` (`docs/final/7-HOW-IT-IS-BUILT.md:280`, `scripts/validate.sh:86-87`), and `/usr/local/sbin/runner-net.sh` + `runner-net.service` (`docs/RUNNER-INFRASTRUCTURE.md:88-99`, only excerpted).

## Proxmox plan

### Status verified on pve2, 2026-10-20
`pct list` on pve2 shows CT **201 ci-dev, 202 ci-stage, 203 ci-prod, 204 tf-state** all `running` (unprivileged, `nesting=1`, 4 cores / 4096 MB / 20 GB on `local-zfs`; ci-dev on `vmbr1` 10.10.10.10/24, gw 10.10.10.1; `vmbr1` is defined in `/etc/network/interfaces` with `bridge-ports none`, NAT via vmbr0). The original build is intact.

### Plan A (use what exists): re-enable Actions, nothing else
1. On the Mac: `gh api -X PUT repos/georgejpark/secure-iac-pipeline/actions/permissions -F enabled=true`
2. Wait a minute, then `gh api repos/georgejpark/secure-iac-pipeline/actions/runners --jq '.runners[]|[.name,.status]|@tsv'` → the three runners report `online` (the runner service inside each CT reconnects by itself; if one stays offline: `ssh pve2 'pct exec 201 -- systemctl status actions.runner.*'`).
3. Still to check on pve2: `/opt/app-source/` and `/usr/local/sbin/runner-net.sh` + `runner-net.service` (see Open questions).

### Plan B (only if pve2 is retired): rebuild on pve5
Everything below runs on **pve5** (`ssh pve5`, root) unless stated. The documented build was on pve2 (104 vCPU / 62 GB, `docs/RUNNER-INFRASTRUCTURE.md:21`, `terraform/modules/workload/main.tf:33-37` defaults `node_name = "pve2"`, `secrets.enc.yaml:8` endpoint `https://192.168.1.132:8006/`). pve5 has 30 GiB shared with CT 100/101, so the sizes are halved versus the doc (4 GB → 2 GB per runner; to verify Checkov fits).

Containers (Debian 13 LXC, unprivileged, on the `nvmepool` ZFS storage — confirm the storage ID with `pvesm status`):

| CT | name | bridge / IP | vCPU / RAM / disk |
|---|---|---|---|
| 201 | ci-dev | vmbr1 10.10.10.10 | 4 / 2048 MB / 20 GB |
| 202 | ci-stage | vmbr2 10.20.10.10 | 4 / 2048 MB / 20 GB |
| 203 | ci-prod | vmbr3 10.30.10.10 | 4 / 2048 MB / 20 GB |
| 204 | tf-state | vmbr4 10.40.10.10 | 2 / 1024 MB / 8 GB |
| 301 / 311 / 321-322 | app-* (Terraform-made) | vmbr1/2/3 `.20+` | 2 / 2048 MB / 8-20 GB (`terraform/deploy/*/main.tf:57-59`) |

Total ≈ 15 GB RAM when everything is up. If that is too much, keep the runners on pve2 as originally built and only change nothing.

1. Template and runner containers (`docs/RUNNER-INFRASTRUCTURE.md:57-69`, storage changed to nvmepool):
```bash
pveam update && pveam download local debian-13-standard_13.6-1_amd64.tar.zst
i=0
for env in dev stage prod; do
  i=$((i+1)); ID=$((200+i))
  pct create $ID local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
    --hostname ci-$env --unprivileged 1 --features nesting=1 \
    --cores 4 --memory 2048 --swap 512 --rootfs nvmepool:20 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1
  pct start $ID
done
pct create 204 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname tf-state --unprivileged 1 --cores 2 --memory 1024 --swap 512 \
  --rootfs nvmepool:8 --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1
pct start 204
```
2. Isolated bridges: append `vmbr1` (10.10.10.1/24), `vmbr2` (10.20.10.1/24), `vmbr3` (10.30.10.1/24), `vmbr4` (10.40.10.1/24) with `bridge-ports none` to `/etc/network/interfaces` exactly as in `docs/RUNNER-INFRASTRUCTURE.md:75-84`, then `ifreload -a`.
3. NAT + isolation: recreate `/usr/local/sbin/runner-net.sh` from the excerpt at `docs/RUNNER-INFRASTRUCTURE.md:91-99` (own chains `RUNNER_NAT`/`RUNNER_FWD`; MASQUERADE each /24 out of vmbr0; DROP every cross-segment pair; ACCEPT ESTABLISHED,RELATED) plus one ACCEPT per environment segment to `10.40.10.10` tcp/5432, and a `runner-net.service` that runs it at boot. The full script is not in the repo — copy it from pve2 (`/usr/local/sbin/runner-net.sh`) if that host still has it.
4. Move the containers onto their segments (always pass `hwaddr=`, lesson at `docs/RUNNER-INFRASTRUCTURE.md:140,181`): for each CT take the MAC from `pct config <id>` and run the form at `docs/RUNNER-INFRASTRUCTURE.md:104-105`, e.g. `pct set 201 --net0 name=eth0,bridge=vmbr1,ip=10.10.10.10/24,gw=10.10.10.1,hwaddr=<current MAC>` and `pct set 201 --nameserver "1.1.1.1 8.8.8.8"`; 202 → vmbr2/10.20.10.10, 203 → vmbr3/10.30.10.10, 204 → vmbr4/10.40.10.10.
5. Tooling inside each runner (pinned, `docs/RUNNER-INFRASTRUCTURE.md:108-111`): `apt-get install -y curl git unzip jq python3 python3-venv`; Terraform 1.5.7 from `https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip` into `/usr/local/bin`; gitleaks 8.30.1 from the GitHub release tarball `gitleaks_8.30.1_linux_x64.tar.gz`; `sops` 3.9.x `.deb` from the getsops release page; `apt-get install -y age`; create user `runner`; `age-keygen -o /home/runner/.config/sops/age/keys.txt` (new key per runner — the old private keys existed only on the pve2 containers).
6. Register each runner (`docs/RUNNER-INFRASTRUCTURE.md:115-120`). On the Mac: `gh api -X POST repos/georgejpark/secure-iac-pipeline/actions/runners/registration-token --jq .token` (remove the stale offline `ci-dev`/`ci-stage`/`ci-prod` entries in the repo's Settings → Actions → Runners first, otherwise the names collide). Inside the container as `runner`, with the latest `actions-runner-linux-x64` tarball unpacked in `/home/runner/actions-runner`: `./config.sh --unattended --url https://github.com/georgejpark/secure-iac-pipeline --token "<token from gh>" --name ci-dev --labels dev --work _work` then `sudo ./svc.sh install runner && sudo ./svc.sh start`. Names and labels must stay `ci-dev`/`dev`, `ci-stage`/`stage`, `ci-prod`/`prod` to match `runs-on` at `security-pipeline.yml:63,123,242`.
7. State DB in CT 204: `apt-get install -y postgresql-17`; `listen_addresses = '10.40.10.10'`; create the three databases and roles; `pg_hba.conf` lines from `docs/final/2-FOR-THE-PANEL.md:671-675` (`host tfstate_dev tf_dev 10.10.10.0/24 scram-sha-256`, etc.). Known trap: Postgres binds 10.40.10.10 only if the interface is up when it starts (`docs/final/7-HOW-IT-IS-BUILT.md:436`).
8. Proxmox API tokens on pve5 (names from `terraform/deploy/*/main.tf:35-38`): `pveum user add terraform@pve`; a role with the container privileges bpg/proxmox needs (`VM.Allocate VM.Audit VM.Config.* VM.PowerMgmt VM.Clone Datastore.AllocateSpace Datastore.Audit SDN.Use Sys.Audit` — exact set to verify against the provider docs); `pveum aclmod / -user terraform@pve -role <role>`; `pveum user token add terraform@pve ci-dev --privsep 0` (and `ci-stage`, `ci-prod`).
9. Re-encrypt secrets for pve5: put each runner's new age public key into `.sops.yaml:13,17,21`; for each env write a plaintext YAML with `username/database/host 10.40.10.10/password/pve_endpoint https://192.168.1.106:8006//pve_token_id terraform@pve!ci-<env>/pve_token_secret`, encrypt with `sops --encrypt --config .sops.yaml` into `terraform/envs/<env>/secrets.enc.yaml`, commit. Values stay encrypted; only the age recipient and `host`/`pve_endpoint` are readable.
10. Terraform changes for pve5: add `node_name = "pve5"` and `datastore = "nvmepool"` (storage ID to verify) to the `module "workload"` block in `terraform/deploy/dev/main.tf:52-67`, `stage/main.tf`, `prod/main.tf` (defaults at `terraform/modules/workload/main.tf:33-37,123-127`); `pveam download local debian-13-standard_13.6-1_amd64.tar.zst` on pve5 so `template_file_id` (`:117-121`) resolves. `scripts/policy_check.py` and `policy/terraform/proxmox.rego` do not check node names, so the gate is unaffected.
11. Workload installer: recreate `/opt/app-source/` on pve5 (copy from pve2 if present) and run `scripts/install_app.sh dev` on the host after the first deploy (`scripts/install_app.sh:25-26` reads `/opt/app-source/VERSION`).

Substitutes: there is no cloud service to replace; AWS stays scan-only. The Anthropic call falls back to `offline_report()` automatically when `ANTHROPIC_API_KEY` is unset.

## Cloud later
If AWS is funded: apply `terraform/bootstrap/github-oidc.tf` once per account, create GitHub Environments `dev/stage/prod` with required reviewers, add an `aws-actions/configure-aws-credentials` step before `terraform apply` on the `envs/` roots, and either keep the pg backend or move state to S3 + DynamoDB locking. The Proxmox deploy tree and the runner isolation design do not change. SARIF uploads only appear in the Security tab with GitHub Advanced Security on private repos.

## Test plan
On the Mac, inside the repo: `make validate` (three lines ending in "Success"), `make scan-insecure` (expected `exit=1 blocking=10` for every environment, `README.md:79`), `make opa` (unit tests pass, failing plan exits 1), `make secrets` (no leaks). Then `gh api repos/georgejpark/secure-iac-pipeline/actions/runners --jq '.runners[]|[.name,.status]|@tsv'` → `ci-dev online`, `ci-stage online`, `ci-prod online`.

On pve5 (`docs/RUNNER-INFRASTRUCTURE.md:160-168`): `pct exec 201 -- curl -s -o /dev/null -w '%{http_code}' https://api.github.com` → `200`; `pct exec 201 -- ping -c2 -W2 10.30.10.10` → blocked; `pct exec 203 -- ping -c2 -W2 10.10.10.10` → blocked; `pct exec 201 -- bash -c "PGPASSWORD='<dev password>' psql -h 10.40.10.10 -U tf_dev -d tfstate_dev -c 'SELECT 1'"` → `1`.

End to end: trigger `workflow_dispatch` with environment `dev`, deploy `true`; the Deploy job must print `container_ids = [301]`; then `scripts/install_app.sh dev` on pve5 and `curl -s http://10.10.10.20:8080/health` → `{"status":"ok"}`, `curl -s http://10.10.10.20:8080/version` → `{"version":"1.1.0"}` (`README.md:140-143`). `scripts/validate.sh` on the host expects 9 containers after the full demo (`scripts/validate.sh:16`).

## Open questions
- Answered 2026-10-20: CTs 201-204 exist and run on pve2, so Plan A applies and the age keys inside them are still there. Not yet checked: `/opt/app-source/` and `/usr/local/sbin/runner-net.sh` on pve2 (`ssh pve2 'ls /opt/app-source /usr/local/sbin/runner-net.sh; systemctl is-active runner-net'`).
- Exact pve5 storage ID for the NVMe ZFS pool (`nvmepool` assumed) and the privilege set bpg/proxmox 0.112 needs for `proxmox_virtual_environment_container`.
- Whether 2 GB RAM per runner is enough for `checkov` on the AWS tree (the original used 4 GB).
- The GitHub path `georgejpark/secure-iac-pipeline` and whether GitHub Advanced Security is enabled (SARIF upload).
- Whether `ANTHROPIC_BASE_URL` with a LiteLLM proxy is acceptable as a local triage substitute, or whether the deterministic fallback is enough.
