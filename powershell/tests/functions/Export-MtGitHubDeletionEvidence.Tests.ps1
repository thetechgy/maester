[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Synthetic HTTP fixtures invoked across runner and module script scopes share one state object, removed in AfterAll.')]
param()

BeforeAll {
    Import-Module "$PSScriptRoot/../../Maester.psd1" -Force
    $script:probeRoot = [IO.Path]::GetFullPath("$PSScriptRoot/../../..")
    $script:probeRunner = Join-Path $script:probeRoot 'build/github/Export-MtGitHubDeletionEvidence.ps1'
    function Invoke-ProbeFixture {
        param([string] $ApiBaseUri = 'https://api.github.com', [int] $MaxPages = 2, [switch] $NoIssue)
        $token = [securestring]::new()
        foreach ($character in 'fixture-credential-never-export'.ToCharArray()) { $token.AppendChar($character) }
        $arguments = @{ Organization = 'fixture-org'; Repository = 'fixture-repo'; Token = $token; AccountModel = 'EnterpriseManagedUsers'; Enterprise = 'fixture-enterprise'; ApiBaseUri = $ApiBaseUri; MaxPages = $MaxPages }
        if (-not $NoIssue) { $arguments.IssueNumber = 987 }
        $paths = & $script:probeRunner @arguments
        [pscustomobject]@{
            Paths = $paths
            Detailed = Get-Content -LiteralPath $paths.DetailedReport -Raw | ConvertFrom-Json
            Summary = Get-Content -LiteralPath $paths.SummaryJson -Raw | ConvertFrom-Json
        }
    }
    function Get-Operation ($Report, $Name) { $Report.Operations | Where-Object Name -eq $Name }
}

Describe 'Deletion evidence runner through real GitHub transports' {
    BeforeEach {
        $global:MtDeletionProbeFixtureState = @{ Mode = 'normal'; Requests = [System.Collections.Generic.List[object]]::new() }
        InModuleScope Maester {
            $__MtSession.GitHubRateLimits = $null
            $__MtSession.MaesterConfig = [pscustomobject]@{ GlobalSettings = [pscustomobject]@{} }
        }
        # The runner imports the same source module already loaded for HTTP mocks.
        # Only avoid reloading that instance; connection, parsing, transports and export are real.
        Mock Import-Module -ParameterFilter { $Name -like '*Maester.psd1' } {}
        Mock Invoke-WebRequest -ModuleName Maester {
            $uriValue = [uri]$Uri
            $path = $uriValue.AbsolutePath
            $operation = if ($Body) { ($Body | ConvertFrom-Json).operationName } else { '' }
            $global:MtDeletionProbeFixtureState.Requests.Add([pscustomobject]@{ Uri = $uriValue; Method = [string]$Method; Version = $Headers['X-GitHub-Api-Version']; Operation = $operation; Body = $Body })
            $headersOut = @{}
            $data = switch ($path) {
                '/user' { @{ login = 'fixture-user'; email = 'never-export@example.invalid' }; break }
                '/orgs/fixture-org' {
                    if ($Headers['X-GitHub-Api-Version'] -eq '2026-03-10' -and $global:MtDeletionProbeFixtureState.Mode -eq 'shapes') { @{ members_can_delete_repositories = $null; members_can_delete_issues = 'false' }; break }
                    if ($Headers['X-GitHub-Api-Version'] -eq '2026-03-10' -and $global:MtDeletionProbeFixtureState.Mode -eq 'primary') { $headersOut['x-ratelimit-remaining'] = '0' }
                    @{ login = 'fixture-org'; plan = @{ name = 'enterprise' }; members_can_delete_repositories = $false; members_can_delete_issues = $true; billing_email = 'never-export@example.invalid' }; break
                }
                '/user/memberships/orgs/fixture-org' { @{ state = 'active'; role = 'admin' }; break }
                '/orgs/fixture-org/actions/permissions' { @{ enabled_repositories = 'all' }; break }
                '/orgs/fixture-org/members' {
                    if ($global:MtDeletionProbeFixtureState.Mode -eq 'rate') {
                        $ex = [Exception]::new('private raw rate error')
                        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
                        $null = $response.Headers.TryAddWithoutValidation('Retry-After', '120')
                        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response
                        throw $ex
                    }
                    if ($global:MtDeletionProbeFixtureState.Mode -eq 'owner-shape') { @{ unexpected = 'private arbitrary shape' }; break }
                    if ($uriValue.Query -notmatch 'page=2') {
                        $headersOut.Link = "<$($uriValue.GetLeftPart([UriPartial]::Authority))/orgs/fixture-org/members?role=admin&per_page=100&page=2>; rel=`"next`""
                        ,@(@{ login = 'fixture-owner-a'; id = 81234 }); break
                    }
                    if ($global:MtDeletionProbeFixtureState.Mode -eq 'page-denied') {
                        $ex = [Exception]::new('private page failure')
                        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden))
                        throw $ex
                    }
                    ,@(@{ login = 'fixture-owner-b'; id = 81235 }); break
                }
                '/repos/fixture-org/fixture-repo/collaborators' {
                    ,@(@{ login = 'fixture-user'; id = 81236; role_name = 'admin'; permissions = @{ admin = $true; maintain = $true; push = $true; triage = $true; pull = $true }; email = 'never-export@example.invalid' }, @{ login = 'fixture-writer'; id = 81237; role_name = 'fixture-custom-role'; permissions = @{ admin = $false; maintain = $false; push = $true; triage = $true; pull = $true } }); break
                }
                '/orgs/fixture-org/custom-repository-roles' {
                    @{ total_count = 1; custom_roles = @(@{ id = 81238; name = 'fixture-custom-role'; base_role = 'write'; permissions = @('delete_issue', 'read_code'); description = 'private role content' }) }; break
                }
                '/orgs/fixture-org/organization-roles' {
                    if ($global:MtDeletionProbeFixtureState.Mode -eq 'denied') {
                        $ex = [Exception]::new('private raw forbidden detail')
                        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden))
                        throw $ex
                    }
                    @{ total_count = 1; roles = @(@{ id = 81239; name = 'fixture-org-role'; permissions = @('read_organization_custom_repo_role') }) }; break
                }
                '/graphql' {
                    $variables = ($Body | ConvertFrom-Json).variables
                    $pageInfo = @{ hasNextPage = $false; endCursor = $null }
                    switch ($operation) {
                        CollaboratorSources {
                            $sources = @(@{ permission = 'ADMIN'; roleName = 'admin'; source = @{ __typename = 'Organization'; login = 'fixture-org' } }, @{ permission = 'WRITE'; roleName = 'write'; source = @{ __typename = 'Team'; slug = 'fixture-team' } })
                            if ($global:MtDeletionProbeFixtureState.Mode -eq 'null-sources') { $sources = $null }
                            if ($global:MtDeletionProbeFixtureState.Mode -eq 'graphql-pages' -and -not $variables.after) { $pageInfo = @{ hasNextPage = $true; endCursor = 'private-cursor' } }
                            $count = if ($global:MtDeletionProbeFixtureState.Mode -eq 'graphql-pages') { 2 } else { 1 }
                            $result = @{ data = @{ repository = @{ collaborators = @{ totalCount = $count; pageInfo = $pageInfo; edges = @(@{ node = @{ login = 'fixture-user' }; permission = 'ADMIN'; permissionSources = $sources }) } } } }
                            if ($global:MtDeletionProbeFixtureState.Mode -eq 'partial') { $result.errors = @(@{ type = 'FORBIDDEN'; message = 'private raw GraphQL detail' }) }
                            $result; break
                        }
                        RepositoryPolicies {
                            $rulePage = @{ hasNextPage = ($global:MtDeletionProbeFixtureState.Mode -eq 'nested-cap'); endCursor = $null }
                            @{ data = @{ repository = @{ rulesets = @{ totalCount = 1; pageInfo = $pageInfo; nodes = @(@{
                                databaseId = 81240; name = 'fixture-policy'; target = 'REPOSITORY'; enforcement = 'ACTIVE'; source = @{ __typename = 'Organization'; login = 'fixture-org' }
                                conditions = @{ repositoryId = $null; repositoryName = @{ include = @('fixture-repo'); exclude = @(); protected = $true }; repositoryProperty = $null }
                                rules = @{ totalCount = 1; pageInfo = $rulePage; nodes = @(@{ type = 'AUTHORIZATION'; parameters = $null }) }
                            }) } } } }; break
                        }
                        PolicyBypass {
                            $policy = @{ databaseId = 81240; bypassActors = @{ totalCount = 1; pageInfo = $pageInfo; nodes = @(@{ bypassMode = 'ALWAYS'; organizationAdmin = $true; enterpriseOwner = $false; enterpriseRole = $false; enterpriseRoleDatabaseId = $null; deployKey = $false; repositoryRoleDatabaseId = $null; repositoryRoleName = $null; actor = $null }) } }
                            if ($global:MtDeletionProbeFixtureState.Mode -eq 'missing-bypass') { $policy.Remove('bypassActors') }
                            @{ data = @{ repository = @{ rulesets = @{ totalCount = 1; pageInfo = $pageInfo; nodes = @($policy) } } } }; break
                        }
                        IssueCapability { @{ data = @{ viewer = @{ login = 'fixture-user' }; repository = @{ issue = @{ viewerCanDelete = $false; title = 'private issue title'; body = 'private issue body' } } } }; break }
                        default { throw "Unexpected fixture operation: $operation" }
                    }
                    break
                }
                default { throw "Unexpected fixture route: $path" }
            }
            [pscustomobject]@{ Content = ConvertTo-Json -InputObject $data -Depth 30 -Compress; Headers = $headersOut }
        }
    }

    It 'collects selected evidence, preserves mixed grants and custom issue permissions, and sanitizes actual files' {
        $run = Invoke-ProbeFixture
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).ItemCount | Should -Be 2
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).PaginationComplete | Should -BeTrue
        (Get-Operation -Report $run.Detailed -Name RepositoryCollaborators).Data[0].permissions.admin | Should -BeTrue
        $sources = (Get-Operation -Report $run.Detailed -Name CollaboratorSources).Data[0].edges[0].permissionSources
        $sources.permission | Should -Be @('ADMIN', 'WRITE')
        (Get-Operation -Report $run.Detailed -Name CustomRepositoryRoles).Data.custom_roles[0].IssueDeletionPermissionMatches | Should -Be @('delete_issue')
        (Get-Operation -Report $run.Detailed -Name PolicyBypass).Outcome | Should -Be Observed
        (Get-Operation -Report $run.Detailed -Name PolicyBypass).Data[0].nodes[0].bypassActors.nodes[0].enterpriseRole | Should -BeFalse
        (Get-Operation -Report $run.Summary -Name PolicyBypass).Data[0].nodes[0].bypassActors.nodes[0].deployKey | Should -BeFalse
        (Get-Operation -Report $run.Detailed -Name RepositoryPolicies).Gaps.Kind | Should -Contain AuthorizationParametersUnavailable
        (Get-Operation -Report $run.Detailed -Name IssueCapability).Data.repository.issue.viewerCanDelete | Should -BeFalse
        $run.Detailed.Context.AccountModel | Should -Be EnterpriseManagedUsers
        $run.Detailed.SourceCommit | Should -Match '^[0-9a-f]{40}$'
        foreach ($path in @($run.Paths.DetailedReport, $run.Paths.SummaryJson, $run.Paths.SummaryMarkdown)) {
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Not -Match 'fixture-credential|Bearer|private issue|private role|never-export|"Authorization"\s*:'
            $content | Should -Not -Match 'CIS.*(Passed|Failed|Investigate)'
        }
        $summary = Get-Content -LiteralPath $run.Paths.SummaryJson -Raw
        $summary | Should -Not -Match 'fixture-org|fixture-user|fixture-owner|fixture-repo|fixture-enterprise|fixture-policy|8123[4-9]|81240'
        (Get-Operation -Report $run.Summary -Name RepositoryCollaborators).Data[0].permissions.admin | Should -BeOfType ([bool])
        (Get-Operation -Report $run.Summary -Name CollaboratorSources).Data[0].edges[0].permissionSources | Should -HaveCount 2
        (Get-Operation -Report $run.Summary -Name CollaboratorSources).Data[0].edges[0].permissionSources[0].source.__typename | Should -Be Organization
    }

    It 'pins new GETs, preserves bootstrap defaults, and only posts static read queries on <ApiHost>' -ForEach @(
        @{ ApiHost = 'https://api.github.com' }, @{ ApiHost = 'https://api.example.ghe.com' }
    ) {
        $null = Invoke-ProbeFixture -ApiBaseUri $ApiHost
        $global:MtDeletionProbeFixtureState.Requests | Should -Not -BeNullOrEmpty
        foreach ($request in $global:MtDeletionProbeFixtureState.Requests) {
            $request.Uri.Host | Should -Be ([uri]$ApiHost).Host
            $request.Method | Should -BeIn @('GET', 'POST')
            if ($request.Method -eq 'POST') {
                $request.Uri.AbsolutePath | Should -Be '/graphql'
                ($request.Body | ConvertFrom-Json).query | Should -Match '^query '
                ($request.Body | ConvertFrom-Json).query | Should -Not -Match '\bmutation\b|\bbody\b|\btitle\b'
                $request.Version | Should -BeNullOrEmpty
            }
        }
        @($global:MtDeletionProbeFixtureState.Requests | Where-Object { $_.Method -eq 'GET' -and $_.Version -eq '2022-11-28' }) | Should -HaveCount 4
        @($global:MtDeletionProbeFixtureState.Requests | Where-Object { $_.Method -eq 'GET' -and $_.Version -eq '2026-03-10' }) | Should -HaveCount 6
    }

    It 'marks capped REST and GraphQL results incomplete without extra HTTP calls' {
        $global:MtDeletionProbeFixtureState.Mode = 'graphql-pages'
        $run = Invoke-ProbeFixture -MaxPages 1
        foreach ($name in 'OrganizationOwners', 'CollaboratorSources') {
            $op = Get-Operation -Report $run.Detailed -Name $name
            $op.PageCount | Should -Be 1
            $op.Outcome | Should -Be Incomplete
            $op.PaginationComplete | Should -BeFalse
            $op.Gaps.Kind | Should -Contain PageCap
        }
        @($global:MtDeletionProbeFixtureState.Requests | Where-Object Operation -eq CollaboratorSources) | Should -HaveCount 1
    }

    It 'follows GraphQL cursors and removes cursor values from retained evidence' {
        $global:MtDeletionProbeFixtureState.Mode = 'graphql-pages'
        $run = Invoke-ProbeFixture
        $op = Get-Operation -Report $run.Detailed -Name CollaboratorSources
        $op.PageCount | Should -Be 2
        $op.ItemCount | Should -Be 2
        $op.Outcome | Should -Be Observed
        $op.Data | ConvertTo-Json -Depth 20 | Should -Not -Match 'private-cursor'
        ($global:MtDeletionProbeFixtureState.Requests | Where-Object Operation -eq CollaboratorSources)[1].Body | Should -Match 'private-cursor'
    }

    It 'keeps null, missing and wrong-type evidence distinct in detailed and summary files' {
        $global:MtDeletionProbeFixtureState.Mode = 'shapes'
        $run = Invoke-ProbeFixture
        foreach ($report in @($run.Detailed, $run.Summary)) {
            $op = Get-Operation -Report $report -Name OrganizationSettings
            $op.Outcome | Should -Be Incomplete
            $op.Data.PSObject.Properties.Name | Should -Contain members_can_delete_repositories
            $op.Data.members_can_delete_repositories | Should -BeNullOrEmpty
            $op.Data.members_can_delete_issues | Should -BeOfType ([string])
            $op.Gaps.Kind | Should -Contain UnavailableField
            $op.Gaps.Kind | Should -Contain UnexpectedShape
        }
    }

    It 'retains useful partial evidence and labels <Mode> explicitly' -ForEach @(
        @{ Mode = 'null-sources'; Operation = 'CollaboratorSources'; Gap = 'UnavailableField' },
        @{ Mode = 'missing-bypass'; Operation = 'PolicyBypass'; Gap = 'UnavailableField' },
        @{ Mode = 'partial'; Operation = 'CollaboratorSources'; Gap = 'FORBIDDEN' },
        @{ Mode = 'nested-cap'; Operation = 'RepositoryPolicies'; Gap = 'NestedCollectionIncomplete' },
        @{ Mode = 'page-denied'; Operation = 'OrganizationOwners'; Gap = 'DeniedAccess' }
    ) {
        $global:MtDeletionProbeFixtureState.Mode = $Mode
        $run = Invoke-ProbeFixture
        $op = Get-Operation -Report $run.Detailed -Name $Operation
        $op.Outcome | Should -Be Incomplete
        $op.Gaps.Kind | Should -Contain $Gap
        $op.Data | Should -Not -BeNullOrEmpty
        if ($Mode -eq 'missing-bypass') {
            (Get-Operation -Report $run.Summary -Name PolicyBypass).Data[0].nodes[0].PSObject.Properties.Name | Should -Not -Contain bypassActors
        }
    }

    It 'reports denied access separately without exporting raw errors or guessing an empty population' {
        $global:MtDeletionProbeFixtureState.Mode = 'denied'
        $run = Invoke-ProbeFixture
        $op = Get-Operation -Report $run.Detailed -Name OrganizationRoles
        $op.Outcome | Should -Be Unavailable
        $op.HttpStatus | Should -Be 403
        $op.Data | Should -BeNullOrEmpty
        $op.Gaps.Kind | Should -Contain DeniedAccess
        Get-Content -LiteralPath $run.Paths.DetailedReport -Raw | Should -Not -Match 'private raw'
    }

    It 'honors the shared secondary rate limit without retries or subsequent outbound reads' {
        $global:MtDeletionProbeFixtureState.Mode = 'rate'
        $run = Invoke-ProbeFixture
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).Gaps.Kind | Should -Contain RateLimited
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).HttpStatus | Should -BeNullOrEmpty
        $global:MtDeletionProbeFixtureState.Requests | Should -HaveCount 6
        @($run.Detailed.Operations | Where-Object { $_.Gaps.Kind -contains 'RateLimited' }) | Should -HaveCount 8
    }


    It 'preserves the shape of malformed collection responses' {
        $global:MtDeletionProbeFixtureState.Mode = 'owner-shape'
        $run = Invoke-ProbeFixture
        foreach ($report in @($run.Detailed, $run.Summary)) {
            $op = Get-Operation -Report $report -Name OrganizationOwners
            $op.Outcome | Should -Be Incomplete
            $op.ContentKind | Should -Be Object
            $op.Gaps.Kind | Should -Contain UnexpectedShape
        }
    }

    It 'retains an exhausted successful response and blocks later REST reads without suppressing GraphQL' {
        $global:MtDeletionProbeFixtureState.Mode = 'primary'
        $run = Invoke-ProbeFixture
        (Get-Operation -Report $run.Detailed -Name OrganizationSettings).Outcome | Should -Be Observed
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).Gaps.Kind | Should -Contain RateLimited
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).HttpStatus | Should -BeNullOrEmpty
        (Get-Operation -Report $run.Detailed -Name IssueCapability).Outcome | Should -Be Observed
        (Get-Operation -Report $run.Detailed -Name OrganizationOwners).RateLimit.SourceHttpStatus | Should -Be 200
        @($global:MtDeletionProbeFixtureState.Requests | Where-Object Method -eq GET) | Should -HaveCount 5
    }

    It 'does not cache capped metadata or change default unbounded pagination' {
        InModuleScope Maester {
            $__MtSession.GitHubConnection = [pscustomobject]@{ Connected = $true; ApiBaseUri = 'https://api.github.com'; ApiVersion = '2022-11-28' }
            $__MtSession.GitHubAuthHeader = @{ Authorization = 'Bearer synthetic'; 'X-GitHub-Api-Version' = '2022-11-28' }
            $__MtSession.GitHubCache = @{}
            $bounded = Invoke-MtGitHubRequest -RelativeUri '/orgs/fixture-org/members?role=admin' -IncludeMetadata -Paginate -MaxPages 1
            $bounded.PaginationComplete | Should -BeFalse
            $__MtSession.GitHubCache.Count | Should -Be 0
            $unbounded = Invoke-MtGitHubRequest -RelativeUri '/orgs/fixture-org/members?role=admin' -IncludeMetadata -Paginate
            $unbounded.PageCount | Should -Be 2
            $unbounded.PaginationComplete | Should -BeTrue
            $__MtSession.GitHubCache.Count | Should -Be 1
            { Invoke-MtGitHubRequest -RelativeUri '/orgs/fixture-org' -MaxPages 1 } | Should -Throw '*requires*'
            Disconnect-MtGitHub
        }
    }
    It 'does not query an issue unless one was supplied' {
        $run = Invoke-ProbeFixture -NoIssue
        (Get-Operation -Report $run.Detailed -Name IssueCapability).Outcome | Should -Be 'Not requested'
        @($global:MtDeletionProbeFixtureState.Requests | Where-Object Operation -eq IssueCapability) | Should -HaveCount 0
    }
}

AfterAll { Remove-Variable MtDeletionProbeFixtureState -Scope Global -ErrorAction SilentlyContinue }
