# PVE policies for the Proxmox deploy tree, written in Rego.
#
# The same rules as scripts/policy_check.py, evaluated against the Terraform
# plan as JSON (`terraform show -json tfplan > plan.json`). Policy on the PLAN,
# not the source: variables are resolved and modules expanded, so this checks
# what will actually be created.
#
#   opa test policy/terraform -v                              unit tests
#   conftest test --policy policy/terraform plan.json         gate a plan
package main

import rego.v1

container_type := "proxmox_virtual_environment_container"

# The environment is read from the plan itself: each root module passes it to
# the workload module as a literal.
environment := input.configuration.root_module.module_calls.workload.expressions.environment.constant_value

# Fail closed. A plan this policy cannot place in an environment is rejected,
# never waved through with the stage/prod rules silently skipped.
deny contains "cannot determine the environment from the plan" if {
	not environment
}

# Containers this plan creates or updates. Deletes and no-ops are not judged,
# as in policy_check.py.
changes contains rc if {
	some rc in input.resource_changes
	rc.type == container_type
	not rc.change.actions == ["no-op"]
	not rc.change.actions == ["delete"]
}

# PVE-1, every environment. Root in a privileged container is root on the
# hypervisor.
deny contains msg if {
	some rc in changes
	not rc.change.after.unprivileged == true
	msg := sprintf("PVE-1 %s: container must be unprivileged", [rc.address])
}

# PVE-2, enforced nowhere, on purpose: the per-container firewall breaks return
# traffic here, and the host forward policy isolates the segments instead. A
# warning, so the decision stays visible instead of silently deleted.
warn contains msg if {
	some rc in changes
	some nic in rc.change.after.network_interface
	not nic.firewall == true
	msg := sprintf("PVE-2 %s: NIC firewall off (not enforced; host forward policy isolates segments)", [rc.address])
}

# PVE-3, stage and prod. Otherwise the next host reboot is an outage.
deny contains msg if {
	environment in {"stage", "prod"}
	some rc in changes
	not rc.change.after.start_on_boot == true
	msg := sprintf("PVE-3 %s: container must start after a host reboot in %s", [rc.address, environment])
}

# PVE-4, prod only. Blocks an accidental destroy of a running workload.
deny contains msg if {
	environment == "prod"
	some rc in changes
	not rc.change.after.protection == true
	msg := sprintf("PVE-4 %s: prod container must have delete protection", [rc.address])
}
