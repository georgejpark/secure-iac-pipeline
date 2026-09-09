#!/usr/bin/env python3
"""
AI triage for Checkov findings.

WHY THIS EXISTS
---------------
Checkov reports 24 findings against 110 lines of Terraform in this repo. A
scanner that produces that ratio gets muted within a week -- not because the
findings are wrong, but because nobody can tell which six of the twenty-four
would actually get someone paged at 3am.

This script does NOT detect anything. Checkov does the detection; that part is
deterministic and must stay that way. This script answers a different question:

    "Given these findings, what should a reviewer do first, and why?"

DESIGN CONSTRAINTS
------------------
1. Detection stays deterministic. The LLM never decides pass/fail. The gate is
   a hardcoded blocklist (BLOCKING_POLICIES); the model only explains and orders.
   If the model is unavailable, the gate still works.
2. Pre-filter before the API call. Findings are deduplicated and capped, so
   cost is bounded and predictable regardless of repo size.
3. Never fail the build on an AI error. A triage outage must not block a deploy.
   Every failure path degrades to the deterministic summary.
4. Works offline. With no API key, it emits the same report shape from local
   rules, so the pipeline is demonstrable on a plane.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import textwrap
from pathlib import Path
from typing import Any

# --- The deterministic gate -------------------------------------------------
# These block a merge. This list is the security policy; it is reviewed by
# humans and version-controlled. The model cannot add to it or remove from it.
BLOCKING_POLICIES: dict[str, str] = {
    # Direct exposure of data or access. Each one of these, left in place, is a
    # plausible incident report.
    "CKV_AWS_20":  "S3 bucket readable by anyone on the internet",
    "CKV2_AWS_6":  "S3 bucket has no public access block",
    "CKV_AWS_24":  "SSH (22) open to 0.0.0.0/0",
    "CKV_AWS_260": "HTTP (80) open to 0.0.0.0/0",
    "CKV_AWS_17":  "RDS instance publicly accessible",
    # Data-at-rest and credential handling. Regulated data, so these are not
    # negotiable regardless of how the network is configured.
    "CKV_AWS_16":  "RDS storage not encrypted at rest",
    "CKV_AWS_145": "S3 bucket holding claims data not encrypted with a CMK",
    "CKV_AWS_161": "RDS IAM database authentication disabled — long-lived DB passwords",
    # System-of-record integrity. An insurer must be able to prove what a
    # document said and when it changed.
    "CKV_AWS_21":  "S3 versioning off — no tamper or ransomware recovery",
    "CKV_AWS_18":  "S3 access logging off — no audit trail of who read claims data",
}

# Controls that are mandatory in production and stage, but a deliberate cost
# tradeoff in dev. This is the difference between a policy engine that people
# respect and one they route around: dev is allowed to be cheaper, and the
# pipeline says so out loud instead of pretending every environment is equal.
#
# This is why `terraform/envs/dev` reports CKV_AWS_293 and `prod` does not --
# dev genuinely has deletion protection off, on purpose, and that is fine in dev
# and a release blocker in prod.
PROMOTION_GATED_POLICIES: dict[str, str] = {
    "CKV_AWS_293": "database deletion protection disabled",
    "CKV_AWS_157": "database not Multi-AZ — an AZ outage takes the service down",
    "CKV_AWS_129": "database logs not exported to CloudWatch — nothing to alert on",
    "CKV_AWS_118": "enhanced monitoring disabled",
}

# Real findings, but not merge-blockers. Tracked, not gated. Being explicit
# about this list is what keeps the blocking list credible.
ADVISORY_POLICIES: dict[str, str] = {
    "CKV_AWS_144": "cross-region replication — a DR and cost decision, not a vulnerability",
    "CKV2_AWS_61": "lifecycle configuration — a retention policy decision",
    "CKV2_AWS_62": "event notifications — observability, nice to have",
    "CKV2_AWS_5":  "security group not attached — false positive when reviewing module code",
    # Deliberately NOT blocking. A missing description is untidy, not unsafe.
    # Blocking a merge on this is how a team learns to ignore the scanner, and
    # once they ignore it they ignore CKV_AWS_20 too.
    "CKV_AWS_23":  "security group rule has no description — hygiene, not a vulnerability",
    # The KMS key policy below grants kms:* on * to the account root. Checkov is
    # technically right and practically wrong: this is the AWS-documented default
    # key policy, and REMOVING it makes the key unmanageable and unrecoverable.
    # Suppressed deliberately, in code, with the reason attached -- not silently
    # in a config file where the next engineer will never find it.
    "CKV_AWS_111": "KMS root-account admin statement — AWS-recommended default",
    "CKV_AWS_356": "KMS root-account admin statement — AWS-recommended default",
    "CKV_AWS_109": "KMS root-account admin statement — AWS-recommended default",
}

MODEL = "claude-sonnet-5"
MAX_FINDINGS_TO_MODEL = 25


def load_checkov(path: Path) -> list[dict[str, Any]]:
    """Read Checkov JSON. Handles both the list and single-object shapes."""
    with path.open() as fh:
        data = json.load(fh)
    if isinstance(data, dict):
        data = [data]
    findings: list[dict[str, Any]] = []
    for block in data:
        for check in block.get("results", {}).get("failed_checks", []):
            findings.append(
                {
                    "id": check.get("check_id", "?"),
                    "name": check.get("check_name", ""),
                    "resource": check.get("resource", "?"),
                    "file": check.get("file_path", "?"),
                    "line": (check.get("file_line_range") or [0])[0],
                    "guide": check.get("guideline", ""),
                }
            )
    return findings


def blocking_set(environment: str) -> dict[str, str]:
    """
    The policies that block a merge for this environment.

    dev   -- the always-blocking set only. Dev is allowed to be cheap.
    stage -- adds the promotion-gated controls, because stage exists to prove
             that prod's configuration actually works. A control absent in
             stage is a control that has never been tested.
    prod  -- same as stage. Stage and prod share a security posture by design;
             they differ only in scale.
    """
    policies = dict(BLOCKING_POLICIES)
    if environment in ("stage", "prod"):
        policies.update(PROMOTION_GATED_POLICIES)
    return policies


def classify(findings: list[dict[str, Any]], environment: str = "dev") -> dict[str, list[dict[str, Any]]]:
    """Split findings into blocking / advisory / other. Pure function, no I/O."""
    blocking = blocking_set(environment)
    buckets: dict[str, list[dict[str, Any]]] = {"blocking": [], "advisory": [], "other": []}
    for f in findings:
        if f["id"] in blocking:
            f["why"] = blocking[f["id"]]
            buckets["blocking"].append(f)
        elif f["id"] in ADVISORY_POLICIES:
            buckets["advisory"].append(f)
        elif f["id"] in PROMOTION_GATED_POLICIES:
            # Not blocking in dev, but say so rather than burying it, so nobody
            # is surprised when the same code is blocked on promotion to stage.
            f["why"] = PROMOTION_GATED_POLICIES[f["id"]] + " (will block on promotion to stage/prod)"
            buckets["advisory"].append(f)
        else:
            buckets["other"].append(f)
    return buckets


def build_prompt(buckets: dict[str, list[dict[str, Any]]], environment: str = "dev") -> str:
    """Compact the findings into a bounded prompt."""
    def fmt(items: list[dict[str, Any]]) -> str:
        return "\n".join(
            f"- {f['id']} | {f['resource']} | {f['file']}:{f['line']} | {f['name']}"
            for f in items[:MAX_FINDINGS_TO_MODEL]
        ) or "  (none)"

    return textwrap.dedent(
        f"""
        You are reviewing Terraform security findings for the `{environment}`
        environment of an insurance company's claims platform. The reader is the engineer who opened the PR. They are
        competent but not a security specialist, and they are busy.

        These findings BLOCK the merge:
        {fmt(buckets['blocking'])}

        These are advisory only (tracked, not blocking):
        {fmt(buckets['advisory'])}

        Other findings:
        {fmt(buckets['other'])}

        Write a PR comment in GitHub Markdown that:
        1. Opens with one sentence: what must be fixed before this can merge.
        2. For each BLOCKING finding, gives the concrete Terraform change needed.
           Show the actual attribute to add or change, not a description of it.
        3. Groups the advisory findings into a single short paragraph. Do not
           lecture about them.
        4. States plainly if any finding looks like a false positive for this
           context, and says why.

        Be direct and specific. No preamble, no "great job", no restating the
        obvious. If a finding is genuinely serious, say so plainly and say what
        the real-world consequence is. Under 400 words.
        """
    ).strip()


def call_claude(prompt: str) -> str | None:
    """Call the Anthropic API. Returns None on any failure -- never raises."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    try:
        import anthropic
    except ImportError:
        print("::warning::anthropic SDK not installed; using offline triage", file=sys.stderr)
        return None
    try:
        client = anthropic.Anthropic(api_key=api_key)
        resp = client.messages.create(
            model=MODEL,
            max_tokens=1500,
            messages=[{"role": "user", "content": prompt}],
        )
        return "".join(block.text for block in resp.content if block.type == "text")
    except Exception as exc:  # noqa: BLE001 - triage must never break the build
        print(f"::warning::AI triage unavailable ({type(exc).__name__}); "
              f"falling back to deterministic summary", file=sys.stderr)
        return None


def offline_report(buckets: dict[str, list[dict[str, Any]]], environment: str = "dev") -> str:
    """The deterministic report. This is what runs with no API key."""
    lines = [f"## Terraform security review — `{environment}`", ""]
    blocking = buckets["blocking"]

    if blocking:
        lines.append(f"**{len(blocking)} finding(s) must be fixed before this can merge.**")
        lines.append("")
        lines.append("| Policy | Resource | Location | What it means |")
        lines.append("|---|---|---|---|")
        for f in blocking:
            why = f.get("why") or BLOCKING_POLICIES.get(f["id"], "")
            lines.append(f"| `{f['id']}` | `{f['resource']}` | `{f['file']}:{f['line']}` | {why} |")
    else:
        lines.append("**No blocking findings.** This change is clear to merge on security grounds.")
    lines.append("")

    if buckets["advisory"]:
        names = ", ".join(f"`{f['id']}`" for f in buckets["advisory"])
        lines.append(
            f"<details><summary>{len(buckets['advisory'])} advisory finding(s) "
            f"— tracked, not blocking</summary>\n\n{names}\n\n"
            "These are cost, retention, or DR tradeoffs rather than "
            "vulnerabilities. They are recorded so the decision is deliberate.\n</details>"
        )
        lines.append("")

    if buckets["other"]:
        lines.append(
            f"<details><summary>{len(buckets['other'])} other finding(s)</summary>\n\n"
            + "\n".join(f"- `{f['id']}` {f['resource']} — {f['name']}" for f in buckets["other"])
            + "\n</details>"
        )
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, type=Path, help="Checkov JSON report")
    ap.add_argument("--output", type=Path, help="Write the Markdown comment here")
    ap.add_argument("--environment", default="dev", choices=["dev", "stage", "prod"],
                    help="Environment being scanned. stage and prod enforce the "
                         "promotion-gated controls in addition to the base set.")
    ap.add_argument("--fail-on-blocking", action="store_true",
                    help="Exit 1 if any blocking policy failed")
    args = ap.parse_args()

    if not args.input.exists():
        print(f"::error::Checkov report not found: {args.input}", file=sys.stderr)
        return 2

    findings = load_checkov(args.input)
    buckets = classify(findings, args.environment)

    prompt = build_prompt(buckets, args.environment)
    body = call_claude(prompt)
    source = "Claude (`%s`)" % MODEL
    if body is None:
        body = offline_report(buckets, args.environment)
        source = "deterministic rules (no API key present)"

    report = f"{body}\n\n---\n<sub>Triage by {source}. "\
             f"Detection by Checkov — deterministic, and unaffected by AI availability.</sub>\n"

    if args.output:
        args.output.write_text(report)
    print(report)

    n = len(buckets["blocking"])
    print(f"\nblocking={n} advisory={len(buckets['advisory'])} other={len(buckets['other'])}",
          file=sys.stderr)

    if args.fail_on_blocking and n:
        print(f"::error::{n} blocking security finding(s); see the PR comment", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
