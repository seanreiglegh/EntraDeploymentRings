# =============================================================================
#  FakeGraph.ps1
#  Revision: 1.0
#
#  In-memory Microsoft Graph emulator used by the Pester tests. Dot-source it
#  AFTER the main script: the functions below shadow Invoke-MgGraphRequest,
#  Get-MgContext and Disconnect-MgGraph so the script runs end to end with no
#  tenant and no Microsoft.Graph module.
#
#  Emulates only what Invoke-EntraDeploymentRings.ps1 uses:
#    GET  users, groups ($filter displayName eq / startswith), groups/{id},
#         groups/{id}/members, groups/{id}/transitiveMembers (paged)
#    POST groups, $batch (PATCH members@odata.bind, POST members/$ref,
#         DELETE members/{id}/$ref)
#
#  REVISION HISTORY (most recent first)
#  1.0   2026-11-01  First public release.
# =============================================================================

function Reset-FakeGraph {
    param([int] $PageSize = 100)
    $global:Fake = @{
        Users        = [ordered]@{}   # id -> hashtable
        Groups       = [ordered]@{}   # id -> hashtable (+ Members HashSet, Nested list)
        PageSize     = $PageSize
        Pages        = @{}            # token -> remaining items
        ThrottleOnce = [System.Collections.Generic.HashSet[string]]::new()   # batch sub-request URLs to 429 once
        Calls        = [System.Collections.Generic.List[string]]::new()
        Mail         = [System.Collections.Generic.List[object]]::new()
        MailFail     = $null      # set to an HTTP status (e.g. 403) to make sendMail fail
        Deny         = [System.Collections.Generic.List[string]]::new()   # regexes on "METHOD route" (no query) -> 403
        Context      = @{ AuthType = 'AppOnly'; Scopes = @('User.Read.All', 'Group.ReadWrite.All', 'AuditLog.Read.All')
                          ClientId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'
                          AppName = 'EntraDeploymentRings-Test'; Account = $null }
        Network      = @{}        # host -> @{ Error = '...'; Proxy = '...' } makes that host unreachable
        Probes       = [System.Collections.Generic.List[string]]::new()   # hosts probed, in order
    }
    # The script's network probe calls this instead of the network (see Invoke-RingHttpProbe).
    $global:EntraDeploymentRingsNetworkProbe = { param([uri] $Uri) Get-FakeNetworkResult -Uri $Uri }
}

function Get-FakeNetworkResult {
    param([uri] $Uri)
    $global:Fake.Probes.Add($Uri.Host)
    $n = $global:Fake.Network[$Uri.Host]
    if ($n) { return [pscustomobject]@{ Reachable = $false; StatusCode = $null; Milliseconds = 15000; Proxy = $n.Proxy; Error = $n.Error } }
    [pscustomobject]@{ Reachable = $true; StatusCode = 404; Milliseconds = 12; Proxy = $null; Error = $null }
}

function New-FakeGuid {
    param([System.Random] $Rng)
    $b = [byte[]]::new(16); $Rng.NextBytes($b); ([guid]::new($b)).ToString()
}

function Add-FakeUser {
    param(
        [string] $Id, [string] $Upn, [bool] $Enabled = $true, [string] $UserType = 'Member',
        [string] $EmployeeType = 'Employee', [string] $CompanyName = 'Contoso',
        [datetime] $Created = ([datetime]::UtcNow.AddYears(-2)), $LastSuccess = ([datetime]::UtcNow.AddDays(-1)),
        [int] $Licenses = 1
    )
    $global:Fake.Users[$Id] = @{
        id = $Id; userPrincipalName = $Upn; accountEnabled = $Enabled; userType = $UserType
        employeeType = $EmployeeType; companyName = $CompanyName
        createdDateTime = $Created.ToString('o')
        signInActivity = @{ lastSuccessfulSignInDateTime = $(if ($LastSuccess) { ([datetime]$LastSuccess).ToString('o') } else { $null }) }
        assignedLicenses = @(1..$Licenses | Where-Object { $Licenses -gt 0 } | ForEach-Object { @{ skuId = [guid]::NewGuid().ToString() } })
    }
}

function Add-FakeGroup {
    param([string] $DisplayName, [string] $Description = '', [string] $Id = ([guid]::NewGuid().ToString()))
    $global:Fake.Groups[$Id] = @{
        id = $Id; displayName = $DisplayName; description = $Description; mailEnabled = $false
        securityEnabled = $true; groupTypes = @(); onPremisesSyncEnabled = $null
        Members = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Nested = [System.Collections.Generic.List[string]]::new()
    }
    return $Id
}

function Get-FakeGroupByName {
    param([string] $DisplayName)
    $global:Fake.Groups.Values | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
}

function Get-FakeTransitiveUsers {
    param([string] $GroupId, [System.Collections.Generic.HashSet[string]] $Seen = [System.Collections.Generic.HashSet[string]]::new())
    if (-not $Seen.Add($GroupId)) { return @() }
    $g = $global:Fake.Groups[$GroupId]
    $out = @($g.Members)
    foreach ($n in $g.Nested) { $out += Get-FakeTransitiveUsers -GroupId $n -Seen $Seen }
    return $out | Select-Object -Unique
}

function New-FakeError {
    param([int] $Status, [string] $Code, [string] $Message)
    $resp = [pscustomobject]@{ StatusCode = $Status; Headers = $null }
    # Like the real SDK: the message ends with Graph's JSON error body.
    $json = @{ error = @{ code = $Code; message = $Message; innerError = @{ 'request-id' = '00000000-0000-0000-0000-0000000000aa'; date = '2026-10-27T23:40:54' } } } | ConvertTo-Json -Depth 5 -Compress
    $ex = [System.Exception]::new("Response status code does not indicate success: $Status ($Code). $json")
    $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
    throw $ex
}

function Get-FakePage {
    param([object[]] $Items)
    $size = $global:Fake.PageSize
    if ($Items.Count -le $size) { return @{ value = @($Items) } }
    $token = [guid]::NewGuid().ToString('N')
    $global:Fake.Pages[$token] = @($Items[$size..($Items.Count - 1)])
    return @{ value = @($Items[0..($size - 1)]); '@odata.nextLink' = "https://graph.microsoft.com/v1.0/fakepage/$token" }
}

function ConvertTo-FakeUserOut {
    param($U, [string[]] $Select)
    $o = @{}
    foreach ($s in $Select) { if ($U.ContainsKey($s)) { $o[$s] = $U[$s] } }
    return $o
}

function Get-FakeQuery {
    param([string] $Uri)
    $q = @{}
    $i = $Uri.IndexOf('?')
    if ($i -lt 0) { return $q }
    foreach ($pair in $Uri.Substring($i + 1).Split('&')) {
        $kv = $pair.Split('=', 2)
        $q[[uri]::UnescapeDataString($kv[0])] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
    }
    return $q
}

function Test-FakeDenied {
    param([string] $Method, [string] $Route)
    foreach ($d in $global:Fake.Deny) { if ("$Method $Route" -match $d) { return $true } }
    return $false
}

function Invoke-FakeSubRequest {
    param([string] $Method, [string] $Url, $Body)
    $Url = $Url.TrimStart('/')
    if (Test-FakeDenied -Method $Method -Route (($Url -split '\?')[0])) {
        return @{ status = 403; body = @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges to complete the operation.' } } }
    }
    if ($Method -eq 'PATCH' -and $Url -match '^groups/([^/]+)$') {
        $g = $global:Fake.Groups[$Matches[1]]
        if (-not $g) { return @{ status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Group not found' } } } }
        $ids = @($Body['members@odata.bind'] | ForEach-Object { ($_ -split '/')[-1] })
        if ($ids.Count -gt 20) { return @{ status = 400; body = @{ error = @{ code = 'Request_BadRequest'; message = 'Too many references' } } } }
        foreach ($id in $ids) {
            if (-not $global:Fake.Users.Contains($id)) { return @{ status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound'; message = "Resource '$id' does not exist" } } } }
            if ($g.Members.Contains($id)) { return @{ status = 400; body = @{ error = @{ code = 'Request_BadRequest'; message = "One or more added object references already exist for the following modified properties: 'members'." } } } }
        }
        foreach ($id in $ids) { [void]$g.Members.Add($id) }
        return @{ status = 204; body = $null }
    }
    if ($Method -eq 'POST' -and $Url -match '^groups/([^/]+)/members/\$ref$') {
        $g = $global:Fake.Groups[$Matches[1]]
        $id = ($Body['@odata.id'] -split '/')[-1]
        if (-not $g -or -not $global:Fake.Users.Contains($id)) { return @{ status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Not found' } } } }
        if (-not $g.Members.Add($id)) { return @{ status = 400; body = @{ error = @{ code = 'Request_BadRequest'; message = 'One or more added object references already exist' } } } }
        return @{ status = 204; body = $null }
    }
    if ($Method -eq 'DELETE' -and $Url -match '^groups/([^/]+)/members/([^/]+)/\$ref$') {
        $g = $global:Fake.Groups[$Matches[1]]
        if (-not $g -or -not $g.Members.Remove($Matches[2])) { return @{ status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Not a member' } } } }
        return @{ status = 204; body = $null }
    }
    return @{ status = 400; body = @{ error = @{ code = 'FakeUnsupported'; message = "$Method $Url" } } }
}

function Invoke-MgGraphRequest {
    [CmdletBinding()]
    param([string] $Method = 'GET', [string] $Uri, $Body, [string] $ContentType, [hashtable] $Headers, [string] $OutputType)
    $global:Fake.Calls.Add("$Method $Uri")
    if ($Body -is [string]) { $Body = $Body | ConvertFrom-Json -AsHashtable }
    $path = ($Uri -replace '^https://graph\.microsoft\.com/', '') -replace '^v1\.0/', ''
    $q = Get-FakeQuery -Uri $path
    $route = ($path -split '\?')[0]
    if ($route -ne '$batch' -and (Test-FakeDenied -Method $Method -Route $route)) {
        New-FakeError 403 'Authorization_RequestDenied' 'Insufficient privileges to complete the operation.'
    }

    if ($Method -eq 'GET' -and $route -match '^fakepage/(\w+)$') {
        $items = $global:Fake.Pages[$Matches[1]]; $global:Fake.Pages.Remove($Matches[1])
        return Get-FakePage -Items $items
    }
    if ($Method -eq 'GET' -and $route -eq 'users') {
        $select = $q['$select'].Split(',')
        $users = @($global:Fake.Users.Values)
        if ($q['$filter'] -eq 'accountEnabled eq true') { $users = @($users | Where-Object { $_.accountEnabled }) }
        return Get-FakePage -Items @($users | ForEach-Object { ConvertTo-FakeUserOut -U $_ -Select $select })
    }
    if ($Method -eq 'GET' -and $route -eq 'groups') {
        $f = $q['$filter']
        $groups = @($global:Fake.Groups.Values)
        if ($f -match "^displayName eq '(.*)'$") { $n = $Matches[1].Replace("''", "'"); $groups = @($groups | Where-Object { $_.displayName -eq $n }) }
        elseif ($f -match "^startswith\(displayName,'(.*)'\)$") { $n = $Matches[1].Replace("''", "'"); $groups = @($groups | Where-Object { $_.displayName.StartsWith($n, [StringComparison]::OrdinalIgnoreCase) }) }
        return Get-FakePage -Items @($groups | ForEach-Object { @{ id = $_.id; displayName = $_.displayName; description = $_.description; mailEnabled = $_.mailEnabled; securityEnabled = $_.securityEnabled; groupTypes = $_.groupTypes; onPremisesSyncEnabled = $_.onPremisesSyncEnabled } })
    }
    if ($Method -eq 'POST' -and $route -eq 'groups') {
        $id = Add-FakeGroup -DisplayName $Body.displayName -Description $Body.description
        return @{ id = $id; displayName = $Body.displayName }
    }
    if ($Method -eq 'GET' -and $route -match '^groups/([^/]+)$') {
        if (-not $global:Fake.Groups.Contains($Matches[1])) { New-FakeError 404 'NotFound' 'Request_ResourceNotFound' }
        return @{ id = $Matches[1]; displayName = $global:Fake.Groups[$Matches[1]].displayName }
    }
    if ($Method -eq 'GET' -and $route -match '^groups/([^/]+)/(members|transitiveMembers)$') {
        $g = $global:Fake.Groups[$Matches[1]]
        if (-not $g) { New-FakeError 404 'NotFound' 'Request_ResourceNotFound' }
        $ids = if ($Matches[2] -eq 'members') { @($g.Members) } else { @(Get-FakeTransitiveUsers -GroupId $g.id) }
        $items = @($ids | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.user'; id = $_; userPrincipalName = $global:Fake.Users[$_].userPrincipalName } })
        if ($Matches[2] -eq 'members') { $items += @($g.Nested | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.group'; id = $_ } }) }
        return Get-FakePage -Items $items
    }
    if ($Method -eq 'POST' -and $route -match '^users/([^/]+)/sendMail$') {
        if ($global:Fake.MailFail) { New-FakeError $global:Fake.MailFail 'ErrorAccessDenied' 'Access is denied.' }
        $global:Fake.Mail.Add([pscustomobject]@{ From = [uri]::UnescapeDataString($Matches[1]); Message = $Body['message']; Save = $Body['saveToSentItems'] })
        return $null
    }
    if ($Method -eq 'POST' -and $route -eq '$batch') {
        if (@($Body['requests']).Count -gt 20) { New-FakeError 400 'BadRequest' 'Batch too large' }
        $responses = foreach ($r in $Body['requests']) {
            $key = "$($r['method']) $($r['url'])"
            if ($global:Fake.ThrottleOnce.Remove($key)) {
                @{ id = $r['id']; status = 429; headers = @{ 'Retry-After' = '1' }; body = @{ error = @{ code = 'TooManyRequests'; message = 'Throttled' } } }
                continue
            }
            $res = Invoke-FakeSubRequest -Method $r['method'] -Url $r['url'] -Body $r['body']
            @{ id = $r['id']; status = $res['status']; headers = @{}; body = $res['body'] }
        }
        return @{ responses = @($responses) }
    }
    New-FakeError 400 'FakeUnsupported' "$Method $Uri"
}

function Get-MgContext {
    $c = $global:Fake.Context
    [pscustomobject]@{ Environment = 'Global'; Scopes = $c.Scopes; AuthType = $c.AuthType; ClientId = $c.ClientId
                       TenantId = $c.TenantId; AppName = $c.AppName; Account = $c.Account }
}
function Disconnect-MgGraph { }

function Get-FakeMembership {
    <# userId -> list of group display names, for assertions. #>
    $map = @{}
    foreach ($g in $global:Fake.Groups.Values) {
        foreach ($m in $g.Members) {
            if (-not $map.ContainsKey($m)) { $map[$m] = [System.Collections.Generic.List[string]]::new() }
            $map[$m].Add($g.displayName)
        }
    }
    return $map
}

# Make Get-MgContext and the other fakes safe to call before a test initialises a tenant.
if (-not (Get-Variable -Name Fake -Scope Global -ErrorAction SilentlyContinue)) { Reset-FakeGraph }
