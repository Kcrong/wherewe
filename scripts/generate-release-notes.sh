#!/usr/bin/env bash
set -euo pipefail

RELEASE_TAG="${1:?release tag is required}"
OUTPUT_PATH="${2:?output path is required}"

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf '%s\n' 'Release tag must match vMAJOR.MINOR.PATCH.' >&2
  exit 1
}
TAG_COMMIT="$(git rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}")"
PREVIOUS_TAG=""
if PARENT_COMMIT="$(git rev-parse --verify "$TAG_COMMIT^" 2>/dev/null)"; then
  while IFS= read -r commit; do
    while IFS= read -r candidate; do
      if [[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PREVIOUS_TAG="$candidate"
        break 2
      fi
    done < <(git tag --points-at "$commit" --list 'v*' --sort=-version:refname)
  done < <(git rev-list --first-parent "$PARENT_COMMIT")
fi

if [[ -n "$PREVIOUS_TAG" ]]; then
  RELEASE_RANGE="$PREVIOUS_TAG..$RELEASE_TAG"
else
  RELEASE_RANGE="$RELEASE_TAG"
fi
COMMIT_COUNT="$(git rev-list --count "$RELEASE_RANGE")"
TEMP_PATH="$OUTPUT_PATH.tmp.$$"
umask 077
trap 'rm -f "$TEMP_PATH"' EXIT
{
  printf '# Wherewe %s\n\n' "${RELEASE_TAG#v}"
  printf '## Changes\n\n'
  if [[ -n "$PREVIOUS_TAG" ]]; then
    printf 'Commit messages since `%s`:\n\n' "$PREVIOUS_TAG"
  else
    printf 'Commit messages included in this release:\n\n'
  fi
  if [[ "$COMMIT_COUNT" -eq 0 ]]; then
    printf '%s\n' '- No new commits.'
  else
    git log --reverse --format='- `%h` %s' "$RELEASE_RANGE"
  fi
} > "$TEMP_PATH"
mv "$TEMP_PATH" "$OUTPUT_PATH"
trap - EXIT
