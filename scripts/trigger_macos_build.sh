#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/trigger_macos_build.sh [--arch all|amd64|arm64] [--env pre|stable] [--ref <branch-or-tag>] [--watch]

Examples:
  scripts/trigger_macos_build.sh
  scripts/trigger_macos_build.sh --arch arm64 --env stable --watch
USAGE
}

arch="all"
app_env="pre"
ref=""
watch="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      arch="${2:?missing value for --arch}"
      shift 2
      ;;
    --env)
      app_env="${2:?missing value for --env}"
      shift 2
      ;;
    --ref)
      ref="${2:?missing value for --ref}"
      shift 2
      ;;
    --watch)
      watch="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$arch" in
  all|amd64|arm64) ;;
  *)
    echo "--arch must be one of: all, amd64, arm64" >&2
    exit 2
    ;;
esac

case "$app_env" in
  pre|stable) ;;
  *)
    echo "--env must be one of: pre, stable" >&2
    exit 2
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required: https://cli.github.com/" >&2
  exit 1
fi

if [[ -z "$ref" ]]; then
  ref="$(git branch --show-current)"
fi

if [[ -z "$ref" ]]; then
  echo "Cannot detect current branch. Pass --ref <branch-or-tag>." >&2
  exit 1
fi

if [[ "$ref" == "$(git branch --show-current)" ]] &&
  ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  echo "Warning: current branch has no upstream. Push it first, or pass --ref for an existing remote ref." >&2
fi

echo "Triggering macos-build.yaml on ref '$ref' with arch=$arch env=$app_env"
gh workflow run macos-build.yaml \
  --ref "$ref" \
  -f "arch=$arch" \
  -f "env=$app_env"

if [[ "$watch" == "true" ]]; then
  sleep 3
  run_id="$(gh run list --workflow macos-build.yaml --branch "$ref" --limit 1 --json databaseId --jq '.[0].databaseId')"
  if [[ -n "$run_id" && "$run_id" != "null" ]]; then
    gh run watch "$run_id"
  else
    echo "Triggered, but could not find the new run id yet. Open Actions in GitHub to watch progress." >&2
  fi
fi
