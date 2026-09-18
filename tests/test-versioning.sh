#!/usr/bin/env bash
set -euo pipefail

# The version must be one string, in one place, that the changelog and the
# menu agree with. A VERSION with no changelog entry is a release nobody wrote
# down; a changelog entry without a matching tag format cannot be tagged.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

version="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
[[ -n "${version}" ]] || fail "VERSION is empty"

# SemVer with an optional pre-release stage of the shape the roadmap defines.
semver='^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'
[[ "${version}" =~ ${semver} ]] || fail "VERSION '${version}' is not SemVer with an alpha/beta/rc stage"

# Pre-1.0 versions must carry a stage label; the roadmap says an unlabeled
# 0.x would be a claim nobody measured.
if [[ "${version}" == 0.* && "${version}" != *-* ]]; then
  fail "VERSION '${version}' is pre-1.0 without a stage suffix (-alpha.N, -beta.N, -rc.N)"
fi

grep -qF "## [${version}]" "${ROOT_DIR}/CHANGELOG.md" \
  || fail "CHANGELOG.md has no section for version ${version}"

grep -qF "[${version}]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v${version}" "${ROOT_DIR}/CHANGELOG.md" \
  || fail "CHANGELOG.md has no release link for v${version}"

out="$("${ROOT_DIR}/scripts/skid-finder.sh" --version)"
[[ "${out}" == "skid-finder ${version}" ]] || fail "menu --version printed '${out}', expected 'skid-finder ${version}'"

# The roadmap's stage table must know every stage the regex accepts.
for stage in alpha beta rc stable; do
  grep -q "\*\*${stage}\*\*" "${ROOT_DIR}/docs/ROADMAP.md" || fail "docs/ROADMAP.md does not define the '${stage}' stage"
done

echo "Versioning test passed (${version})."
