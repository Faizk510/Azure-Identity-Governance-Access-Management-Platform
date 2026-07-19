<#
.SYNOPSIS
    Generates a Microsoft Entra ID group-membership report.

.DESCRIPTION
    Reports direct or transitive membership for one group or all groups.

    Supported member types include users, groups, devices, service
    principals, and organizational contacts. Empty groups are represented
    clearly in the report rather than silently omitted.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permission:
        Directory.Read.All
#>

[CmdletBinding(DefaultParameterSetName = "AllGroups")]
param(
    [Parameter(
        Mandatory,
        ParameterSetName = "ByGroupId"
    )]
    [string]$GroupId,

    [Parameter(
        Mandatory,
        ParameterSetName = "ByGroupName"
    )]
    [string]$GroupName,

    [Parameter(ParameterSetName = "AllGroups")]
    [switch]$AllGroups,

    [Parameter()]
    [switch]$IncludeTransitiveMembers,

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

Connect before running this report:

Connect-MgGraph -Scopes "Directory.Read.All"
"@
    }

    Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
}

function Get-ObjectPropertyValue {
    param(
        [Parameter()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter()]
        [object]$DefaultValue = $null
    )

    if (-not $InputObject) {
        return $DefaultValue
    }

    $Property = $InputObject.PSObject.Properties[$PropertyName]

    if (-not $Property) {
        return $DefaultValue
    }

    return $Property.Value
}

function Invoke-GraphCollectionRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Results = [System.Collections.Generic.List[object]]::new()
    $NextLink = $Uri

    while (-not [string]::IsNullOrWhiteSpace($NextLink)) {
        $Response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $NextLink `
            -OutputType PSObject `
            -ErrorAction Stop

        if ($Response.PSObject.Properties.Name -contains "value") {
            foreach ($Item in @($Response.value)) {
                $Results.Add($Item)
            }
        }

        if (
            $Response.PSObject.Properties.Name -contains "@odata.nextLink"
        ) {
            $NextLink = $Response.'@odata.nextLink'
        }
        else {
            $NextLink = $null
        }
    }

    return $Results
}

function Get-EncodedODataString {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Get-GroupClassification {
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    $GroupTypes = @(
        Get-ObjectPropertyValue `
            -InputObject $Group `
            -PropertyName "groupTypes" `
            -DefaultValue @()
    )

    $MailEnabled = Get-ObjectPropertyValue `
        -InputObject $Group `
        -PropertyName "mailEnabled" `
        -DefaultValue $false

    $SecurityEnabled = Get-ObjectPropertyValue `
        -InputObject $Group `
        -PropertyName "securityEnabled" `
        -DefaultValue $false

    if ($GroupTypes -contains "Unified") {
        return "Microsoft 365"
    }

    if ($MailEnabled -and $SecurityEnabled) {
        return "Mail-Enabled Security"
    }

    if ($MailEnabled -and -not $SecurityEnabled) {
        return "Distribution"
    }

    if ($SecurityEnabled) {
        return "Security"
    }

    return "Other"
}

function Get-MembershipSource {
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    $GroupTypes = @(
        Get-ObjectPropertyValue `
            -InputObject $Group `
            -PropertyName "groupTypes" `
            -DefaultValue @()
    )

    if ($GroupTypes -contains "DynamicMembership") {
        return "Dynamic"
    }

    return "Assigned"
}

function Get-MemberType {
    param(
        [Parameter()]
        [object]$Member
    )

    $ODataType = Get-ObjectPropertyValue `
        -InputObject $Member `
        -PropertyName "@odata.type"

    switch ($ODataType) {
        "#microsoft.graph.user" {
            return "User"
        }

        "#microsoft.graph.group" {
            return "Group"
        }

        "#microsoft.graph.device" {
            return "Device"
        }

        "#microsoft.graph.servicePrincipal" {
            return "Service Principal"
        }

        "#microsoft.graph.orgContact" {
            return "Organizational Contact"
        }

        default {
            return "Unknown"
        }
    }
}

function Get-MemberIdentifier {
    param(
        [Parameter()]
        [object]$Member,

        [Parameter(Mandatory)]
        [string]$MemberType
    )

    switch ($MemberType) {
        "User" {
            return Get-ObjectPropertyValue `
                -InputObject $Member `
                -PropertyName "userPrincipalName"
        }

        "Group" {
            $Mail = Get-ObjectPropertyValue `
                -InputObject $Member `
                -PropertyName "mail"

            if ($Mail) {
                return $Mail
            }
        }

        "Device" {
            return Get-ObjectPropertyValue `
                -InputObject $Member `
                -PropertyName "deviceId"
        }

        "Service Principal" {
            return Get-ObjectPropertyValue `
                -InputObject $Member `
                -PropertyName "appId"
        }

        "Organizational Contact" {
            return Get-ObjectPropertyValue `
                -InputObject $Member `
                -PropertyName "mail"
        }
    }

    return Get-ObjectPropertyValue `
        -InputObject $Member `
        -PropertyName "id"
}

function Get-TargetGroups {
    $GroupSelect = @(
        "id"
        "displayName"
        "description"
        "mail"
        "mailNickname"
        "mailEnabled"
        "securityEnabled"
        "groupTypes"
        "membershipRule"
        "createdDateTime"
    ) -join ","

    switch ($PSCmdlet.ParameterSetName) {
        "ByGroupId" {
            $Uri = (
                "https://graph.microsoft.com/v1.0/groups/" +
                "$GroupId?`$select=$GroupSelect"
            )

            return @(
                Invoke-MgGraphRequest `
                    -Method GET `
                    -Uri $Uri `
                    -OutputType PSObject `
                    -ErrorAction Stop
            )
        }

        "ByGroupName" {
            $EscapedName = Get-EncodedODataString -Value $GroupName
            $EncodedFilter = [uri]::EscapeDataString(
                "displayName eq '$EscapedName'"
            )

            $Uri = (
                "https://graph.microsoft.com/v1.0/groups" +
                "?`$filter=$EncodedFilter" +
                "&`$select=$GroupSelect" +
                "&`$top=100"
            )

            $Matches = @(
                Invoke-GraphCollectionRequest -Uri $Uri
            )

            if ($Matches.Count -eq 0) {
                throw "No group was found with display name '$GroupName'."
            }

            if ($Matches.Count -gt 1) {
                throw @"
Multiple groups were found with display name '$GroupName'.

Use -GroupId to select the intended group.
"@
            }

            return $Matches
        }

        default {
            $Uri = (
                "https://graph.microsoft.com/v1.0/groups" +
                "?`$select=$GroupSelect" +
                "&`$top=100"
            )

            return @(
                Invoke-GraphCollectionRequest -Uri $Uri
            )
        }
    }
}

function Get-GroupMembers {
    param(
        [Parameter(Mandatory)]
        [string]$TargetGroupId,

        [Parameter()]
        [switch]$Transitive
    )

    $Relationship = if ($Transitive) {
        "transitiveMembers"
    }
    else {
        "members"
    }

    $MemberSelect = @(
        "id"
        "displayName"
        "userPrincipalName"
        "userType"
        "accountEnabled"
        "mail"
        "appId"
        "deviceId"
    ) -join ","

    $Uri = (
        "https://graph.microsoft.com/v1.0/groups/" +
        "$TargetGroupId/$Relationship" +
        "?`$select=$MemberSelect" +
        "&`$top=100"
    )

    return @(
        Invoke-GraphCollectionRequest -Uri $Uri
    )
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

    Write-Host "Retrieving Microsoft Entra ID groups..." `
        -ForegroundColor Cyan

    $Groups = @(
        Get-TargetGroups
    )

    if ($Groups.Count -eq 0) {
        Write-Host ""
        Write-Host "No Microsoft Entra ID groups were found." `
            -ForegroundColor Yellow
        Write-Host "No CSV report was created." `
            -ForegroundColor Yellow

        return
    }

    $MembershipMode = if ($IncludeTransitiveMembers) {
        "Transitive"
    }
    else {
        "Direct"
    }

    $ReportRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($Group in $Groups) {
        $CurrentGroupId = Get-ObjectPropertyValue `
            -InputObject $Group `
            -PropertyName "id"

        $CurrentGroupName = Get-ObjectPropertyValue `
            -InputObject $Group `
            -PropertyName "displayName" `
            -DefaultValue "Unnamed Group"

        Write-Verbose (
            "Retrieving $MembershipMode membership for " +
            "'$CurrentGroupName'..."
        )

        $Members = @(
            Get-GroupMembers `
                -TargetGroupId $CurrentGroupId `
                -Transitive:$IncludeTransitiveMembers
        )

        $GroupType = Get-GroupClassification -Group $Group
        $MembershipSource = Get-MembershipSource -Group $Group

        if ($Members.Count -eq 0) {
            $ReportRecords.Add(
                [PSCustomObject]@{
                    GroupDisplayName     = $CurrentGroupName
                    GroupId              = $CurrentGroupId
                    GroupType            = $GroupType
                    MembershipSource     = $MembershipSource
                    MembershipMode       = $MembershipMode
                    MemberCount          = 0
                    IsEmpty              = $true

                    MemberDisplayName    = $null
                    MemberType           = "None"
                    MemberIdentifier     = $null
                    MemberUserType       = $null
                    MemberAccountEnabled = $null
                    MemberId             = $null
                }
            )

            continue
        }

        foreach ($Member in $Members) {
            $MemberType = Get-MemberType -Member $Member

            $ReportRecords.Add(
                [PSCustomObject]@{
                    GroupDisplayName     = $CurrentGroupName
                    GroupId              = $CurrentGroupId
                    GroupType            = $GroupType
                    MembershipSource     = $MembershipSource
                    MembershipMode       = $MembershipMode
                    MemberCount          = $Members.Count
                    IsEmpty              = $false

                    MemberDisplayName    = Get-ObjectPropertyValue `
                                            -InputObject $Member `
                                            -PropertyName "displayName"

                    MemberType           = $MemberType

                    MemberIdentifier     = Get-MemberIdentifier `
                                            -Member $Member `
                                            -MemberType $MemberType

                    MemberUserType       = Get-ObjectPropertyValue `
                                            -InputObject $Member `
                                            -PropertyName "userType"

                    MemberAccountEnabled = Get-ObjectPropertyValue `
                                            -InputObject $Member `
                                            -PropertyName "accountEnabled"

                    MemberId             = Get-ObjectPropertyValue `
                                            -InputObject $Member `
                                            -PropertyName "id"
                }
            )
        }
    }

    $Report = @(
        $ReportRecords |
            Sort-Object `
                GroupDisplayName,
                MemberType,
                MemberDisplayName
    )

    $UniqueGroupCount = @(
        $Report.GroupId |
            Sort-Object -Unique
    ).Count

    $EmptyGroupCount = @(
        $Report |
            Where-Object IsEmpty -eq $true
    ).Count

    $MembershipRecordCount = @(
        $Report |
            Where-Object IsEmpty -eq $false
    ).Count

    Write-Host ""
    Write-Host "Group-membership report completed." `
        -ForegroundColor Green
    Write-Host "Groups processed: $UniqueGroupCount" `
        -ForegroundColor Green
    Write-Host "Membership mode: $MembershipMode" `
        -ForegroundColor Green
    Write-Host "Membership records: $MembershipRecordCount" `
        -ForegroundColor Green
    Write-Host "Empty groups: $EmptyGroupCount" `
        -ForegroundColor Green
    Write-Host ""

    $Report |
        Format-Table `
            GroupDisplayName,
            GroupType,
            MembershipSource,
            MemberDisplayName,
            MemberType,
            MemberIdentifier,
            MemberAccountEnabled `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $CsvPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-GroupMembershipReport-$Timestamp.csv"

        $Report |
            Export-Csv `
                -Path $CsvPath `
                -NoTypeInformation `
                -Encoding utf8

        Write-Host ""
        Write-Host "CSV report exported to:" `
            -ForegroundColor Green
        Write-Host $CsvPath
    }
}
catch {
    $ErrorMessage = $_.Exception.Message

    if (
        $ErrorMessage -match "403" -or
        $ErrorMessage -match "Authorization_RequestDenied" -or
        $ErrorMessage -match "Insufficient privileges"
    ) {
        Write-Error @"
Group-membership report generation failed because the Graph session does not
have sufficient permission.

Reconnect using:

Disconnect-MgGraph
Connect-MgGraph -Scopes "Directory.Read.All"
"@
    }
    else {
        Write-Error "Group-membership report generation failed: $ErrorMessage"
    }

    exit 1
}