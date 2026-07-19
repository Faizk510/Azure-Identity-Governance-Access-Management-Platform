<#
.SYNOPSIS
    Generates a consolidated Microsoft Entra privileged-role report.

.DESCRIPTION
    Retrieves current active and eligible Microsoft Entra directory-role
    assignments through Microsoft Graph.

    The report includes standing assignments, active PIM activations,
    eligible PIM assignments, principal details, assignment scope,
    membership type, start date, expiration date, and permanence status.

.NOTES
    Project:
        Q Financial Services
        Azure Identity Governance & Access Management Platform

    Required delegated Microsoft Graph permissions:
        RoleManagement.Read.Directory
        Directory.Read.All
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
    [ValidateSet("All", "Active", "Eligible")]
    [string]$AssignmentState = "All",

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

Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All"
"@
    }
}

function Invoke-GraphCollectionRequest {
    <#
    .SYNOPSIS
        Retrieves all pages from a Microsoft Graph collection endpoint.
    #>

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

function Get-PrincipalType {
    <#
    .SYNOPSIS
        Converts the Graph object type into a readable principal type.
    #>

    param(
        [Parameter()]
        [object]$Principal
    )

    if (-not $Principal) {
        return "Unknown"
    }

    $ODataType = $Principal.'@odata.type'

    switch ($ODataType) {
        "#microsoft.graph.user" {
            return "User"
        }

        "#microsoft.graph.group" {
            return "Group"
        }

        "#microsoft.graph.servicePrincipal" {
            return "Service Principal"
        }

        default {
            return "Unknown"
        }
    }
}

function Get-PrincipalIdentifier {
    <#
    .SYNOPSIS
        Returns the most useful identifier for the assigned principal.
    #>

    param(
        [Parameter()]
        [object]$Principal,

        [Parameter(Mandatory)]
        [string]$PrincipalType
    )

    if (-not $Principal) {
        return $null
    }

    switch ($PrincipalType) {
        "User" {
            return $Principal.userPrincipalName
        }

        "Group" {
            if ($Principal.mail) {
                return $Principal.mail
            }

            return $Principal.id
        }

        "Service Principal" {
            if ($Principal.appId) {
                return $Principal.appId
            }

            return $Principal.id
        }

        default {
            return $Principal.id
        }
    }
}

function Get-ScopeDetails {
    <#
    .SYNOPSIS
        Converts a Graph directory scope into a readable classification.
    #>

    param(
        [Parameter()]
        [string]$DirectoryScopeId,

        [Parameter()]
        [string]$AppScopeId
    )

    if (
        [string]::IsNullOrWhiteSpace($DirectoryScopeId) -or
        $DirectoryScopeId -eq "/"
    ) {
        return [PSCustomObject]@{
            ScopeType = "Tenant"
            ScopeId   = "/"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AppScopeId)) {
        return [PSCustomObject]@{
            ScopeType = "Application Scope"
            ScopeId   = $AppScopeId
        }
    }

    if ($DirectoryScopeId -match "administrativeUnits") {
        return [PSCustomObject]@{
            ScopeType = "Administrative Unit"
            ScopeId   = $DirectoryScopeId
        }
    }

    return [PSCustomObject]@{
        ScopeType = "Directory Scope"
        ScopeId   = $DirectoryScopeId
    }
}

function ConvertTo-RoleAssignmentRecord {
    <#
    .SYNOPSIS
        Converts a Graph role schedule instance into a report record.
    #>

    param(
        [Parameter(Mandatory)]
        [object]$Assignment,

        [Parameter(Mandatory)]
        [ValidateSet("Active", "Eligible")]
        [string]$State
    )

    $Principal = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "principal"

    $RoleDefinition = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "roleDefinition"

    $PrincipalType = Get-PrincipalType `
        -Principal $Principal

    $PrincipalIdentifier = Get-PrincipalIdentifier `
        -Principal $Principal `
        -PrincipalType $PrincipalType

    $DirectoryScopeId = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "directoryScopeId"

    $AppScopeId = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "appScopeId"

    $ScopeDetails = Get-ScopeDetails `
        -DirectoryScopeId $DirectoryScopeId `
        -AppScopeId $AppScopeId

    $EndDateTime = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "endDateTime"

    $IsPermanent = [string]::IsNullOrWhiteSpace(
        [string]$EndDateTime
    )

    $AssignmentType = Get-ObjectPropertyValue `
        -InputObject $Assignment `
        -PropertyName "assignmentType"

    if ([string]::IsNullOrWhiteSpace($AssignmentType)) {
        $AssignmentType = if ($State -eq "Eligible") {
            "Eligible"
        }
        else {
            "Assigned"
        }
    }

    $PrincipalAccountEnabled = Get-ObjectPropertyValue `
        -InputObject $Principal `
        -PropertyName "accountEnabled"

    $PrincipalDisplayName = Get-ObjectPropertyValue `
        -InputObject $Principal `
        -PropertyName "displayName" `
        -DefaultValue "Unresolved Principal"

    $RoleName = Get-ObjectPropertyValue `
        -InputObject $RoleDefinition `
        -PropertyName "displayName" `
        -DefaultValue "Unresolved Role"

    [PSCustomObject]@{
        RoleName                = $RoleName

        RoleTemplateId          = Get-ObjectPropertyValue `
                                    -InputObject $RoleDefinition `
                                    -PropertyName "templateId"

        AssignmentState         = $State
        AssignmentType          = $AssignmentType

        MemberType              = Get-ObjectPropertyValue `
                                    -InputObject $Assignment `
                                    -PropertyName "memberType"

        PrincipalType           = $PrincipalType
        PrincipalDisplayName    = $PrincipalDisplayName
        PrincipalIdentifier     = $PrincipalIdentifier

        PrincipalId             = Get-ObjectPropertyValue `
                                    -InputObject $Assignment `
                                    -PropertyName "principalId"

        PrincipalAccountEnabled = $PrincipalAccountEnabled

        ScopeType               = $ScopeDetails.ScopeType
        ScopeId                 = $ScopeDetails.ScopeId

        StartDateTime           = Get-ObjectPropertyValue `
                                    -InputObject $Assignment `
                                    -PropertyName "startDateTime"

        EndDateTime             = $EndDateTime
        IsPermanent             = $IsPermanent

        RoleDefinitionId        = Get-ObjectPropertyValue `
                                    -InputObject $Assignment `
                                    -PropertyName "roleDefinitionId"

        AssignmentInstanceId    = Get-ObjectPropertyValue `
                                    -InputObject $Assignment `
                                    -PropertyName "id"
    }
}

function Get-ObjectPropertyValue {
    <#
    .SYNOPSIS
        Safely retrieves an optional property from a PowerShell object.
    #>

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

try {
    Test-GraphConnection

    if (-not (Test-Path -Path $OutputPath)) {
        New-Item `
            -Path $OutputPath `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    $ReportRecords = [System.Collections.Generic.List[object]]::new()

    if ($AssignmentState -in @("All", "Active")) {
        Write-Host `
            "Retrieving active Microsoft Entra role assignments..." `
            -ForegroundColor Cyan

        $ActiveUri = @(
            "https://graph.microsoft.com/v1.0/"
            "roleManagement/directory/"
            "roleAssignmentScheduleInstances"
            "?`$expand=principal,roleDefinition"
            "&`$top=100"
        ) -join ""

        $ActiveAssignments = Invoke-GraphCollectionRequest `
            -Uri $ActiveUri

        foreach ($Assignment in $ActiveAssignments) {
            $Record = ConvertTo-RoleAssignmentRecord `
                -Assignment $Assignment `
                -State "Active"

            $ReportRecords.Add($Record)
        }
    }

    if ($AssignmentState -in @("All", "Eligible")) {
        Write-Host `
            "Retrieving eligible Microsoft Entra PIM assignments..." `
            -ForegroundColor Cyan

        $EligibleUri = @(
            "https://graph.microsoft.com/v1.0/"
            "roleManagement/directory/"
            "roleEligibilityScheduleInstances"
            "?`$expand=principal,roleDefinition"
            "&`$top=100"
        ) -join ""

        $EligibleAssignments = Invoke-GraphCollectionRequest `
            -Uri $EligibleUri

        foreach ($Assignment in $EligibleAssignments) {
            $Record = ConvertTo-RoleAssignmentRecord `
                -Assignment $Assignment `
                -State "Eligible"

            $ReportRecords.Add($Record)
        }
    }

    $Report = @(
        $ReportRecords |
            Sort-Object `
                RoleName,
                AssignmentState,
                PrincipalDisplayName
    )

    if ($Report.Count -eq 0) {
        Write-Host ""
        Write-Host `
            "No matching Microsoft Entra role assignments were found." `
            -ForegroundColor Yellow
        Write-Host "Assignments returned: 0" -ForegroundColor Yellow
        Write-Host "No CSV report was created." -ForegroundColor Yellow

        return
    }

    $ActiveCount = @(
        $Report |
            Where-Object AssignmentState -eq "Active"
    ).Count

    $EligibleCount = @(
        $Report |
            Where-Object AssignmentState -eq "Eligible"
    ).Count

    $PermanentCount = @(
        $Report |
            Where-Object IsPermanent -eq $true
    ).Count

    $TimeBoundCount = @(
        $Report |
            Where-Object IsPermanent -eq $false
    ).Count

    Write-Host ""
    Write-Host "Privileged-role report completed." -ForegroundColor Green
    Write-Host "Assignments returned: $($Report.Count)" -ForegroundColor Green
    Write-Host "Active assignments: $ActiveCount" -ForegroundColor Green
    Write-Host "Eligible assignments: $EligibleCount" -ForegroundColor Green
    Write-Host "Permanent assignments: $PermanentCount" -ForegroundColor Green
    Write-Host "Time-bound assignments: $TimeBoundCount" -ForegroundColor Green
    Write-Host ""

    $Report |
        Format-Table `
            RoleName,
            AssignmentState,
            AssignmentType,
            PrincipalDisplayName,
            PrincipalType,
            MemberType,
            ScopeType,
            EndDateTime `
            -AutoSize

    if (-not $SkipCsvExport) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $CsvPath = Join-Path `
            -Path $OutputPath `
            -ChildPath "IAM-PrivilegedRoleReport-$Timestamp.csv"

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
    $ErrorMessage = $_.Exception.Message

    if (
        $ErrorMessage -match "403" -or
        $ErrorMessage -match "Authorization_RequestDenied" -or
        $ErrorMessage -match "Insufficient privileges"
    ) {
        Write-Error @"
Privileged-role report generation failed because the Graph session does not
have sufficient permission.

Reconnect using:

Disconnect-MgGraph

Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All"
"@
    }
    else {
        Write-Error "Privileged-role report generation failed: $ErrorMessage"
    }

    exit 1
}