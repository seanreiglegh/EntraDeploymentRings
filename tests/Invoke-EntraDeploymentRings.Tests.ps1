# =============================================================================
#  Invoke-EntraDeploymentRings.Tests.ps1
#  Revision: 1.0.1
#
#  Pester 5 tests. Unit tests for the pure ring logic plus end-to-end runs
#  against the in-memory Graph emulator in FakeGraph.ps1. No tenant and no
#  Microsoft.Graph module are needed.
#
#    Invoke-Pester -Path ./tests -Output Detailed
#
#  REVISION HISTORY (most recent first)
#  1.0.1 2026-11-02  Example request IDs, timestamp and group prefix standardised on
#                    obvious placeholders; Examples sync test accepts CRLF.
#  1.0   2026-11-01  First public release.
# =============================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Invoke-EntraDeploymentRings.ps1')
    . (Join-Path $PSScriptRoot 'FakeGraph.ps1')

    $script:ReportRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("edr-tests-" + [guid]::NewGuid().ToString('N'))
    $script:Now = [datetime]::new(2026, 10, 25, 12, 0, 0, [DateTimeKind]::Utc)

    function New-TestSettings {
        param([hashtable] $Override = @{})
        $v = @{
            GroupNameBase = 'SG-Test'; RingCount = 4; RingWeights = @(5, 15, 30, 50)
            AuthMode = 'ExistingConnection'; ReportDirectory = $script:ReportRoot; CreateMissingGroups = $true
            MaxChangePercent = 10; MaxChangeFloor = 25
        }
        foreach ($k in $Override.Keys) { $v[$k] = $Override[$k] }
        ConvertTo-RingSettings -Values $v
    }

    function New-TestUser {
        param([string] $Id = ([guid]::NewGuid().ToString()), [string] $Company = 'Contoso', $LastSignIn = $script:Now.AddDays(-1), $Created = $script:Now.AddYears(-1),
              [string] $EmployeeType = 'Employee', [string] $UserType = 'Member', [bool] $Enabled = $true, [int] $Licenses = 1)
        [pscustomobject]@{
            Id = $Id; UserPrincipalName = "$Id@contoso.test"; AccountEnabled = $Enabled; UserType = $UserType
            EmployeeType = $EmployeeType; CompanyName = $Company; CreatedDateTime = $Created; LastSuccessfulSignIn = $LastSignIn; LicenseCount = $Licenses
        }
    }

    function New-EmptyMembers {
        param($Settings)
        $m = @{ First = @{}; Last = @{}; Inactive = @{} }
        foreach ($k in $Settings.RingKeys) { $m[$k] = @{} }
        $m
    }

    function New-IdSet { param([string[]] $Ids = @()) [System.Collections.Generic.HashSet[string]]::new($Ids, [StringComparer]::OrdinalIgnoreCase) }

    function Initialize-FakeTenant {
        param([int] $Count = 1200, [int] $Seed = 42)
        Reset-FakeGraph -PageSize 100
        $rng = [System.Random]::new($Seed)
        $types = 'Employee', 'Employee', 'Employee', 'Contingent Worker', 'Vendor', ''
        for ($i = 0; $i -lt $Count; $i++) {
            $id = New-FakeGuid -Rng $rng
            Add-FakeUser -Id $id -Upn "user$i@contoso.test" -EmployeeType $types[$i % $types.Count] `
                -LastSuccess ([datetime]::UtcNow.AddDays(-($rng.Next(0, 30))))
        }
        # Special cases
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000001' -Upn 'guest@contoso.test' -UserType 'Guest'
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000002' -Upn 'disabled@contoso.test' -Enabled $false
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000003' -Upn 'former@contoso.test' -CompanyName 'Former'
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000004' -Upn 'stale@contoso.test' -LastSuccess ([datetime]::UtcNow.AddDays(-200))
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000005' -Upn 'neverold@contoso.test' -LastSuccess $null -Created ([datetime]::UtcNow.AddDays(-100))
        Add-FakeUser -Id 'aaaaaaaa-0000-0000-0000-000000000006' -Upn 'nevernew@contoso.test' -LastSuccess $null -Created ([datetime]::UtcNow.AddDays(-3))
    }

    function Get-ExpectedScopedIds {
        @($global:Fake.Users.Values | Where-Object { $_.userType -eq 'Member' -and $_.employeeType -in 'Employee', 'Contingent Worker' } | ForEach-Object id)
    }

    function Invoke-TestSync {
        param([hashtable] $Override = @{}, [switch] $WhatIf)
        $s = New-TestSettings -Override $Override
        Invoke-DeploymentRingSync -Settings $s -WhatIf:$WhatIf -InformationAction SilentlyContinue -WarningAction SilentlyContinue
    }
}

AfterAll {
    if ($script:ReportRoot -and (Test-Path $script:ReportRoot)) { Remove-Item $script:ReportRoot -Recurse -Force }
}

Describe 'Get-NormalizedWeights' {
    It 'returns equal weights when none are given' {
        $w = Get-NormalizedWeights -RingCount 4
        $w.Count | Should -Be 4
        $w[0] | Should -Be 0.25
    }
    It 'normalizes weights to sum to 1' {
        $w = Get-NormalizedWeights -Weights 1, 5, 15, 30, 49 -RingCount 5
        [math]::Round(($w | Measure-Object -Sum).Sum, 10) | Should -Be 1
        $w[0] | Should -Be 0.01
    }
    It 'rejects a count mismatch' {
        { Get-NormalizedWeights -Weights 1, 2 -RingCount 3 } | Should -Throw '*exactly one weight*'
    }
    It 'rejects weights that do not add up to 100' {
        { Get-NormalizedWeights -Weights 10, 20, 30 -RingCount 3 } | Should -Throw '*add up to 100*'
        { Get-NormalizedWeights -Weights 1, 1, 1, 1 -RingCount 4 } | Should -Throw '*add up to 100*'
    }
    It 'accepts rounding within 0.01' {
        (Get-NormalizedWeights -Weights 33.33, 33.33, 33.34 -RingCount 3).Count | Should -Be 3
    }
    It 'rejects bad weights when settings are built' {
        { New-TestSettings -Override @{ RingWeights = @(5, 15, 30, 40) } } | Should -Throw '*add up to 100*'
    }
    It 'rejects zero or negative weights' {
        { Get-NormalizedWeights -Weights 1, 0 -RingCount 2 } | Should -Throw '*positive*'
    }
}

Describe 'Hash ring assignment' {
    It 'is deterministic and case-insensitive for the object ID' {
        $w = Get-NormalizedWeights -Weights 5, 15, 30, 50 -RingCount 4
        $id = '0f8fad5b-d9cb-469f-a165-70867728950e'
        $a = Get-HashRingIndex -Seed 'SG-Test' -ObjectId $id -Weights $w
        $b = Get-HashRingIndex -Seed 'SG-Test' -ObjectId $id.ToUpper() -Weights $w
        $a | Should -Be $b
    }
    It 'returns a fraction in [0,1)' {
        1..200 | ForEach-Object {
            $f = Get-HashFraction -Seed 's' -ObjectId ([guid]::NewGuid().ToString())
            $f | Should -BeGreaterOrEqual 0
            $f | Should -BeLessThan 1
        }
    }
    It 'matches the weights within tolerance over 20,000 users' {
        $w = Get-NormalizedWeights -Weights 5, 15, 30, 50 -RingCount 4
        $counts = @{ 1 = 0; 2 = 0; 3 = 0; 4 = 0 }
        $rng = [System.Random]::new(7)
        for ($i = 0; $i -lt 20000; $i++) { $counts[(Get-HashRingIndex -Seed 'SG-Test' -ObjectId (New-FakeGuid -Rng $rng) -Weights $w)]++ }
        for ($r = 1; $r -le 4; $r++) {
            [math]::Abs($counts[$r] / 20000 - $w[$r - 1]) | Should -BeLessThan 0.015
        }
    }
}

Describe 'Get-InactiveReason' {
    BeforeAll { $s = New-TestSettings }
    It 'flags company name Former (case-insensitive)' {
        Get-InactiveReason -User (New-TestUser -Company 'former') -Settings $s -Now $script:Now | Should -BeLike 'CompanyName:*'
    }
    It 'flags last successful sign-in older than the threshold' {
        Get-InactiveReason -User (New-TestUser -LastSignIn $script:Now.AddDays(-91)) -Settings $s -Now $script:Now | Should -Be 'NoSignInFor90Days'
    }
    It 'does not flag a recent sign-in' {
        Get-InactiveReason -User (New-TestUser -LastSignIn $script:Now.AddDays(-89)) -Settings $s -Now $script:Now | Should -BeNullOrEmpty
    }
    It 'flags never-signed-in accounts older than the grace period' {
        Get-InactiveReason -User (New-TestUser -LastSignIn $null -Created $script:Now.AddDays(-31)) -Settings $s -Now $script:Now | Should -Be 'NeverSignedIn'
    }
    It 'gives new accounts a grace period' {
        Get-InactiveReason -User (New-TestUser -LastSignIn $null -Created $script:Now.AddDays(-5)) -Settings $s -Now $script:Now | Should -BeNullOrEmpty
    }
    It 'can disable the sign-in rule only' {
        $s2 = New-TestSettings -Override @{ InactiveSignInDays = 0 }
        Get-InactiveReason -User (New-TestUser -LastSignIn $script:Now.AddDays(-400)) -Settings $s2 -Now $script:Now | Should -BeNullOrEmpty
        Get-InactiveReason -User (New-TestUser -Company 'Former') -Settings $s2 -Now $script:Now | Should -Not -BeNullOrEmpty
    }
    It 'can disable the company rule only' {
        $s2 = New-TestSettings -Override @{ InactiveCompanyNames = @() }
        Get-InactiveReason -User (New-TestUser -Company 'Former') -Settings $s2 -Now $script:Now | Should -BeNullOrEmpty
    }
    It 'supports wildcard company patterns' {
        $s2 = New-TestSettings -Override @{ InactiveCompanyNames = @('Former*') }
        Get-InactiveReason -User (New-TestUser -Company 'Former Employee') -Settings $s2 -Now $script:Now | Should -Not -BeNullOrEmpty
    }
    It 'flags a UPN matching InactiveUpnPatterns' {
        $s2 = New-TestSettings -Override @{ InactiveUpnPatterns = @('{user}.former@{domain}') }
        $u = New-TestUser; $u.UserPrincipalName = 'Jane.Doe.Former@contoso.com'
        Get-InactiveReason -User $u -Settings $s2 -Now $script:Now | Should -Be 'UpnPattern:{user}.former@{domain}'
        $u.UserPrincipalName = 'jane.formerly@contoso.com'
        Get-InactiveReason -User $u -Settings $s2 -Now $script:Now | Should -BeNullOrEmpty
    }
    It 'validates InactiveUpnPatterns when settings are built' {
        { New-TestSettings -Override @{ InactiveUpnPatterns = @('{usr}.former@{domain}') } } | Should -Throw '*unknown placeholder*'
    }
    It 'flags employeeType Former (case-insensitive) by default' {
        Get-InactiveReason -User (New-TestUser -EmployeeType 'former') -Settings $s -Now $script:Now | Should -Be 'EmployeeType:former'
    }
    It 'reports Disabled first when an offboarded account is also disabled' {
        Get-InactiveReason -User (New-TestUser -EmployeeType 'Former' -Enabled $false) -Settings $s -Now $script:Now | Should -Be 'Disabled'
    }
    It 'flags disabled accounts first, regardless of sign-in' {
        Get-InactiveReason -User (New-TestUser -Enabled $false -LastSignIn $script:Now) -Settings $s -Now $script:Now | Should -Be 'Disabled'
    }
    It 'does not flag disabled accounts with DisabledUserAction Exclude' {
        $s2 = New-TestSettings -Override @{ DisabledUserAction = 'Exclude' }
        Get-InactiveReason -User (New-TestUser -Enabled $false) -Settings $s2 -Now $script:Now | Should -BeNullOrEmpty
    }
    It 'returns nothing when the Inactive ring is disabled' {
        $s2 = New-TestSettings -Override @{ EnableInactiveRing = $false }
        Get-InactiveReason -User (New-TestUser -Company 'Former') -Settings $s2 -Now $script:Now | Should -BeNullOrEmpty
    }
}

Describe 'Test-RingUserInScope' {
    BeforeAll { $s = New-TestSettings }
    It 'includes Employee and Contingent Worker' {
        Test-RingUserInScope -User (New-TestUser -EmployeeType 'Employee') -Settings $s | Should -BeTrue
        Test-RingUserInScope -User (New-TestUser -EmployeeType 'contingent worker') -Settings $s | Should -BeTrue
    }
    It 'excludes other or empty employee types' {
        Test-RingUserInScope -User (New-TestUser -EmployeeType 'Vendor') -Settings $s | Should -BeFalse
        Test-RingUserInScope -User (New-TestUser -EmployeeType '') -Settings $s | Should -BeFalse
    }
    It 'keeps employeeType Former in scope (it goes to Inactive)' {
        Test-RingUserInScope -User (New-TestUser -EmployeeType 'Former') -Settings $s | Should -BeTrue
    }
    It 'excludes employeeType Former when InactiveEmployeeTypes is empty' {
        $s2 = New-TestSettings -Override @{ InactiveEmployeeTypes = @() }
        Get-RingScopeExclusion -User (New-TestUser -EmployeeType 'Former') -Settings $s2 | Should -Be 'EmployeeType:Former'
    }
    It 'excludes employeeType Former when the Inactive ring is off' {
        $s2 = New-TestSettings -Override @{ EnableInactiveRing = $false } 3>$null
        Test-RingUserInScope -User (New-TestUser -EmployeeType 'Former') -Settings $s2 | Should -BeFalse
    }
    It 'lets a UPN exclusion win over employeeType Former' {
        $s2 = New-TestSettings -Override @{ ExcludeUpnPatterns = @('SVC-{user}@{domain}') }
        $u = New-TestUser -EmployeeType 'Former'; $u.UserPrincipalName = 'svc-old@contoso.com'
        Get-RingScopeExclusion -User $u -Settings $s2 | Should -Be 'UpnPattern:SVC-{user}@{domain}'
    }
    It 'excludes guests' {
        Test-RingUserInScope -User (New-TestUser -UserType 'Guest') -Settings $s | Should -BeFalse
    }
    It 'keeps disabled users in scope by default (they go to Inactive)' {
        Test-RingUserInScope -User (New-TestUser -Enabled $false) -Settings $s | Should -BeTrue
    }
    It 'excludes disabled users with DisabledUserAction Exclude' {
        $s2 = New-TestSettings -Override @{ DisabledUserAction = 'Exclude' }
        Test-RingUserInScope -User (New-TestUser -Enabled $false) -Settings $s2 | Should -BeFalse
    }
    It 'falls back to Exclude when the Inactive ring is off' {
        $s2 = New-TestSettings -Override @{ EnableInactiveRing = $false } 3>$null
        $s2.DisabledUserAction | Should -Be 'Exclude'
        Test-RingUserInScope -User (New-TestUser -Enabled $false) -Settings $s2 | Should -BeFalse
    }
    It 'honours exclusion groups' {
        $u = New-TestUser
        Test-RingUserInScope -User $u -Settings $s -ExcludedIds (New-IdSet $u.Id) | Should -BeFalse
    }
    It 'includes every employee type when the filter is empty' {
        $s2 = New-TestSettings -Override @{ IncludeEmployeeTypes = @() }
        Test-RingUserInScope -User (New-TestUser -EmployeeType '') -Settings $s2 | Should -BeTrue
    }
    It 'optionally requires a license' {
        $s2 = New-TestSettings -Override @{ RequireAssignedLicense = $true }
        Test-RingUserInScope -User (New-TestUser -Licenses 0) -Settings $s2 | Should -BeFalse
    }
}

Describe 'ConvertTo-UpnPatternRegex' {
    It 'matches <Upn> against <Pattern> = <Expected>' -ForEach @(
        @{ Pattern = '{user}.former@{domain}'; Upn = 'john.smith.former@contoso.com'; Expected = $true }
        @{ Pattern = '{user}.former@{domain}'; Upn = 'JOHN.FORMER@CONTOSO.COM';       Expected = $true }
        @{ Pattern = '{user}.former@{domain}'; Upn = 'john.formerly@contoso.com';     Expected = $false }
        @{ Pattern = '{user}.former@{domain}'; Upn = '.former@contoso.com';           Expected = $false }
        @{ Pattern = 'SVC-{user}@{domain}';    Upn = 'svc-backup@contoso.com';        Expected = $true }
        @{ Pattern = 'SVC-{user}@{domain}';    Upn = 'jsvc-backup@contoso.com';       Expected = $false }
        @{ Pattern = 'SVC-{user}@{domain}';    Upn = 'svc-@contoso.com';              Expected = $false }
        @{ Pattern = 'admin-{user}@contoso.com'; Upn = 'admin-jo@contoso.com';        Expected = $true }
        @{ Pattern = 'admin-{user}@contoso.com'; Upn = 'admin-jo@fabrikam.com';       Expected = $false }
        @{ Pattern = '*#EXT#@*';               Upn = 'bob_x.com#EXT#@contoso.onmicrosoft.com'; Expected = $true }
        @{ Pattern = 'test?@{domain}';         Upn = 'test1@contoso.com';             Expected = $true }
        @{ Pattern = 'test?@{domain}';         Upn = 'test12@contoso.com';            Expected = $false }
    ) {
        (ConvertTo-UpnPatternRegex -Pattern $Pattern).IsMatch($Upn) | Should -Be $Expected
    }
    It 'rejects unknown placeholders' { { ConvertTo-UpnPatternRegex -Pattern '{usr}@{domain}' } | Should -Throw '*unknown placeholder*' }
    It 'rejects unbalanced braces' { { ConvertTo-UpnPatternRegex -Pattern '{user@{domain}' } | Should -Throw '*unbalanced*' }
    It 'is validated when settings are built' {
        { New-TestSettings -Override @{ ExcludeUpnPatterns = @('{nope}@x') } } | Should -Throw '*unknown placeholder*'
    }
}

Describe 'Get-RingScopeExclusion' {
    It 'names the UPN pattern that excluded the user' {
        $s = New-TestSettings -Override @{ ExcludeUpnPatterns = @('{user}.former@{domain}', 'SVC-{user}@{domain}') }
        $u = New-TestUser; $u.UserPrincipalName = 'svc-sql@contoso.com'
        Get-RingScopeExclusion -User $u -Settings $s | Should -Be 'UpnPattern:SVC-{user}@{domain}'
    }
    It 'returns nothing for an in-scope user' {
        $s = New-TestSettings -Override @{ ExcludeUpnPatterns = @('SVC-{user}@{domain}') }
        Get-RingScopeExclusion -User (New-TestUser) -Settings $s | Should -BeNullOrEmpty
    }
    It 'reports the first failing rule' {
        $s = New-TestSettings
        Get-RingScopeExclusion -User (New-TestUser -EmployeeType 'Vendor') -Settings $s | Should -Be 'EmployeeType:Vendor'
        Get-RingScopeExclusion -User (New-TestUser -Enabled $false) -Settings (New-TestSettings -Override @{ DisabledUserAction = 'Exclude' }) | Should -Be 'Disabled'
        Get-RingScopeExclusion -User (New-TestUser -Enabled $false) -Settings $s | Should -BeNullOrEmpty
    }
}

Describe 'Get-RingPlan' {
    BeforeAll { $s = New-TestSettings }

    It 'assigns new users to their hash ring' {
        $u = New-TestUser
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers (New-EmptyMembers $s) -Now $script:Now
        $expected = Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $u.Id -Weights $s.RingWeights)
        $plan.Changes.Count | Should -Be 1
        $plan.Changes[0].Action | Should -Be 'Add'
        $plan.Changes[0].GroupKey | Should -Be $expected
        $plan.Changes[0].Reason | Should -Be 'NewAssignment'
    }

    It 'keeps users in their current ring even when the hash says otherwise (sticky)' {
        $u = New-TestUser
        $hashKey = Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $u.Id -Weights $s.RingWeights)
        $other = $s.RingKeys | Where-Object { $_ -ne $hashKey } | Select-Object -First 1
        $m = New-EmptyMembers $s; $m[$other][$u.Id] = $u.UserPrincipalName
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers $m -Now $script:Now
        $plan.Changes.Count | Should -Be 0
        $plan.Desired[$u.Id] | Should -Be $other
    }

    It 'removes a user from computed rings when they are in First' {
        $u = New-TestUser
        $m = New-EmptyMembers $s; $m['Ring02'][$u.Id] = $u.UserPrincipalName
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers $m -FirstIds (New-IdSet $u.Id) -Now $script:Now
        $plan.Changes.Count | Should -Be 1
        $plan.Changes[0].Action | Should -Be 'Remove'
        $plan.Changes[0].Reason | Should -Be 'ManualRingOverride:First'
    }

    It 'gives Last precedence over First and reports the conflict' {
        $u = New-TestUser
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers (New-EmptyMembers $s) -FirstIds (New-IdSet $u.Id) -LastIds (New-IdSet $u.Id) -Now $script:Now
        $plan.Desired[$u.Id] | Should -Be 'Last'
        $plan.Conflicts.Conflict | Should -Contain 'InFirstAndLast'
    }

    It 'moves inactive users out of computed rings into Inactive' {
        $u = New-TestUser -Company 'Former'
        $m = New-EmptyMembers $s; $m['Ring03'][$u.Id] = $u.UserPrincipalName
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers $m -Now $script:Now
        ($plan.Changes | Where-Object { $_.Action -eq 'Remove' -and $_.GroupKey -eq 'Ring03' }).Reason | Should -Be 'MovedToInactive'
        ($plan.Changes | Where-Object { $_.Action -eq 'Add' }).GroupKey | Should -Be 'Inactive'
    }

    It 'gives Inactive precedence over First and reports the conflict' {
        $u = New-TestUser -Company 'Former'
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers (New-EmptyMembers $s) -FirstIds (New-IdSet $u.Id) -Now $script:Now
        $plan.Desired[$u.Id] | Should -Be 'Inactive'
        $plan.Conflicts.Conflict | Should -Contain 'InactiveUserInManualRing'
    }

    It 'removes inactive users from First when RemoveInactiveFromManualRings is set' {
        $s2 = New-TestSettings -Override @{ RemoveInactiveFromManualRings = $true }
        $u = New-TestUser -Company 'Former'
        $m = New-EmptyMembers $s2; $m['First'][$u.Id] = $u.UserPrincipalName
        $plan = Get-RingPlan -Users @($u) -Settings $s2 -CurrentMembers $m -FirstIds (New-IdSet $u.Id) -Now $script:Now
        $plan.Changes | Where-Object { $_.Action -eq 'Remove' -and $_.GroupKey -eq 'First' } | Should -Not -BeNullOrEmpty
    }

    It 'returns a user from Inactive to their hash ring' {
        $u = New-TestUser
        $m = New-EmptyMembers $s; $m['Inactive'][$u.Id] = $u.UserPrincipalName
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers $m -Now $script:Now
        $expected = Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $u.Id -Weights $s.RingWeights)
        ($plan.Changes | Where-Object Action -eq 'Remove').Reason | Should -Be 'NoLongerInactive'
        $add = $plan.Changes | Where-Object Action -eq 'Add'
        $add.GroupKey | Should -Be $expected
        $add.Reason | Should -Be 'ReturnedFromInactive'
    }

    It 'removes out-of-scope members from managed groups' {
        $m = New-EmptyMembers $s; $m['Ring01']['gone'] = 'gone@contoso.test'; $m['Inactive']['gone2'] = 'gone2@contoso.test'
        $plan = Get-RingPlan -Users @() -Settings $s -CurrentMembers $m -Now $script:Now
        $plan.Changes.Count | Should -Be 2
        $plan.Changes.Reason | Should -Not -Contain 'MovedToInactive'
        @($plan.Changes | Where-Object Reason -eq 'OutOfScope').Count | Should -Be 2
    }

    It 'never touches First or Last membership by default' {
        $m = New-EmptyMembers $s; $m['First']['x'] = 'x@contoso.test'; $m['Last']['y'] = 'y@contoso.test'
        $plan = Get-RingPlan -Users @() -Settings $s -CurrentMembers $m -FirstIds (New-IdSet 'x') -LastIds (New-IdSet 'y') -Now $script:Now
        $plan.Changes.Count | Should -Be 0
    }

    It 'resolves duplicate computed-ring membership to a single ring' {
        $u = New-TestUser
        $m = New-EmptyMembers $s; $m['Ring01'][$u.Id] = 'a'; $m['Ring04'][$u.Id] = 'a'
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers $m -Now $script:Now
        $plan.Changes.Count | Should -Be 1
        $plan.Changes[0].Action | Should -Be 'Remove'
        $plan.Changes[0].Reason | Should -Be 'DuplicateRingMembership'
    }

    It 'fills the most under-target ring in Balance mode' {
        $s2 = New-TestSettings -Override @{ AssignmentMode = 'Balance'; RingWeights = @(25, 25, 25, 25) }
        $existing = 1..9 | ForEach-Object { New-TestUser }
        $m = New-EmptyMembers $s2
        foreach ($u in $existing) { $m['Ring01'][$u.Id] = 'x' }        # Ring01 already full
        $new = 1..27 | ForEach-Object { New-TestUser }
        $plan = Get-RingPlan -Users (@($existing) + @($new)) -Settings $s2 -CurrentMembers $m -Now $script:Now
        $plan.Counts['Ring01'] | Should -Be 9
        $plan.Counts['Ring02'] | Should -Be 9
        $plan.Counts['Ring03'] | Should -Be 9
        $plan.Counts['Ring04'] | Should -Be 9
    }

    It 'moves users only when Rebalance is requested' {
        $s2 = New-TestSettings -Override @{ Rebalance = $true }
        $users = 1..40 | ForEach-Object { New-TestUser }
        $m = New-EmptyMembers $s2
        foreach ($u in $users) { $m['Ring01'][$u.Id] = 'x' }
        $plan = Get-RingPlan -Users $users -Settings $s2 -CurrentMembers $m -Now $script:Now
        foreach ($u in $users) {
            $plan.Desired[$u.Id] | Should -Be (Get-RingKey (Get-HashRingIndex -Seed $s2.HashSeed -ObjectId $u.Id -Weights $s2.RingWeights))
        }
        ($plan.Changes | Where-Object Action -eq 'Remove').Reason | Select-Object -Unique | Should -Be 'Rebalance'
    }

    It 'InitialRun re-places every computed user and labels the change InitialRun' {
        $s2 = New-TestSettings -Override @{ InitialRun = $true }
        $s2.Rebalance | Should -BeTrue
        $users = 1..40 | ForEach-Object { New-TestUser }
        $m = New-EmptyMembers $s2
        foreach ($u in $users) { $m['Ring01'][$u.Id] = 'x' }
        $plan = Get-RingPlan -Users $users -Settings $s2 -CurrentMembers $m -Now $script:Now
        foreach ($u in $users) {
            $plan.Desired[$u.Id] | Should -Be (Get-RingKey (Get-HashRingIndex -Seed $s2.HashSeed -ObjectId $u.Id -Weights $s2.RingWeights))
        }
        $plan.Changes.Reason | Select-Object -Unique | Should -Be 'InitialRun'
    }

    It 'InitialRun still honours Inactive, First and Last' {
        $s2 = New-TestSettings -Override @{ InitialRun = $true }
        $inactive = New-TestUser -Company 'Former'; $first = New-TestUser; $last = New-TestUser
        $plan = Get-RingPlan -Users @($inactive, $first, $last) -Settings $s2 -CurrentMembers (New-EmptyMembers $s2) -FirstIds (New-IdSet $first.Id) -LastIds (New-IdSet $last.Id) -Now $script:Now
        $plan.Desired[$inactive.Id] | Should -Be 'Inactive'
        $plan.Desired[$first.Id] | Should -Be 'First'
        $plan.Desired[$last.Id] | Should -Be 'Last'
    }

    It 'puts a .former user in Inactive (not excluded) and lets exclusion win when both match' {
        $s2 = New-TestSettings -Override @{ InactiveUpnPatterns = @('{user}.former@{domain}'); ExcludeUpnPatterns = @('SVC-{user}@{domain}') }
        $former = New-TestUser; $former.UserPrincipalName = 'jane.former@contoso.com'
        Test-RingUserInScope -User $former -Settings $s2 | Should -BeTrue
        $m = New-EmptyMembers $s2; $m['Ring02'][$former.Id] = $former.UserPrincipalName
        $plan = Get-RingPlan -Users @($former) -Settings $s2 -CurrentMembers $m -Now $script:Now
        $plan.Desired[$former.Id] | Should -Be 'Inactive'
        ($plan.Changes | Where-Object Action -eq 'Add').Reason | Should -Be 'Inactive:UpnPattern:{user}.former@{domain}'

        $both = New-TestSettings -Override @{ InactiveUpnPatterns = @('{user}.former@{domain}'); ExcludeUpnPatterns = @('{user}.former@{domain}') } 3>$null
        Test-RingUserInScope -User $former -Settings $both | Should -BeFalse
    }

    It 'labels removals with the exclusion reason when known' {
        $m = New-EmptyMembers $s; $m['Ring02']['svc'] = 'svc-sql@contoso.com'
        $plan = Get-RingPlan -Users @() -Settings $s -CurrentMembers $m -ExclusionReasons @{ svc = 'UpnPattern:SVC-{user}@{domain}' } -Now $script:Now
        $plan.Changes[0].Reason | Should -Be 'OutOfScope:UpnPattern:SVC-{user}@{domain}'
    }

    It 're-places members of retired orphan rings' {
        $s3 = New-TestSettings -Override @{ RingCount = 3; RingWeights = @(33.33, 33.33, 33.34) }
        $u = New-TestUser
        $m = New-EmptyMembers $s3; $m['Ring04'] = @{ $u.Id = 'x' }
        $plan = Get-RingPlan -Users @($u) -Settings $s3 -CurrentMembers $m -OrphanKeys @('Ring04') -Now $script:Now
        ($plan.Changes | Where-Object Action -eq 'Remove').Reason | Should -Be 'OrphanRingRetired'
        ($plan.Changes | Where-Object Action -eq 'Add').GroupKey | Should -BeIn $s3.RingKeys
    }

    It 'reports an excluded user found in First, with the reason and group key' {
        $m = New-EmptyMembers $s; $m['First']['svc1'] = 'svc-app@contoso.com'
        $plan = Get-RingPlan -Users @() -Settings $s -CurrentMembers $m -FirstIds (New-IdSet 'svc1') -ExclusionReasons @{ svc1 = 'UpnPattern:SVC-{user}@{domain}' } -UpnById @{ svc1 = 'svc-app@contoso.com' } -Now $script:Now
        $c = $plan.Conflicts | Where-Object Conflict -eq 'ExcludedUserInManualRing'
        @($c).Count | Should -Be 1
        $c.UserPrincipalName | Should -Be 'svc-app@contoso.com'
        $c.GroupKeys | Should -Be 'First'
        $c.Detail | Should -Match 'UpnPattern:SVC-\{user\}@\{domain\}'
        $plan.Changes.Count | Should -Be 0
    }

    It 'labels nested membership and users Graph did not return' {
        $m = New-EmptyMembers $s
        $plan = Get-RingPlan -Users @() -Settings $s -CurrentMembers $m -LastIds (New-IdSet 'gone') -Now $script:Now
        $c = $plan.Conflicts | Where-Object Conflict -eq 'ExcludedUserInManualRing'
        $c.GroupKeys | Should -Be 'Last'
        $c.Detail | Should -Match 'NotReturnedByGraph'
        $c.Detail | Should -Match 'nested group'
    }

    It 'does not report excluded users in First/Last when the option is off' {
        $s2 = New-TestSettings -Override @{ ReportExcludedInManualRings = $false }
        $plan = Get-RingPlan -Users @() -Settings $s2 -CurrentMembers (New-EmptyMembers $s2) -FirstIds (New-IdSet 'svc1') -ExclusionReasons @{ svc1 = 'ExclusionGroup' } -Now $script:Now
        @($plan.Conflicts | Where-Object Conflict -eq 'ExcludedUserInManualRing').Count | Should -Be 0
    }

    It 'does not report in-scope First members as excluded' {
        $u = New-TestUser
        $plan = Get-RingPlan -Users @($u) -Settings $s -CurrentMembers (New-EmptyMembers $s) -FirstIds (New-IdSet $u.Id) -Now $script:Now
        @($plan.Conflicts | Where-Object Conflict -eq 'ExcludedUserInManualRing').Count | Should -Be 0
    }

    It 'puts every in-scope user in exactly one ring' {
        $users = 1..500 | ForEach-Object { New-TestUser -Company $(if ($_ % 50 -eq 0) { 'Former' } else { 'Contoso' }) }
        $first = New-IdSet @($users[0..9].Id); $last = New-IdSet @($users[10..14].Id)
        $plan = Get-RingPlan -Users $users -Settings $s -CurrentMembers (New-EmptyMembers $s) -FirstIds $first -LastIds $last -Now $script:Now
        $plan.Desired.Count | Should -Be 500
        ($plan.Counts.Values | Measure-Object -Sum).Sum | Should -Be 500
    }
}

Describe 'Test-ChangeThreshold' {
    BeforeAll { $s = New-TestSettings }
    It 'allows the initial population' { (Test-ChangeThreshold -ChangeCount 5000 -Baseline 0 -Settings $s).Reason | Should -Be 'InitialPopulation' }
    It 'allows changes below the floor' { (Test-ChangeThreshold -ChangeCount 20 -Baseline 50 -Settings $s).Allowed | Should -BeTrue }
    It 'allows changes within the percentage' { (Test-ChangeThreshold -ChangeCount 90 -Baseline 1000 -Settings $s).Allowed | Should -BeTrue }
    It 'blocks changes above the percentage and floor' { (Test-ChangeThreshold -ChangeCount 200 -Baseline 1000 -Settings $s).Allowed | Should -BeFalse }
    It 'is not enforced on a Rebalance' {
        $s2 = New-TestSettings -Override @{ Rebalance = $true }
        $r = Test-ChangeThreshold -ChangeCount 900 -Baseline 1000 -Settings $s2
        $r.Allowed | Should -BeTrue
        $r.Reason | Should -Be 'Rebalance'
    }
    It 'is not enforced on an InitialRun' {
        $s2 = New-TestSettings -Override @{ InitialRun = $true }
        $r = Test-ChangeThreshold -ChangeCount 900 -Baseline 1000 -Settings $s2
        $r.Allowed | Should -BeTrue
        $r.Reason | Should -Be 'InitialRun'
    }
    It 'can be bypassed' {
        $s2 = New-TestSettings -Override @{ BypassChangeLimit = $true }
        (Test-ChangeThreshold -ChangeCount 200 -Baseline 1000 -Settings $s2).Reason | Should -Be 'Bypassed'
    }
}

Describe 'Configuration' {
    It 'requires GroupNameBase' { { ConvertTo-RingSettings -Values @{ RingCount = 3 } } | Should -Throw '*GroupNameBase*' }
    It 'requires a valid RingCount' { { ConvertTo-RingSettings -Values @{ GroupNameBase = 'X'; RingCount = 0 } } | Should -Throw '*RingCount*' }
    It 'rejects marker characters in the base name' { { ConvertTo-RingSettings -Values @{ GroupNameBase = 'X:Y'; RingCount = 2 } } | Should -Throw '*marker*' }
    It 'requires credentials for Certificate auth' {
        { ConvertTo-RingSettings -Values @{ GroupNameBase = 'X'; RingCount = 2; AuthMode = 'Certificate' } } | Should -Throw '*CertificateThumbprint*'
    }
    It 'requires both Log Analytics values' {
        { ConvertTo-RingSettings -Values @{ GroupNameBase = 'X'; RingCount = 2; LogIngestionEndpoint = 'https://x' } } | Should -Throw '*LogDcrImmutableId*'
    }
    It 'derives the Azure Monitor audience from the cloud' {
        (ConvertTo-RingSettings -Values @{ GroupNameBase = 'X'; RingCount = 2; GraphEnvironment = 'USGov' }).LogTokenAudience | Should -Be 'https://monitor.azure.us'
    }
    It 'reads a configuration file and rejects unknown keys and secrets' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $good = Join-Path $dir 'good.json'
            '{ "$schema": "x", "_comment": "c", "groupnamebase": "SG-Cfg", "RingCount": 3 }' | Set-Content $good
            $v = Read-RingConfigFile -Path $good -AllowedNames 'GroupNameBase', 'RingCount'
            $v['GroupNameBase'] | Should -Be 'SG-Cfg'
            $v['RingCount'] | Should -Be 3

            $bad = Join-Path $dir 'bad.json'
            '{ "Nope": 1 }' | Set-Content $bad
            { Read-RingConfigFile -Path $bad -AllowedNames 'GroupNameBase' } | Should -Throw '*Unknown configuration key*'

            $init = Join-Path $dir 'init.json'
            '{ "InitialRun": true }' | Set-Content $init
            { Read-RingConfigFile -Path $init -AllowedNames 'GroupNameBase', 'InitialRun' } | Should -Throw '*command line*'
            '{ "Rebalance": true }' | Set-Content $init
            { Read-RingConfigFile -Path $init -AllowedNames 'GroupNameBase', 'Rebalance' } | Should -Throw '*command line*'
            '{ "Preflight": true }' | Set-Content $init
            { Read-RingConfigFile -Path $init -AllowedNames 'GroupNameBase', 'Preflight' } | Should -Throw '*never apply*'
            '{ "CreateGroupsOnly": true }' | Set-Content $init
            { Read-RingConfigFile -Path $init -AllowedNames 'GroupNameBase', 'CreateGroupsOnly' } | Should -Throw '*never fill the rings*'

            $secret = Join-Path $dir 'secret.json'
            '{ "ClientSecret": "abc" }' | Set-Content $secret
            { Read-RingConfigFile -Path $secret -AllowedNames 'GroupNameBase' } | Should -Throw '*not allowed*'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }
}

Describe 'Reports' {
    BeforeAll {
        $script:RptDir = Join-Path ([System.IO.Path]::GetTempPath()) ('edr-rpt-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:RptDir | Out-Null
        function New-RptContext([string] $Format) {
            $s = New-TestSettings -Override @{ ReportDirectory = $script:RptDir; ReportFormat = $Format }
            [pscustomobject]@{ RunId = [guid]::NewGuid().ToString(); StartTime = [datetime]::UtcNow; Settings = $s; IsWhatIf = $false; Groups = @{} }
        }
        function New-OldFile([string] $Name, [int] $DaysOld) {
            $f = Join-Path $script:RptDir $Name
            'x' | Set-Content $f
            (Get-Item $f).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-$DaysOld)
            $f
        }
    }
    AfterAll { Remove-Item $script:RptDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'plans <Expected> file(s) for format <Format>' -ForEach @(
        @{ Format = 'Csv'; Expected = 1 }
        @{ Format = 'Json'; Expected = 1 }
        @{ Format = 'Both'; Expected = 2 }
    ) {
        $p = Get-RingReportPath -Context (New-RptContext $Format)
        @(@($p.Csv, $p.Json) | Where-Object { $_ }).Count | Should -Be $Expected
        if ($Format -eq 'Json') { $p.Csv | Should -BeNullOrEmpty }
        if ($Format -eq 'Csv') { $p.Json | Should -BeNullOrEmpty }
    }

    It 'plans no files with SkipReport' {
        $ctx = New-RptContext 'Both'; $ctx.Settings.SkipReport = $true
        $p = Get-RingReportPath -Context $ctx
        $p.Csv | Should -BeNullOrEmpty
        $p.Json | Should -BeNullOrEmpty
    }

    It 'writes a header-only CSV when there are no changes' {
        $p = Get-RingReportPath -Context (New-RptContext 'Csv')
        Write-RingCsvReport -Path $p.Csv -Records @()
        (Get-Content $p.Csv -First 1) | Should -BeLike 'TimeGenerated,RunId,*'
    }

    It 'prunes only this ring set''s expired reports' {
        $mineOld   = New-OldFile 'EntraDeploymentRings_SG-Test_20250101-010101_abcdef12.csv' 100
        $mineOldJ  = New-OldFile 'EntraDeploymentRings_SG-Test_20250101-010101_abcdef12.summary.json' 100
        $mineNew   = New-OldFile 'EntraDeploymentRings_SG-Test_20261020-010101_abcdef13.csv' 5
        $otherSet  = New-OldFile 'EntraDeploymentRings_SG-Test-Other_20250101-010101_abcdef14.csv' 100
        $prefixSet = New-OldFile 'EntraDeploymentRings_SG_20250101-010101_abcdef15.csv' 100
        $unrelated = New-OldFile 'notes.csv' 100
        $lookalike = New-OldFile 'EntraDeploymentRings_SG-Test_old-copy.csv' 100

        Remove-RingExpiredReport -Directory $script:RptDir -Base 'SG-Test' -RetentionDays 30 -WhatIf | Should -Be 0
        Test-Path $mineOld | Should -BeTrue

        Remove-RingExpiredReport -Directory $script:RptDir -Base 'SG-Test' -RetentionDays 30 | Should -Be 2
        Test-Path $mineOld | Should -BeFalse
        Test-Path $mineOldJ | Should -BeFalse
        foreach ($f in $mineNew, $otherSet, $prefixSet, $unrelated, $lookalike) { Test-Path $f | Should -BeTrue }
    }

    It 'keeps everything when retention is 0' {
        $f = New-OldFile 'EntraDeploymentRings_SG-Test_20240101-010101_abcdef16.csv' 900
        Remove-RingExpiredReport -Directory $script:RptDir -Base 'SG-Test' -RetentionDays 0 | Should -Be 0
        Test-Path $f | Should -BeTrue
    }

    It 'validates the settings' {
        { New-TestSettings -Override @{ ReportFormat = 'Xml' } } | Should -Throw '*ReportFormat*'
        { New-TestSettings -Override @{ ReportRetentionDays = -1 } } | Should -Throw '*ReportRetentionDays*'
        (New-TestSettings -Override @{ ReportFormat = 'json' }).ReportFormat | Should -Be 'Json'
    }
}

Describe 'Teams notifications' {
    BeforeAll {
        $script:Hook = 'https://prod-00.westus.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sig=SECRET-SIG-123'
        function New-Sum([string] $Result) {
            [pscustomobject]@{ RunId = 'r1'; ScriptRevision = '1.0'; RingSet = 'SG-Test'; Mode = 'Live'; Result = $Result; ErrorMessage = $null
                EndTime = '2026-10-26T01:00:00Z'; PlannedAdds = 3; PlannedRemoves = 2; Failed = 0; Conflicts = 1; ScopedUsers = 400
                ChangePercent = 1.2; ChangeBaseline = 400; ChangeLimitReason = 'BelowFloor'; RetiredRingGroups = @(); DurationSeconds = 2.5
                ReportPath = '/r/x.csv'; Distribution = @([pscustomobject]@{ Ring = 'Ring01'; Members = 31; TargetPercentOfComputed = 10.0; ActualPercentOfComputed = 7.8 }) }
        }
    }

    It 'validates the webhook settings' {
        { New-TestSettings -Override @{ TeamsWebhookUrl = 'http://insecure.example.com/x' } } | Should -Throw '*https*'
        { New-TestSettings -Override @{ TeamsWebhookUrl = $script:Hook; TeamsNotifyOn = @('Sometimes') } } | Should -Throw '*TeamsNotifyOn*'
        (New-TestSettings -Override @{ TeamsWebhookUrl = $script:Hook; TeamsNotifyOn = @('success') }).TeamsNotifyOn | Should -Be 'Success'
        (New-TestSettings).TeamsNotifyOn -join ',' | Should -Be 'Failed,BlockedByChangeLimit,CompletedWithErrors,CertificateExpiring'
    }

    It 'decides when to notify: <Result> (WhatIf=<WhatIf>, NotifyOn=<On>) -> <Expected>' -ForEach @(
        @{ Result = 'Failed';               WhatIf = $false; On = 'default'; Expected = $true }
        @{ Result = 'BlockedByChangeLimit'; WhatIf = $false; On = 'default'; Expected = $true }
        @{ Result = 'CompletedWithErrors';  WhatIf = $false; On = 'default'; Expected = $true }
        @{ Result = 'Success';              WhatIf = $false; On = 'default'; Expected = $false }
        @{ Result = 'Success';              WhatIf = $false; On = 'Success'; Expected = $true }
        @{ Result = 'WhatIf';               WhatIf = $true;  On = 'default'; Expected = $false }
        @{ Result = 'BlockedByChangeLimit'; WhatIf = $true;  On = 'default'; Expected = $false }
        @{ Result = 'WhatIf';               WhatIf = $true;  On = 'WhatIf';  Expected = $true }
    ) {
        $o = @{ TeamsWebhookUrl = $script:Hook }
        if ($On -ne 'default') { $o.TeamsNotifyOn = @($On) }
        Test-RingShouldNotify -Settings (New-TestSettings -Override $o) -Result $Result -IsWhatIf $WhatIf | Should -Be $Expected
    }

    It 'never notifies without a webhook URL' {
        Test-RingShouldNotify -Settings (New-TestSettings) -Result 'Failed' | Should -BeFalse
    }

    It 'builds a Workflows-compatible Adaptive Card with counts only' {
        $changes = @(
            [pscustomobject]@{ Action = 'Add'; Reason = 'NewAssignment'; UserPrincipalName = 'secret.person@contoso.com'; UserId = 'uid-1' }
            [pscustomobject]@{ Action = 'Remove'; Reason = 'MovedToInactive'; UserPrincipalName = 'other.person@contoso.com'; UserId = 'uid-2' }
        )
        $p = Get-RingTeamsPayload -Summary (New-Sum 'BlockedByChangeLimit') -Changes $changes
        $json = $p | ConvertTo-Json -Depth 20
        $p.type | Should -Be 'message'
        $p.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $p.attachments[0].content.type | Should -Be 'AdaptiveCard'
        $json | Should -Match 'Blocked by change limit'
        $json | Should -Match 'Add: NewAssignment'
        $json | Should -Not -Match 'secret\.person'
        $json | Should -Not -Match 'uid-1'
    }

    It 'uses a distinct title for <Result>' -ForEach @(
        @{ Result = 'Success'; Text = 'Run succeeded' }
        @{ Result = 'CompletedWithErrors'; Text = 'Completed with errors' }
        @{ Result = 'Failed'; Text = 'Run failed' }
        @{ Result = 'WhatIf'; Text = 'Preview' }
    ) {
        (Get-RingTeamsPayload -Summary (New-Sum $Result) | ConvertTo-Json -Depth 20) | Should -Match $Text
    }
}

Describe 'Email notifications' {
    BeforeAll {
        function New-Sum2([string] $Result) {
            [pscustomobject]@{ RunId = 'r9'; ScriptRevision = '1.0'; RingSet = 'SG-<Test>&Co'; Mode = 'Live'; Result = $Result; ErrorMessage = 'Bad <script>alert(1)</script> thing'
                EndTime = '2026-10-26T01:00:00Z'; PlannedAdds = 3; PlannedRemoves = 2; Failed = 1; Conflicts = 0; ScopedUsers = 400
                ChangePercent = 1.2; ChangeBaseline = 400; ChangeLimitReason = 'BelowFloor'; RetiredRingGroups = @(); DurationSeconds = 2.5
                ReportPath = '/r/x.csv'; Distribution = @() }
        }
    }

    It 'validates the email settings' {
        { New-TestSettings -Override @{ EmailTo = @('ops@contoso.com') } } | Should -Throw '*EmailFrom is required*'
        { New-TestSettings -Override @{ EmailTo = @('not-an-address'); EmailFrom = 'rings@contoso.com' } } | Should -Throw '*not a valid email*'
        { New-TestSettings -Override @{ EmailTo = @('ops@contoso.com'); EmailFrom = 'rings' } } | Should -Throw '*not a valid email*'
        { New-TestSettings -Override @{ EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com'; EmailNotifyOn = @('Never') } } | Should -Throw '*EmailNotifyOn*'
        $s = New-TestSettings -Override @{ EmailTo = @('ops@contoso.com', 'secops@contoso.com'); EmailFrom = 'rings@contoso.com' }
        $s.EmailEnabled | Should -BeTrue
        $s.EmailNotifyOn -join ',' | Should -Be 'Failed,BlockedByChangeLimit,CompletedWithErrors,CertificateExpiring'
        (Get-RingRequiredScopes -Settings $s) | Should -Contain 'Mail.Send'
        (Get-RingRequiredScopes -Settings (New-TestSettings)) | Should -Not -Contain 'Mail.Send'
    }

    It 'decides email and Teams independently' {
        $s = New-TestSettings -Override @{ EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com'; EmailNotifyOn = @('Success') }
        Test-RingShouldNotify -Settings $s -Result 'Success' -Channel Email | Should -BeTrue
        Test-RingShouldNotify -Settings $s -Result 'Failed' -Channel Email | Should -BeFalse
        Test-RingShouldNotify -Settings $s -Result 'Success' -Channel Teams | Should -BeFalse
    }

    It 'HTML-encodes everything and contains no user data' {
        $changes = @([pscustomobject]@{ Action = 'Add'; Reason = 'NewAssignment'; UserPrincipalName = 'secret.person@contoso.com'; UserId = 'uid-77' })
        $m = Get-RingEmailMessage -Summary (New-Sum2 'CompletedWithErrors') -Changes $changes
        $m.Subject | Should -Be '[EntraDeploymentRings] Completed with errors - SG-<Test>&Co'
        $m.Html | Should -Not -Match '<script>'
        $m.Html | Should -Match '&lt;script&gt;'
        $m.Html | Should -Match 'SG-&lt;Test&gt;&amp;Co'
        $m.Html | Should -Match 'Add: NewAssignment'
        $m.Html | Should -Not -Match 'secret\.person'
        $m.Html | Should -Not -Match 'uid-77'
    }
}

Describe 'Configuration files and schema' {
    BeforeAll {
        $script:RepoRoot   = Join-Path $PSScriptRoot '..'
        $script:SchemaFile = Join-Path $script:RepoRoot 'config' 'EntraDeploymentRings.schema.json'
        $script:Schema     = Get-Content $script:SchemaFile -Raw | ConvertFrom-Json -AsHashtable
        $script:ScriptPath = Join-Path $script:RepoRoot 'Invoke-EntraDeploymentRings.ps1'
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $script:ParamNames = @((Get-Command $script:ScriptPath).Parameters.Keys | Where-Object { $_ -notin $common })
        $script:NotAllowed = 'ClientSecret', 'Rebalance', 'InitialRun', 'Preflight', 'CreateGroupsOnly', 'ConfigPath'
        $script:ConfigFiles = @(Get-ChildItem (Join-Path $script:RepoRoot 'config') -Recurse -Filter '*.json' | Where-Object Name -ne 'EntraDeploymentRings.schema.json')
        function Test-AgainstSchema([string] $Json) { Test-Json -Json $Json -SchemaFile $script:SchemaFile -ErrorAction SilentlyContinue }
    }

    It 'describes every script parameter' {
        $props = @($script:Schema.properties.Keys)
        $missing = @($script:ParamNames | Where-Object { $_ -notin $props })
        $missing -join ',' | Should -BeNullOrEmpty
        $extra = @($props | Where-Object { $_ -notin $script:ParamNames })
        $extra -join ',' | Should -BeNullOrEmpty
    }

    It 'marks keys the script rejects as not allowed' {
        foreach ($k in $script:NotAllowed) { $script:Schema.properties[$k].ContainsKey('not') | Should -BeTrue }
    }

    It 'uses the same notification values as the script' {
        $scriptValues = (Get-Command $script:ScriptPath).Parameters['TeamsNotifyOn'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues
        ($script:Schema.properties.TeamsNotifyOn.items.enum -join ',') | Should -Be ($scriptValues -join ',')
        ($script:Schema.properties.EmailNotifyOn.items.enum -join ',') | Should -Be ($scriptValues -join ',')
    }

    It 'finds the bundled configs' {
        $script:ConfigFiles.Count | Should -BeGreaterOrEqual 4
    }

    It 'validates every bundled config against the schema AND the script' {
        foreach ($f in $script:ConfigFiles) {
            Test-AgainstSchema (Get-Content $f.FullName -Raw) | Should -BeTrue -Because $f.Name
            $v = Read-RingConfigFile -Path $f.FullName -AllowedNames ($script:ParamNames | Where-Object { $_ -notin 'ConfigPath', 'ClientSecret' })
            { ConvertTo-RingSettings -Values $v 3>$null } | Should -Not -Throw -Because $f.Name
        }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown key';              Json = '{ "GroupNameBase": "X", "RingCount": 2, "RingCont": 3 }' }
        @{ Case = 'Certificate auth without a thumbprint'; Json = '{ "GroupNameBase": "X", "RingCount": 2, "AuthMode": "Certificate", "TenantId": "t", "ClientId": "11111111-1111-1111-1111-111111111111" }' }
        @{ Case = 'EmailTo without EmailFrom';   Json = '{ "GroupNameBase": "X", "RingCount": 2, "EmailTo": ["a@b.com"] }' }
        @{ Case = 'a client secret';             Json = '{ "GroupNameBase": "X", "RingCount": 2, "ClientSecret": "x" }' }
        @{ Case = 'Rebalance';                   Json = '{ "GroupNameBase": "X", "RingCount": 2, "Rebalance": true }' }
        @{ Case = 'CreateGroupsOnly';            Json = '{ "GroupNameBase": "X", "RingCount": 2, "CreateGroupsOnly": true }' }
        @{ Case = 'an invalid notify value';     Json = '{ "GroupNameBase": "X", "RingCount": 2, "TeamsNotifyOn": ["Sometimes"] }' }
        @{ Case = 'an http webhook';             Json = '{ "GroupNameBase": "X", "RingCount": 2, "TeamsWebhookUrl": "http://x" }' }
        @{ Case = 'half the Log Analytics pair'; Json = '{ "GroupNameBase": "X", "RingCount": 2, "LogDcrImmutableId": "dcr-1" }' }
        @{ Case = 'a non-GUID exclusion group';  Json = '{ "GroupNameBase": "X", "RingCount": 2, "ExcludeGroupIds": ["nope"] }' }
        @{ Case = 'a missing GroupNameBase';     Json = '{ "RingCount": 2 }' }
    ) {
        Test-AgainstSchema $Json | Should -BeFalse
    }

    It 'keeps docs/Examples.md and config/examples in sync' {
        $md = Get-Content (Join-Path $script:RepoRoot 'docs' 'Examples.md') -Raw
        # \r?\n: Windows checkouts convert line endings to CRLF.
        $blocks = @([regex]::Matches($md, '(?s)```json\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_.Trim().StartsWith('{') })
        $files = 'healthcare.json', 'small-org.json', 'single-department.json'
        $blocks.Count | Should -BeGreaterOrEqual $files.Count -Because 'docs/Examples.md should contain one JSON block per example config'
        for ($i = 0; $i -lt $files.Count; $i++) {
            $fromDoc  = $blocks[$i] | ConvertFrom-Json -AsHashtable
            $fromFile = Get-Content (Join-Path $script:RepoRoot 'config' 'examples' $files[$i]) -Raw | ConvertFrom-Json -AsHashtable
            $fromFile.Remove('$schema')
            ($fromFile | ConvertTo-Json -Depth 5 -Compress) | Should -Be ($fromDoc | ConvertTo-Json -Depth 5 -Compress) -Because $files[$i]
        }
    }
}

Describe 'Certificate expiry' {
    BeforeAll {
        function New-TestCert([int] $DaysFromNow, [int] $StartDaysFromNow = -30) {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=edr-exp', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays($StartDaysFromNow), [DateTimeOffset]::UtcNow.AddDays($DaysFromNow))
        }
    }

    It 'classifies <Name>' -ForEach @(
        @{ Name = 'a long-lived certificate as Valid';     Days = 200; Start = -30; Warn = 30; Expected = 'Valid' }
        @{ Name = 'a certificate inside the window as Expiring'; Days = 10; Start = -30; Warn = 30; Expected = 'Expiring' }
        @{ Name = 'an expired certificate as Expired';      Days = -2;  Start = -60; Warn = 30; Expected = 'Expired' }
        @{ Name = 'a future certificate as NotYetValid';    Days = 60;  Start = 5;   Warn = 30; Expected = 'NotYetValid' }
        @{ Name = 'expiring as Valid when the warning is off'; Days = 10; Start = -30; Warn = 0; Expected = 'Valid' }
    ) {
        $c = New-TestCert -DaysFromNow $Days -StartDaysFromNow $Start
        (Get-RingCertificateStatus -Certificate $c -WarningDays $Warn).Status | Should -Be $Expected
    }

    It 'validates CertificateExpiryWarningDays' {
        { New-TestSettings -Override @{ CertificateExpiryWarningDays = -1 } } | Should -Throw '*CertificateExpiryWarningDays*'
        { New-TestSettings -Override @{ CertificateExpiryWarningDays = 400 } } | Should -Throw '*CertificateExpiryWarningDays*'
        (New-TestSettings).CertificateExpiryWarningDays | Should -Be 30
    }

    It 'notifies a successful run when the certificate is expiring (default), but not a preview' {
        $s = New-TestSettings -Override @{ TeamsWebhookUrl = 'https://x.logic.azure.com/w' }
        Test-RingShouldNotify -Settings $s -Result 'Success' -CertificateWarning $true -Channel Teams | Should -BeTrue
        Test-RingShouldNotify -Settings $s -Result 'Success' -CertificateWarning $false -Channel Teams | Should -BeFalse
        Test-RingShouldNotify -Settings $s -Result 'WhatIf' -IsWhatIf $true -CertificateWarning $true -Channel Teams | Should -BeFalse
        $s2 = New-TestSettings -Override @{ TeamsWebhookUrl = 'https://x.logic.azure.com/w'; TeamsNotifyOn = @('Failed') }
        Test-RingShouldNotify -Settings $s2 -Result 'Success' -CertificateWarning $true -Channel Teams | Should -BeFalse
    }

    It 'puts the warning in the Teams card and the email subject' {
        $sum = [pscustomobject]@{ RunId = 'r'; ScriptRevision = '1.0'; RingSet = 'SG-Test'; Mode = 'Live'; Result = 'Success'; ErrorMessage = $null
            EndTime = '2026-10-26T01:00:00Z'; PlannedAdds = 0; PlannedRemoves = 0; Failed = 0; Conflicts = 0; ScopedUsers = 10
            ChangePercent = 0; ChangeBaseline = 10; ChangeLimitReason = 'NoChanges'; RetiredRingGroups = @(); DurationSeconds = 1
            ReportPath = $null; Distribution = @(); CertificateWarning = $true; CertificateDaysLeft = 12; CertificateExpires = '2026-11-07T00:00:00Z' }
        (Get-RingTeamsPayload -Summary $sum | ConvertTo-Json -Depth 20) | Should -Match 'expires in 12 day'
        (Get-RingEmailMessage -Summary $sum).Subject | Should -Match 'certificate expires in 12 day'
    }

    It 'warns and notifies on a certificate run, and stops on an expired certificate' {
        Initialize-FakeTenant -Count 30
        $global:TeamsPosts = [System.Collections.Generic.List[object]]::new()
        function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $Headers, $ErrorAction) $global:TeamsPosts.Add([System.Text.Encoding]::UTF8.GetString($Body)) }
        function Connect-MgGraph { }
        $script:TestCert = New-TestCert -DaysFromNow 10
        function Get-RingCertificate { param($Thumbprint) $script:TestCert }
        $cfg = @{ AuthMode = 'Certificate'; TenantId = 'contoso.onmicrosoft.com'; ClientId = '11111111-1111-1111-1111-111111111111'
                  CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'; TeamsWebhookUrl = 'https://x.logic.azure.com/w' }
        $r = Invoke-TestSync -Override $cfg
        $r.Result | Should -Be 'Success'
        $r.CertificateWarning | Should -BeTrue
        $r.CertificateDaysLeft | Should -BeLessOrEqual 10
        $r.Notification | Should -Be 'Sent'
        $global:TeamsPosts[0] | Should -Match 'expires in'
        (Get-Content ($r.ReportFiles | Where-Object { $_ -like '*.json' }) -Raw | ConvertFrom-Json).CertificateWarning | Should -BeTrue

        $script:TestCert = New-TestCert -DaysFromNow -1 -StartDaysFromNow -60
        $global:TeamsPosts.Clear()
        { Invoke-TestSync -Override $cfg } | Should -Throw '*expired on*'
        $global:TeamsPosts.Count | Should -Be 1
        $global:TeamsPosts[0] | Should -Match 'Run failed'
        Remove-Item function:Invoke-RestMethod, function:Connect-MgGraph, function:Get-RingCertificate
    }
}

Describe 'Certificate expiry by email' {
    BeforeAll {
        function New-TestCert2([int] $DaysFromNow, [int] $StartDaysFromNow = -30) {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=edr-mail', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays($StartDaysFromNow), [DateTimeOffset]::UtcNow.AddDays($DaysFromNow))
        }
        $script:MailCfg = @{ AuthMode = 'Certificate'; TenantId = 'contoso.onmicrosoft.com'; ClientId = '11111111-1111-1111-1111-111111111111'
                             CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'; EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com' }
    }

    It 'emails the advance warning while the certificate still works' {
        Initialize-FakeTenant -Count 30
        function Connect-MgGraph { }
        $script:MailCert = New-TestCert2 -DaysFromNow 10
        function Get-RingCertificate { param($Thumbprint) $script:MailCert }
        $global:Fake.Mail.Clear()
        $r = Invoke-TestSync -Override $script:MailCfg
        $r.Result | Should -Be 'Success'
        $r.EmailNotification | Should -Be 'Sent'
        $global:Fake.Mail.Count | Should -Be 1
        $global:Fake.Mail[0].Message.subject | Should -Match 'certificate expires in'
        Remove-Item function:Connect-MgGraph, function:Get-RingCertificate
    }

    It 'never sends through a Graph session it did not open (expired certificate)' {
        # The emulator's Get-MgContext always reports a session: exactly the "someone else's
        # session left in this window" case. The run must not use it.
        function Connect-MgGraph { throw 'Connect-MgGraph must not be called with an expired certificate' }
        $script:MailCert = New-TestCert2 -DaysFromNow -1 -StartDaysFromNow -60
        function Get-RingCertificate { param($Thumbprint) $script:MailCert }
        $global:Fake.Mail.Clear()
        $before = Get-Date
        { Invoke-TestSync -Override $script:MailCfg } | Should -Throw '*expired on*'
        $global:Fake.Mail.Count | Should -Be 0
        $json = Get-ChildItem -Path $script:ReportRoot -Filter '*.json' -Recurse | Where-Object { $_.LastWriteTime -ge $before.AddSeconds(-1) } |
            Sort-Object LastWriteTime | Select-Object -Last 1
        $json | Should -Not -BeNullOrEmpty
        $summary = Get-Content $json.FullName -Raw | ConvertFrom-Json
        $summary.Result | Should -Be 'Failed'
        $summary.EmailNotification | Should -Be 'Failed'
        Remove-Item function:Connect-MgGraph, function:Get-RingCertificate
    }
}

Describe 'Preflight' {
    BeforeAll {
        $script:PfDir = Join-Path ([System.IO.Path]::GetTempPath()) ('edr-pf-' + [guid]::NewGuid().ToString('N'))
        function Invoke-TestPreflight([hashtable] $Override = @{}) {
            $o = @{ ReportDirectory = $script:PfDir }; foreach ($k in $Override.Keys) { $o[$k] = $Override[$k] }
            Invoke-RingPreflight -Settings (New-TestSettings -Override $o) -InformationAction SilentlyContinue -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 2>$null
        }
    }
    AfterAll { Remove-Item $script:PfDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'fails without creating anything when groups are missing' {
        Initialize-FakeTenant -Count 20
        $r = Invoke-TestPreflight -Override @{ CreateMissingGroups = $false }
        $r.Mode | Should -Be 'Preflight'
        $r.Result | Should -Be 'PreflightFailed'
        @($r.Checks | Where-Object { $_.Area -eq 'Groups' -and $_.Status -eq 'Fail' }).Count | Should -Be 7
        $global:Fake.Groups.Count | Should -Be 0
    }

    It 'warns instead of failing when -CreateMissingGroups would create them' {
        $r = Invoke-TestPreflight -Override @{ CreateMissingGroups = $true }
        $r.Result | Should -Be 'PreflightPassedWithWarnings'
        $global:Fake.Groups.Count | Should -Be 0
    }

    It 'passes on a healthy ring set, changes no membership, and skips the write test' {
        Invoke-TestSync | Out-Null
        $before = (Get-FakeMembership).Count
        $r = Invoke-TestPreflight
        $r.Result | Should -Be 'PreflightPassed'
        $r.Failed | Should -Be 0
        ($r.Checks | Where-Object Check -eq 'Change membership').Status | Should -Be 'Skip'
        (Get-FakeMembership).Count | Should -Be $before
        Get-ChildItem $script:PfDir -Filter '.preflight-*' -Force | Should -BeNullOrEmpty
    }

    It 'names a missing exclusion group' {
        $r = Invoke-TestPreflight -Override @{ ExcludeGroupIds = @('99999999-9999-9999-9999-999999999999') }
        $c = $r.Checks | Where-Object Area -eq 'Scope'
        $c.Status | Should -Be 'Fail'
        $c.Detail | Should -Match '99999999-9999-9999-9999-999999999999.*ExcludeGroupIds'
    }

    It 'sends one test message per configured channel, with no user data' {
        $global:Posts = [System.Collections.Generic.List[object]]::new()
        function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $Headers, $ErrorAction) $global:Posts.Add([pscustomobject]@{ Uri = $Uri; Json = [System.Text.Encoding]::UTF8.GetString($Body) }) }
        function Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = 'tok' } }
        $global:Fake.Mail.Clear()
        $r = Invoke-TestPreflight -Override @{
            TeamsWebhookUrl = 'https://prod-1.westus.logic.azure.com/workflows/w'; EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com'
            LogIngestionEndpoint = 'https://dcr-x.westus2-1.ingest.monitor.azure.com'; LogDcrImmutableId = 'dcr-1' }
        $r.Result | Should -Be 'PreflightPassed'
        $teams = @($global:Posts | Where-Object { $_.Uri -like '*logic.azure.com*' })
        $la = @($global:Posts | Where-Object { $_.Uri -like '*ingest.monitor*' })
        $teams.Count | Should -Be 1
        $la.Count | Should -Be 1
        $global:Fake.Mail.Count | Should -Be 1
        $teams[0].Json | Should -Match 'Preflight passed'
        $teams[0].Json | Should -Not -Match '@contoso\.test'
        ($la[0].Json | ConvertFrom-Json).RecordType | Should -Be 'Preflight'
        $global:Fake.Mail[0].Message.subject | Should -Be '[EntraDeploymentRings] Preflight passed - SG-Test'
        Remove-Item function:Invoke-RestMethod, function:Get-AzAccessToken
    }

    It 'runs from the command line with -Preflight' {
        $script = Join-Path $PSScriptRoot '..' 'Invoke-EntraDeploymentRings.ps1'
        $r = & $script -GroupNameBase 'SG-Test' -RingCount 4 -RingWeights 5, 15, 30, 50 -AuthMode ExistingConnection -SkipReport -Preflight -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.Mode | Should -Be 'Preflight'
        $r.Result | Should -Be 'PreflightPassed'
    }
}

Describe 'GitHub rulesets' {
    BeforeAll {
        $script:GhDir = Join-Path $PSScriptRoot '..' '.github'
        $script:MainRuleset = Get-Content (Join-Path $script:GhDir 'rulesets' 'main-branch.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:TagRuleset  = Get-Content (Join-Path $script:GhDir 'rulesets' 'release-tags.json') -Raw | ConvertFrom-Json -AsHashtable

        # Status check names GitHub reports for ci.yml: "<job>" or "<job> (<matrix value>)".
        function Get-CiCheckName {
            $lines = Get-Content (Join-Path $script:GhDir 'workflows' 'ci.yml')
            $names = [System.Collections.Generic.List[string]]::new()
            $inJobs = $false; $job = $null
            foreach ($line in $lines) {
                if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
                if (-not $inJobs) { continue }
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $job = $Matches[1]; $names.Add($job); continue }
                if ($job -and $line -match '^\s+os:\s*\[(.+)\]\s*$') {
                    $names.Remove($job) | Out-Null
                    foreach ($os in $Matches[1].Split(',')) { $names.Add("$job ($($os.Trim()))") }
                }
            }
            return , $names.ToArray()
        }
    }

    It 'requires exactly the checks that ci.yml produces' {
        $required = @($script:MainRuleset.rules | Where-Object { $_.type -eq 'required_status_checks' } | ForEach-Object { $_.parameters.required_status_checks.context })
        $fromCi = Get-CiCheckName
        ($required | Sort-Object) -join '|' | Should -Be (($fromCi | Sort-Object) -join '|')
    }

    It 'protects the default branch without a bypass and without self-approval lockout' {
        $script:MainRuleset.target | Should -Be 'branch'
        $script:MainRuleset.enforcement | Should -Be 'active'
        $script:MainRuleset.conditions.ref_name.include | Should -Contain '~DEFAULT_BRANCH'
        @($script:MainRuleset.bypass_actors).Count | Should -Be 0
        $types = @($script:MainRuleset.rules.type)
        foreach ($t in 'deletion', 'non_fast_forward', 'pull_request', 'required_status_checks') { $types | Should -Contain $t }
        $pr = ($script:MainRuleset.rules | Where-Object { $_.type -eq 'pull_request' }).parameters
        $pr.required_approving_review_count | Should -Be 0
        $pr.require_code_owner_review | Should -BeFalse
    }

    It 'lets only repository admins create, move or delete v* tags' {
        $script:TagRuleset.target | Should -Be 'tag'
        $script:TagRuleset.conditions.ref_name.include | Should -Contain 'refs/tags/v*'
        $types = @($script:TagRuleset.rules.type)
        foreach ($t in 'creation', 'update', 'deletion') { $types | Should -Contain $t }
        $bypass = @($script:TagRuleset.bypass_actors)
        $bypass.Count | Should -Be 1
        $bypass[0].actor_type | Should -Be 'RepositoryRole'
        $bypass[0].actor_id | Should -Be 5
    }

    It 'uses a tag pattern the release workflow triggers on' {
        (Get-Content (Join-Path $script:GhDir 'workflows' 'release.yml') -Raw) | Should -Match "tags:\s*\['v\*'\]"
    }
}

Describe 'Get-RingClientAssertion' {
    It 'produces an RS256 JWT that verifies with the certificate public key' {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=edr-test', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
        $jwt = Get-RingClientAssertion -Certificate $cert -ClientId 'client-1' -Audience 'https://login.microsoftonline.com/t/oauth2/v2.0/token'
        $parts = $jwt.Split('.')
        $parts.Count | Should -Be 3
        $fromB64Url = { param($s) $s = $s.Replace('-', '+').Replace('_', '/'); switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }; [Convert]::FromBase64String($s) }
        $header = [System.Text.Encoding]::UTF8.GetString((& $fromB64Url $parts[0])) | ConvertFrom-Json
        $payload = [System.Text.Encoding]::UTF8.GetString((& $fromB64Url $parts[1])) | ConvertFrom-Json
        $header.alg | Should -Be 'RS256'
        $payload.iss | Should -Be 'client-1'
        $payload.sub | Should -Be 'client-1'
        $ok = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert).VerifyData([System.Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"), (& $fromB64Url $parts[2]), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $ok | Should -BeTrue
    }
}

Describe 'Create groups only' {
    It 'implies CreateMissingGroups and turns off the sign-in rule''s permission' {
        $s = New-TestSettings -Override @{ CreateGroupsOnly = $true; CreateMissingGroups = $false }
        $s.CreateGroupsOnly | Should -BeTrue
        $s.CreateMissingGroups | Should -BeTrue
        $s.NeedsSignInActivity | Should -BeFalse
    }

    It 'refuses to combine with <Other>' -ForEach @(
        @{ Other = 'InitialRun' }
        @{ Other = 'Rebalance' }
        @{ Other = 'Preflight' }
        @{ Other = 'RetireOrphanRings' }
    ) {
        { New-TestSettings -Override @{ CreateGroupsOnly = $true; $Other = $true } } | Should -Throw "*can't be combined with -$Other*"
    }

    It 'asks only for group permissions' {
        $s = New-TestSettings -Override @{ CreateGroupsOnly = $true }
        Get-RingRequiredScopes -Settings $s | Should -Be 'Group.ReadWrite.All'
        $m = New-TestSettings -Override @{ CreateGroupsOnly = $true; EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com' }
        (Get-RingRequiredScopes -Settings $m) -join ',' | Should -Be 'Group.ReadWrite.All,Mail.Send'
    }

    It 'checks the token for create and read permissions only' {
        $s = New-TestSettings -Override @{ CreateGroupsOnly = $true }
        try {
            $global:Fake.Context.Scopes = @('Group.ReadWrite.All')
            (Get-RingMissingPermission -Settings $s).Count | Should -Be 0
            $global:Fake.Context.Scopes = @('Group.Create')
            Get-RingMissingPermission -Settings $s | Should -Match 'group read permission'
            $global:Fake.Context.Scopes = @('Group.Create', 'GroupMember.Read.All')
            (Get-RingMissingPermission -Settings $s).Count | Should -Be 0
            $global:Fake.Context.Scopes = @('User.Read.All', 'GroupMember.ReadWrite.All', 'AuditLog.Read.All')
            Get-RingMissingPermission -Settings $s | Should -Match 'Group\.Create \(app or managed identity\) or Group\.ReadWrite\.All \(signed-in user\)'
        }
        finally { Reset-FakeGraph }
    }

    It 'shows the groups created, not change counts, in Teams and email' {
        $sum = [pscustomobject]@{ RunId = 'r'; ScriptRevision = '1.0'; RingSet = 'SG-Test'; Mode = 'Live'; Result = 'Success'; ErrorMessage = $null
            EndTime = '2026-11-01T01:00:00Z'; PlannedAdds = 0; PlannedRemoves = 0; Failed = 0; Conflicts = 0; ScopedUsers = 0
            ChangePercent = 0; ChangeBaseline = 0; ChangeLimitReason = $null; RetiredRingGroups = @(); DurationSeconds = 1
            ReportPath = $null; Distribution = @(); CreateGroupsOnly = $true; GroupsCreated = @('SG-Test-First', 'SG-Test-Ring01') }
        $card = Get-RingTeamsPayload -Summary $sum | ConvertTo-Json -Depth 20
        $card | Should -Match 'create-groups-only run'
        $card | Should -Match 'SG-Test-First, SG-Test-Ring01'
        $card | Should -Not -Match 'Users in scope'
        $html = (Get-RingEmailMessage -Summary $sum).Html
        $html | Should -Match 'Create groups only'
        $html | Should -Match 'SG-Test-First, SG-Test-Ring01'
        $html | Should -Not -Match 'Users in scope'
    }

    It 'previews with -WhatIf without creating anything' {
        Initialize-FakeTenant -Count 30
        $r = Invoke-TestSync -Override @{ CreateGroupsOnly = $true } -WhatIf
        $r.Result | Should -Be 'WhatIf'
        @($r.GroupsCreated).Count | Should -Be 7
        $global:Fake.Groups.Count | Should -Be 0
    }

    It 'creates every ring group with nothing but group permissions, reads no users and adds no members' {
        Initialize-FakeTenant -Count 30
        $global:Fake.Context.Scopes = @('Group.ReadWrite.All')
        $global:Fake.Deny.Add('^GET users$')                 # proves no user is read
        $global:Fake.Calls.Clear()
        $r = Invoke-TestSync -Override @{ CreateGroupsOnly = $true }
        $r.Result | Should -Be 'Success'
        $r.CreateGroupsOnly | Should -BeTrue
        @($r.GroupsCreated).Count | Should -Be 7
        $r.ScopedUsers | Should -Be 0
        $r.PlannedAdds | Should -Be 0
        foreach ($g in $global:Fake.Groups.Values) {
            $g.Members.Count | Should -Be 0
            $g.description | Should -Match '\[EntraDeploymentRings:SG-Test:\w+\]'
        }
        @($global:Fake.Calls | Where-Object { $_ -match '^GET .*\busers\b' }).Count | Should -Be 0
        @($global:Fake.Calls | Where-Object { $_ -match '\$batch' }).Count | Should -Be 0
        (Get-Content ($r.ReportFiles | Where-Object { $_ -like '*.json' }) -Raw | ConvertFrom-Json).CreateGroupsOnly | Should -BeTrue
        Reset-FakeGraph
    }

    It 'works for an app with only Group.Create and GroupMember.ReadWrite.All' {
        Initialize-FakeTenant -Count 20
        $global:Fake.Context.Scopes = @('Group.Create', 'GroupMember.ReadWrite.All')
        $global:Fake.Deny.Add('^GET users$')
        $out = Invoke-DeploymentRingSync -Settings (New-TestSettings -Override @{ CreateGroupsOnly = $true }) -InformationAction SilentlyContinue -WarningAction Continue 3>&1
        $r = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] })[-1]
        $r.Result | Should -Be 'Success'
        @($r.GroupsCreated).Count | Should -Be 7
        @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'missing Graph permission' }).Count | Should -Be 0
        Reset-FakeGraph
    }

    It 'leaves existing groups and their members alone, and the next normal run fills the rings' {
        Initialize-FakeTenant -Count 40
        Invoke-TestSync -Override @{ CreateGroupsOnly = $true } | Out-Null
        $first = Get-FakeGroupByName 'SG-Test-First'
        $pilot = @($global:Fake.Users.Keys)[0]
        [void]$first.Members.Add($pilot)

        $again = Invoke-TestSync -Override @{ CreateGroupsOnly = $true }
        $again.Result | Should -Be 'Success'
        @($again.GroupsCreated).Count | Should -Be 0
        $global:Fake.Groups.Count | Should -Be 7
        $first.Members.Count | Should -Be 1

        $fill = Invoke-TestSync -Override @{ CreateMissingGroups = $false }
        $fill.Result | Should -Be 'Success'
        $fill.ChangeLimitReason | Should -Be 'InitialPopulation'
        foreach ($id in (Get-ExpectedScopedIds)) { (Get-FakeMembership)[$id].Count | Should -Be 1 }
        $first.Members.Contains($pilot) | Should -BeTrue
    }

    It 'still refuses a same-named group without the marker' {
        Initialize-FakeTenant -Count 10
        Add-FakeGroup -DisplayName 'SG-Test-Ring02' -Description 'someone else''s group' | Out-Null
        { Invoke-TestSync -Override @{ CreateGroupsOnly = $true } } | Should -Throw '*marker*'
        $global:Fake.Groups.Count | Should -Be 1
    }

    It 'runs from the command line with -CreateGroupsOnly' {
        Initialize-FakeTenant -Count 10
        $script = Join-Path $PSScriptRoot '..' 'Invoke-EntraDeploymentRings.ps1'
        $r = & $script -GroupNameBase 'SG-Cli' -RingCount 2 -AuthMode ExistingConnection -SkipReport -CreateGroupsOnly -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.Result | Should -Be 'Success'
        @($r.GroupsCreated).Count | Should -Be 5
    }
}

Describe 'Network test' {
    BeforeAll {
        function New-NetCert([int] $DaysFromNow = 200) {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=edr-net', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-30), [DateTimeOffset]::UtcNow.AddDays($DaysFromNow))
        }
        $script:NetCert = @{ AuthMode = 'Certificate'; TenantId = 'contoso.onmicrosoft.com'; ClientId = '11111111-1111-1111-1111-111111111111'
                             CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567' }
        $script:NetHook = 'https://prod-00.westus.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sig=SECRET-SIG-NET'
        function Get-LatestSummary([datetime] $Since) {
            $f = Get-ChildItem $script:ReportRoot -Filter '*.summary.json' | Where-Object { $_.LastWriteTime -ge $Since.AddSeconds(-1) } | Sort-Object LastWriteTime | Select-Object -Last 1
            Get-Content $f.FullName -Raw | ConvertFrom-Json
        }
    }

    It 'tests every endpoint the run needs first, logs host names only, and records them in the JSON' {
        Initialize-FakeTenant -Count 20
        $out = Invoke-DeploymentRingSync -Settings (New-TestSettings -Override @{ TeamsWebhookUrl = $script:NetHook }) -InformationAction Continue -WarningAction SilentlyContinue 6>&1
        $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $summary = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] })[-1]
        $iNet = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match 'Testing network access to 2 endpoint\(s\)' })
        $iSign = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match 'Signing in to Microsoft Graph \(the session already open in this window\)' })
        $iNet | Should -BeGreaterOrEqual 0
        $iSign | Should -BeGreaterThan $iNet
        @($lines | Where-Object { $_ -match 'OK      Microsoft Graph \(graph\.microsoft\.com\) - HTTP 404 in 12 ms, direct' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'OK      Teams webhook host \(prod-00\.westus\.logic\.azure\.com\)' }).Count | Should -Be 1
        ($lines -join "`n") | Should -Not -Match 'SECRET-SIG-NET|/workflows/'
        @($global:Fake.Probes) | Should -Be @('graph.microsoft.com', 'prod-00.westus.logic.azure.com')
        $summary.Result | Should -Be 'Success'
        @($summary.Network).Count | Should -Be 2
        ($summary.Network | ConvertTo-Json -Depth 5) | Should -Not -Match 'SECRET-SIG-NET'
    }

    It 'tests Entra sign-in for certificate auth, and stops before signing in when it can''t be reached' {
        Initialize-FakeTenant -Count 20
        $script:NetCertObj = New-NetCert
        function Get-RingCertificate { param($Thumbprint) $script:NetCertObj }
        function Connect-MgGraph { throw 'Connect-MgGraph must not be called when the network test fails' }
        $global:Fake.Network['login.microsoftonline.com'] = @{ Error = 'no response within 15 s'; Proxy = 'http://proxy.contoso.com:8080' }
        $before = Get-Date
        try {
            { Invoke-TestSync -Override $script:NetCert } | Should -Throw '*Network test failed*'
            $s = Get-LatestSummary $before
            $s.ErrorMessage | Should -Match "nothing was changed\. Can't reach Microsoft Entra sign-in \(login\.microsoftonline\.com\): no response within 15 s"
            $s.ErrorMessage | Should -Match 'sends HTTPS through http://proxy\.contoso\.com:8080'
            $s.ErrorMessage | Should -Match 'outbound HTTPS \(443\) to login\.microsoftonline\.com, graph\.microsoft\.com'
            @($global:Fake.Calls).Count | Should -Be 0
            $global:Fake.Groups.Count | Should -Be 0
        }
        finally { Remove-Item function:Get-RingCertificate, function:Connect-MgGraph }
    }

    It 'stops before any Graph call when Graph can''t be reached' {
        Initialize-FakeTenant -Count 20
        $global:Fake.Network['graph.microsoft.com'] = @{ Error = 'the proxy answered HTTP 502 (it couldn''t reach the endpoint, or blocks it)'; Proxy = 'http://proxy.contoso.com:8080' }
        { Invoke-TestSync } | Should -Throw "*Can't reach Microsoft Graph (graph.microsoft.com): the proxy answered HTTP 502*"
        @($global:Fake.Calls).Count | Should -Be 0
    }

    It 'only warns when an optional endpoint can''t be reached' {
        Initialize-FakeTenant -Count 20
        $global:Fake.Network['prod-00.westus.logic.azure.com'] = @{ Error = 'no response within 15 s'; Proxy = $null }
        $out = Invoke-DeploymentRingSync -Settings (New-TestSettings -Override @{ TeamsWebhookUrl = $script:NetHook }) -InformationAction SilentlyContinue -WarningAction Continue 3>&1
        $summary = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] })[-1]
        $summary.Result | Should -Be 'Success'
        @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'FAILED \(optional\) Teams webhook host' }).Count | Should -Be 1
    }

    It 'logs the sign-in and explains a failure with the whole inner error chain' {
        Initialize-FakeTenant -Count 20
        $script:NetCertObj = New-NetCert
        function Get-RingCertificate { param($Thumbprint) $script:NetCertObj }
        function Connect-MgGraph { throw [System.Exception]::new('ClientCertificateCredential authentication failed: ', [System.Threading.Tasks.TaskCanceledException]::new('A task was canceled.')) }
        $before = Get-Date
        try {
            $out = $null
            { $script:SignOut = Invoke-DeploymentRingSync -Settings (New-TestSettings -Override $script:NetCert) -InformationAction Continue -WarningAction SilentlyContinue 6>&1 } | Should -Throw '*Sign-in to Microsoft Graph failed after * s (Certificate): Exception: ClientCertificateCredential authentication failed: -> TaskCanceledException: A task was canceled.*'
            (Get-LatestSummary $before).ErrorMessage | Should -Match 'TaskCanceledException: A task was canceled'
            @($global:Fake.Calls).Count | Should -Be 0
        }
        finally { Remove-Item function:Get-RingCertificate, function:Connect-MgGraph }
    }

    It 'describes the sign-in it is about to make' {
        Get-RingSignInDescription -Settings (New-TestSettings -Override $script:NetCert) | Should -Be 'certificate, app 11111111-1111-1111-1111-111111111111, tenant contoso.onmicrosoft.com'
        Get-RingSignInDescription -Settings (New-TestSettings -Override @{ AuthMode = 'ManagedIdentity' }) | Should -Be 'system-assigned managed identity'
    }

    It 'shows network checks in preflight, and skips sign-in when a required endpoint fails' {
        Initialize-FakeTenant -Count 20
        $global:Fake.Network['graph.microsoft.com'] = @{ Error = 'no response within 15 s'; Proxy = $null }
        $r = Invoke-RingPreflight -Settings (New-TestSettings -Override @{ SkipReport = $true }) -InformationAction SilentlyContinue -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 2>$null
        $r.Result | Should -Be 'PreflightFailed'
        ($r.Checks | Where-Object { $_.Area -eq 'Network' -and $_.Check -eq 'Microsoft Graph' }).Status | Should -Be 'Fail'
        ($r.Checks | Where-Object { $_.Area -eq 'Sign-in' -and $_.Check -eq 'Microsoft Graph' }).Status | Should -Be 'Skip'
    }

    It 'reports an endpoint that refuses the connection as unreachable (real probe)' {
        $saved = $global:EntraDeploymentRingsNetworkProbe
        $global:EntraDeploymentRingsNetworkProbe = $null
        try {
            $p = Invoke-RingHttpProbe -Uri 'https://127.0.0.1:9/' -TimeoutSeconds 5
            $p.Reachable | Should -BeFalse
            $p.Error | Should -Not -BeNullOrEmpty
        }
        finally { $global:EntraDeploymentRingsNetworkProbe = $saved }
    }

    It 'joins every message in an exception chain, naming empty ones by type' {
        $ex = [System.Exception]::new('outer', [System.AggregateException]::new([System.TimeoutException]::new('slow')))
        Get-RingExceptionChain $ex | Should -Match '^Exception: outer -> AggregateException: .* -> TimeoutException: slow$'
    }
}

Describe 'Access-denied explanations' {
    BeforeAll {
        function New-Session([string[]] $Scopes, [bool] $Delegated = $false) {
            [pscustomobject]@{ Delegated = $Delegated; ClientId = '11111111-1111-1111-1111-111111111111'; AppName = 'EntraDeploymentRings'
                               TenantId = '22222222-2222-2222-2222-222222222222'; Scopes = $Scopes }
        }
        $script:Denied = [pscustomobject]@{ Code = 'Authorization_RequestDenied'; Message = 'Insufficient privileges to complete the operation.'
                                            RequestId = '11111111-2222-3333-4444-555555555555'; Date = '2026-01-15T12:00:00' }
        $script:ListUri = 'v1.0/groups?$filter=startswith%28displayName%2C%27SG-Deploy-Users-Ring%27%29&$select=id,displayName,description'
    }

    It 'knows what <Method> <Uri> needs' -ForEach @(
        @{ Method = 'GET';    Uri = 'v1.0/groups?$filter=displayName%20eq%20%27X%27';           Op = 'listing groups';            Grant = 'GroupMember.ReadWrite.All' }
        @{ Method = 'GET';    Uri = 'v1.0/groups/g1/transitiveMembers?$select=id';             Op = 'reading group membership';  Grant = 'GroupMember.ReadWrite.All' }
        @{ Method = 'GET';    Uri = 'v1.0/groups/g1?$select=id,displayName';                   Op = 'reading a group';           Grant = 'GroupMember.ReadWrite.All' }
        @{ Method = 'POST';   Uri = 'v1.0/groups';                                             Op = 'creating a group';          Grant = 'Group.Create' }
        @{ Method = 'PATCH';  Uri = '/groups/g1';                                              Op = 'changing group membership'; Grant = 'GroupMember.ReadWrite.All' }
        @{ Method = 'DELETE'; Uri = '/groups/g1/members/u1/$ref';                              Op = 'changing group membership'; Grant = 'GroupMember.ReadWrite.All' }
        @{ Method = 'GET';    Uri = 'v1.0/users?$select=id,accountEnabled&$top=999';            Op = 'reading users';             Grant = 'User.Read.All' }
        @{ Method = 'POST';   Uri = 'v1.0/users/rings%40contoso.com/sendMail';                 Op = 'sending email';             Grant = 'Mail.Send' }
    ) {
        $h = Get-RingGraphPermissionHint -Method $Method -Uri $Uri
        $h.Operation | Should -Be $Op
        $h.Requires[0].AnyOf[0] | Should -Be $Grant
    }

    It 'adds AuditLog.Read.All when sign-in activity is read' {
        $h = Get-RingGraphPermissionHint -Method GET -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,signInActivity&$top=120'
        $h.Operation | Should -Be 'reading users and their sign-in activity'
        @($h.Requires).Count | Should -Be 2
        $h.Requires[1].AnyOf | Should -Be 'AuditLog.Read.All'
    }

    It 'shows the request decoded, without the host or API version' {
        (Get-RingGraphPermissionHint -Method GET -Uri "https://graph.microsoft.com/$script:ListUri").Path |
            Should -Be "/groups?`$filter=startswith(displayName,'SG-Deploy-Users-Ring')&`$select=id,displayName,description"
    }

    It 'reads the code, message and request-id from the SDK error text' {
        $raw = "GET`nhttps://graph.microsoft.com/$script:ListUri HTTP/2.0 403 Forbidden Cache-Control: no-cache request-id: 11111111-2222-3333-4444-555555555555 Content-Type: application/json  " +
               '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation.","innerError":{"date":"2026-01-15T12:00:00","request-id":"11111111-2222-3333-4444-555555555555","client-request-id":"66666666-7777-8888-9999-000000000000"}}}'
        $er = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($raw), 'x', 'PermissionDenied', $null)
        $d = Get-RingGraphErrorDetail -ErrorRecord $er
        $d.Code | Should -Be 'Authorization_RequestDenied'
        $d.Message | Should -Be 'Insufficient privileges to complete the operation.'
        $d.RequestId | Should -Be '11111111-2222-3333-4444-555555555555'
        $d.Date | Should -Be '2026-01-15T12:00:00'
        (Get-GraphErrorStatus -ErrorRecord $er).Status | Should -Be 403
    }

    It 'tells an app to grant the missing permission and consent to it' {
        $m = Get-RingGraphAccessDeniedMessage -Method GET -Uri $script:ListUri -Detail $script:Denied -Purpose 'looking for ring groups' -Session (New-Session @('User.Read.All', 'AuditLog.Read.All'))
        $m | Should -Match 'refused access \(403 Authorization_RequestDenied\) while listing groups \(looking for ring groups\)'
        $m | Should -Match ([regex]::Escape("Request:    GET /groups?`$filter=startswith(displayName,'SG-Deploy-Users-Ring')"))
        $m | Should -Match 'Needs:      one of GroupMember\.ReadWrite\.All, GroupMember\.Read\.All'
        $m | Should -Match "Signed in:  app 'EntraDeploymentRings' 11111111-1111-1111-1111-111111111111 \(application permissions\) in tenant 22222222"
        $m | Should -Match 'Token has:  AuditLog\.Read\.All, User\.Read\.All'
        $m | Should -Match 'Fix:        Grant GroupMember\.ReadWrite\.All as an Application permission .* Grant admin consent'
        $m | Should -Match 'request-id: 11111111-2222-3333-4444-555555555555, 2026-01-15T12:00:00 UTC'
    }

    It 'suggests GroupMember.Read.All when the app already has GroupMember.ReadWrite.All' {
        $m = Get-RingGraphAccessDeniedMessage -Method GET -Uri $script:ListUri -Detail $script:Denied -Session (New-Session @('User.Read.All', 'GroupMember.ReadWrite.All'))
        $m | Should -Match 'The token has GroupMember\.ReadWrite\.All, which normally allows this'
        $m | Should -Match 'also grant GroupMember\.Read\.All'
    }

    It 'points at role-assignable groups when a membership change is refused despite the permission' {
        $m = Get-RingGraphAccessDeniedMessage -Method PATCH -Uri 'groups/g1' -Detail $script:Denied -Session (New-Session @('GroupMember.ReadWrite.All'))
        $m | Should -Match 'role-assignable'
    }

    It 'names the directory role for a delegated sign-in, and never the account' {
        $global:Fake.Context.AuthType = 'Delegated'
        $global:Fake.Context.Account = 'admin.person@contoso.com'
        $global:Fake.Context.Scopes = @('User.Read.All', 'GroupMember.ReadWrite.All', 'AuditLog.Read.All')
        try {
            $m = Get-RingGraphAccessDeniedMessage -Method PATCH -Uri 'groups/g1' -Detail $script:Denied
            $m | Should -Match 'a signed-in user \(delegated permissions\)'
            $m | Should -Match 'needs Groups Administrator'
            $m | Should -Match 'PIM'
            $m | Should -Not -Match 'admin\.person'
            Get-RingGraphAccessDeniedMessage -Method GET -Uri 'v1.0/users?$select=id,signInActivity' -Detail $script:Denied | Should -Match 'Reports Reader'
        }
        finally { Reset-FakeGraph }
    }

    It 'asks a delegated user to consent when the token lacks the scope' {
        $m = Get-RingGraphAccessDeniedMessage -Method GET -Uri $script:ListUri -Detail $script:Denied -Session (New-Session @('User.Read.All') -Delegated $true)
        $m | Should -Match "doesn't include GroupMember\.ReadWrite\.All\. Sign in again and consent"
    }

    It 'explains a missing Entra ID P1/P2 licence' {
        $d = [pscustomobject]@{ Code = 'Authentication_RequestFromNonPremiumTenantOrB2CTenant'; Message = 'Neither tenant is B2C or tenant doesn''t have premium license'; RequestId = $null; Date = $null }
        $m = Get-RingGraphAccessDeniedMessage -Method GET -Uri 'v1.0/users?$select=id,signInActivity' -Detail $d -Session (New-Session @('User.Read.All', 'AuditLog.Read.All'))
        $m | Should -Match 'P1 or P2'
        $m | Should -Match 'InactiveSignInDays to 0'
    }

    It 'says so when the token does not list its permissions' {
        $m = Get-RingGraphAccessDeniedMessage -Method GET -Uri $script:ListUri -Detail $script:Denied -Session (New-Session $null)
        $m | Should -Match 'does not list its permissions'
        $m | Should -Match 'granted GroupMember\.ReadWrite\.All'
    }

    It 'tells an app to use Group.Create, not Group.ReadWrite.All, to create groups' {
        $m = Get-RingGraphAccessDeniedMessage -Method POST -Uri 'v1.0/groups' -Detail $script:Denied -Session (New-Session @('GroupMember.ReadWrite.All'))
        $m | Should -Match 'Needs:      one of Group\.Create, Group\.ReadWrite\.All'
        $m | Should -Match 'Grant Group\.Create as an Application permission'
        $m | Should -Match 'not Group\.ReadWrite\.All'
    }

    It 'tells a signed-in user to consent to Group.ReadWrite.All, because Group.Create is application-only' {
        $m = Get-RingGraphAccessDeniedMessage -Method POST -Uri 'v1.0/groups' -Detail $script:Denied -Session (New-Session @('GroupMember.ReadWrite.All') -Delegated $true)
        $m | Should -Match "doesn't include Group\.ReadWrite\.All \(Group\.Create is not available to a signed-in user\)"
    }

    It 'treats a 401 as a rejected token' {
        Get-RingGraphAccessDeniedMessage -Method GET -Uri $script:ListUri -Status 401 -Session (New-Session @('GroupMember.ReadWrite.All')) | Should -Match 'Sign in again'
    }
}

Describe 'Access denied end to end' {
    AfterAll { Reset-FakeGraph }

    It 'stops with an explained error when listing groups is refused, and records it in the JSON' {
        Initialize-FakeTenant -Count 40
        $global:Fake.Context.Scopes = @('User.Read.All', 'AuditLog.Read.All')
        $global:Fake.Deny.Add('^GET groups$')
        $before = Get-Date
        $err = $null
        try { Invoke-TestSync | Out-Null } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $m = $err.Exception.Message
        $m | Should -Match "while listing groups \(looking for ring groups above RingCount, whose names start with 'SG-Test-Ring'\)"
        $m | Should -Match ([regex]::Escape("GET /groups?`$filter=startswith(displayName,'SG-Test-Ring')"))
        $m | Should -Match 'Token has:  AuditLog\.Read\.All, User\.Read\.All'
        $m | Should -Match 'Grant GroupMember\.ReadWrite\.All'
        $m | Should -Match 'request-id: 00000000-0000-0000-0000-0000000000aa'
        $m | Should -Not -Match '%27'
        (Get-GraphErrorStatus -ErrorRecord $err).Status | Should -Be 403
        $global:Fake.Groups.Count | Should -Be 0
        $json = Get-ChildItem $script:ReportRoot -Filter '*.summary.json' | Where-Object { $_.LastWriteTime -ge $before.AddSeconds(-1) } | Sort-Object LastWriteTime | Select-Object -Last 1
        (Get-Content $json.FullName -Raw | ConvertFrom-Json).ErrorMessage | Should -Match 'Grant GroupMember\.ReadWrite\.All'
    }

    It 'explains refused membership changes in one warning per group, with no user names' {
        Initialize-FakeTenant -Count 40
        Invoke-TestSync | Out-Null
        $rng = [System.Random]::new(5)
        1..3 | ForEach-Object { Add-FakeUser -Id (New-FakeGuid -Rng $rng) -Upn "denied$_@contoso.test" }
        $global:Fake.Deny.Add('^(PATCH|POST|DELETE) groups/')
        $out = Invoke-DeploymentRingSync -Settings (New-TestSettings) -InformationAction SilentlyContinue -WarningAction Continue 3>&1
        $summary = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] })[-1]
        $summary.Result | Should -Be 'CompletedWithErrors'
        $summary.Failed | Should -Be 3
        $warn = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -match 'refused access' } | ForEach-Object Message)
        $warn.Count | Should -BeGreaterOrEqual 1
        foreach ($w in $warn) {
            $w | Should -Match "while changing group membership \(\d+ change\(s\) to 'SG-Test-Ring0\d' refused\)"
            $w | Should -Match 'GroupMember\.ReadWrite\.All'
            $w | Should -Not -Match 'denied\d@contoso\.test'
        }
        $rows = Import-Csv $summary.ReportPath | Where-Object Result -eq 'Failed'
        @($rows).Count | Should -Be 3
        $rows.ErrorMessage | Select-Object -Unique | Should -Match '^403: Authorization_RequestDenied'
    }

    It 'names the missing permission in the preflight group checks' {
        Initialize-FakeTenant -Count 40
        $global:Fake.Context.Scopes = @('User.Read.All', 'AuditLog.Read.All')
        $global:Fake.Deny.Add('^GET groups$')
        $r = Invoke-RingPreflight -Settings (New-TestSettings -Override @{ SkipReport = $true }) -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $r.Result | Should -Be 'PreflightFailed'
        ($r.Checks | Where-Object Check -eq 'Graph permissions').Detail | Should -Match 'GroupMember\.ReadWrite\.All'
        $g = @($r.Checks | Where-Object { $_.Area -eq 'Groups' -and $_.Status -eq 'Fail' })[0]
        $g.Detail | Should -Match 'looking up ring group .SG-Test-First.'
        $g.Detail | Should -Match 'Grant GroupMember\.ReadWrite\.All'
    }
}

Describe 'End-to-end against emulated Graph' {
    BeforeAll { Initialize-FakeTenant }

    It 'stops before changing anything when groups are missing and creation is not allowed' {
        { Invoke-TestSync -Override @{ CreateMissingGroups = $false } } | Should -Throw '*CreateMissingGroups*'
        $global:Fake.Groups.Count | Should -Be 0
    }

    It 'does not create the rest of the set when only some groups exist' {
        $id = Add-FakeGroup -DisplayName 'SG-Test-First' -Description (Get-RingGroupDescription -Base 'SG-Test' -Key 'First')
        { Invoke-TestSync -Override @{ CreateMissingGroups = $false } } | Should -Throw '*SG-Test-Ring01*'
        $global:Fake.Groups.Count | Should -Be 1
        $global:Fake.Groups.Remove($id)
    }

    It 'previews the first run with -WhatIf without creating anything' {
        $r = Invoke-TestSync -WhatIf
        $r.Result | Should -Be 'WhatIf'
        $global:Fake.Groups.Count | Should -Be 0
        $r.PlannedAdds | Should -BeGreaterThan 0
        $csv = Import-Csv $r.ReportPath
        ($csv | Where-Object RecordType -eq 'Change').Result | Select-Object -Unique | Should -Be 'WhatIf'
    }

    It 'creates all groups and places every in-scope user in exactly one ring' {
        $r = Invoke-TestSync
        $r.Result | Should -Be 'Success'
        $r.ChangeLimitReason | Should -Be 'InitialPopulation'
        $names = $global:Fake.Groups.Values.displayName
        foreach ($n in 'SG-Test-First', 'SG-Test-Ring01', 'SG-Test-Ring02', 'SG-Test-Ring03', 'SG-Test-Ring04', 'SG-Test-Last', 'SG-Test-Inactive') { $names | Should -Contain $n }

        $membership = Get-FakeMembership
        $scoped = Get-ExpectedScopedIds
        foreach ($id in $scoped) { $membership[$id].Count | Should -Be 1 }
        $membership.Keys.Count | Should -Be $scoped.Count

        $membership['aaaaaaaa-0000-0000-0000-000000000001'] | Should -BeNullOrEmpty   # guest
        $membership['aaaaaaaa-0000-0000-0000-000000000002'] | Should -Be 'SG-Test-Inactive'   # disabled
        $membership['aaaaaaaa-0000-0000-0000-000000000003'] | Should -Be 'SG-Test-Inactive'   # Former
        $membership['aaaaaaaa-0000-0000-0000-000000000004'] | Should -Be 'SG-Test-Inactive'   # stale sign-in
        $membership['aaaaaaaa-0000-0000-0000-000000000005'] | Should -Be 'SG-Test-Inactive'   # never signed in, old
        $membership['aaaaaaaa-0000-0000-0000-000000000006'] | Should -Not -Be 'SG-Test-Inactive' # never signed in, new
    }

    It 'stamps the marker tag on every group' {
        foreach ($g in $global:Fake.Groups.Values) { $g.description | Should -Match '\[EntraDeploymentRings:SG-Test:\w+\]' }
    }

    It 'is idempotent: a second run makes no changes' {
        $r = Invoke-TestSync
        $r.PlannedAdds | Should -Be 0
        $r.PlannedRemoves | Should -Be 0
        $r.Result | Should -Be 'Success'
    }

    It 'keeps a manually relocated user where they are (sticky)' {
        $r1 = (Get-FakeGroupByName 'SG-Test-Ring01'); $r3 = (Get-FakeGroupByName 'SG-Test-Ring03')
        $id = @($r1.Members)[0]
        [void]$r1.Members.Remove($id); [void]$r3.Members.Add($id)
        $r = Invoke-TestSync
        $r.PlannedAdds + $r.PlannedRemoves | Should -Be 0
        $r3.Members.Contains($id) | Should -BeTrue
    }

    It 'places only new users and leaves existing users alone' {
        $before = Get-FakeMembership
        $rng = [System.Random]::new(99)
        $newIds = 1..30 | ForEach-Object { $id = New-FakeGuid -Rng $rng; Add-FakeUser -Id $id -Upn "new$_@contoso.test"; $id }
        $r = Invoke-TestSync
        $r.PlannedAdds | Should -Be 30
        $r.PlannedRemoves | Should -Be 0
        $after = Get-FakeMembership
        foreach ($k in $before.Keys) { $after[$k][0] | Should -Be $before[$k][0] }
        foreach ($id in $newIds) { $after[$id].Count | Should -Be 1 }
    }

    It 'removes a user from computed rings when an admin adds them to First' {
        $first = Get-FakeGroupByName 'SG-Test-First'
        $r2 = Get-FakeGroupByName 'SG-Test-Ring02'
        $id = @($r2.Members)[0]
        [void]$first.Members.Add($id)
        $r = Invoke-TestSync
        $r.PlannedRemoves | Should -Be 1
        $r2.Members.Contains($id) | Should -BeFalse
        $first.Members.Contains($id) | Should -BeTrue
        $script:FirstUser = $id
    }

    It 'honours First membership through a nested group' {
        $first = Get-FakeGroupByName 'SG-Test-First'
        $nested = Add-FakeGroup -DisplayName 'Pilot Team'
        $r4 = Get-FakeGroupByName 'SG-Test-Ring04'
        $id = @($r4.Members)[0]
        [void]$global:Fake.Groups[$nested].Members.Add($id)
        $first.Nested.Add($nested)
        Invoke-TestSync | Out-Null
        $r4.Members.Contains($id) | Should -BeFalse
    }

    It 'moves a user to Inactive and back to their original ring' {
        $r1 = Get-FakeGroupByName 'SG-Test-Ring01'
        $id = @($r1.Members)[0]
        $global:Fake.Users[$id].companyName = 'Former'
        Invoke-TestSync | Out-Null
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Inactive'

        $global:Fake.Users[$id].companyName = 'Contoso'
        Invoke-TestSync | Out-Null
        $s = New-TestSettings
        $expected = 'SG-Test-' + (Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $id -Weights $s.RingWeights))
        (Get-FakeMembership)[$id] | Should -Be $expected
    }

    It 'survives throttling on batch sub-requests' {
        $rng = [System.Random]::new(123)
        $id = New-FakeGuid -Rng $rng
        Add-FakeUser -Id $id -Upn 'throttled@contoso.test'
        $s = New-TestSettings
        $ring = Get-FakeGroupByName ('SG-Test-' + (Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $id -Weights $s.RingWeights)))
        [void]$global:Fake.ThrottleOnce.Add("PATCH /groups/$($ring.id)")
        $r = Invoke-TestSync
        $r.Failed | Should -Be 0
        $ring.Members.Contains($id) | Should -BeTrue
    }

    It 'trips the circuit breaker and changes nothing when too many users vanish' {
        $victims = @(Get-ExpectedScopedIds) | Select-Object -First 300
        foreach ($v in $victims) { $global:Fake.Users[$v].accountEnabled = $false }
        $before = Get-FakeMembership
        { Invoke-TestSync } | Should -Throw '*MaxChangePercent*'
        $after = Get-FakeMembership
        $after.Keys.Count | Should -Be $before.Keys.Count
        foreach ($v in $victims) { $global:Fake.Users[$v].accountEnabled = $true }
    }

    It 'moves a renamed .former user into Inactive and back out when renamed again' {
        $r2 = Get-FakeGroupByName 'SG-Test-Ring02'
        $id = @($r2.Members)[0]
        $old = $global:Fake.Users[$id].userPrincipalName
        $global:Fake.Users[$id].userPrincipalName = 'leaver.former@contoso.test'
        $r = Invoke-TestSync -Override @{ InactiveUpnPatterns = @('{user}.former@{domain}') }
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Inactive'
        (Import-Csv $r.ReportPath | Where-Object { $_.UserId -eq $id -and $_.Action -eq 'Add' }).Reason | Should -Be 'Inactive:UpnPattern:{user}.former@{domain}'
        $global:Fake.Users[$id].userPrincipalName = $old
        Invoke-TestSync -Override @{ InactiveUpnPatterns = @('{user}.former@{domain}') } | Out-Null
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Ring02'
    }

    It 'moves a disabled user to Inactive and back to their ring when re-enabled' {
        $r3 = Get-FakeGroupByName 'SG-Test-Ring03'
        $id = @($r3.Members)[0]
        $global:Fake.Users[$id].accountEnabled = $false
        $r = Invoke-TestSync
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Inactive'
        (Import-Csv $r.ReportPath | Where-Object { $_.UserId -eq $id -and $_.Action -eq 'Add' }).Reason | Should -Be 'Inactive:Disabled'
        $global:Fake.Users[$id].accountEnabled = $true
        Invoke-TestSync | Out-Null
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Ring03'
    }

    It 'moves an offboarded user (employeeType Former) to Inactive instead of dropping them' {
        $r2 = Get-FakeGroupByName 'SG-Test-Ring02'
        $a = @($r2.Members)[0]; $b = @($r2.Members)[1]
        $global:Fake.Users[$a].employeeType = 'Former'                                      # offboarded, still enabled
        $global:Fake.Users[$b].employeeType = 'Former'; $global:Fake.Users[$b].accountEnabled = $false   # offboarded and disabled
        $r = Invoke-TestSync
        $m = Get-FakeMembership
        $m[$a] | Should -Be 'SG-Test-Inactive'
        $m[$b] | Should -Be 'SG-Test-Inactive'
        $rows = Import-Csv $r.ReportPath | Where-Object Action -eq 'Add'
        ($rows | Where-Object UserId -eq $a).Reason | Should -Be 'Inactive:EmployeeType:Former'
        ($rows | Where-Object UserId -eq $b).Reason | Should -Be 'Inactive:Disabled'
        foreach ($id in $a, $b) { $global:Fake.Users[$id].employeeType = 'Employee'; $global:Fake.Users[$id].accountEnabled = $true }
        Invoke-TestSync | Out-Null
    }

    It 'excludes disabled users and filters them server-side with DisabledUserAction Exclude' {
        $id = @((Get-FakeGroupByName 'SG-Test-Ring04').Members)[0]
        $global:Fake.Users[$id].accountEnabled = $false
        $global:Fake.Calls.Clear()
        $r = Invoke-TestSync -Override @{ DisabledUserAction = 'Exclude' }
        (Get-FakeMembership)[$id] | Should -BeNullOrEmpty
        @($global:Fake.Calls | Where-Object { $_ -like '*accountEnabled*' }).Count | Should -BeGreaterThan 0
        $global:Fake.Users[$id].accountEnabled = $true
        Invoke-TestSync | Out-Null
        (Get-FakeMembership)[$id] | Should -Be 'SG-Test-Ring04'
    }

    It 'removes users matching an excluded UPN pattern and records why' {
        $r1 = Get-FakeGroupByName 'SG-Test-Ring01'
        $id = @($r1.Members)[0]
        $old = $global:Fake.Users[$id].userPrincipalName
        $global:Fake.Users[$id].userPrincipalName = 'svc-reporting@contoso.test'
        $r = Invoke-TestSync -Override @{ ExcludeUpnPatterns = @('{user}.former@{domain}', 'SVC-{user}@{domain}') }
        $r.ExcludedByReason['UpnPattern'] | Should -Be 1
        (Get-FakeMembership)[$id] | Should -BeNullOrEmpty
        $row = Import-Csv $r.ReportPath | Where-Object { $_.UserId -eq $id }
        $row.Reason | Should -Be 'OutOfScope:UpnPattern:SVC-{user}@{domain}'
        $global:Fake.Users[$id].userPrincipalName = $old
        Invoke-TestSync | Out-Null
        (Get-FakeMembership)[$id].Count | Should -Be 1
    }

    It 'InitialRun re-seeds a skewed ring set without tripping the change limit' {
        # Pile everyone from Ring02-04 into Ring01, as a hand-populated set might look.
        $r1 = Get-FakeGroupByName 'SG-Test-Ring01'
        foreach ($n in 'SG-Test-Ring02', 'SG-Test-Ring03', 'SG-Test-Ring04') {
            $g = Get-FakeGroupByName $n
            foreach ($m in @($g.Members)) { [void]$r1.Members.Add($m) }
            $g.Members.Clear()
        }
        $normal = Invoke-TestSync -WhatIf
        $normal.PlannedAdds + $normal.PlannedRemoves | Should -Be 0     # sticky: a normal run leaves the skew alone

        $r = Invoke-TestSync -Override @{ InitialRun = $true }
        $r.Result | Should -Be 'Success'
        $r.ChangeLimitReason | Should -Be 'InitialRun'
        $r.InitialRun | Should -BeTrue
        $s = New-TestSettings
        $membership = Get-FakeMembership
        foreach ($k in $s.RingKeys) {
            $g = Get-FakeGroupByName "SG-Test-$k"
            foreach ($m in $g.Members) { $k | Should -Be (Get-RingKey (Get-HashRingIndex -Seed $s.HashSeed -ObjectId $m -Weights $s.RingWeights)) }
        }
        foreach ($id in (Get-ExpectedScopedIds)) { $membership[$id].Count | Should -Be 1 }
    }

    It 'Rebalance re-seeds without tripping the change limit and runs fine without CreateMissingGroups' {
        $r1 = Get-FakeGroupByName 'SG-Test-Ring01'
        $r4 = Get-FakeGroupByName 'SG-Test-Ring04'
        foreach ($m in @($r4.Members)) { [void]$r1.Members.Add($m) }
        $r4.Members.Clear()
        $r = Invoke-TestSync -Override @{ Rebalance = $true; CreateMissingGroups = $false }
        $r.Result | Should -Be 'Success'
        $r.ChangeLimitReason | Should -Be 'Rebalance'
        $r4.Members.Count | Should -BeGreaterThan 0
    }

    It 'stops when RingCount is reduced, and retires the orphan ring on request' {
        { Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60) } } | Should -Throw '*RetireOrphanRings*'
        $r = Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60); RetireOrphanRings = $true; BypassChangeLimit = $true }
        $r.Result | Should -Be 'Success'
        (Get-FakeGroupByName 'SG-Test-Ring04').Members.Count | Should -Be 0
        foreach ($id in (Get-ExpectedScopedIds)) { (Get-FakeMembership)[$id].Count | Should -Be 1 }
    }

    It 'reports an excluded user in First with the group name, and never removes them' {
        $first = Get-FakeGroupByName 'SG-Test-First'
        $id = 'bbbbbbbb-0000-0000-0000-000000000001'
        Add-FakeUser -Id $id -Upn 'svc-backup@contoso.test'
        [void]$first.Members.Add($id)
        $r = Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60); ExcludeUpnPatterns = @('SVC-{user}@{domain}') }
        $row = Import-Csv $r.ReportPath | Where-Object { $_.UserId -eq $id -and $_.RecordType -eq 'Conflict' }
        $row.Reason | Should -Be 'ExcludedUserInManualRing'
        $row.GroupName | Should -Be 'SG-Test-First'
        $row.RingKey | Should -Be 'First'
        $row.UserPrincipalName | Should -Be 'svc-backup@contoso.test'
        $first.Members.Contains($id) | Should -BeTrue
        [void]$first.Members.Remove($id); $global:Fake.Users.Remove($id)
    }

    It 'names both groups when a user is in First and Last' {
        $id = @((Get-FakeGroupByName 'SG-Test-Ring01').Members)[0]
        [void](Get-FakeGroupByName 'SG-Test-First').Members.Add($id); [void](Get-FakeGroupByName 'SG-Test-Last').Members.Add($id)
        $r = Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60) }
        (Import-Csv $r.ReportPath | Where-Object Reason -eq 'InFirstAndLast').GroupName | Should -Be 'SG-Test-First; SG-Test-Last'
        [void](Get-FakeGroupByName 'SG-Test-First').Members.Remove($id); [void](Get-FakeGroupByName 'SG-Test-Last').Members.Remove($id)
        Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60) } | Out-Null
    }

    It 'logs exclusion groups by name, and stops with a named error when one is missing' {
        $gid = Add-FakeGroup -DisplayName 'Break Glass Accounts'
        $r = Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60); ExcludeGroupIds = @($gid) }
        $r.ExclusionGroups[0].DisplayName | Should -Be 'Break Glass Accounts'
        $global:Fake.Groups.Remove($gid)
        { Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60); ExcludeGroupIds = @($gid) } } | Should -Throw "*$gid*ExcludeGroupIds*"
    }

    It 'keeps running normally after an orphan ring was emptied' {
        $r = Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60) }
        $r.Result | Should -Be 'Success'
        $r.RetiredRingGroups | Should -Be 'SG-Test-Ring04'
        (Get-FakeGroupByName 'SG-Test-Ring04').Members.Count | Should -Be 0
    }

    It 'still stops when an orphan ring regains members' {
        $id = @((Get-FakeGroupByName 'SG-Test-Ring01').Members)[0]
        [void](Get-FakeGroupByName 'SG-Test-Ring04').Members.Add($id)
        { Invoke-TestSync -Override @{ RingCount = 3; RingWeights = @(10, 30, 60) } } | Should -Throw '*still have members*'
        [void](Get-FakeGroupByName 'SG-Test-Ring04').Members.Remove($id)
    }

    It 'refuses to manage a same-named group that lacks the marker' {
        Reset-FakeGraph
        Add-FakeGroup -DisplayName 'SG-Test-Ring01' -Description 'someone else''s group' | Out-Null
        { Invoke-TestSync } | Should -Throw '*marker*'
    }

    It 'honours ReportFormat and ReportRetentionDays in a full run' {
        Initialize-FakeTenant -Count 50
        $old = Join-Path $script:ReportRoot 'EntraDeploymentRings_SG-Test_20200101-000000_00000000.csv'
        'x' | Set-Content $old
        (Get-Item $old).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-400)
        $r = Invoke-TestSync -Override @{ ReportFormat = 'Json'; ReportRetentionDays = 30 }
        $r.ReportPath | Should -BeLike '*.summary.json'
        $r.ReportFiles.Count | Should -Be 1
        $r.ReportsPruned | Should -BeGreaterOrEqual 1
        Test-Path $old | Should -BeFalse
        (Get-Content $r.ReportPath -Raw | ConvertFrom-Json).RunId | Should -Be $r.RunId
    }

    It 'writes the JSON summary last, with its own file list and statuses' {
        Initialize-FakeTenant -Count 40
        $r = Invoke-TestSync
        $jsonPath = $r.ReportFiles | Where-Object { $_ -like '*.summary.json' }
        $j = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $j.ReportPath | Should -Be $r.ReportPath
        @($j.ReportFiles).Count | Should -Be 2
        @($j.ReportFiles) | Should -Contain $jsonPath
        $j.Notification | Should -Be 'NotConfigured'
        $j.LogAnalytics | Should -Be 'NotConfigured'
        (Get-Item $jsonPath).LastWriteTimeUtc | Should -BeGreaterOrEqual (Get-Item $r.ReportPath).LastWriteTimeUtc
    }

    It 'posts to Teams when a run is blocked, and records it in the JSON' {
        $global:TeamsPosts = [System.Collections.Generic.List[object]]::new()
        function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $Headers, $ErrorAction) $global:TeamsPosts.Add([pscustomobject]@{ Uri = $Uri; Body = [System.Text.Encoding]::UTF8.GetString($Body) }) }
        $hook = 'https://prod-00.westus.logic.azure.com/workflows/x/triggers/manual/paths/invoke?sig=SECRET-SIG-123'
        $victims = @(Get-ExpectedScopedIds) | Select-Object -First 25
        foreach ($v in $victims) { $global:Fake.Users[$v].employeeType = 'Vendor' }
        $info = $null
        { $script:blocked = Invoke-TestSync -Override @{ TeamsWebhookUrl = $hook; MaxChangeFloor = 5; MaxChangePercent = 1 } } | Should -Throw '*MaxChangePercent*'
        $global:TeamsPosts.Count | Should -Be 1
        $global:TeamsPosts[0].Uri | Should -Be $hook
        $global:TeamsPosts[0].Body | Should -Match 'Blocked by change limit'
        $global:TeamsPosts[0].Body | Should -Not -Match '@contoso\.test'
        $latestJson = Get-ChildItem (Join-Path $script:ReportRoot '*.summary.json') | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        (Get-Content $latestJson -Raw | ConvertFrom-Json).Notification | Should -Be 'Sent'
        foreach ($v in $victims) { $global:Fake.Users[$v].employeeType = 'Employee' }
        Remove-Item function:Invoke-RestMethod
    }

    It 'does not post on success by default, but does when Success is listed' {
        $global:TeamsPosts = [System.Collections.Generic.List[object]]::new()
        function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $Headers, $ErrorAction) $global:TeamsPosts.Add($Uri) }
        $hook = 'https://prod-00.westus.logic.azure.com/workflows/x/triggers/manual/paths/invoke?sig=S'
        $r = Invoke-TestSync -Override @{ TeamsWebhookUrl = $hook }
        $r.Result | Should -Be 'Success'
        $r.Notification | Should -Be 'NotRequested'
        $global:TeamsPosts.Count | Should -Be 0
        $r = Invoke-TestSync -Override @{ TeamsWebhookUrl = $hook; TeamsNotifyOn = @('Success') }
        $r.Notification | Should -Be 'Sent'
        $global:TeamsPosts.Count | Should -Be 1
        Remove-Item function:Invoke-RestMethod
    }

    It 'keeps the run successful when Teams fails, and never logs the URL' {
        function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $Headers, $ErrorAction) throw "Response status code does not indicate success: 400 (Bad Request). $Uri" }
        $hook = 'https://prod-00.westus.logic.azure.com/workflows/x/triggers/manual/paths/invoke?sig=SUPER-SECRET-SIG'
        $s = New-TestSettings -Override @{ TeamsWebhookUrl = $hook; TeamsNotifyOn = @('Success') }
        $out = Invoke-DeploymentRingSync -Settings $s -InformationAction Continue -WarningAction Continue *>&1
        $summary = $out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] } | Select-Object -Last 1
        $summary.Result | Should -Be 'Success'
        $summary.Notification | Should -Be 'Failed'
        ($out | ForEach-Object { "$_" }) -join "`n" | Should -Not -Match 'SUPER-SECRET-SIG'
        ($out | ForEach-Object { "$_" }) -join "`n" | Should -Match 'Could not send Teams notification'
        Get-ChildItem $script:ReportRoot -File | ForEach-Object { Get-Content $_.FullName -Raw } | Where-Object { $_ -match 'SUPER-SECRET-SIG' } | Should -BeNullOrEmpty
        Remove-Item function:Invoke-RestMethod
    }

    It 'emails a successful run when Success is listed, from the configured mailbox, without saving to Sent Items' {
        $global:Fake.Mail.Clear(); $global:Fake.MailFail = $null
        $mailCfg = @{ EmailTo = @('ops@contoso.com', 'secops@contoso.com'); EmailFrom = 'rings@contoso.com'; EmailNotifyOn = @('Success') }
        $r = Invoke-TestSync -Override $mailCfg
        $r.EmailNotification | Should -Be 'Sent'
        $global:Fake.Mail.Count | Should -Be 1
        $m = $global:Fake.Mail[0]
        $m.From | Should -Be 'rings@contoso.com'
        $m.Save | Should -BeFalse
        @($m.Message.toRecipients).Count | Should -Be 2
        $m.Message.body.contentType | Should -Be 'HTML'
        $m.Message.subject | Should -Be '[EntraDeploymentRings] Run succeeded - SG-Test'
        $m.Message.body.content | Should -Not -Match '@contoso\.test'
        (Get-Content ($r.ReportFiles | Where-Object { $_ -like '*.json' }) -Raw | ConvertFrom-Json).EmailNotification | Should -Be 'Sent'
    }

    It 'does not email a successful run by default' {
        $global:Fake.Mail.Clear()
        $r = Invoke-TestSync -Override @{ EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com' }
        $r.EmailNotification | Should -Be 'NotRequested'
        $global:Fake.Mail.Count | Should -Be 0
    }

    It 'keeps the run successful when sendMail is denied, with a helpful warning' {
        $global:Fake.Mail.Clear(); $global:Fake.MailFail = 403
        $s = New-TestSettings -Override @{ EmailTo = @('ops@contoso.com'); EmailFrom = 'rings@contoso.com'; EmailNotifyOn = @('Success') }
        $out = Invoke-DeploymentRingSync -Settings $s -InformationAction SilentlyContinue -WarningAction Continue 3>&1
        $summary = $out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] } | Select-Object -Last 1
        $summary.Result | Should -Be 'Success'
        $summary.EmailNotification | Should -Be 'Failed'
        (($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) -join "`n") | Should -Match 'Mail.Send'
        $global:Fake.MailFail = $null
    }

    It 'shows progress while reading users' {
        Initialize-FakeTenant -Count 450
        $saved = $script:UserProgressEvery; $script:UserProgressEvery = 50
        try {
            $out = Invoke-DeploymentRingSync -Settings (New-TestSettings) -InformationAction Continue -WarningAction SilentlyContinue 6>&1
            $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            @($lines | Where-Object { $_ -match 'Reading users from Microsoft Graph with sign-in activity \(Graph returns at most 120' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'user\(s\) read so far' }).Count | Should -Be 4      # pages of 100: at 100, 200, 300, 400
            @($lines | Where-Object { $_ -match '456 user\(s\) read so far' }).Count | Should -Be 0  # the last page passes 450, but the total line covers it
            @($lines | Where-Object { $_ -match 'Read 456 user\(s\) in \d+ s\.' }).Count | Should -Be 1
        }
        finally { $script:UserProgressEvery = $saved }
    }

    It 'reports progress while changing group membership, and stays quiet in a preview' {
        Initialize-FakeTenant -Count 450
        $saved = $script:ApplyProgressEvery; $script:ApplyProgressEvery = 50
        try {
            $preview = Invoke-DeploymentRingSync -Settings (New-TestSettings) -WhatIf -InformationAction Continue -WarningAction SilentlyContinue 6>&1
            @($preview | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and "$($_.MessageData)" -match 'Applying|change\(s\) applied' }).Count | Should -Be 0

            $out = Invoke-DeploymentRingSync -Settings (New-TestSettings) -InformationAction Continue -WarningAction SilentlyContinue 6>&1
            $summary = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['RunId'] })[-1]
            $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            $n = $summary.PlannedAdds
            $groups = @($summary.Distribution | Where-Object { $_.Members -gt 0 }).Count
            @($lines | Where-Object { $_ -match ("Applying {0:N0} change\(s\) to {1} group\(s\): removals first, then additions" -f $n, $groups) }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'SG-Test-Ring04: adding [\d,]+ user\(s\)\.\.\.' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'SG-Test-Ring04: [\d,]+ added, 0 failed \(\d+ s\)\.' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'change\(s\) applied \(\d+%' }).Count | Should -BeGreaterOrEqual 3   # about every 50; changes land in chunks of 20, so one chunk can pass two marks
            @($lines | Where-Object { $_ -match ("Applied {0:N0} change\(s\) in \d+ s: {0:N0} succeeded, 0 failed\." -f $n) }).Count | Should -Be 1
        }
        finally { $script:ApplyProgressEvery = $saved }
    }

    It 'reports reading the ring groups between sign-in and reading users' {
        Initialize-FakeTenant -Count 40
        Invoke-TestSync | Out-Null
        $nested = Add-FakeGroup -DisplayName 'Pilot Team'
        $uid = @((Get-FakeGroupByName 'SG-Test-Ring02').Members)[0]
        [void]$global:Fake.Groups[$nested].Members.Add($uid)
        (Get-FakeGroupByName 'SG-Test-First').Nested.Add($nested)
        $out = Invoke-DeploymentRingSync -Settings (New-TestSettings) -InformationAction Continue -WarningAction SilentlyContinue 6>&1
        $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $iSigned = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match 'Signed in \(' })
        $iGroups = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match 'Reading ring groups and their members\.\.\.' })
        $iUsers  = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match 'Reading users from Microsoft Graph' })
        $iGroups | Should -BeGreaterThan $iSigned
        $iUsers | Should -BeGreaterThan $iGroups
        @($lines | Where-Object { $_ -match 'Read 7 ring group\(s\) with [\d,]+ user member\(s\), including 1 through groups nested in First or Last in \d+ s\.' }).Count | Should -Be 1
    }

    It 'pages through large result sets' {
        Initialize-FakeTenant -Count 450
        $r = Invoke-TestSync
        $r.CandidateUsers | Should -Be 456    # 450 + 6 specials (disabled users are read too)
        @($global:Fake.Calls | Where-Object { $_ -like '*fakepage*' }).Count | Should -BeGreaterThan 3
    }
}
