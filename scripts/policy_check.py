#!/usr/bin/env python3
"""
Policy gate for the Proxmox deploy code.

WHY THIS EXISTS
---------------
Checkov ships no rules for the Proxmox provider. Scanned with Checkov alone the
deploy code passes every check by virtue of being unrecognised -- which is the
worst kind of green, and exactly the failure this pipeline is built to catch.
A control that inspects nothing and reports success manufactures confidence.

So the policy is written here instead, and it runs against `terraform show
-json` of the PLAN rather than the source. That matters: the plan is what will
actually be created, with variables resolved and modules expanded. Source-level
checks can be defeated by a variable default changing somewhere else.

Same design as the Checkov gate:
  - deterministic, no network call, no model in the decision path
  - environment-tiered, because dev is allowed to be cheaper than prod
  - a short, defensible blocking list rather than everything it could check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

CONTAINER = "proxmox_virtual_environment_container"


# --- The policy -------------------------------------------------------------
# id, description, the consequence of failing it, and which environments enforce
# it. Kept in one table so the whole policy fits on a screen and can be reviewed
# by someone who does not read Python.
POLICIES: list[dict[str, Any]] = [
    {
        "id": "PVE-1",
        "title": "Container must be unprivileged",
        "why": "A privileged container shares the host user namespace — root inside it "
               "is effectively root on the hypervisor.",
        "enforced_in": ("dev", "stage", "prod"),
        "check": lambda v: v.get("unprivileged") is True,
    },
    {
        "id": "PVE-2",
        "title": "Network interface must have the firewall enabled",
        "why": "Without it the container bypasses the Proxmox firewall entirely, so any "
               "host segmentation policy silently does not apply.",
        # Enforced NOWHERE, deliberately. Enabling the per-container firewall
        # breaks return traffic for outbound connections on this platform, and
        # segment isolation is enforced by the host forward policy instead --
        # verified dev->prod and prod->dev, both blocked.
        #
        # Left in the table rather than deleted so the decision is visible. A
        # policy silently removed looks like an oversight; a policy that says
        # why it is not enforced is a decision.
        "enforced_in": (),
        "check": lambda v: all(
            n.get("firewall") is True for n in (v.get("network_interface") or [{}])
        ),
    },
    {
        "id": "PVE-3",
        "title": "Container must restart after a host reboot",
        "why": "Otherwise the next maintenance window is an unplanned outage.",
        "enforced_in": ("stage", "prod"),
        "check": lambda v: v.get("start_on_boot") is True,
    },
    {
        "id": "PVE-4",
        "title": "Container must have delete protection",
        "why": "Blocks an accidental destroy of a running production workload.",
        "enforced_in": ("prod",),
        "check": lambda v: v.get("protection") is True,
    },
]


def planned_containers(plan: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    """Every container the plan intends to create or update, with its values."""
    out: list[tuple[str, dict[str, Any]]] = []
    for change in plan.get("resource_changes", []):
        if change.get("type") != CONTAINER:
            continue
        actions = change.get("change", {}).get("actions", [])
        if actions == ["no-op"] or actions == ["delete"]:
            continue
        after = change.get("change", {}).get("after") or {}
        out.append((change.get("address", "?"), after))
    # a plan with no changes still has state worth checking
    if not out:
        for res in (plan.get("planned_values", {}).get("root_module", {})
                    .get("child_modules", []) or []):
            for r in res.get("resources", []):
                if r.get("type") == CONTAINER:
                    out.append((r.get("address", "?"), r.get("values") or {}))
    return out


def evaluate(containers, environment: str):
    failures, passes, skipped = [], [], []
    for address, values in containers:
        for pol in POLICIES:
            entry = {"id": pol["id"], "title": pol["title"],
                     "why": pol["why"], "resource": address}
            if environment not in pol["enforced_in"]:
                entry["note"] = f"advisory in {environment}; enforced in " \
                                f"{', '.join(pol['enforced_in'])}"
                (skipped if pol["check"](values) else skipped).append(entry)
                continue
            if pol["check"](values):
                passes.append(entry)
            else:
                failures.append(entry)
    return failures, passes, skipped


def render(failures, passes, skipped, environment: str, n_containers: int) -> str:
    lines = [f"## Proxmox deploy policy — `{environment}`", ""]
    lines.append(f"{n_containers} container(s) planned. "
                 f"{len(passes)} check(s) passed, {len(failures)} failed.")
    lines.append("")
    if failures:
        lines.append("**Blocking:**")
        lines.append("")
        lines.append("| Policy | Resource | Requirement | Why it matters |")
        lines.append("|---|---|---|---|")
        for f in failures:
            lines.append(f"| `{f['id']}` | `{f['resource']}` | {f['title']} | {f['why']} |")
    else:
        lines.append("**No blocking policy failures.** Deploy may proceed.")
    if skipped:
        lines.append("")
        lines.append(f"<details><summary>{len(skipped)} check(s) not enforced in "
                     f"`{environment}`</summary>\n")
        for s in skipped:
            lines.append(f"- `{s['id']}` {s['title']} — {s.get('note','')}")
        lines.append("\n</details>")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan", required=True, type=Path,
                    help="Output of: terraform show -json tfplan")
    ap.add_argument("--environment", required=True, choices=["dev", "stage", "prod"])
    ap.add_argument("--output", type=Path, help="Write the Markdown report here")
    args = ap.parse_args()

    if not args.plan.exists():
        print(f"::error::plan file not found: {args.plan}", file=sys.stderr)
        return 2

    plan = json.loads(args.plan.read_text())
    containers = planned_containers(plan)
    failures, passes, skipped = evaluate(containers, args.environment)

    report = render(failures, passes, skipped, args.environment, len(containers))
    print(report)
    if args.output:
        args.output.write_text(report + "\n")

    print(f"\ncontainers={len(containers)} passed={len(passes)} "
          f"failed={len(failures)}", file=sys.stderr)
    if failures:
        print(f"::error::{len(failures)} blocking policy failure(s) for "
              f"{args.environment}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
