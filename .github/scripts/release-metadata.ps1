<#
.SYNOPSIS
    TEST adaptation of the real release-metadata wrapper (orchestration-only).

.DESCRIPTION
    Identical to the production .github/scripts/release-metadata.ps1 EXCEPT it
    resolves digests from public MCR (no `az acr login`, no ACR-derived repo) so the
    publish orchestration (build, upload skip-if-exists, one-PR guard, cr index --pr,
    bot identity) can be exercised in a throwaway repo without Azure. Expects
    GH_TOKEN in the environment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$tag,

    [string]$releaseType = "",

    [Parameter(Mandatory = $true)]
    [string]$pagesBranch
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = git rev-parse --show-toplevel
$owner = $env:GITHUB_REPOSITORY_OWNER
$repoName = ($env:GITHUB_REPOSITORY -split '/')[1]
$crVersion = "1.8.1"
$crDir = "$env:RUNNER_TEMP/crbin"
$packagePath = "$env:RUNNER_TEMP/cr-release-packages"

# TEST: resolve digests from public MCR (prod resolves from the release ACR).
$repo = "mcr.microsoft.com/azurecleanroom"

# powershell-yaml is required by the chart build script (ConvertFrom/To-Yaml).
Install-Module -Name powershell-yaml -Force

# Install chart-releaser (cr).
New-Item -ItemType Directory -Force $crDir | Out-Null
$crUrl = "https://github.com/helm/chart-releaser/releases/download/v$crVersion/" +
"chart-releaser_${crVersion}_linux_amd64.tar.gz"
Invoke-WebRequest -Uri $crUrl -OutFile "$crDir/cr.tgz"
tar -xz -C $crDir -f "$crDir/cr.tgz" cr
$cr = "$crDir/cr"

# cr needs origin/<pages-branch> to worktree the current index and branch off it.
git fetch origin "${pagesBranch}:refs/remotes/origin/$pagesBranch"

# Resolve digests, carry forward images not released this cycle, package the .tgz.
& "$root/build/build-release-metadata-chart.ps1" `
    -tag $tag `
    -repo $repo `
    -releasedGroups $releaseType `
    -outDir $packagePath

# Attach the chart .tgz to the (already-created) Release for this tag. Skip if it
# already exists so a re-run never overwrites a published, digest-referenced asset.
$asset = "release-metadata-$tag.tgz"
$existing = gh release view $tag --json assets --jq '.assets[].name'
if (@($existing) -contains $asset) {
    Write-Host "Asset $asset already present on release $tag; skipping upload."
}
else {
    gh release upload $tag "$packagePath/$asset"
}

# Keep at most one outstanding index PR: skip if one is already open. (An
# already-merged version is a no-op inside cr, which adds only missing versions.)
$openPrs = gh pr list --repo $env:GITHUB_REPOSITORY --state open --base $pagesBranch `
    --json headRefName --jq '[.[] | select(.headRefName | startswith("chart-releaser-"))] | length'
if ([int]$openPrs -gt 0) {
    Write-Host "An index update PR is already open; skipping to avoid duplicates."
    return
}

# Commit the index update as github-actions[bot] (which also opens the PR).
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Open the PR. --index-path is a local scratch copy; the published index is written
# on the pages branch via --pages-index-path.
& $cr index `
    --owner $owner `
    --git-repo $repoName `
    --token $env:GH_TOKEN `
    --package-path $packagePath `
    --release-name-template "{{ .Version }}" `
    --pages-branch $pagesBranch `
    --pages-index-path index.yaml `
    --index-path "$env:RUNNER_TEMP/cr-index.yaml" `
    --pr
