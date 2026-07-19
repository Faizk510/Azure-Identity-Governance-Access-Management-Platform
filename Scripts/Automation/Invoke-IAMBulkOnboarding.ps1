<#
.SYNOPSIS
    Creates Microsoft Entra ID users from a CSV input file.

.DESCRIPTION
    Creates enabled member users with department, job title, usage location,
    and an optional manager assignment.

    The script intentionally creates the identity only. Lifecycle Workflows
    remain responsible for governed access provisioning.

    Required CSV columns:
        DisplayName
        GivenName
        Surname
        UserPrincipalName
        MailNickname
        Department
        JobTitle
        UsageLocation
        TemporaryPassword
        ManagerUserPrincipalName

.NOTES
    Required delegated Microsoft Graph permission:
        User.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [string]$CsvPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Input\Bulk-Onboarding.csv"
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

$ErrorActionPreference = "Stop"

function Test-GraphConnection {
    $Context = Get-MgContext

    if (-not $Context) {
        throw @"
Microsoft Graph authentication is required.

Connect before running this script:

Connect-MgGraph -Scopes "User.ReadWrite.All"
"@
    }

    Write-Verbose "Connected to Microsoft Graph as $($Context.Account)."
}

function New-ResultRecord {
    param(
        [int]$RowNumber,
        [string]$UserPrincipalName,
        [string]$DisplayName,
        [string]$Department,
        [string]$ManagerUserPrincipalName,
        [string]$Status,
        [string]$Message
    )

    [PSCustomObject]@{
        Timestamp                = (Get-Date).ToString("o")
        RowNumber                = $RowNumber
        UserPrincipalName        = $UserPrincipalName
        DisplayName              = $DisplayName
        Department               = $Department
        ManagerUserPrincipalName = $ManagerUserPrincipalName
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
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $Rows = @(Import-Csv -Path $CsvPath)

    if ($Rows.Count -eq 0) {
        throw "The input CSV contains no data rows."
    }

    $RequiredColumns = @(
        "DisplayName"
        "GivenName"
        "Surname"
        "UserPrincipalName"
        "MailNickname"
        "Department"
        "JobTitle"
        "UsageLocation"
        "TemporaryPassword"
        "ManagerUserPrincipalName"
    )

    $CsvColumns = @($Rows[0].PSObject.Properties.Name)
    $MissingColumns = @(
        $RequiredColumns |
            Where-Object { $_ -notin $CsvColumns }
    )

    if ($MissingColumns.Count -gt 0) {
        throw "The CSV is missing required columns: $($MissingColumns -join ', ')"
    }

    Write-Host "Processing bulk onboarding..." -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $Upn = [string]$Row.UserPrincipalName
        $CreatedUser = $null

        try {
            if (
                [string]::IsNullOrWhiteSpace($Upn) -or
                [string]::IsNullOrWhiteSpace([string]$Row.DisplayName) -or
                [string]::IsNullOrWhiteSpace([string]$Row.MailNickname) -or
                [string]::IsNullOrWhiteSpace([string]$Row.TemporaryPassword)
            ) {
                throw "DisplayName, UserPrincipalName, MailNickname, and TemporaryPassword are required."
            }

            Write-Verbose "Row $($RowNumber): checking user '$Upn'."

            $ExistingUser = Get-MgUser `
                -UserId $Upn `
                -ErrorAction SilentlyContinue

            if ($null -ne $ExistingUser) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $Upn `
                        -DisplayName ([string]$Row.DisplayName) `
                        -Department ([string]$Row.Department) `
                        -ManagerUserPrincipalName ([string]$Row.ManagerUserPrincipalName) `
                        -Status "Already Exists" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            $Target = "$Upn ($([string]$Row.Department))"

            if ($PSCmdlet.ShouldProcess($Target, "Create Microsoft Entra ID user")) {
                $Body = @{
                    accountEnabled    = $true
                    displayName       = ([string]$Row.DisplayName).Trim()
                    givenName         = ([string]$Row.GivenName).Trim()
                    surname           = ([string]$Row.Surname).Trim()
                    userPrincipalName = $Upn.Trim()
                    mailNickname      = ([string]$Row.MailNickname).Trim()
                    userType          = "Member"
                    department        = ([string]$Row.Department).Trim()
                    jobTitle          = ([string]$Row.JobTitle).Trim()
					employeeHireDate  = ([datetime]$Row.EmployeeHireDate).ToString("yyyy-MM-dd")
                    usageLocation     = ([string]$Row.UsageLocation).Trim()
                    passwordProfile   = @{
                        password                      = [string]$Row.TemporaryPassword
                        forceChangePasswordNextSignIn = $true
                    }
                }

                $CreatedUser = New-MgUser `
                    -BodyParameter $Body `
                    -ErrorAction Stop

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$Row.ManagerUserPrincipalName
                    )
                ) {
                    Write-Verbose (
                        "Row $($RowNumber): assigning manager " +
                        "'$([string]$Row.ManagerUserPrincipalName)'."
                    )

                    $Manager = Get-MgUser `
                        -UserId ([string]$Row.ManagerUserPrincipalName).Trim() `
                        -ErrorAction Stop

                    Set-MgUserManagerByRef `
                        -UserId $CreatedUser.Id `
                        -BodyParameter @{
                            "@odata.id" = (
                                "https://graph.microsoft.com/v1.0/users/" +
                                $Manager.Id
                            )
                        } `
                        -ErrorAction Stop
                }

                $Status = "Created"
                $Message = "User was created successfully."
            }
            else {
                $Status = "WhatIf"
                $Message = "No change was made."
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $Upn `
                    -DisplayName ([string]$Row.DisplayName) `
                    -Department ([string]$Row.Department) `
                    -ManagerUserPrincipalName ([string]$Row.ManagerUserPrincipalName) `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $Upn `
                    -DisplayName ([string]$Row.DisplayName) `
                    -Department ([string]$Row.Department) `
                    -ManagerUserPrincipalName ([string]$Row.ManagerUserPrincipalName) `
                    -Status "Failed" `
                    -Message $_.Exception.Message)
            )
        }

        $RowNumber++
    }

    $CreatedCount = @($Results | Where-Object Status -eq "Created").Count
    $ExistingCount = @($Results | Where-Object Status -eq "Already Exists").Count
    $WhatIfCount = @($Results | Where-Object Status -eq "WhatIf").Count
    $FailedCount = @($Results | Where-Object Status -eq "Failed").Count

    Write-Host ""
    Write-Host "Bulk onboarding completed." -ForegroundColor Green
    Write-Host "Created: $CreatedCount"
    Write-Host "Already exists: $ExistingCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            Department,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-BulkOnboarding-$Timestamp.csv"

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
