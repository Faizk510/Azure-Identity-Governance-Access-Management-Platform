<#
.SYNOPSIS
    Adds Microsoft Entra ID users to groups from a CSV input file.

.DESCRIPTION
    Resolves users and groups, validates input, detects existing direct
    membership, and adds users only when required.

    Each CSV row must contain:
        UserPrincipalName
        GroupName or GroupId

    The script supports PowerShell -WhatIf and exports a detailed result
    report for auditing and troubleshooting.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        User.Read.All
        Group.Read.All
        GroupMember.ReadWrite.All

    Role-assignable groups are intentionally blocked.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [string]$CsvPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Input\Bulk-GroupAssignments.csv"
    ),

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

Connect-MgGraph -Scopes "User.Read.All","Group.Read.All","GroupMember.ReadWrite.All"
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

function Get-EscapedODataValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Resolve-IAMUser {
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    try {
        return Get-MgUser `
            -UserId $UserPrincipalName `
            -Property @(
                "id"
                "displayName"
                "userPrincipalName"
                "accountEnabled"
                "userType"
            ) `
            -ErrorAction Stop
    }
    catch {
        throw "User '$UserPrincipalName' was not found or could not be read."
    }
}

function Resolve-IAMGroup {
    param(
        [Parameter()]
        [string]$GroupName,

        [Parameter()]
        [string]$GroupId
    )

    $Properties = @(
        "id"
        "displayName"
        "description"
        "groupTypes"
        "securityEnabled"
        "mailEnabled"
        "isAssignableToRole"
        "membershipRule"
    )

    if (-not [string]::IsNullOrWhiteSpace($GroupId)) {
        try {
            return Get-MgGroup `
                -GroupId $GroupId `
                -Property $Properties `
                -ErrorAction Stop
        }
        catch {
            throw "Group ID '$GroupId' was not found or could not be read."
        }
    }

    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        throw "Either GroupName or GroupId must be provided."
    }

    $EscapedName = Get-EscapedODataValue -Value $GroupName

    $Groups = @(
        Get-MgGroup `
            -Filter "displayName eq '$EscapedName'" `
            -All `
            -Property $Properties `
            -ErrorAction Stop
    )

    if ($Groups.Count -eq 0) {
        throw "No group was found with display name '$GroupName'."
    }

    if ($Groups.Count -gt 1) {
        throw @"
Multiple groups were found with display name '$GroupName'.
Use GroupId in the CSV to select the intended group.
"@
    }

    return $Groups[0]
}

function Test-AssignedMembershipGroup {
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    $GroupTypes = @(
        Get-ObjectPropertyValue `
            -InputObject $Group `
            -PropertyName "GroupTypes" `
            -DefaultValue @()
    )

    if ($GroupTypes -contains "DynamicMembership") {
        throw @"
Group '$($Group.DisplayName)' uses dynamic membership.
Members cannot be manually assigned to a dynamic group.
"@
    }

    $IsAssignableToRole = Get-ObjectPropertyValue `
        -InputObject $Group `
        -PropertyName "IsAssignableToRole" `
        -DefaultValue $false

    if ($IsAssignableToRole -eq $true) {
        throw @"
Group '$($Group.DisplayName)' is role-assignable.
This toolkit intentionally blocks privileged group membership changes.
"@
    }
}

function Test-DirectGroupMembership {
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,

        [Parameter(Mandatory)]
        [string]$UserId
    )

    $DirectMembers = @(
        Get-MgGroupMember `
            -GroupId $GroupId `
            -All `
            -Property "id" `
            -ErrorAction Stop
    )

    return (
        $null -ne (
            $DirectMembers |
                Where-Object { $_.Id -eq $UserId } |
                Select-Object -First 1
        )
    )
}

function New-ResultRecord {
    param(
        [Parameter()]
        [int]$RowNumber,

        [Parameter()]
        [string]$UserPrincipalName,

        [Parameter()]
        [string]$UserDisplayName,

        [Parameter()]
        [string]$GroupName,

        [Parameter()]
        [string]$GroupId,

        [Parameter()]
        [string]$Status,

        [Parameter()]
        [string]$Message
    )

    return [PSCustomObject]@{
        Timestamp             = (Get-Date).ToString("o")
        RowNumber             = $RowNumber
        UserPrincipalName     = $UserPrincipalName
        UserDisplayName       = $UserDisplayName
        GroupName             = $GroupName
        GroupId               = $GroupId
        Status                = $Status
        Message               = $Message
    }
}

try {
    Test-GraphConnection

    if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
        throw "Input CSV was not found: $CsvPath"
    }

    if (-not (Test-Path -Path $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    $Rows = @(
        Import-Csv -Path $CsvPath
    )

    if ($Rows.Count -eq 0) {
        throw "The input CSV contains no data rows."
    }

    $RequiredColumns = @(
        "UserPrincipalName"
        "GroupName"
        "GroupId"
    )

    $CsvColumns = @(
        $Rows[0].PSObject.Properties.Name
    )

    $MissingColumns = @(
        $RequiredColumns |
            Where-Object { $_ -notin $CsvColumns }
    )

    if ($MissingColumns.Count -gt 0) {
        throw (
            "The CSV is missing required columns: " +
            ($MissingColumns -join ", ")
        )
    }

    Write-Host "Processing bulk group assignments..." `
        -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" `
        -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $UserPrincipalName = [string]$Row.UserPrincipalName
        $RequestedGroupName = [string]$Row.GroupName
        $RequestedGroupId = [string]$Row.GroupId

        $ResolvedUser = $null
        $ResolvedGroup = $null

        try {
            if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
                throw "UserPrincipalName is required."
            }

            $HasGroupName = -not [string]::IsNullOrWhiteSpace(
                $RequestedGroupName
            )

            $HasGroupId = -not [string]::IsNullOrWhiteSpace(
                $RequestedGroupId
            )

            if (-not $HasGroupName -and -not $HasGroupId) {
                throw "Either GroupName or GroupId must be provided."
            }

            if ($HasGroupName -and $HasGroupId) {
                throw "Provide GroupName or GroupId, not both."
            }

            Write-Verbose (
                "Row $($RowNumber): resolving user " +
                "'$UserPrincipalName'."
            )

            $ResolvedUser = Resolve-IAMUser `
                -UserPrincipalName $UserPrincipalName

            if ($ResolvedUser.AccountEnabled -ne $true) {
                throw "The user account is disabled."
            }

            Write-Verbose (
                "Row $($RowNumber): resolving target group."
            )

            $ResolvedGroup = Resolve-IAMGroup `
                -GroupName $RequestedGroupName `
                -GroupId $RequestedGroupId

            Test-AssignedMembershipGroup -Group $ResolvedGroup

            $AlreadyMember = Test-DirectGroupMembership `
                -GroupId $ResolvedGroup.Id `
                -UserId $ResolvedUser.Id

            if ($AlreadyMember) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $ResolvedUser.UserPrincipalName `
                        -UserDisplayName $ResolvedUser.DisplayName `
                        -GroupName $ResolvedGroup.DisplayName `
                        -GroupId $ResolvedGroup.Id `
                        -Status "Already Member" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            $TargetDescription = (
                "$($ResolvedUser.UserPrincipalName) -> " +
                "$($ResolvedGroup.DisplayName)"
            )

            if (
                $PSCmdlet.ShouldProcess(
                    $TargetDescription,
                    "Add user to Microsoft Entra ID group"
                )
            ) {
                New-MgGroupMemberByRef `
                    -GroupId $ResolvedGroup.Id `
                    -BodyParameter @{
                        "@odata.id" = (
                            "https://graph.microsoft.com/v1.0/" +
                            "directoryObjects/$($ResolvedUser.Id)"
                        )
                    } `
                    -ErrorAction Stop

                $Status = "Added"
                $Message = "User was added successfully."
            }
            else {
                $Status = "WhatIf"
                $Message = "No change was made."
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $ResolvedUser.UserPrincipalName `
                    -UserDisplayName $ResolvedUser.DisplayName `
                    -GroupName $ResolvedGroup.DisplayName `
                    -GroupId $ResolvedGroup.Id `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
			$UserDisplayName = $null
				$ResultGroupName = $RequestedGroupName
				$ResultGroupId = $RequestedGroupId

					if ($null -ne $ResolvedUser) {
						$UserDisplayName = $ResolvedUser.DisplayName
					}

					if ($null -ne $ResolvedGroup) {
						$ResultGroupName = $ResolvedGroup.DisplayName
						$ResultGroupId = $ResolvedGroup.Id
					}

			$FailureRecord = New-ResultRecord `
				-RowNumber $RowNumber `
				-UserPrincipalName $UserPrincipalName `
				-UserDisplayName $UserDisplayName `
				-GroupName $ResultGroupName `
				-GroupId $ResultGroupId `
				-Status "Failed" `
				-Message $_.Exception.Message

			$Results.Add($FailureRecord)
	}

        $RowNumber++
    }

    $AddedCount = @(
        $Results |
            Where-Object Status -eq "Added"
    ).Count

    $AlreadyMemberCount = @(
        $Results |
            Where-Object Status -eq "Already Member"
    ).Count

    $WhatIfCount = @(
        $Results |
            Where-Object Status -eq "WhatIf"
    ).Count

    $FailedCount = @(
        $Results |
            Where-Object Status -eq "Failed"
    ).Count

    Write-Host ""
    Write-Host "Bulk group assignment completed." `
        -ForegroundColor Green
    Write-Host "Added: $AddedCount"
    Write-Host "Already members: $AlreadyMemberCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            GroupName,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $ResultPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-BulkGroupAssignment-$Timestamp.csv"

        $Results |
			Export-Csv `
				-Path $ResultPath `
				-NoTypeInformation `
				-Encoding utf8 `
				-WhatIf:$false

		Write-Host ""
		Write-Host "Result report exported to:" `
			-ForegroundColor Green
		Write-Host $ResultPath
	}	
}
catch {
    Write-Error "Bulk group assignment failed: $($_.Exception.Message)"
    exit 1
}