# GitHub deletion evidence probe

Read-only research for the deletion checks, on an independent branch based on
`7812f2bed06f8851817dfb81335f8cc2466627af` (#2540). This does not change the CIS
checks or assign Passed, Failed or Investigate. A successful API read is an
observation, not a compliance conclusion. Local fixture validation is separate
from the live EMU qualification you perform at work.

## Checkout and prerequisites

Use a fresh PowerShell 7.4+ session with Git and the source module's dependency,
Microsoft.Graph.Authentication 2.27.0 or later, already installed through your
approved software process. No Graph connection is needed. The runner imports this
checkout's `powershell/Maester.psd1`, not a Gallery copy, and disconnects its GitHub
session afterwards. Do not use a session with other work in progress.

From PowerShell, clone to a new directory:

```powershell
git clone --single-branch --branch research/github-cis-deletion-probe https://github.com/thetechgy/maester.git maester-deletion-probe
Set-Location maester-deletion-probe
git rev-parse HEAD
git status --short
```

Keep the printed commit with your observations. Reports include that commit and a
source-dirty flag. A dirty flag means the commit alone cannot reproduce the source;
use a clean checkout for qualification.

Use an **existing user token** approved for this organization and repository. The
runner passes a SecureString or the existing `MAESTER_GITHUB_TOKEN` / `GH_TOKEN`
environment variable through `Connect-MtGitHub`. Without one it prompts securely.
It deliberately uses token authentication, so it cannot start the connection's
optional app installation/approval or retry flow. Do not paste tokens into command
lines, transcripts, reports or review messages. App installation tokens do not
represent a signed-in user and fail the connection's user-membership probes.

Endpoint access is the intersection of the user's rights, token grants, selected
repositories, SSO authorization, IP restrictions and organization/enterprise
policies. Organization-owner access and repository administration visibility are
useful for a complete manual comparison, but connection success does not establish
that visibility. Use existing access; do not change permissions to qualify this
probe.

| Evidence | Documented access prerequisites |
| --- | --- |
| User and organization connection probes | Active organization membership; organization Members read and Administration read for full bootstrap coverage; classic PAT `admin:org` |
| Organization owners (`members?role=admin`) | Members read; classic `read:org` (included by `admin:org`) |
| Repository collaborators | Repository Metadata read; organization membership and write/maintain/admin repository access; classic `read:org` and `repo` |
| Custom repository roles | Organization Custom repository roles read or repository Administration read; organization or repository administrator; classic `admin:org` or `repo` |
| Organization role definitions | Organization Custom organization roles read; owner or existing view-role access; classic `admin:org` |
| GraphQL collaborators, policies and bypass | User/token access to these fields and selected repository; policy/bypass visibility can be narrower than repository visibility |
| Issue capability | Access to the supplied existing issue as the current user; no issue content is queried |

These are read requirements for collection, not a request to grant new permissions.
Classic `repo` / `admin:org` scopes are broad, and some supported user tokens have
write rights even though this runner only sends GETs and static GraphQL queries.
If organizational policy prohibits such tokens, retain the unavailable evidence
and use an approved existing authentication context. The app's configured grants
may not include all research endpoints. Do not install or reconfigure it for this
probe.

## Run at work

Replace the example values locally; supply just the repository name within the
organization. `AccountModel` and optional `Enterprise` are your declarations,
not API-verified facts. Enterprise is context only and triggers no extra scan.

```powershell
$token = Read-Host 'Existing GitHub user token' -AsSecureString
$evidence = ./build/github/Export-MtGitHubDeletionEvidence.ps1 `
    -Organization 'YOUR-ORG' `
    -Repository 'YOUR-SAMPLE-REPO' `
    -AccountModel EnterpriseManagedUsers `
    -Enterprise 'YOUR-ENTERPRISE' `
    -IssueNumber 123 `
    -MaxPages 5 `
    -Token $token
Remove-Variable token
Get-Content -LiteralPath $evidence.SummaryMarkdown
```

For GHE.com data residency add `-ApiBaseUri 'https://api.YOUR-SUBDOMAIN.ghe.com'`.
The default is `https://api.github.com`. The existing connection host allowlist
rejects GHES and arbitrary API hosts. Omit `IssueNumber` if no suitable existing
issue is available; its operation will be `Not requested`.

The runner reads the organization deletion flags, owners, one repository's full
visible collaborator list and GraphQL permission sources, and organization role
definitions. It highlights permission strings matching issue/deletion in either
order (for example `delete_issue`); those matches are discovery hints, not effective
permission evaluation or a complete permission taxonomy. It does not enumerate
organization-role assignments or everyone in the enterprise.

Top-level REST/GraphQL lists stop after `MaxPages` (default 5, maximum 100) of up to
100 items. Custom-role APIs are documented as single-object lists without page
parameters; their item counts are reconciled with `total_count`. Policy rules and
bypass actors are each limited to the first 100 per policy, with count/page checks;
the runner does not fan out across nested connections. There are no automatic
retries, sleeps, issue deletions, mutations, permission changes or repository scans.
The connection's four bootstrap reads keep its existing REST default; new REST
reads explicitly use `2026-03-10`. GraphQL has no REST API version header.

## Reports and diagnostic outcomes

Each invocation creates a unique directory in ignored
`TestResults/github-deletion-<UTC>-<random>/`:

- `detailed.json`: private, minimal allowlisted evidence including user logins,
  role names/permissions and policy conditions. Keep on the work machine.
- `summary.json`: API-data strings replaced by per-run aliases except fixed public schema/permission/policy values; identifier
  numbers aliased, while booleans, counts, nulls, missing keys and array shapes
  remain diagnostic. No reverse map or identifier hashes are exported. Aliases
  correlate identical strings within that summary only.
- `summary.md`: readable outcomes, timestamps, source identity and limitations.

The detailed report excludes credentials, authorization/HTTP headers, raw errors,
issue titles/bodies, role descriptions and unrelated profile/organization fields.
Cursors are replaced by presence markers after pagination. Unknown complex values
are reduced to type markers rather than exported. Both JSON reports preserve absent
versus explicit-null keys and unexpected scalar types. Reports include operation
outcomes and coverage, not compliance results. On Unix, the output directory is
owner-only; on Windows, keep the checkout in a private user directory with suitable
ACLs. Git ignore is not access control. Even pseudonymized counts, timings, Boolean
settings and grant structure can be sensitive; review summaries before sharing.
Never commit tenant reports, private benchmark inputs or a CIS PDF.

| Outcome | Meaning |
| --- | --- |
| Observed | The selected response fields were usable within the stated visibility and collection limits |
| Unavailable | No usable response was obtained; inspect the gap category and HTTP status |
| Incomplete | Some data was retained, with missing/null fields, unexpected shapes, partial responses, count mismatches, capped traversal or unresolved policy details |
| Not requested | No issue was supplied |

Gap categories distinguish denied access, not-found-or-not-visible, unavailable
fields, unexpected shapes, access-limited collections, GraphQL error codes,
incomplete pagination and rate limits. A rate-limited operation has no attributed `HttpStatus`:
`RateLimit.SourceHttpStatus` belongs to the shared observation and may come from an
earlier request. It does not prove this operation sent a new HTTP request. An empty visible population does not prove
that no other actors or policies exist. HTTP 404 cannot distinguish absent and
inaccessible objects. Failed connections stop before producing a report; consult
the local `Connect-MtGitHub` message without sharing raw diagnostics.

## Manual EMU qualification

Use only existing settings and access. Do not toggle settings, grant roles, submit
bypass requests or attempt deletion.

1. Compare the selected repository's **Settings → Collaborators and teams / Manage
   access → Admin access** view with `RepositoryCollaborators`, `OrganizationOwners`
   and `CollaboratorSources` in the private detail. Compare identities and grant
   sources, including organization owners, direct grants, teams, base permissions,
   custom roles and any additional implicit access visible in the UI. Record any
   discrepancy or unobservable source. Do not treat `permissions.admin`, `role_name`
   or a null `permissionSources` list as the complete issue-deleter population.
2. Compare the existing organization **Member privileges** repository-deletion and
   issue-deletion settings with `OrganizationSettings`. Independently note whether
   enterprise legacy policies restrict the setting; this probe does not collect
   their legacy representation. Compare organization/enterprise **Policies →
   Repository** with `RepositoryPolicies` and `PolicyBypass`: selected-repository
   targeting, enforcement, rule types, bypass roles/actors and delegated bypass.
   Missing policy details remain gaps even when a policy's name is visible.
3. For the supplied existing issue, compare the current user's existing UI delete
   capability with `IssueCapability` and its `viewer.login`. Observe the menu only;
   do not click delete or confirm anything. `viewerCanDelete` describes **that
   signed-in user on that issue at that time**. It is not a query about other admins
   or all issues, and neither Boolean value establishes the organization's policy.
4. Retain the source commit, UTC window, declared account model, UI observations and
   any gaps locally. Read `summary.md` and `summary.json` before sharing them for API
   qualification. UI and API observations taken at different times may differ.

Stronger-policy equivalence, whether owners/admins are trusted or qualified, and
what “few” means are unresolved assessment questions. The probe draws no conclusion
about them and supplies no numeric thresholds.

## Policy API limitations and reference contract

The [current GraphQL repository reference](https://docs.github.com/en/graphql/reference/repos)
documents `Repository.rulesets(includeParents:true, targets:[REPOSITORY])`. It is
scoped to applicable representations for this repository, including higher-level
rulesets. These are repository lifecycle policies, not branch-ref deletion rules.
The current [REST rules reference](https://docs.github.com/en/rest/repos/rules?apiVersion=2026-03-10)
does not document the repository target in its target enum, so the probe uses the
GraphQL representation and does not guess an undocumented REST policy endpoint.

The public GraphQL rule parameter union does not document an authorization parameter
fragment. The runner requests available parameter `__typename` only and marks
`AUTHORIZATION` rules `AuthorizationParametersUnavailable`; it cannot prove which
lifecycle action an authorization rule restricts. Null conditions that are valid
alternatives are retained as null. Bypass is a separate operation so denied bypass
reads do not discard usable core policy data. A missing or null bypass list is not
an empty allowlist. The selected fields include enterprise-role, enterprise-owner, organization-admin,
repository-role and deploy-key indicators. An EnterpriseTeam actor is retained by
type only and marked `UnresolvedEnterpriseTeamIdentity`. The selected fields do not
completely describe delegated bypass reviewers or pending approvals. Those remain manual evidence gaps.

Additional endpoint and semantics references, checked during implementation:

- [Organization settings](https://docs.github.com/en/rest/orgs/orgs?apiVersion=2026-03-10#get-an-organization)
- [Organization members](https://docs.github.com/en/rest/orgs/members?apiVersion=2026-03-10#list-organization-members)
- [Collaborators](https://docs.github.com/en/rest/collaborators/collaborators?apiVersion=2026-03-10#list-repository-collaborators)
- [Custom repository roles](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/custom-roles?apiVersion=2026-03-10)
- [Organization roles](https://docs.github.com/en/rest/orgs/organization-roles?apiVersion=2026-03-10)
- [GraphQL collaborator edges](https://docs.github.com/en/graphql/reference/users#repositorycollaboratoredge)
- [GraphQL issue capability](https://docs.github.com/en/graphql/reference/issues#issue)
- [Repository policies, targeting and additive behavior](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/governing-how-people-use-repositories-in-your-organization)

## Troubleshooting and local fixture validation

For denied/missing fields, check the existing token's selected repositories, SSO/IP
restrictions and account role with your administrator; do not expand grants during
this probe. A schema error or unexpected shape is an API qualification gap, not a
negative setting. Check the current public schema before any follow-up edit.

On a rate limit, keep the partial report and wait until GitHub permits access again
before another explicit run. The shared connection guard stops affected requests
and does not retry. Do not reconnect repeatedly to bypass a cooldown. A capped
result remains incomplete; a later explicit larger cap is a different collection
window and can still be visibility-limited.

From a development checkout with the repository's test dependencies already
installed (Pester 5.7.1, PSModuleDevelopment, PSScriptAnalyzer):

```powershell
./powershell/tests/pester.ps1 -Include 'Export-MtGitHubDeletionEvidence*','Invoke-MtGitHubRequest*','Invoke-MtGitHubGraphQLRequest*','GitHubRateLimit*','RepositoryLayout*' -Output Normal
./powershell/tests/pester.ps1 -Output Normal
./build/Build-MaesterModule.ps1
./build/Test-MaesterModuleOutput.ps1
```

The synthetic fixture calls the actual runner, connection bootstrap and shared
transports with HTTP mocked. It checks mixed grants, roles, pagination/caps,
nullable/missing fields, partial/denied responses, rate-limit propagation, host
routing, read-only requests and emitted report sanitization. It does not qualify
live GitHub.com/GHE.com/EMU behavior, the work tenant's access, or policy equivalence.
