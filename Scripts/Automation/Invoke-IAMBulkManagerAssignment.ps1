<#
.SYNOPSIS
    Assigns Microsoft Entra ID managers from a CSV input file.

.DESCRIPTION
    Resolves each target user and requested manager, checks the existing
    manager assignment, and assigns or updates the manager when required.

    Required CSV columns:
        UserPrincipalName
        ManagerUserPrincipalName

    The script supports PowerShell -WhatIf and exports a result CSV.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        User.Read.All
        User.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [string]$CsvPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Input\Bulk-ManagerAssignments.csv"
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

Connect-MgGraph -Scopes "User.Read.All","User.ReadWrite.All"
"@
    }

    Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
}

function Resolve-IAMUser {
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$ObjectType
    )

    try {
        return Get-MgUser `
            -UserId $UserPrincipalName `
            -Property @(
                "id"
                "displayName"
                "userPrincipalName"
                "accountEnabled"
            ) `
            -ErrorAction Stop
    }
    catch {
        throw "$ObjectType '$UserPrincipalName' was not found or could not be read."
    }
}

function Get-CurrentManager {
    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    return Get-MgUserManager `
        -UserId $UserId `
        -ErrorAction SilentlyContinue
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
        [string]$ManagerUserPrincipalName,

        [Parameter()]
        [string]$ManagerDisplayName,

        [Parameter()]
        [string]$PreviousManagerId,

        [Parameter()]
        [string]$RequestedManagerId,

        [Parameter()]
        [string]$Status,

        [Parameter()]
        [string]$Message
    )

    return [PSCustomObject]@{
        Timestamp                = (Get-Date).ToString("o")
        RowNumber                = $RowNumber
        UserPrincipalName        = $UserPrincipalName
        UserDisplayName          = $UserDisplayName
        ManagerUserPrincipalName = $ManagerUserPrincipalName
        ManagerDisplayName       = $ManagerDisplayName
        PreviousManagerId        = $PreviousManagerId
        RequestedManagerId       = $RequestedManagerId
        Status                   = $Status
        Message                  = $Message
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
        "ManagerUserPrincipalName"
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

    Write-Host "Processing bulk manager assignments..." `
        -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" `
        -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $UserPrincipalName = [string]$Row.UserPrincipalName
        $ManagerUserPrincipalName = [string]$Row.ManagerUserPrincipalName

        $ResolvedUser = $null
        $ResolvedManager = $null
        $CurrentManager = $null

        try {
            if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
                throw "UserPrincipalName is required."
            }

            if ([string]::IsNullOrWhiteSpace($ManagerUserPrincipalName)) {
                throw "ManagerUserPrincipalName is required."
            }

            Write-Verbose (
                "Row $($RowNumber): resolving user " +
                "'$UserPrincipalName'."
            )

            $ResolvedUser = Resolve-IAMUser `
                -UserPrincipalName $UserPrincipalName `
                -ObjectType "User"

            if ($ResolvedUser.AccountEnabled -ne $true) {
                throw "The target user account is disabled."
            }

            Write-Verbose (
                "Row $($RowNumber): resolving manager " +
                "'$ManagerUserPrincipalName'."
            )

            $ResolvedManager = Resolve-IAMUser `
                -UserPrincipalName $ManagerUserPrincipalName `
                -ObjectType "Manager"

            if ($ResolvedManager.AccountEnabled -ne $true) {
                throw "The manager account is disabled."
            }

            if ($ResolvedUser.Id -eq $ResolvedManager.Id) {
                throw "A user cannot be assigned as their own manager."
            }

            Write-Verbose (
                "Row $($RowNumber): checking current manager."
            )

            $CurrentManager = Get-CurrentManager `
                -UserId $ResolvedUser.Id

            $CurrentManagerId = $null

            if ($null -ne $CurrentManager) {
                $CurrentManagerId = [string]$CurrentManager.Id
            }

            if ($CurrentManagerId -eq $ResolvedManager.Id) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $ResolvedUser.UserPrincipalName `
                        -UserDisplayName $ResolvedUser.DisplayName `
                        -ManagerUserPrincipalName $ResolvedManager.UserPrincipalName `
                        -ManagerDisplayName $ResolvedManager.DisplayName `
                        -PreviousManagerId $CurrentManagerId `
                        -RequestedManagerId $ResolvedManager.Id `
                        -Status "Already Assigned" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            if ($null -eq $CurrentManager) {
                $Action = "Assign manager in Microsoft Entra ID"
                $SuccessStatus = "Assigned"
                $SuccessMessage = "Manager was assigned successfully."
            }
            else {
                $Action = "Update manager in Microsoft Entra ID"
                $SuccessStatus = "Updated"
                $SuccessMessage = "Manager was updated successfully."
            }

            $TargetDescription = (
                "$($ResolvedUser.UserPrincipalName) -> " +
                "$($ResolvedManager.UserPrincipalName)"
            )

            if (
                $PSCmdlet.ShouldProcess(
                    $TargetDescription,
                    $Action
                )
            ) {
                Set-MgUserManagerByRef `
                    -UserId $ResolvedUser.Id `
                    -BodyParameter @{
                        "@odata.id" = (
                            "https://graph.microsoft.com/v1.0/" +
                            "users/$($ResolvedManager.Id)"
                        )
                    } `
                    -ErrorAction Stop

                $Status = $SuccessStatus
                $Message = $SuccessMessage
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
                    -ManagerUserPrincipalName $ResolvedManager.UserPrincipalName `
                    -ManagerDisplayName $ResolvedManager.DisplayName `
                    -PreviousManagerId $CurrentManagerId `
                    -RequestedManagerId $ResolvedManager.Id `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
            $UserDisplayName = $null
            $ManagerDisplayName = $null
            $PreviousManagerId = $null
            $RequestedManagerId = $null

            if ($null -ne $ResolvedUser) {
                $UserDisplayName = $ResolvedUser.DisplayName
            }

            if ($null -ne $ResolvedManager) {
                $ManagerDisplayName = $ResolvedManager.DisplayName
                $RequestedManagerId = $ResolvedManager.Id
            }

            if ($null -ne $CurrentManager) {
                $PreviousManagerId = $CurrentManager.Id
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $UserPrincipalName `
                    -UserDisplayName $UserDisplayName `
                    -ManagerUserPrincipalName $ManagerUserPrincipalName `
                    -ManagerDisplayName $ManagerDisplayName `
                    -PreviousManagerId $PreviousManagerId `
                    -RequestedManagerId $RequestedManagerId `
                    -Status "Failed" `
                    -Message $_.Exception.Message)
            )
        }

        $RowNumber++
    }

    $AssignedCount = @(
        $Results |
            Where-Object Status -eq "Assigned"
    ).Count

    $UpdatedCount = @(
        $Results |
            Where-Object Status -eq "Updated"
    ).Count

    $AlreadyAssignedCount = @(
        $Results |
            Where-Object Status -eq "Already Assigned"
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
    Write-Host "Bulk manager assignment completed." `
        -ForegroundColor Green
    Write-Host "Assigned: $AssignedCount"
    Write-Host "Updated: $UpdatedCount"
    Write-Host "Already assigned: $AlreadyAssignedCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            ManagerUserPrincipalName,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-BulkManagerAssignment-$Timestamp.csv"

        $Results |
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
