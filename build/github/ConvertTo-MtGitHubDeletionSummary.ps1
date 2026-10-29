function ConvertTo-MtGitHubDeletionSummary {
    <#
    .SYNOPSIS
    Makes a pseudonymized diagnostic summary without mutating private evidence.
    .DESCRIPTION
    Pseudonymizes data strings and identifier numbers, retaining fixed public
    permission/policy enums, booleans, nulls and array shape. No reverse map is written.
    Diagnostic labels are locally authored; raw API errors are never accepted.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Report)
    $strings = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $identifiers = @{}
    function Convert-DataValue ($Value, [string] $Field) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [string]) {
            $publicValues = @('ADMIN', 'MAINTAIN', 'WRITE', 'TRIAGE', 'READ', 'NONE', 'REPOSITORY', 'ACTIVE', 'DISABLED', 'EVALUATE', 'AUTHORIZATION', 'ALWAYS', 'EXEMPT', 'PULL_REQUEST', 'admin', 'maintain', 'write', 'triage', 'read', 'delete_issue', 'Organization', 'Enterprise', 'Repository', 'Team', 'User', 'App', 'PSCustomObject', 'Object[]')
            if ($Field -in 'permission', 'type', 'target', 'enforcement', 'bypassMode', 'base_role', 'permissions', 'IssueDeletionPermissionMatches', '__typename', 'DiagnosticType' -and $Value -cin $publicValues) { return $Value }
            if (-not $strings.ContainsKey($Value)) { $strings[$Value] = 'string-{0}' -f ($strings.Count + 1) }
            return $strings[$Value]
        }
        if ($Value -is [array]) {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Value) { $items.Add((Convert-DataValue -Value $item -Field $Field)) }
            return ,$items.ToArray()
        }
        if ($Value -is [pscustomobject]) {
            $properties = [ordered]@{}
            foreach ($property in $Value.PSObject.Properties) { $properties[$property.Name] = Convert-DataValue -Value $property.Value -Field $property.Name }
            return [pscustomobject]$properties
        }
        if ($Value -is [bool]) { return $Value }
        # Only counts retain their numeric value. This also covers unexpected
        # numeric types in login/permission fields; do not leak a numeric identifier.
        if ($Value -is [ValueType] -and $Field -notin 'totalCount', 'total_count') {
            $key = "$($Value.GetType().Name):$Value"
            if (-not $identifiers.ContainsKey($key)) { $identifiers[$key] = $identifiers.Count + 1 }
            if ($Value -is [bigint]) { return [bigint]$identifiers[$key] }
            if ($Value -is [datetime]) { return [datetime]::UnixEpoch.AddTicks($identifiers[$key]) }
            return [Convert]::ChangeType($identifiers[$key], $Value.GetType())
        }
        return $Value
    }
    $operations = foreach ($operation in $Report.Operations) {
        [pscustomobject]@{
            Name = $operation.Name; Api = $operation.Api; Outcome = $operation.Outcome
            StartedUtc = $operation.StartedUtc; CompletedUtc = $operation.CompletedUtc
            HttpStatus = $operation.HttpStatus; ContentKind = $operation.ContentKind; RateLimit = $operation.RateLimit; PageCount = $operation.PageCount
            PaginationComplete = $operation.PaginationComplete; ItemCount = $operation.ItemCount
            Gaps = @($operation.Gaps); Data = Convert-DataValue -Value $operation.Data -Field ''
        }
    }
    [ordered]@{
        SchemaVersion = $Report.SchemaVersion; SourceCommit = $Report.SourceCommit; SourceDirty = $Report.SourceDirty
        StartedUtc = $Report.StartedUtc; CompletedUtc = $Report.CompletedUtc
        Context = @{
            Organization = 'organization-1'; Repository = 'repository-1'; Viewer = 'user-1'
            EnterpriseSupplied = -not [string]::IsNullOrEmpty($Report.Context.Enterprise)
            AccountModel = $Report.Context.AccountModel
            HostKind = $(if ($Report.Context.Connection.ApiBaseUri -eq 'https://api.github.com') { 'github.com' } else { 'GHE.com' })
            IssueRequested = $null -ne $Report.Context.IssueNumber
        }
        MaxPages = $Report.MaxPages; NestedItemCap = $Report.NestedItemCap
        Operations = @($operations); Limitations = $Report.Limitations
    }
}
