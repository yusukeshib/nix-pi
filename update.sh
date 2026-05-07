#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/earendil-works/pi.git
archive_base_url=https://github.com/earendil-works/pi/archive/refs/tags
version_file=VERSION.json
models_file=models.generated.ts

die() { echo "$*" >&2; exit 1; }
out() { [[ -n ${GITHUB_OUTPUT:-} ]] && echo "$1=$2" >> "$GITHUB_OUTPUT" || true; }

write_version_json() {
  local rev=$1 hash=$2 npm_deps_hash=$3 tmp
  tmp=$(mktemp)
  jq \
    --arg rev "$rev" \
    --arg hash "$hash" \
    --arg npmDepsHash "$npm_deps_hash" \
    '.rev = $rev
    | .hash = $hash
    | .projects["coding-agent"].npmDepsHash = $npmDepsHash' \
    "$version_file" > "$tmp"
  mv "$tmp" "$version_file"
}

latest_tag() {
  git ls-remote --tags --refs "$repo_url" 'v*' \
    | awk -F/ '{print $3}' \
    | grep -E '^v[0-9]+(\.[0-9]+)*$' \
    | sort -V \
    | tail -n1
}

cleanup() {
  rm -rf "$tmpdir" "$backup_dir"
}

restore_and_cleanup() {
  local status=$?
  if (( status != 0 )); then
    cp "$backup_dir/$version_file" "$version_file" 2>/dev/null || true
    cp "$backup_dir/$models_file" "$models_file" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}

current_rev=$(jq -r '.rev' "$version_file")
latest_rev=$(latest_tag)
[[ -n "$latest_rev" ]] || die "Failed to determine latest upstream tag"

target_rev=$current_rev
version_changed=false
if [[ "$latest_rev" != "$current_rev" ]]; then
  target_rev=$latest_rev
  version_changed=true
fi

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$version_file" "$backup_dir/$version_file"
cp "$models_file" "$backup_dir/$models_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$target_rev.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
src_hash=$(jq -r .hash <<< "$prefetch_json")
src_path=$(jq -r .storePath <<< "$prefetch_json")

cp -R "$src_path"/. "$tmpdir"/
chmod -R u+w "$tmpdir"
[[ -f "$tmpdir/package-lock.json" ]] || die "Upstream archive does not contain package-lock.json"

echo "Generating model definitions for $target_rev..."
pushd "$tmpdir" >/dev/null
export NPM_CONFIG_YES=true
npm ci --ignore-scripts
npm run generate-models --workspace=packages/ai
popd >/dev/null

generated_models="$tmpdir/packages/ai/src/models.generated.ts"
[[ -f "$generated_models" ]] || die "Model generation did not produce $generated_models"

models_changed=false
if cmp -s "$generated_models" "$models_file"; then
  echo "models.generated.ts is already up to date"
else
  cp "$generated_models" "$models_file"
  models_changed=true
  echo "Updated models.generated.ts"
fi

if [[ "$version_changed" == "true" ]]; then
  npm_deps_hash=$(nix run --inputs-from . nixpkgs#prefetch-npm-deps -- "$tmpdir/package-lock.json" | tail -n1)
  [[ -n "$npm_deps_hash" ]] || die "Failed to determine npmDepsHash"
  write_version_json "$target_rev" "$src_hash" "$npm_deps_hash"
fi

if [[ "$version_changed" == "true" || "$models_changed" == "true" ]]; then
  nix build .#coding-agent --no-link >/dev/null
fi

if [[ "$version_changed" == "true" ]]; then
  echo "Updated VERSION.json to $target_rev"
elif [[ "$models_changed" == "true" ]]; then
  echo "Updated models for $target_rev"
else
  echo "VERSION.json already points to $current_rev"
  echo "No changes to commit"
fi

out version "$target_rev"
out version_changed "$version_changed"

trap - EXIT
cleanup
