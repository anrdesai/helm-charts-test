param(
    [parameter(Mandatory = $true)]
    [string]$tag,

    [parameter(Mandatory = $true)]
    [string]$repo,

    # Registry/repo to bake into the published references (e.g. the public
    # mcr.microsoft.com/azurecleanroom). Digests are resolved from -repo (the ACR
    # just pushed to) but the published reference is rebased onto this, matching the
    # attest-artefact convention. Defaults to -repo (single-registry local runs).
    [string]$publishRepo = "",

    # Comma-separated release-type tokens released this cycle (e.g.
    # "ccf-network-containers,cleanroom-containers"). Images whose group was
    # released are resolved fresh at $tag; all others are carried forward from the
    # previous published catalog. Empty => full release (resolve everything).
    [string]$releasedGroups = "",

    # GitHub Pages index.yaml used to source carry-forward references for images not
    # released this cycle. Defaults to the published catalog; override for local/test.
    [string]$previousIndexUrl = "https://azure.github.io/azure-cleanroom/index.yaml",

    # Base URL under which the packaged .tgz is served, written into index.yaml.
    # Optional: when empty, the local 'helm repo index' step is skipped (used when
    # an external tool such as chart-releaser 'cr' owns index generation).
    [string]$chartBaseUrl = "",

    [string]$outDir = ""
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if ($publishRepo -eq "") {
    $publishRepo = $repo
}

$root = git rev-parse --show-toplevel
$buildRoot = "$root/build"

. $buildRoot/helpers.ps1

# Fetches the image map (name -> ref) from the most recently published catalog
# version, used to carry forward references for components not released this cycle.
function Get-PreviousImages {
    param([string]$indexUrl)

    # Download to a file first: Invoke-WebRequest.Content is Byte[] (not string) on
    # PowerShell/Linux, which breaks ConvertFrom-Yaml.
    $indexFile = "$([System.IO.Path]::GetTempFileName()).yaml"
    try {
        Invoke-WebRequest -Uri $indexUrl -OutFile $indexFile -UseBasicParsing
    }
    catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        # No published catalog yet (e.g. first release before Pages is seeded).
        # Treat as an empty baseline so full releases bootstrap cleanly; partial
        # releases then fail later with the actionable per-image error.
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            Write-Host "No published index.yaml at $indexUrl (404); treating as empty baseline."
            Remove-Item -Force $indexFile -ErrorAction SilentlyContinue
            return @{}
        }
        throw
    }
    $index = Get-Content -Raw $indexFile | ConvertFrom-Yaml
    Remove-Item -Force $indexFile -ErrorAction SilentlyContinue

    $entries = $index.entries."release-metadata"
    if (-not $entries) {
        return @{}
    }

    # Pick the latest by publish timestamp (robust to non-semver catalog versions).
    $latest = $entries | Sort-Object { [datetime]$_.created } -Descending | Select-Object -First 1
    $tgz = "$([System.IO.Path]::GetTempFileName()).tgz"
    Invoke-WebRequest -Uri $latest.urls[0] -OutFile $tgz -UseBasicParsing
    $values = (helm show values $tgz) -join "`n" | ConvertFrom-Yaml
    Remove-Item -Force $tgz -ErrorAction SilentlyContinue

    $result = @{}
    if ($values.images) {
        foreach ($k in $values.images.Keys) {
            $result[$k] = $values.images[$k]
        }
    }
    return $result
}

if ($outDir -eq "") {
    $outDir = "$root/.charts/release-metadata"
}
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
}

# Canonical image catalog. Each entry maps a logical image name to its repo path,
# kind (container images are digest-pinned; policy artifacts are tag-referenced),
# and the set of release-type groups that build/push it. An image is resolved
# fresh when ANY of its groups is released this cycle; otherwise it is carried
# forward from the previous published catalog.
$catalog = @(
    @{ name = "ccf-run-js-app-virtual"; path = "ccf/app/run-js/virtual"; kind = "container"; groups = @("ccf-network-containers") }
    @{ name = "ccf-run-js-app-snp"; path = "ccf/app/run-js/snp"; kind = "container"; groups = @("ccf-network-containers") }
    @{ name = "ccf-recovery-agent"; path = "ccf/ccf-recovery-agent"; kind = "container"; groups = @("ccf-network-containers") }
    @{ name = "ccf-recovery-service"; path = "ccf/ccf-recovery-service"; kind = "container"; groups = @("ccf-recovery-service-containers") }
    @{ name = "ccf-consortium-manager"; path = "ccf/ccf-consortium-manager"; kind = "container"; groups = @("ccf-consortium-manager-containers") }
    @{ name = "cvm-attestation-verifier"; path = "cvm/cvm-attestation-verifier"; kind = "container"; groups = @("ccf-network-containers") }
    @{ name = "ccr-proxy"; path = "ccr-proxy"; kind = "container"; groups = @("ccf-network-containers", "ccf-recovery-service-containers", "cleanroom-containers") }
    @{ name = "skr"; path = "skr"; kind = "container"; groups = @("ccf-network-containers", "ccf-recovery-service-containers", "cleanroom-containers") }
    @{ name = "ccf-network-security-policy"; path = "policies/ccf/ccf-network-security-policy"; kind = "policy"; groups = @("ccf-network-containers") }
    @{ name = "ccf-recovery-service-security-policy"; path = "policies/ccf/ccf-recovery-service-security-policy"; kind = "policy"; groups = @("ccf-recovery-service-containers") }
    @{ name = "ccf-consortium-manager-security-policy"; path = "policies/ccf/ccf-consortium-manager-security-policy"; kind = "policy"; groups = @("ccf-consortium-manager-containers") }
)

$allGroups = $catalog.groups | Select-Object -Unique
if ([string]::IsNullOrWhiteSpace($releasedGroups)) {
    # Full release: resolve every image fresh at $tag.
    $releasedSet = $allGroups
}
else {
    $releasedSet = $releasedGroups -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
Write-Host "Released groups this cycle: $($releasedSet -join ', ')"

# Load the carry-forward baseline only if some image is not covered this cycle.
$carryForwardNeeded = @(
    $catalog | Where-Object { -not ($_.groups | Where-Object { $releasedSet -contains $_ }) }
).Count -gt 0
$previousImages = @{}
if ($carryForwardNeeded) {
    Write-Host "Loading carry-forward baseline from $previousIndexUrl"
    $previousImages = Get-PreviousImages -indexUrl $previousIndexUrl
}

$images = [ordered]@{}
foreach ($e in $catalog) {
    $released = [bool]($e.groups | Where-Object { $releasedSet -contains $_ })
    if ($released) {
        if ($e.kind -eq "container") {
            $digest = Get-Digest -repo $repo -containerName $e.path -tag $tag
            $images[$e.name] = "$publishRepo/$($e.path)@$digest"
        }
        else {
            $images[$e.name] = "$publishRepo/$($e.path):$tag"
        }
    }
    else {
        if (-not $previousImages.Contains($e.name)) {
            throw "No previous reference to carry forward for '$($e.name)' (groups: $($e.groups -join ', ')); it was not released this cycle and is absent from the previous catalog. Release its group, or make this a full release to bootstrap the catalog."
        }
        $images[$e.name] = $previousImages[$e.name]
        Write-Host "Carrying forward $($e.name) => $($images[$e.name])"
    }
}

# Assemble a fresh chart directory and stamp the version (== the release tag).
$chartSrc = "$buildRoot/release-metadata-chart"
$chartDir = "$outDir/release-metadata"
if (Test-Path $chartDir) {
    Remove-Item -Recurse -Force $chartDir
}
Copy-Item -Recurse $chartSrc $chartDir

$chart = Get-Content -Path "$chartDir/Chart.yaml" -Raw | ConvertFrom-Yaml
$chart.version = $tag
($chart | ConvertTo-Yaml).TrimEnd() | Out-File "$chartDir/Chart.yaml"

# Fill the values.yaml template placeholders with the resolved values.
$valuesPath = "$chartDir/values.yaml"
$content = Get-Content -Path $valuesPath -Raw
$content = $content.Replace("__RELEASE_VERSION__", $tag)
$content = $content.Replace("__PUBLISHED__", (Get-Date -Format "yyyy-MM-dd"))
foreach ($img in $images.GetEnumerator()) {
    $token = "__IMAGE_" + ($img.Name.ToUpperInvariant() -replace '-', '_') + "__"
    $content = $content.Replace($token, $img.Value)
}

$remaining = [regex]::Matches($content, '__[A-Z0-9_]+__').Value | Select-Object -Unique
if ($remaining) {
    throw "Unfilled placeholder(s) in ${valuesPath}: $($remaining -join ', ')"
}
$content.TrimEnd() | Out-File $valuesPath

# Validate the generated contract against values.schema.json before publishing.
# helm enforces the schema on 'lint' (not on 'package'/'show values'); this is the
# producer-side guardrail for the non-deployable metadata chart.
Write-Host "Linting release-metadata chart against values.schema.json"
helm lint $chartDir

Write-Host "Packaging release-metadata chart version $tag"
helm package $chartDir --destination $outDir --version $tag

# Local index generation is optional: in CI, chart-releaser ('cr index') owns the
# published index.yaml. Only build a local index when a base URL is supplied.
if ([string]::IsNullOrWhiteSpace($chartBaseUrl)) {
    Write-Host "chartBaseUrl not set; skipping local 'helm repo index' (cr owns it)."
    return
}

$indexFile = "$outDir/index.yaml"
if (Test-Path $indexFile) {
    helm repo index $outDir --url $chartBaseUrl --merge $indexFile
}
else {
    helm repo index $outDir --url $chartBaseUrl
}

Write-Host "Updated $indexFile (chart base url: $chartBaseUrl)"
