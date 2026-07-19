<#
.SYNOPSIS
    Generates an operational report of Microsoft Entra ID guest users.

.DESCRIPTION
    Retrieves guest identity, invitation, sign-in, and sponsor information
    through Microsoft Graph.

    The script handles tenants with no guest users without failing or
    exporting an empty CSV file.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        User.Read.All
        Directory.Read.All
        AuditLog.Read.All
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

Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All","AuditLog.Read.All"
"@
    }
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

function Get-GuestSponsorDetails {
    <#
    .SYNOPSIS
        Retrieves and validates sponsors assigned to a guest user.
    #>

    param(
        [Parameter(Mandatory)]
        [string]$UserId
    )

    try {
        $Uri = "https://graph.microsoft.com/v1.0/users/$UserId/sponsors?`$select=id,displayName,userPrincipalName,accountEnabled"

        $Response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $Uri `
            -ErrorAction Stop

        $Sponsors = @($Response.value)

        if ($Sponsors.Count -eq 0) {
            return [PSCustomObject]@{
                SponsorNames            = $null
                SponsorUserPrincipalName = $null
                SponsorCount            = 0
                SponsorValidationStatus  = "No Sponsor Assigned"
            }
        }

        $SponsorNames = @()
        $SponsorUpns = @()
        $DisabledSponsorFound = $false

        foreach ($Sponsor in $Sponsors) {
            $SponsorNames += $Sponsor.displayName

            if ($Sponsor.userPrincipalName) {
                $SponsorUpns += $Sponsor.userPrincipalName
            }

            if (
                $null -ne $Sponsor.accountEnabled -and
                $Sponsor.accountEnabled -eq $false
            ) {
                $DisabledSponsorFound = $true
            }
        }

        $ValidationStatus = if ($DisabledSponsorFound) {
            "Disabled Sponsor Assigned"
        }
        else {
            "Valid"
        }

        return [PSCustomObject]@{
            SponsorNames            = ($SponsorNames | Sort-Object -Unique) -join "; "
            SponsorUserPrincipalName = ($SponsorUpns | Sort-Object -Unique) -join "; "
            SponsorCount            = $Sponsors.Count
            SponsorValidationStatus  = $ValidationStatus
        }
    }
    catch {
        Write-Warning "Sponsor lookup failed for user ID '$UserId': $($_.Exception.Message)"

        return [PSCustomObject]@{
            SponsorNames            = $null
            SponsorUserPrincipalName = $null
            SponsorCount            = $null
            SponsorValidationStatus  = "Lookup Failed"
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

    $GuestProperties = @(
        "id"
        "displayName"
        "userPrincipalName"
        "mail"
        "userType"
        "accountEnabled"
        "externalUserState"
        "externalUserStateChangeDateTime"
        "createdDateTime"
        "signInActivity"
    )

    Write-Host "Retrieving Microsoft Entra ID guest users..." -ForegroundColor Cyan

    $GuestUsers = @(
        Get-MgUser `
            -Filter "userType eq 'Guest'" `
            -All `
            -Property $GuestProperties
    )

    if ($GuestUsers.Count -eq 0) {
        Write-Host ""
        Write-Host "No guest users were found in the tenant." -ForegroundColor Yellow
        Write-Host "Guest users returned: 0" -ForegroundColor Yellow
        Write-Host "No CSV report was created." -ForegroundColor Yellow

        return
    }

    $Report = foreach ($Guest in $GuestUsers) {
        Write-Verbose "Resolving sponsor information for $($Guest.UserPrincipalName)..."

        $SponsorDetails = Get-GuestSponsorDetails -UserId $Guest.Id
        $LastSuccessfulSignIn =
            $Guest.SignInActivity.LastSuccessfulSignInDateTime

        [PSCustomObject]@{
            DisplayName                       = $Guest.DisplayName
            UserPrincipalName                 = $Guest.UserPrincipalName
            Email                             = $Guest.Mail
            UserType                          = $Guest.UserType
            AccountEnabled                    = $Guest.AccountEnabled
            InvitationStatus                  = $Guest.ExternalUserState
            InvitationStatusChangeDateTime    = $Guest.ExternalUserStateChangeDateTime
            CreatedDateTime                   = $Guest.CreatedDateTime
            SponsorNames                      = $SponsorDetails.SponsorNames
            SponsorUserPrincipalName          = $SponsorDetails.SponsorUserPrincipalName
            SponsorCount                      = $SponsorDetails.SponsorCount
            SponsorValidationStatus           = $SponsorDetails.SponsorValidationStatus
            LastSuccessfulSignIn              = $LastSuccessfulSignIn
            DaysSinceLastSuccessfulSignIn     = Get-DaysSinceSignIn `
                                                   -LastSuccessfulSignIn $LastSuccessfulSignIn
        }
    }

    $Report = $Report |
        Sort-Object DisplayName

    Write-Host ""
    Write-Host "Guest user report completed." -ForegroundColor Green
    Write-Host "Guest users returned: $($Report.Count)" -ForegroundColor Green
    Write-Host ""

    $Report |
        Format-Table `
            DisplayName,
            UserPrincipalName,
            AccountEnabled,
            InvitationStatus,
            SponsorNames,
            SponsorValidationStatus,
            DaysSinceLastSuccessfulSignIn `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $CsvPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-GuestUserReport-$Timestamp.csv"

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
    Write-Error "Guest user report generation failed: $($_.Exception.Message)"
    exit 1
}