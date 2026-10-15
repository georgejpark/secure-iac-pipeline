# Unit tests for proxmox.rego:  opa test policy/terraform -v
package main

import rego.v1

# A minimal plan: one container being created in `env`, with `after` values.
plan(env, after) := {
	"configuration": {"root_module": {"module_calls": {"workload": {"expressions": {"environment": {"constant_value": env}}}}}},
	"resource_changes": [{
		"address": "module.workload.proxmox_virtual_environment_container.app[0]",
		"type": "proxmox_virtual_environment_container",
		"change": {"actions": ["create"], "after": after},
	}],
}

hardened := {
	"unprivileged": true,
	"start_on_boot": true,
	"protection": true,
	"network_interface": [{"name": "eth0", "firewall": false}],
}

test_hardened_container_passes_in_every_environment if {
	every env in ["dev", "stage", "prod"] {
		count(deny) == 0 with input as plan(env, hardened)
	}
}

test_privileged_container_denied_in_every_environment if {
	every env in ["dev", "stage", "prod"] {
		some msg in deny with input as plan(env, object.union(hardened, {"unprivileged": false}))
		startswith(msg, "PVE-1")
	}
}

test_prod_without_delete_protection_denied if {
	some msg in deny with input as plan("prod", object.union(hardened, {"protection": false}))
	startswith(msg, "PVE-4")
}

test_stage_without_start_on_boot_denied if {
	some msg in deny with input as plan("stage", object.union(hardened, {"start_on_boot": false}))
	startswith(msg, "PVE-3")
}

test_dev_is_allowed_to_be_cheap if {
	count(deny) == 0 with input as plan("dev", object.union(hardened, {"protection": false, "start_on_boot": false}))
}

test_firewall_off_is_a_warning_not_a_deny if {
	count(deny) == 0 with input as plan("prod", hardened)
	count(warn) == 1 with input as plan("prod", hardened)
}

test_unknown_environment_fails_closed if {
	"cannot determine the environment from the plan" in deny with input as {"resource_changes": []}
}

test_deletes_are_not_judged if {
	p := plan("prod", {"unprivileged": false})
	count(deny) == 0 with input as object.union(p, {"resource_changes": [object.union(
		p.resource_changes[0],
		{"change": {"actions": ["delete"], "after": null}},
	)]})
}
