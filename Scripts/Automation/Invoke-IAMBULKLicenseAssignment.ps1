<#
.SYNOPSIS
    Assigns Microsoft Entra ID licenses from a CSV input file.

.DESCRIPTION
    Resolves each user and requested license SKU, checks whether the license
    is already assigned, and assigns it when required.

    Required CSV columns:
        UserPrincipalName
        SkuPartNumber

    The script supports PowerShell -WhatIf and exports a result CSV.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        User.ReadWrite.All
        Organization.Read.All
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [string]$CsvPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Input\Bulk-LicenseAssignments.csv"
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

Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"
"@
    }

    Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
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
                "usageLocation"
                "assignedLicenses"
            ) `
            -ErrorAction Stop
    }
    catch {
        throw "User '$UserPrincipalName' was not found or could not be read."
    }
}

function Resolve-LicenseSku {
    param(
        [Parameter(Mandatory)]
        [string]$SkuPartNumber,

        [Parameter(Mandatory)]
        [object[]]$SubscribedSkus
    )

    $Matches = @(
        $SubscribedSkus |
            Where-Object {
                $_.SkuPartNumber -eq $SkuPartNumber
            }
    )

    if ($Matches.Count -eq 0) {
        throw "License SKU '$SkuPartNumber' was not found in the tenant."
    }

    if ($Matches.Count -gt 1) {
        throw "More than one license SKU matched '$SkuPartNumber'."
    }

    return $Matches[0]
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
        [string]$SkuPartNumber,

        [Parameter()]
        [string]$SkuId,

        [Parameter()]
        [string]$Status,

        [Parameter()]
        [string]$Message
    )

    return [PSCustomObject]@{
        Timestamp         = (Get-Date).ToString("o")
        RowNumber         = $RowNumber
        UserPrincipalName = $UserPrincipalName
        UserDisplayName   = $UserDisplayName
        SkuPartNumber     = $SkuPartNumber
        SkuId             = $SkuId
        Status            = $Status
        Message           = $Message
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
        "SkuPartNumber"
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

    Write-Verbose "Retrieving subscribed license SKUs."

    $SubscribedSkus = @(
        Get-MgSubscribedSku `
            -All `
            -ErrorAction Stop
    )

    Write-Host "Processing bulk license assignments..." `
        -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" `
        -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $UserPrincipalName = [string]$Row.UserPrincipalName
        $SkuPartNumber = [string]$Row.SkuPartNumber

        $ResolvedUser = $null
        $ResolvedSku = $null

        try {
            if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
                throw "UserPrincipalName is required."
            }

            if ([string]::IsNullOrWhiteSpace($SkuPartNumber)) {
                throw "SkuPartNumber is required."
            }

            $UserPrincipalName = $UserPrincipalName.Trim()
            $SkuPartNumber = $SkuPartNumber.Trim()

            Write-Verbose (
                "Row $($RowNumber): resolving user " +
                "'$UserPrincipalName'."
            )

            $ResolvedUser = Resolve-IAMUser `
                -UserPrincipalName $UserPrincipalName

            if ($ResolvedUser.AccountEnabled -ne $true) {
                throw "The target user account is disabled."
            }

            if ([string]::IsNullOrWhiteSpace($ResolvedUser.UsageLocation)) {
                throw (
                    "The target user does not have a Usage Location. " +
                    "Set Usage Location before assigning a license."
                )
            }

            Write-Verbose (
                "Row $($RowNumber): resolving license SKU " +
                "'$SkuPartNumber'."
            )

            $ResolvedSku = Resolve-LicenseSku `
                -SkuPartNumber $SkuPartNumber `
                -SubscribedSkus $SubscribedSkus

            $AlreadyAssigned = @(
                $ResolvedUser.AssignedLicenses |
                    Where-Object {
                        $_.SkuId -eq $ResolvedSku.SkuId
                    }
            ).Count -gt 0

            if ($AlreadyAssigned) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $ResolvedUser.UserPrincipalName `
                        -UserDisplayName $ResolvedUser.DisplayName `
                        -SkuPartNumber $ResolvedSku.SkuPartNumber `
                        -SkuId ([string]$ResolvedSku.SkuId) `
                        -Status "Already Assigned" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            $AvailableUnits = (
                [int]$ResolvedSku.PrepaidUnits.Enabled -
                [int]$ResolvedSku.ConsumedUnits
            )

            if ($AvailableUnits -le 0) {
                throw "No available units remain for license SKU '$SkuPartNumber'."
            }

            $TargetDescription = (
                "$($ResolvedUser.UserPrincipalName) -> " +
                "$($ResolvedSku.SkuPartNumber)"
            )

            if (
                $PSCmdlet.ShouldProcess(
                    $TargetDescription,
                    "Assign Microsoft Entra ID license"
                )
            ) {
                $LicenseBody = @{
                    addLicenses = @(
                        @{
                            skuId = $ResolvedSku.SkuId
                        }
                    )
                    removeLicenses = @()
                }

                Set-MgUserLicense `
                    -UserId $ResolvedUser.Id `
                    -BodyParameter $LicenseBody `
                    -ErrorAction Stop |
                    Out-Null

                $Status = "Assigned"
                $Message = "License was assigned successfully."
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
                    -SkuPartNumber $ResolvedSku.SkuPartNumber `
                    -SkuId ([string]$ResolvedSku.SkuId) `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
            $UserDisplayName = $null
            $ResolvedSkuPartNumber = $SkuPartNumber
            $ResolvedSkuId = $null

            if ($null -ne $ResolvedUser) {
                $UserDisplayName = $ResolvedUser.DisplayName
            }

            if ($null -ne $ResolvedSku) {
                $ResolvedSkuPartNumber = $ResolvedSku.SkuPartNumber
                $ResolvedSkuId = [string]$ResolvedSku.SkuId
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $UserPrincipalName `
                    -UserDisplayName $UserDisplayName `
                    -SkuPartNumber $ResolvedSkuPartNumber `
                    -SkuId $ResolvedSkuId `
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
    Write-Host "Bulk license assignment completed." `
        -ForegroundColor Green
    Write-Host "Assigned: $AssignedCount"
    Write-Host "Already assigned: $AlreadyAssignedCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            SkuPartNumber,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-BulkLicenseAssignment-$Timestamp.csv"

        $Results |
            Export-Csv `
                -Path $ReportPath `
                -NoTypeInformation `
                -Encoding UTF8 `
                -WhatIf:$false

        Write-Host ""
        Write-Host "Result report exported to:"
        Write-Host $ReportPath
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
