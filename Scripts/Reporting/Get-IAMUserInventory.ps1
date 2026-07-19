<#
.SYNOPSIS
    Generates an operational inventory of Microsoft Entra ID users.

.DESCRIPTION
    Retrieves Microsoft Entra ID user identity, employment, licensing,
    account-status, and sign-in information through Microsoft Graph.

    The report can be displayed in the PowerShell console and exported
    to a timestamped CSV file.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        User.Read.All
        Directory.Read.All
        AuditLog.Read.All
        Organization.Read.All
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (
		[System.IO.Path]::GetFullPath(
			(Join-Path `
				-Path $PSScriptRoot `
				-ChildPath "..\Output")
		)
    ),

    [Parameter()]
    [switch]$IncludeDisabledUsers,

    [Parameter()]
    [switch]$SkipCsvExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-GraphConnection {
    <#
    .SYNOPSIS
        Confirms that an active Microsoft Graph session exists.
    #>

    try {
        $Context = Get-MgContext

        if (-not $Context) {
            throw "No active Microsoft Graph session was found."
        }

        Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
    }
    catch {
        throw @"
Microsoft Graph authentication is required.

Connect before running this report:

Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All","AuditLog.Read.All","Organization.Read.All"
"@
    }
}

function Get-LicenseLookup {
    <#
    .SYNOPSIS
        Creates a lookup table that translates SKU GUIDs into readable names.
    #>

    $LicenseLookup = @{}

    try {
        $SubscribedSkus = Get-MgSubscribedSku -All

        foreach ($Sku in $SubscribedSkus) {
            $LicenseLookup[$Sku.SkuId.ToString()] = $Sku.SkuPartNumber
        }
    }
    catch {
        Write-Warning "License SKU information could not be retrieved: $($_.Exception.Message)"
    }

    return $LicenseLookup
}

function Get-ReadableLicenseNames {
    <#
    .SYNOPSIS
        Resolves assigned license GUIDs into readable SKU names.
    #>

    param(
        [Parameter()]
        [object[]]$AssignedLicenses,

        [Parameter(Mandatory)]
        [hashtable]$LicenseLookup
    )

    if (-not $AssignedLicenses) {
        return "Unlicensed"
    }

    $LicenseNames = foreach ($License in $AssignedLicenses) {
        $SkuId = $License.SkuId.ToString()

        if ($LicenseLookup.ContainsKey($SkuId)) {
            $LicenseLookup[$SkuId]
        }
        else {
            "Unknown SKU: $SkuId"
        }
    }

    return ($LicenseNames | Sort-Object -Unique) -join "; "
}

function Get-DaysSinceSignIn {
    <#
    .SYNOPSIS
        Calculates the number of days since the last successful sign-in.
    #>

    param(
        [Parameter()]
        [object]$LastSuccessfulSignIn
    )

    if (-not $LastSuccessfulSignIn) {
        return $null
    }

    try {
        $SignInDate = [datetimeoffset]$LastSuccessfulSignIn

        return [math]::Floor(
            (
                [datetimeoffset]::UtcNow -
                $SignInDate.ToUniversalTime()
            ).TotalDays
        )
    }
    catch {
        Write-Warning "Could not calculate sign-in age for value '$LastSuccessfulSignIn'."
        return $null
    }
}

function Get-ManagerDetails {
    <#
    .SYNOPSIS
        Retrieves and validates the assigned manager for a user.
    #>

    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    try {
        $Manager = Get-MgUserManager `
            -UserId $UserId `
            -Property @(
                "id"
                "displayName"
                "userPrincipalName"
                "accountEnabled"
            ) `
            -ErrorAction Stop

        return [PSCustomObject]@{
            DisplayName       = $Manager.AdditionalProperties["displayName"]
            UserPrincipalName = $Manager.AdditionalProperties["userPrincipalName"]
            AccountEnabled    = $Manager.AdditionalProperties["accountEnabled"]
            ValidationStatus  = if (
                $Manager.AdditionalProperties["accountEnabled"] -eq $false
            ) {
                "Manager Disabled"
            }
            else {
                "Valid"
            }
        }
    }
    catch {
        if (
            $_.Exception.Message -match "404" -or
            $_.Exception.Message -match "Request_ResourceNotFound"
        ) {
            return [PSCustomObject]@{
                DisplayName       = $null
                UserPrincipalName = $null
                AccountEnabled    = $null
                ValidationStatus  = "No Manager Assigned"
            }
        }

        return [PSCustomObject]@{
            DisplayName       = $null
            UserPrincipalName = $null
            AccountEnabled    = $null
            ValidationStatus  = "Lookup Failed"
        }
    }
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

    Write-Host "Retrieving tenant license information..." -ForegroundColor Cyan
    $LicenseLookup = Get-LicenseLookup

    $UserProperties = @(
        "id"
        "displayName"
        "userPrincipalName"
        "userType"
        "accountEnabled"
        "department"
        "jobTitle"
        "employeeType"
        "createdDateTime"
        "assignedLicenses"
        "signInActivity"
    )

    Write-Host "Retrieving Microsoft Entra ID users..." -ForegroundColor Cyan

    $Users = Get-MgUser `
        -All `
        -Property $UserProperties

    if (-not $IncludeDisabledUsers) {
        $Users = $Users |
            Where-Object AccountEnabled -eq $true
    }

    $Report = foreach ($User in $Users) {
		Write-Verbose "Resolving manager for $($User.UserPrincipalName)..."

		$ManagerDetails = Get-ManagerDetails -UserId $User.Id
        
		$LastSuccessfulSignIn = $User.SignInActivity.LastSuccessfulSignInDateTime

        [PSCustomObject]@{
            DisplayName             = $User.DisplayName
            UserPrincipalName       = $User.UserPrincipalName
            UserType                = $User.UserType
            AccountEnabled          = $User.AccountEnabled
            Department              = $User.Department
            JobTitle                = $User.JobTitle
            EmployeeType            = $User.EmployeeType
			ManagerDisplayName       = $ManagerDetails.DisplayName
			ManagerUserPrincipalName = $ManagerDetails.UserPrincipalName
			ManagerAccountEnabled    = $ManagerDetails.AccountEnabled
			ManagerValidationStatus  = $ManagerDetails.ValidationStatus
            CreatedDateTime         = $User.CreatedDateTime
            AssignedLicenseCount    = @($User.AssignedLicenses).Count
            AssignedLicenses        = Get-ReadableLicenseNames `
                                        -AssignedLicenses $User.AssignedLicenses `
                                        -LicenseLookup $LicenseLookup
            LastSuccessfulSignIn    = $LastSuccessfulSignIn
            DaysSinceLastSignIn     = Get-DaysSinceSignIn `
                                        -LastSuccessfulSignIn $LastSuccessfulSignIn
        }
    }

    $Report = $Report |
        Sort-Object DisplayName

    Write-Host ""
    Write-Host "User inventory completed." -ForegroundColor Green
    Write-Host "Users returned: $($Report.Count)" -ForegroundColor Green
    Write-Host ""

    $Report |
		Format-Table `
			DisplayName,
			UserPrincipalName,
			Department,
			ManagerDisplayName,
			ManagerValidationStatus,
			AssignedLicenseCount,
			DaysSinceLastSignIn `
			-AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $CsvPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-UserInventory-$Timestamp.csv"

        $Report |
            Export-Csv `
                -Path $CsvPath `
                -NoTypeInformation `
                -Encoding utf8

        Write-Host ""
        Write-Host "CSV report exported to:" -ForegroundColor Green
        Write-Host $CsvPath
    }

    
}
catch {
    Write-Error "User inventory generation failed: $($_.Exception.Message)"
    exit 1
}