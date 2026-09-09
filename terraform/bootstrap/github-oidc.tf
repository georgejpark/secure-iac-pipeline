# ---------------------------------------------------------------------------
# The trust relationship that lets this pipeline run without storing a single
# AWS credential.
#
# Applied ONCE per AWS account, by an administrator, before the pipeline runs.
# After this, `secrets` contains no cloud credentials at all -- GitHub presents
# a signed OIDC token, AWS validates it against the conditions below, and hands
# back credentials that expire in an hour.
#
# The security of the whole arrangement rests on the `condition` blocks. Get
# those wrong -- most commonly by allowing `repo:*` -- and any repository on
# GitHub can assume this role.
# ---------------------------------------------------------------------------

variable "github_org" {
  type        = string
  description = "GitHub organisation or user that owns the repository"
}

variable "github_repo" {
  type        = string
  description = "Repository name, without the owner"
}

variable "environment" {
  type        = string
  description = "Environment this role deploys to"
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

# GitHub's OIDC identity provider. One per AWS account.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Audience must be AWS STS, or a token minted for another service would be
    # accepted here.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The important one. Scoped to a single repository AND a single GitHub
    # Environment, so a workflow in a fork -- or a job targeting dev -- cannot
    # assume the production role.
    #
    # NEVER write this as "repo:${var.github_org}/*". That grants every
    # repository in the org, and it is the single most common mistake in
    # GitHub OIDC setups.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:environment:${var.environment}"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "github-actions-${var.github_repo}-${var.environment}"
  description          = "Assumed by GitHub Actions via OIDC for ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Deliberately not AdministratorAccess. Scope this to what the module actually
# manages before using it for real.
resource "aws_iam_role_policy_attachment" "terraform" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

output "role_arn" {
  description = "Set this as the AWS_ROLE_ARN variable on the GitHub Environment"
  value       = aws_iam_role.github_actions.arn
}
