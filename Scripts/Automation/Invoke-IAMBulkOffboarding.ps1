<#
.SYNOPSIS
    Prepares Microsoft Entra ID users for Lifecycle Workflow offboarding.

.DESCRIPTION
    Sets EmployeeLeaveDateTime and disables the user account. These identity
    changes provide the source state used by the configured leaver workflow.

    The script intentionally does not remove licenses, groups, access package
    assignments, or sessions directly. Lifecycle Workflows perform those
    governed offboarding tasks.

    Required CSV columns:
        UserPrincipalName
        EmployeeLeaveDateTime

    EmployeeLeaveDateTime must be an ISO 8601 value, for example:
        2026-07-15T18:00:00Z

.NOTES
    Required delegated Microsoft Graph permission:
        User.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [Parameter()]
    [string]$CsvPath = (
        Join-Path `
            -Path $PSScriptRoot `
            -ChildPath "..\Input\Bulk-Offboarding.csv"
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
        [bool]$PreviousAccountEnabled,
        [string]$EmployeeLeaveDateTime,
        [string]$Status,
        [string]$Message
    )

    [PSCustomObject]@{
        Timestamp              = (Get-Date).ToString("o")
        RowNumber              = $RowNumber
        UserPrincipalName      = $UserPrincipalName
        PreviousAccountEnabled = $PreviousAccountEnabled
        AccountEnabled         = $false
        EmployeeLeaveDateTime  = $EmployeeLeaveDateTime
        Status                 = $Status
        Message                = $Message
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
        "UserPrincipalName"
        "EmployeeLeaveDateTime"
    )

    $CsvColumns = @($Rows[0].PSObject.Properties.Name)
    $MissingColumns = @(
        $RequiredColumns |
            Where-Object { $_ -notin $CsvColumns }
    )

    if ($MissingColumns.Count -gt 0) {
        throw "The CSV is missing required columns: $($MissingColumns -join ', ')"
    }

    Write-Host "Processing bulk offboarding preparation..." -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $Upn = [string]$Row.UserPrincipalName
        $User = $null

        try {
            if (
                [string]::IsNullOrWhiteSpace($Upn) -or
                [string]::IsNullOrWhiteSpace(
                    [string]$Row.EmployeeLeaveDateTime
                )
            ) {
                throw "UserPrincipalName and EmployeeLeaveDateTime are required."
            }

            $LeaveDate = [datetimeoffset]::Parse(
                [string]$Row.EmployeeLeaveDateTime
            ).ToUniversalTime()

            Write-Verbose "Row $($RowNumber): resolving user '$Upn'."

            $User = Get-MgUser `
                -UserId $Upn `
                -Property @(
                    "id"
                    "userPrincipalName"
                    "accountEnabled"
                    "employeeLeaveDateTime"
                ) `
                -ErrorAction Stop

            $ExistingLeaveDate = $null

            if ($null -ne $User.EmployeeLeaveDateTime) {
                $ExistingLeaveDate = (
                    [datetimeoffset]$User.EmployeeLeaveDateTime
                ).ToUniversalTime()
            }

            if (
                $User.AccountEnabled -eq $false -and
                $null -ne $ExistingLeaveDate -and
                $ExistingLeaveDate -eq $LeaveDate
            ) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $User.UserPrincipalName `
                        -PreviousAccountEnabled $User.AccountEnabled `
                        -EmployeeLeaveDateTime $LeaveDate.ToString("o") `
                        -Status "Already Prepared" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            $Target = (
                "$($User.UserPrincipalName) -> disabled, leave date " +
                $LeaveDate.ToString("o")
            )

            if (
                $PSCmdlet.ShouldProcess(
                    $Target,
                    "Prepare user for Lifecycle Workflow offboarding"
                )
            ) {
                $Body = @{
                    accountEnabled        = $false
                    employeeLeaveDateTime = $LeaveDate.ToString("o")
                }

                Update-MgUser `
                    -UserId $User.Id `
                    -BodyParameter $Body `
                    -ErrorAction Stop

                $Status = "Prepared"
                $Message = "User was disabled and the leave date was set successfully."
            }
            else {
                $Status = "WhatIf"
                $Message = "No change was made."
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $User.UserPrincipalName `
                    -PreviousAccountEnabled $User.AccountEnabled `
                    -EmployeeLeaveDateTime $LeaveDate.ToString("o") `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
            $PreviousEnabled = $false

            if ($null -ne $User) {
                $PreviousEnabled = [bool]$User.AccountEnabled
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $Upn `
                    -PreviousAccountEnabled $PreviousEnabled `
                    -EmployeeLeaveDateTime ([string]$Row.EmployeeLeaveDateTime) `
                    -Status "Failed" `
                    -Message $_.Exception.Message)
            )
        }

        $RowNumber++
    }

    $PreparedCount = @($Results | Where-Object Status -eq "Prepared").Count
    $AlreadyPreparedCount = @($Results | Where-Object Status -eq "Already Prepared").Count
    $WhatIfCount = @($Results | Where-Object Status -eq "WhatIf").Count
    $FailedCount = @($Results | Where-Object Status -eq "Failed").Count

    Write-Host ""
    Write-Host "Bulk offboarding preparation completed." -ForegroundColor Green
    Write-Host "Prepared: $PreparedCount"
    Write-Host "Already prepared: $AlreadyPreparedCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            EmployeeLeaveDateTime,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-BulkOffboarding-$Timestamp.csv"

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
