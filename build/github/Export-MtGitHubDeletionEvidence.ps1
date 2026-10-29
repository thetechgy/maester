#Requires -Version 7.4
<#
.SYNOPSIS
Exports read-only GitHub deletion diagnostics for one organization and repository.
.DESCRIPTION
Loads this checkout, connects through Connect-MtGitHub and writes a private detailed
JSON report plus a pseudonymized JSON/Markdown summary under ignored TestResults.
Does not run CIS checks, delete issues, alter permissions or retry failed requests.
.PARAMETER Organization
Organization login to inspect.
.PARAMETER Repository
One repository name within Organization (not owner/name or a URL).
.PARAMETER AccountModel
Assessor-supplied identity context; not independently verified by this probe.
.PARAMETER Enterprise
Optional assessor-supplied enterprise slug. Recorded as context only; no enterprise-wide scan.
.PARAMETER IssueNumber
Optional existing issue in the selected repository; reads viewerCanDelete for the signed-in user only.
.PARAMETER ApiBaseUri
Supported Connect-MtGitHub API host. Defaults to api.github.com; use api.<subdomain>.ghe.com for data residency.
.PARAMETER Token
Optional SecureString passed to Connect-MtGitHub. Environment token resolution otherwise applies; without a token, prompts securely for an existing user token.
.PARAMETER MaxPages
Maximum 100-item pages per paginated operation. Nested policy rules and bypass lists are each capped at 100.
.EXAMPLE
./build/github/Export-MtGitHubDeletionEvidence.ps1 -Organization example -Repository sample -AccountModel EnterpriseManagedUsers -IssueNumber 1
.OUTPUTS
Paths to local artifacts. Review summary files before sharing; keep detailed.json private.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,99}$')] [string] $Organization,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')] [string] $Repository,
    [ValidateSet('Unknown', 'PersonalAccounts', 'EnterpriseManagedUsers')] [string] $AccountModel = 'Unknown',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,99}$')] [string] $Enterprise,
    [ValidateRange(1, [int]::MaxValue)] [int] $IssueNumber,
    [string] $ApiBaseUri = 'https://api.github.com',
    [securestring] $Token,
    [ValidateRange(1, 100)] [int] $MaxPages = 5
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$sourceCommit = & git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Run from a Git source checkout.' }
$sourceStatus = @(& git -C $root status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect source checkout status.' }

# Always load this checkout. A fresh pwsh session is recommended in the runbook.
Import-Module (Join-Path $root 'powershell/Maester.psd1') -Force
$module = Get-Module Maester
$started = [DateTimeOffset]::UtcNow
$connect = @{ Organization = $Organization; ApiBaseUri = $ApiBaseUri }
if (-not $Token -and -not $env:MAESTER_GITHUB_TOKEN -and -not $env:GH_TOKEN) {
    $Token = Read-Host 'Existing GitHub user token (no app installation)' -AsSecureString
    if ($Token.Length -eq 0) { throw 'An existing user token is required.' }
}
if ($Token) { $connect.Token = $Token }
try {
    Connect-MtGitHub @connect
    $context = & $module {
        $c = $__MtSession.GitHubConnection
        [pscustomobject]@{
            Connected = $c.Connected; FailureReason = $c.FailureReason
            Organization = $c.Organization; ApiBaseUri = $c.ApiBaseUri; ApiVersion = $c.ApiVersion
            TokenLogin = $c.TokenLogin; Role = $c.Role; RoleState = $c.RoleState
            AuthenticationType = $c.AuthenticationType
            AdministrationPermissionVerified = $c.AdministrationPermissionVerified
        }
    }
    if (-not $context.Connected) { throw 'GitHub connection failed. See Connect-MtGitHub diagnostics; no evidence report was produced.' }
    $operations = & $module {
        param($CollectorPath, $RepositoryName, $Number, $Pages)
        . $CollectorPath
        Get-MtGitHubDeletionEvidence -Repository $RepositoryName -IssueNumber $Number -MaxPages $Pages
    } (Join-Path $PSScriptRoot 'Get-MtGitHubDeletionEvidence.ps1') $Repository $IssueNumber $MaxPages
} finally {
    Disconnect-MtGitHub
}
$limitations = @(
    'Diagnostic collection only; Observed does not establish compliance or a complete effective deletion population.'
    'One selected repository; no tenant-wide repository or enterprise scan. Enterprise and account model are supplied context only.'
    'Owner/admin visibility must be compared with the UI. Custom role definitions do not enumerate organization role assignments.'
    'GraphQL permissionSources may be null, partial or omit implicit access; no inferred effective grant or trust decision.'
    'Policy rules and bypass lists each stop at 100. Top-level operations stop at MaxPages. Concurrent changes can affect pagination.'
    'Authorization rule parameters are not exposed by the queried public parameter union; only their available type is retained.'
    'Policy delegated bypass, legacy enterprise overrides and stronger-policy equivalence need manual qualification; empty results do not prove absence.'
    'viewerCanDelete applies only to the signed-in viewer and supplied existing issue at collection time; no deletion attempt is made.'
    'Trusted/qualified owners and administrators and the meaning of few remain unresolved assessment questions.'
    'Allowlisted diagnostics retain missing keys, nulls, arrays and scalar types. Unexpected objects are reduced to diagnostic type markers.'
    'A shared rate-limit observation may precede this operation; its SourceHttpStatus does not prove a new HTTP request was sent.'
    'No automatic retries. Connection bootstrap reads retain the existing REST version default; new diagnostic REST reads use 2026-03-10.'
)
$report = [ordered]@{
    SchemaVersion = 1; SourceCommit = [string]$sourceCommit; SourceDirty = $sourceStatus.Count -gt 0
    StartedUtc = $started; CompletedUtc = [DateTimeOffset]::UtcNow
    Context = [ordered]@{ Organization = $Organization; Repository = $Repository; IssueNumber = $(if ($IssueNumber) { $IssueNumber } else { $null }); Enterprise = $Enterprise; AccountModel = $AccountModel; Connection = $context }
    MaxPages = $MaxPages; NestedItemCap = 100; Operations = @($operations); Limitations = $limitations
}
. (Join-Path $PSScriptRoot 'ConvertTo-MtGitHubDeletionSummary.ps1')
$summary = ConvertTo-MtGitHubDeletionSummary -Report $report

# Fixed ignored destination; a unique directory avoids overwriting earlier evidence.
$resultRoot = Join-Path $root 'TestResults'
$output = Join-Path $resultRoot ("github-deletion-{0}-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 8))
# Refuse symlinked ancestors before writing private evidence.
foreach ($path in @($resultRoot, $root)) {
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path -Force).LinkType) { throw 'Report destination must not be a symbolic link.' }
}
$null = New-Item -ItemType Directory -Path $output
if (-not $IsWindows) { [IO.File]::SetUnixFileMode($output, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
$report | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $output 'detailed.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $output 'summary.json') -Encoding utf8
$lines = @(
    '# GitHub deletion evidence (pseudonymized)'
    ''
    "Source: ``$sourceCommit``; source dirty: $($report.SourceDirty)."
    "Collected: $($report.StartedUtc.ToString('o')) to $($report.CompletedUtc.ToString('o'))."
    "Supplied account model: $AccountModel. Targets: organization-1 / repository-1; viewer: user-1."
    ''
    '| Operation | Outcome | Pages | Items | Pagination complete | Gaps |'
    '| --- | --- | ---: | ---: | --- | ---: |'
)
foreach ($operation in $operations) {
    $lines += "| $($operation.Name) | $($operation.Outcome) | $($operation.PageCount) | $($operation.ItemCount) | $($operation.PaginationComplete) | $($operation.Gaps.Count) |"
}
$lines += @('', 'See summary.json for field-presence/type diagnostics and gap categories. Strings are pseudonymized per run; identifiers are not hashes.', '', '## Limitations', '')
$lines += $limitations | ForEach-Object { "- $_" }
$lines | Set-Content -LiteralPath (Join-Path $output 'summary.md') -Encoding utf8
[pscustomobject]@{ DetailedReport = Join-Path $output 'detailed.json'; SummaryJson = Join-Path $output 'summary.json'; SummaryMarkdown = Join-Path $output 'summary.md' }
