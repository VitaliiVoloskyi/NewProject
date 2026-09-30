#!/usr/bin/env bash
# Creates the IAM role GitHub Actions assumes via OIDC (infra/github-oidc.yaml) and prints the
# repository variables the deploy workflow needs. Run once via `make deploy-ci`, with
# GITHUB_REPO=owner/name in .env.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  repo="${GITHUB_REPO:-}"
  if [ -z "$repo" ]; then
    # Fall back to the origin remote, e.g. https://github.com/owner/name.git
    repo="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  fi
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Set GITHUB_REPO=owner/name in .env" >&2; exit 1; }

  # Newer repositories get OIDC subjects with immutable ids (owner@123/repo@456); look them up
  # from GitHub's public API so the trust policy accepts that format too.
  repo_ids="$(curl -fsS "https://api.github.com/repos/$repo" 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("%s@%s/%s@%s" % (r["owner"]["login"], r["owner"]["id"], r["name"], r["id"]))' 2>/dev/null || true)"
  [ -n "$repo_ids" ] || repo_ids="$(gh api "repos/$repo" --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' 2>/dev/null || true)"
  echo "    Repository ids: ${repo_ids:-not found (private repo without gh login?)}"

  account="$(aws sts get-caller-identity --query Account --output text)"
  provider="arn:aws:iam::$account:oidc-provider/token.actions.githubusercontent.com"
  existing=""
  # The provider is account-wide; reuse it unless this stack is the one that created it.
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" >/dev/null 2>&1; then
    owner_stack="$(aws cloudformation describe-stack-resource --stack-name "$CI_STACK" \
      --logical-resource-id GitHubProvider --query StackResourceDetail.PhysicalResourceId \
      --output text 2>/dev/null || true)"
    [ "$owner_stack" = "$provider" ] || existing="$provider"
  fi

  echo "==> GitHub OIDC deploy role for $repo (branch main) ($CI_STACK)"
  aws cloudformation deploy \
    --stack-name "$CI_STACK" \
    --template-file infra/github-oidc.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ProjectName=$PROJECT_NAME" "GitHubRepo=$repo" "GitHubRepoWithIds=$repo_ids" \
      "ExistingProviderArn=$existing" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo
  echo "Add these as repository VARIABLES (Settings -> Secrets and variables -> Actions ->"
  echo "Variables). None of them is a secret; there are no AWS keys to store."
  echo
  echo "  AWS_ROLE_ARN    = $(output "$CI_STACK" RoleArn)"
  echo "  AWS_REGION      = $AWS_REGION"
  echo "  PROJECT_NAME    = $PROJECT_NAME"
  echo "  DOMAIN_NAME     = ${DOMAIN_NAME:-}   (optional)"
  echo "  HOSTED_ZONE_ID  = ${HOSTED_ZONE_ID:-}   (optional)"
  echo
  echo "With gh:  gh variable set AWS_ROLE_ARN --body '$(output "$CI_STACK" RoleArn)'   (and so on)"
}

main "$@"
