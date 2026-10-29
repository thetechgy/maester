function Get-MtGitHubDeletionEvidence {
    <#
    .SYNOPSIS
    Collects bounded deletion diagnostics inside the source Maester module session.
    .DESCRIPTION
    Used only by the research runner. All requests use the shared read transports.
    Reports contain allowlisted fields, never raw HTTP bodies, errors or headers.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [int] $IssueNumber,
        [ValidateRange(1, 100)] [int] $MaxPages = 5
    )

    # The runner establishes and validates this connection before entering module scope.
    $pageLimit = $MaxPages
    $connection = $__MtSession.GitHubConnection
    $organization = $connection.Organization
    $org = [uri]::EscapeDataString($organization)
    $repo = [uri]::EscapeDataString($Repository)
    $operations = [System.Collections.Generic.List[object]]::new()
    $pageInfoSpec = @{ hasNextPage = 'Boolean'; endCursor = '?String' }
    $actorSpec = @{ __typename = 'String'; login = '?String'; slug = '?String'; nameWithOwner = '?String' }
    $sourceSpec = @{ permission = 'String'; roleName = '?String'; source = $actorSpec }
    $collaboratorSpec = @{ node = @{ login = 'String' }; permission = 'String'; permissionSources = @($sourceSpec) }
    $roleSpec = @{ id = 'Integer'; name = 'String'; permissions = @('String') }
    $repoRoleSpec = $roleSpec + @{ base_role = 'String' }
    $bypassSpec = @{
        bypassMode = 'String'; organizationAdmin = 'Boolean'; enterpriseOwner = 'Boolean'; enterpriseRole = 'Boolean'; deployKey = 'Boolean'
        enterpriseRoleDatabaseId = '?Identifier'
        repositoryRoleDatabaseId = '?Integer'; repositoryRoleName = '?String'
        actor = ($actorSpec + @{ '$nullable' = $true })
    }
    $policySpec = @{
        databaseId = '?Integer'; name = 'String'; target = 'String'; enforcement = 'String'; source = $actorSpec
        conditions = @{
            repositoryId = @{ '$nullable' = $true; repositoryIds = @('String') }
            repositoryName = @{ '$nullable' = $true; include = @('String'); exclude = @('String'); protected = 'Boolean' }
            repositoryProperty = @{
                '$nullable' = $true
                include = @(@{ name = 'String'; propertyValues = @('String'); source = 'String' })
                exclude = @(@{ name = 'String'; propertyValues = @('String'); source = 'String' })
            }
        }
        rules = @{ totalCount = 'Integer'; pageInfo = $pageInfoSpec; nodes = @(@{ type = 'String'; parameters = @{ __typename = 'String'; '$nullable' = $true } }) }
    }

    function Add-Gap ($Record, [string] $Kind, [string] $Field) {
        $Record.Gaps.Add([pscustomobject]@{ Kind = $Kind; Field = $Field })
    }

    # Keep absent keys absent, nulls null, singleton arrays arrays and wrong scalar
    # types intact. Unexpected objects are reduced to a type marker, not serialized.
    function Select-EvidenceField ($Value, $Spec, $Record, [string] $Path) {
        if ($null -eq $Value) {
            if (-not ($Spec -is [hashtable] -and $Spec['$nullable']) -and ($Spec -isnot [string] -or -not $Spec.StartsWith('?'))) { Add-Gap -Record $Record -Kind UnavailableField -Field $Path }
            return $null
        }
        if ($Spec -is [hashtable]) {
            if ($Value -isnot [pscustomobject]) {
                Add-Gap -Record $Record -Kind UnexpectedShape -Field $Path
                if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
                return [pscustomobject]@{ DiagnosticType = $Value.GetType().Name }
            }
            $selected = [ordered]@{}
            foreach ($key in ($Spec.Keys | Where-Object { $_ -ne '$nullable' } | Sort-Object)) {
                if ($Value.PSObject.Properties.Name -contains $key) {
                    $selected[$key] = Select-EvidenceField -Value $Value.$key -Spec $Spec[$key] -Record $Record -Path "$Path.$key"
                    if ($key -eq 'endCursor' -and $selected[$key] -is [string]) { $selected[$key] = '[present]' }
                } elseif ($Spec[$key] -isnot [string] -or -not $Spec[$key].StartsWith('?')) {
                    Add-Gap -Record $Record -Kind UnavailableField -Field "$Path.$key"
                }
            }
            return [pscustomobject]$selected
        }
        if ($Spec -is [array]) {
            if ($Value -isnot [array]) {
                Add-Gap -Record $Record -Kind UnexpectedShape -Field $Path
                if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
                return [pscustomobject]@{ DiagnosticType = $Value.GetType().Name }
            }
            $selected = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Value) { $selected.Add((Select-EvidenceField -Value $item -Spec $Spec[0] -Record $Record -Path "$Path[]")) }
            return ,$selected.ToArray()
        }
        $type = $Spec.TrimStart('?')
        $valid = switch ($type) {
            String { $Value -is [string] }
            Boolean { $Value -is [bool] }
            Integer { $Value -is [int] -or $Value -is [long] -or $Value -is [bigint] }
            Identifier { $Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [bigint] }
        }
        if (-not $valid) {
            Add-Gap -Record $Record -Kind UnexpectedShape -Field $Path
            if ($Value -isnot [string] -and $Value -isnot [ValueType]) { return [pscustomobject]@{ DiagnosticType = $Value.GetType().Name } }
        }
        return $Value
    }

    function Get-OperationRecord ([string] $Name, [string] $Api) {
        $record = [pscustomobject]@{
            Name = $Name; Api = $Api; Outcome = 'Unavailable'; StartedUtc = [DateTimeOffset]::UtcNow
            CompletedUtc = $null; HttpStatus = $null; ContentKind = $null; RateLimit = $null; PageCount = 0; PaginationComplete = $null
            ItemCount = 0; Gaps = [System.Collections.Generic.List[object]]::new(); Data = $null
        }
        $operations.Add($record)
        return $record
    }

    function Get-RequestFailure ($Record, $Failure) {
        $Record.HttpStatus = Get-MtGitHubErrorStatusCode -ErrorRecord $Failure
        $kind = if ($Failure.Exception.Data['GitHubRateLimit']) { 'RateLimited' }
        elseif ($Record.HttpStatus -in 401, 403) { 'DeniedAccess' }
        elseif ($Record.HttpStatus -eq 404) { 'NotFoundOrNotVisible' }
        else { 'RequestOrParsingFailure' }
        Add-Gap -Record $Record -Kind $kind -Field '$'
        $limit = $Failure.Exception.Data['GitHubRateLimit']
        if ($limit) {
            # The shared guard reuses an observation when it blocks a later request.
            # Its status is not proof this operation reached the HTTP boundary.
            $Record.HttpStatus = $null
            $Record.RateLimit = [pscustomobject]@{
                Kind = $limit.Kind; Scope = $limit.Scope; SourceHttpStatus = $limit.HttpStatus; RetryAfterSeconds = $limit.RetryAfterSeconds
                ResetUtc = $limit.ResetUtc; ResumeUtc = $limit.ResumeUtc
            }
        }
        # No exception messages, bodies, request URIs, cursors or headers enter reports.
        $Record.CompletedUtc = [DateTimeOffset]::UtcNow
    }

    function Read-RestEvidence ([string] $Name, [string] $Path, $Spec, [switch] $Paginate) {
        $record = Get-OperationRecord -Name $Name -Api REST
        try {
            $arguments = @{ RelativeUri = $Path; ApiVersion = '2026-03-10'; IncludeMetadata = $true; DisableCache = $true }
            if ($Paginate) { $arguments.Paginate = $true; $arguments.MaxPages = $pageLimit }
            $result = Invoke-MtGitHubRequest @arguments
            $record.PageCount = $result.PageCount
            $record.ContentKind = $result.ContentKind
            if (($Spec -is [array] -and $result.ContentKind -ne 'Array') -or ($Spec -is [hashtable] -and $result.ContentKind -ne 'Object')) {
                Add-Gap -Record $record -Kind UnexpectedShape -Field '$'
            }
            $record.StartedUtc = $result.StartedUtc
            $record.CompletedUtc = $result.CompletedUtc
            if ($Paginate) { $record.PaginationComplete = $result.PaginationComplete }
            $record.Data = Select-EvidenceField -Value $result.Data -Spec $Spec -Record $record -Path '$'
            if (-not $result.CollectionIntegrityValid) { Add-Gap -Record $record -Kind CollectionIntegrity -Field '$' }
            if ($result.AccessLimited) { Add-Gap -Record $record -Kind AccessLimited -Field '$' }
            if ($Paginate -and -not $result.PaginationComplete) { Add-Gap -Record $record -Kind PageCap -Field '$' }
            $record.HttpStatus = 200
            $record.ItemCount = if ($result.Data -is [array]) { $result.Data.Count } else { 1 }
            $record.Outcome = if ($record.Gaps.Count) { 'Incomplete' } else { 'Observed' }
        } catch {
            Get-RequestFailure -Record $record -Failure $_
            $partial = $_.Exception.Data['GitHubPartialResponse']
            if ($partial) {
                $record.Data = Select-EvidenceField -Value $partial.Data -Spec $Spec -Record $record -Path '$'
                $record.PageCount = $partial.PageCount
                $record.ItemCount = @($partial.Data).Count
                $record.PaginationComplete = $false
                $record.StartedUtc = $partial.StartedUtc
                $record.Outcome = 'Incomplete'
            }
        }
        return $record
    }

    function Read-GraphEvidence ([string] $Name, [string] $Query, [hashtable] $Variables, [string] $Field, $Spec, [string] $Items) {
        $record = Get-OperationRecord -Name $Name -Api GraphQL
        $all = [System.Collections.Generic.List[object]]::new()
        $cursors = [System.Collections.Generic.HashSet[string]]::new()
        try {
            do {
                $result = Invoke-MtGitHubGraphQLRequest -Query $Query -Variables $Variables -OperationName $Name -DisableCache
                $record.PageCount++
                $record.CompletedUtc = $result.CompletedUtc
                foreach ($code in $result.Errors) { Add-Gap -Record $record -Kind $code -Field '$' }
                $data = if ($Field -eq 'issue') { $result.Data } else { $result.Data.repository.$Field }
                $selected = Select-EvidenceField -Value $data -Spec $Spec -Record $record -Path '$'
                if (-not $Items) { $record.Data = $selected; break }
                # Retain each page's totalCount and pageInfo fields without retaining cursor values.
                $all.Add($selected)
                $record.Data = $all.ToArray()
                if ($data.$Items -isnot [array] -or $data.pageInfo.hasNextPage -isnot [bool]) { break }
                $record.ItemCount += $data.$Items.Count
                $record.PaginationComplete = -not $data.pageInfo.hasNextPage
                if ($result.Errors.Count -or $record.PaginationComplete) { break }
                if ($record.PageCount -ge $pageLimit) { Add-Gap -Record $record -Kind PageCap -Field '$'; break }
                $cursor = $data.pageInfo.endCursor
                if ($cursor -isnot [string] -or -not $cursor -or -not $cursors.Add($cursor)) { Add-Gap -Record $record -Kind InvalidCursor -Field '$'; break }
                $Variables.after = $cursor
            } while ($true)
            if ($Items -and -not $record.PaginationComplete) { Add-Gap -Record $record -Kind IncompletePagination -Field '$' }
            if ($Items -and $record.PaginationComplete -and $data.totalCount -ne $record.ItemCount) { Add-Gap -Record $record -Kind CountMismatch -Field '$' }
            $record.Outcome = if ($null -eq $data) { 'Unavailable' } elseif ($record.Gaps.Count) { 'Incomplete' } else { 'Observed' }
        } catch {
            Get-RequestFailure -Record $record -Failure $_
            if ($record.PageCount) { $record.Outcome = 'Incomplete'; $record.PaginationComplete = $false }
        }
        return $record
    }

    $null = Read-RestEvidence -Name OrganizationSettings -Path "/orgs/$org" -Spec @{
        members_can_delete_repositories = 'Boolean'; members_can_delete_issues = 'Boolean'
    }
    $null = Read-RestEvidence -Name OrganizationOwners -Path "/orgs/$org/members?role=admin" -Spec @(@{ login = 'String'; id = 'Integer' }) -Paginate
    $null = Read-RestEvidence -Name RepositoryCollaborators -Path "/repos/$org/$repo/collaborators?affiliation=all" -Spec @(@{
        login = 'String'; id = 'Integer'; role_name = 'String'
        permissions = @{ admin = 'Boolean'; maintain = 'Boolean'; push = 'Boolean'; triage = 'Boolean'; pull = 'Boolean' }
    }) -Paginate
    $roles = Read-RestEvidence -Name CustomRepositoryRoles -Path "/orgs/$org/custom-repository-roles" -Spec @{ total_count = 'Integer'; custom_roles = @($repoRoleSpec) }
    $orgRoles = Read-RestEvidence -Name OrganizationRoles -Path "/orgs/$org/organization-roles" -Spec @{ total_count = 'Integer'; roles = @($roleSpec + @{ base_role = '?String'; source = '?String' }) }
    foreach ($entry in @(@{ Record = $roles; Key = 'custom_roles' }, @{ Record = $orgRoles; Key = 'roles' })) {
        $record = $entry.Record
        if ($record.Data -is [pscustomobject]) {
            $values = $record.Data.($entry.Key)
            if ($values -is [array]) {
                $record.ItemCount = $values.Count
                if ($record.Data.total_count -ne $values.Count) { Add-Gap -Record $record -Kind CountMismatch -Field '$'; $record.Outcome = 'Incomplete' }
                foreach ($role in $values) {
                    if ($role -is [pscustomobject] -and $role.permissions -is [array]) {
                        $role | Add-Member -NotePropertyName IssueDeletionPermissionMatches -NotePropertyValue @($role.permissions | Where-Object { $_ -is [string] -and $_ -match '(?i)issue.*delet|delet.*issue' })
                    }
                }
            }
        }
    }
    $collaboratorQuery = @'
query CollaboratorSources($org:String!,$repo:String!,$after:String){
  repository(owner:$org,name:$repo){collaborators(first:100,after:$after,affiliation:ALL){
    totalCount pageInfo{hasNextPage endCursor}
    edges{node{login} permission permissionSources{permission roleName source{
      __typename ... on Organization{login} ... on Team{slug} ... on Repository{nameWithOwner}
    }}}
  }}
}
'@
    $null = Read-GraphEvidence -Name CollaboratorSources -Query $collaboratorQuery -Variables @{ org = $organization; repo = $Repository; after = $null } -Field collaborators -Spec @{
        totalCount = 'Integer'; pageInfo = $pageInfoSpec; edges = @($collaboratorSpec)
    } -Items edges

    # Keep bypass separate: an inaccessible field must not discard core policy evidence.
    $policyQuery = @'
query RepositoryPolicies($org:String!,$repo:String!,$after:String){
  repository(owner:$org,name:$repo){rulesets(first:100,after:$after,includeParents:true,targets:[REPOSITORY]){
    totalCount pageInfo{hasNextPage endCursor} nodes{
      databaseId name target enforcement source{__typename ... on Organization{login} ... on Enterprise{slug} ... on Repository{nameWithOwner}}
      conditions{repositoryId{repositoryIds} repositoryName{include exclude protected}
        repositoryProperty{include{name propertyValues source} exclude{name propertyValues source}}}
      rules(first:100){totalCount pageInfo{hasNextPage endCursor} nodes{type parameters{__typename}}}
    }
  }}
}
'@
    # Conditions are alternatives; null alternatives are expected, not missing evidence.
    $policies = Read-GraphEvidence -Name RepositoryPolicies -Query $policyQuery -Variables @{ org = $organization; repo = $Repository; after = $null } -Field rulesets -Spec @{
        totalCount = 'Integer'; pageInfo = $pageInfoSpec; nodes = @($policySpec)
    } -Items nodes
    $bypassQuery = @'
query PolicyBypass($org:String!,$repo:String!,$after:String){
  repository(owner:$org,name:$repo){rulesets(first:100,after:$after,includeParents:true,targets:[REPOSITORY]){
    totalCount pageInfo{hasNextPage endCursor} nodes{databaseId bypassActors(first:100){
      totalCount pageInfo{hasNextPage endCursor} nodes{
        bypassMode organizationAdmin enterpriseOwner enterpriseRole enterpriseRoleDatabaseId deployKey repositoryRoleDatabaseId repositoryRoleName
        actor{__typename ... on Team{slug} ... on User{login} ... on App{slug}}
      }
    }}
  }}
}
'@
    $bypass = Read-GraphEvidence -Name PolicyBypass -Query $bypassQuery -Variables @{ org = $organization; repo = $Repository; after = $null } -Field rulesets -Spec @{
        totalCount = 'Integer'; pageInfo = $pageInfoSpec; nodes = @(@{
            databaseId = '?Integer'; bypassActors = @{ totalCount = 'Integer'; pageInfo = $pageInfoSpec; nodes = @($bypassSpec) }
        })
    } -Items nodes
    foreach ($record in @($policies, $bypass)) {
        foreach ($page in $record.Data) {
            foreach ($policy in $page.nodes) {
                $nested = if ($record.Name -eq 'RepositoryPolicies') { $policy.rules } else { $policy.bypassActors }
                if ($null -eq $nested -or $nested.pageInfo.hasNextPage -ne $false -or $nested.nodes -isnot [array] -or $nested.totalCount -ne $nested.nodes.Count) {
                    Add-Gap -Record $record -Kind NestedCollectionIncomplete -Field '$.nodes'; $record.Outcome = 'Incomplete'
                }
                if ($record.Name -eq 'PolicyBypass' -and @($nested.nodes | Where-Object { $_.actor.__typename -eq 'EnterpriseTeam' }).Count) {
                    Add-Gap -Record $record -Kind UnresolvedEnterpriseTeamIdentity -Field '$.nodes.bypassActors'; $record.Outcome = 'Incomplete'
                }
                if ($record.Name -eq 'RepositoryPolicies' -and @($nested.nodes | Where-Object { $_.type -eq 'AUTHORIZATION' }).Count) {
                    Add-Gap -Record $record -Kind AuthorizationParametersUnavailable -Field '$.nodes.rules'; $record.Outcome = 'Incomplete'
                }
            }
        }
    }
    if ($IssueNumber) {
        $issueQuery = @'
query IssueCapability($org:String!,$repo:String!,$number:Int!){
  viewer{login} repository(owner:$org,name:$repo){issue(number:$number){viewerCanDelete}}
}
'@
        $null = Read-GraphEvidence -Name IssueCapability -Query $issueQuery -Variables @{ org = $organization; repo = $Repository; number = $IssueNumber } -Field issue -Spec @{
            viewer = @{ login = 'String' }; repository = @{ issue = @{ viewerCanDelete = 'Boolean' } }
        }
    } else {
        $record = Get-OperationRecord -Name IssueCapability -Api GraphQL
        $record.Outcome = 'Not requested'; $record.CompletedUtc = [DateTimeOffset]::UtcNow
    }
    return ,$operations.ToArray()
}
