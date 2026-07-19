<#
.SYNOPSIS
    Updates user department and job title from a CSV input file.

.DESCRIPTION
    Updates Microsoft Entra ID attributes used by Lifecycle Workflows to
    identify mover events. The script does not directly modify access package
    assignments or group memberships.

    Required CSV columns:
        UserPrincipalName
        NewDepartment
        NewJobTitle

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
            -ChildPath "..\Input\Bulk-DepartmentTransfers.csv"
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
        [string]$PreviousDepartment,
        [string]$NewDepartment,
        [string]$PreviousJobTitle,
        [string]$NewJobTitle,
        [string]$Status,
        [string]$Message
    )

    [PSCustomObject]@{
        Timestamp          = (Get-Date).ToString("o")
        RowNumber          = $RowNumber
        UserPrincipalName  = $UserPrincipalName
        PreviousDepartment = $PreviousDepartment
        NewDepartment      = $NewDepartment
        PreviousJobTitle   = $PreviousJobTitle
        NewJobTitle        = $NewJobTitle
        Status             = $Status
        Message            = $Message
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
        "NewDepartment"
        "NewJobTitle"
    )

    $CsvColumns = @($Rows[0].PSObject.Properties.Name)
    $MissingColumns = @(
        $RequiredColumns |
            Where-Object { $_ -notin $CsvColumns }
    )

    if ($MissingColumns.Count -gt 0) {
        throw "The CSV is missing required columns: $($MissingColumns -join ', ')"
    }

    Write-Host "Processing department transfers..." -ForegroundColor Cyan
    Write-Host "Input rows: $($Rows.Count)" -ForegroundColor Cyan

    $Results = [System.Collections.Generic.List[object]]::new()
    $RowNumber = 1

    foreach ($Row in $Rows) {
        $Upn = [string]$Row.UserPrincipalName
        $User = $null

        try {
            if (
                [string]::IsNullOrWhiteSpace($Upn) -or
                [string]::IsNullOrWhiteSpace([string]$Row.NewDepartment)
            ) {
                throw "UserPrincipalName and NewDepartment are required."
            }

            Write-Verbose "Row $($RowNumber): resolving user '$Upn'."

            $User = Get-MgUser `
                -UserId $Upn `
                -Property @(
                    "id"
                    "userPrincipalName"
                    "accountEnabled"
                    "department"
                    "jobTitle"
                ) `
                -ErrorAction Stop

            if ($User.AccountEnabled -ne $true) {
                throw "The target user account is disabled."
            }

            $NewDepartment = ([string]$Row.NewDepartment).Trim()
            $NewJobTitle = ([string]$Row.NewJobTitle).Trim()

            if (
                $User.Department -eq $NewDepartment -and
                $User.JobTitle -eq $NewJobTitle
            ) {
                $Results.Add(
                    (New-ResultRecord `
                        -RowNumber $RowNumber `
                        -UserPrincipalName $User.UserPrincipalName `
                        -PreviousDepartment $User.Department `
                        -NewDepartment $NewDepartment `
                        -PreviousJobTitle $User.JobTitle `
                        -NewJobTitle $NewJobTitle `
                        -Status "Already Updated" `
                        -Message "No change was required.")
                )

                $RowNumber++
                continue
            }

            $Target = (
                "$($User.UserPrincipalName): " +
                "$($User.Department) -> $NewDepartment"
            )

            if ($PSCmdlet.ShouldProcess($Target, "Update user department")) {
                $Body = @{
                    department = $NewDepartment
                    jobTitle   = $NewJobTitle
                }

                Update-MgUser `
                    -UserId $User.Id `
                    -BodyParameter $Body `
                    -ErrorAction Stop

                $Status = "Updated"
                $Message = "Department transfer attributes were updated successfully."
            }
            else {
                $Status = "WhatIf"
                $Message = "No change was made."
            }

            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $User.UserPrincipalName `
                    -PreviousDepartment $User.Department `
                    -NewDepartment $NewDepartment `
                    -PreviousJobTitle $User.JobTitle `
                    -NewJobTitle $NewJobTitle `
                    -Status $Status `
                    -Message $Message)
            )
        }
        catch {
            $Results.Add(
                (New-ResultRecord `
                    -RowNumber $RowNumber `
                    -UserPrincipalName $Upn `
                    -PreviousDepartment (
                        if ($null -ne $User) { $User.Department } else { $null }
                    ) `
                    -NewDepartment ([string]$Row.NewDepartment) `
                    -PreviousJobTitle (
                        if ($null -ne $User) { $User.JobTitle } else { $null }
                    ) `
                    -NewJobTitle ([string]$Row.NewJobTitle) `
                    -Status "Failed" `
                    -Message $_.Exception.Message)
            )
        }

        $RowNumber++
    }

    $UpdatedCount = @($Results | Where-Object Status -eq "Updated").Count
    $AlreadyUpdatedCount = @($Results | Where-Object Status -eq "Already Updated").Count
    $WhatIfCount = @($Results | Where-Object Status -eq "WhatIf").Count
    $FailedCount = @($Results | Where-Object Status -eq "Failed").Count

    Write-Host ""
    Write-Host "Department transfer completed." -ForegroundColor Green
    Write-Host "Updated: $UpdatedCount"
    Write-Host "Already updated: $AlreadyUpdatedCount"
    Write-Host "WhatIf only: $WhatIfCount"
    Write-Host "Failed: $FailedCount"
    Write-Host ""

    $Results |
        Format-Table `
            RowNumber,
            UserPrincipalName,
            PreviousDepartment,
            NewDepartment,
            Status,
            Message `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ReportPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-DepartmentTransfer-$Timestamp.csv"

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
