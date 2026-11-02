# PSScriptAnalyzerSettings.psd1
# Revision: 1.0
#
# REVISION HISTORY (most recent first)
# 1.0   2026-11-01  First public release.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Internal helpers such as Resolve-RingGroups and Get-RingRecords
        # return collections; plural nouns describe them more accurately.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.2')
        }
    }
}
