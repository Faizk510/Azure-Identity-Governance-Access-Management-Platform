<#
.SYNOPSIS
    Identifies empty Microsoft Entra ID groups.

.DESCRIPTION
    Retrieves Microsoft Entra ID groups, checks whether each group has any
    direct members, and exports a report containing groups with zero members.

    This is a read-only health-check script. It does not modify groups,
    memberships, or Identity Governance configuration.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permission:
        Group.Read.All
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Output"
    ),

    [Parameter()]
    [switch]$SkipCsvExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-GraphConnection {
    $Context = Get-MgContext

    if (-not $Context) {
        throw @"
Microsoft Graph authentication is required.

Connect before running this script:

Connect-MgGraph -Scopes "Group.Read.All"
"@
    }

    Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
}

function Get-GroupCategory {
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    if ($Group.GroupTypes -contains "Unified") {
        return "Microsoft 365"
    }

    if ($Group.SecurityEnabled -eq $true) {
        return "Security"
    }

    if ($Group.MailEnabled -eq $true) {
        return "Distribution"
    }

    return "Other"
}

function Get-MembershipType {
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    if ($Group.GroupTypes -contains "DynamicMembership") {
        return "Dynamic"
    }

    return "Assigned"
}

try {
    Test-GraphConnection

    if (-not (Test-Path -Path $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    Write-Verbose "Retrieving Microsoft Entra ID groups."

    $Groups = @(
        Get-MgGroup `
            -All `
            -Property @(
                "id"
                "displayName"
                "description"
                "createdDateTime"
                "groupTypes"
                "mail"
                "mailEnabled"
                "securityEnabled"
                "isAssignableToRole"
                "visibility"
            ) `
            -ErrorAction Stop
    )

    Write-Host "Processing empty groups health check..." `
        -ForegroundColor Cyan
    Write-Host "Groups evaluated: $($Groups.Count)" `
        -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $GroupNumber = 1

    foreach ($Group in $Groups) {
        try {
            Write-Verbose (
                "Group $($GroupNumber): checking " +
                "'$($Group.DisplayName)'."
            )

            $FirstMember = @(
                Get-MgGroupMember `
                    -GroupId $Group.Id `
                    -Top 1 `
                    -ErrorAction Stop
            )

            if ($FirstMember.Count -eq 0) {
                $Results.Add(
                    [PSCustomObject]@{
                        Timestamp          = (Get-Date).ToString("o")
                        DisplayName        = $Group.DisplayName
                        GroupId            = $Group.Id
                        Description        = $Group.Description
                        GroupCategory      = Get-GroupCategory -Group $Group
                        MembershipType     = Get-MembershipType -Group $Group
                        SecurityEnabled    = $Group.SecurityEnabled
                        MailEnabled        = $Group.MailEnabled
                        IsAssignableToRole = $Group.IsAssignableToRole
                        Visibility         = $Group.Visibility
                        Mail               = $Group.Mail
                        CreatedDateTime     = $Group.CreatedDateTime
                        MemberCount        = 0
                        Status             = "Empty"
                    }
                )
            }
        }
        catch {
            $Results.Add(
                [PSCustomObject]@{
                    Timestamp          = (Get-Date).ToString("o")
                    DisplayName        = $Group.DisplayName
                    GroupId            = $Group.Id
                    Description        = $Group.Description
                    GroupCategory      = Get-GroupCategory -Group $Group
                    MembershipType     = Get-MembershipType -Group $Group
                    SecurityEnabled    = $Group.SecurityEnabled
                    MailEnabled        = $Group.MailEnabled
                    IsAssignableToRole = $Group.IsAssignableToRole
                    Visibility         = $Group.Visibility
                    Mail               = $Group.Mail
                    CreatedDateTime     = $Group.CreatedDateTime
                    MemberCount        = $null
                    Status             = "Check Failed"
                }
            )

            Write-Warning (
                "Could not evaluate group '$($Group.DisplayName)': " +
                $_.Exception.Message
            )
        }

        $GroupNumber++
    }

    $EmptyGroups = @(
        $Results |
            Where-Object Status -eq "Empty"
    )

    $FailedChecks = @(
        $Results |
            Where-Object Status -eq "Check Failed"
    )

    $AssignedEmptyCount = @(
        $EmptyGroups |
            Where-Object MembershipType -eq "Assigned"
    ).Count

    $DynamicEmptyCount = @(
        $EmptyGroups |
            Where-Object MembershipType -eq "Dynamic"
    ).Count

    $RoleAssignableEmptyCount = @(
        $EmptyGroups |
            Where-Object IsAssignableToRole -eq $true
    ).Count

    Write-Host ""
    Write-Host "Empty groups health check completed." `
        -ForegroundColor Green
    Write-Host "Total groups evaluated: $($Groups.Count)"
    Write-Host "Empty groups found: $($EmptyGroups.Count)"
    Write-Host "Assigned empty groups: $AssignedEmptyCount"
    Write-Host "Dynamic empty groups: $DynamicEmptyCount"
    Write-Host "Role-assignable empty groups: $RoleAssignableEmptyCount"
    Write-Host "Checks failed: $($FailedChecks.Count)"
    Write-Host ""

    if ($Results.Count -gt 0) {
        $Results |
            Sort-Object Status, DisplayName |
            Format-Table `
                DisplayName,
                GroupCategory,
                MembershipType,
                IsAssignableToRole,
                Status `
                -AutoSize
    }
    else {
        Write-Host "No empty groups were found."
    }

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-EmptyGroupsHealthCheck-$Timestamp.csv"

        $Results |
            Sort-Object Status, DisplayName |
            Export-Csv `
                -Path $ReportPath `
                -NoTypeInformation `
                -Encoding UTF8

        Write-Host ""
        Write-Host "Result report exported to:"
        Write-Host $ReportPath
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
