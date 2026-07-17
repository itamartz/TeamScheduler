# ============================================================================
#  TeamScheduler - PowerShell 5.1 data/API layer for scheduler_v3.html
#
#  - Windows PowerShell 5.1, standard user, NO admin rights required.
#  - Storage: JSON files under %LOCALAPPDATA%\TeamScheduler (always user-writable).
#  - HTTP:    System.Net.HttpListener bound to http://localhost:PORT/ only.
#             The literal "localhost" prefix is special-cased by Windows so a
#             non-admin process may register it (no netsh urlacl needed).
#  - JSON field names are snake_case to match the existing HTML UI verbatim
#    (person_id, project_id, domain_id, customer_id, start_min, duration_min).
#
#  PS 5.1 gotchas handled throughout:
#    * ConvertFrom-Json collapses 1-element arrays -> everything wrapped in @()
#    * ConvertTo-Json default -Depth 2 truncates gradients -> always -Depth 10,
#      and -InputObject is used so arrays (incl. empty/1-item) stay arrays
#    * Out-File UTF8 writes a BOM -> [IO.File]::WriteAllText + UTF8Encoding($false)
# ============================================================================

Add-Type -AssemblyName System.Web

$script:DataDir = Join-Path $env:LOCALAPPDATA "TeamScheduler"
$script:DebugMode = $false   # -Debug on Start-SchedulerServer: UI prefixes names/titles with #id
$script:DefaultLeadDays = 14 # build time a project needs before its own deadline, when unset

# ---------------------------------------------------------------------------
# storage layer
# ---------------------------------------------------------------------------

function Set-SchedulerDataDir {
    <#
    .SYNOPSIS
        Overrides the data directory (mainly for testing). Default is
        %LOCALAPPDATA%\TeamScheduler.
    .PARAMETER Path
        Directory that will hold the JSON files.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $script:DataDir = $Path
}

function Get-SchedulerDataDir {
    <# .SYNOPSIS Returns the current data directory. #>
    return $script:DataDir
}

function Save-RawText {
    <#
    .SYNOPSIS
        Writes text as UTF-8 WITHOUT BOM (required for Hebrew + clean JSON).
    .PARAMETER Path
        Full file path.
    .PARAMETER Text
        The exact string to write.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $enc = New-Object System.Text.UTF8Encoding($false)   # $false => no BOM
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Initialize-Store {
    <#
    .SYNOPSIS
        Ensures the data directory and all JSON files exist, seeding empty ones.
        Safe to call repeatedly; never touches existing files.
    #>
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
    $files = @{
        "people.json"       = "[]"
        "customers.json"    = "[]"
        "environments.json" = "[]"
        "projects.json"     = "[]"
        "tasks.json"        = "[]"
        "holidays.json"     = "[]"
        "templates.json"    = "[]"
        "meta.json"         = '{"nextId":{"person":1,"customer":1,"environment":1,"project":1,"task":1,"holiday":1,"template":1}}'
    }
    foreach ($name in $files.Keys) {
        $path = Join-Path $script:DataDir $name
        if (-not (Test-Path $path)) {
            Save-RawText -Path $path -Text $files[$name]
        }
    }
}

function Get-Entities {
    <#
    .SYNOPSIS
        Loads an entity collection from its JSON file as an array.
    .PARAMETER Name
        Entity file base name, e.g. "customers".
    .OUTPUTS
        Always an array (never a scalar), even for 0 or 1 items.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:DataDir "$Name.json"
    if (-not (Test-Path $path)) { return @() }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # PS 5.1 ConvertFrom-Json emits a JSON array as ONE Object[] item, so it
    # must be enumerated (ForEach-Object) or @() nests it; @() then re-wraps
    # scalars so 0-, 1- and N-item files all come back as flat arrays.
    return @(($raw | ConvertFrom-Json) | ForEach-Object { $_ })
}

function Save-Entities {
    <#
    .SYNOPSIS
        Persists an entity collection to its JSON file.
    .PARAMETER Name
        Entity file base name, e.g. "customers".
    .PARAMETER Items
        The array to write. Depth 10 preserves nested gradient colors.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items
    )
    $path = Join-Path $script:DataDir "$Name.json"
    # -InputObject keeps 0- and 1-item arrays serialized as JSON arrays
    $json = ConvertTo-Json -InputObject $Items -Depth 10
    Save-RawText -Path $path -Text $json
}

function Get-NextId {
    <#
    .SYNOPSIS
        Returns and increments the next id for an entity kind.
    .PARAMETER Kind
        One of person|customer|environment|project|task.
    #>
    param([Parameter(Mandatory)][string]$Kind)
    $metaPath = Join-Path $script:DataDir "meta.json"
    $meta = [System.IO.File]::ReadAllText($metaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    # An older meta.json may predate a newer entity kind (e.g. "holiday"): add the
    # counter on first use so existing stores upgrade in place.
    if (-not ($meta.nextId.PSObject.Properties.Name -contains $Kind)) {
        Add-Member -InputObject $meta.nextId -NotePropertyName $Kind -NotePropertyValue 1
    }
    $id = [int]$meta.nextId.$Kind
    if ($id -lt 1) { $id = 1 }
    $meta.nextId.$Kind = $id + 1
    Save-RawText -Path $metaPath -Text (ConvertTo-Json -InputObject $meta -Depth 10)
    return $id
}

# ---------------------------------------------------------------------------
# validation helpers
# ---------------------------------------------------------------------------

function Test-ColorValue {
    <#
    .SYNOPSIS
        Throws if $Color is neither "#hex" nor a gradient {type,angle,stops[2+]}.
    .PARAMETER Color
        Hex string, gradient hashtable, or gradient PSCustomObject.
    #>
    param([Parameter(Mandatory)]$Color)
    if ($Color -is [string]) {
        if ($Color -notmatch '^#[0-9a-fA-F]{3,8}$') {
            throw "Invalid color '$Color' - expected '#rrggbb' or a gradient object."
        }
        return
    }
    $stops = $null
    if ($Color -is [System.Collections.IDictionary]) { $stops = $Color['stops'] }
    elseif ($Color.PSObject.Properties.Name -contains 'stops') { $stops = $Color.stops }
    if ($null -eq $stops -or @($stops).Count -lt 2) {
        throw "Invalid gradient color - 'stops' must contain at least 2 entries."
    }
}

function ConvertTo-ColorKey {
    <#
    .SYNOPSIS
        Normalizes a color (solid or gradient) into a comparable string key.
    .PARAMETER Color
        The color to normalize.
    #>
    param([Parameter(Mandatory)]$Color)
    if ($Color -is [string]) { return $Color.ToLower() }
    if ($Color -is [System.Collections.IDictionary]) {
        $angle = $Color['angle']; $stops = $Color['stops']
    } else {
        $angle = $Color.angle; $stops = $Color.stops
    }
    return ("grad:{0}:{1}" -f $angle, (($stops -join ",").ToLower()))
}

function Test-DateString {
    <#
    .SYNOPSIS
        Throws unless $Date is a valid local "yyyy-MM-dd" string.
    .PARAMETER Date
        Date string to validate.
    #>
    param([Parameter(Mandatory)][string]$Date)
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Date, 'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { throw "Invalid date '$Date' - expected yyyy-MM-dd." }
}

# ---------------------------------------------------------------------------
# people
# ---------------------------------------------------------------------------

function New-Person {
    <#
    .SYNOPSIS  Creates a person (a scheduler row).
    .PARAMETER Name  Display name (Hebrew ok).
    .OUTPUTS   The created person object.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $all = @(Get-Entities "people")
    $item = [PSCustomObject]@{
        id   = Get-NextId "person"
        name = $Name
    }
    $all += $item
    Save-Entities "people" $all
    return $item
}

function Get-People {
    <# .SYNOPSIS Returns all people as an array. #>
    return @(Get-Entities "people")
}

function Set-Person {
    <#
    .SYNOPSIS  Renames a person.
    .PARAMETER Id    Person id.
    .PARAMETER Name  New name.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name
    )
    $all = @(Get-Entities "people")
    $found = $false
    foreach ($p in $all) {
        if ($p.id -eq $Id) { $p.name = $Name; $found = $true }
    }
    if (-not $found) { throw "Person $Id not found" }
    Save-Entities "people" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Person {
    <#
    .SYNOPSIS
        Deletes a person. Refuses if they still have tasks, unless -ReassignTo is
        given, in which case all their tasks move to that person first.
    .PARAMETER Id          Person id.
    .PARAMETER ReassignTo  Person id to receive this person's tasks (0 = don't reassign).
    #>
    param([Parameter(Mandatory)][int]$Id, [int]$ReassignTo = 0)
    $tasks = @(Get-Entities "tasks" | Where-Object { $_.person_id -eq $Id })
    if ($tasks.Count -gt 0) {
        if ($ReassignTo -le 0) {
            throw "Cannot delete person ${Id}: they have $($tasks.Count) task(s). Reassign them first."
        }
        if ($ReassignTo -eq $Id) { throw "Cannot reassign a person's tasks to themselves." }
        if (-not (@(Get-Entities "people") | Where-Object { $_.id -eq $ReassignTo })) {
            throw "Reassign target person $ReassignTo not found."
        }
        $allTasks = @(Get-Entities "tasks")
        foreach ($t in $allTasks) { if ($t.person_id -eq $Id) { $t.person_id = $ReassignTo } }
        Save-Entities "tasks" $allTasks
    }
    $all = @(Get-Entities "people" | Where-Object { $_.id -ne $Id })
    Save-Entities "people" $all
}

# ---------------------------------------------------------------------------
# customers
# ---------------------------------------------------------------------------

function New-Customer {
    <#
    .SYNOPSIS  Creates a customer.
    .PARAMETER Name   Display name (Hebrew ok).
    .PARAMETER Color  Hex string or gradient hashtable/PSCustomObject.
    .OUTPUTS   The created customer object.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Color
    )
    Test-ColorValue -Color $Color
    $all = @(Get-Entities "customers")
    $item = [PSCustomObject]@{
        id    = Get-NextId "customer"
        name  = $Name
        color = $Color
    }
    $all += $item
    Save-Entities "customers" $all
    return $item
}

function Get-Customers {
    <# .SYNOPSIS Returns all customers as an array. #>
    return @(Get-Entities "customers")
}

function Set-Customer {
    <#
    .SYNOPSIS  Updates a customer's name and/or color.
    .PARAMETER Id     Customer id.
    .PARAMETER Name   New name (optional).
    .PARAMETER Color  New color (optional).
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name,
        $Color
    )
    if ($PSBoundParameters.ContainsKey('Color')) { Test-ColorValue -Color $Color }
    $all = @(Get-Entities "customers")
    $found = $false
    foreach ($c in $all) {
        if ($c.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('Name'))  { $c.name  = $Name }
            if ($PSBoundParameters.ContainsKey('Color')) { $c.color = $Color }
            $found = $true
        }
    }
    if (-not $found) { throw "Customer $Id not found" }
    Save-Entities "customers" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Customer {
    <#
    .SYNOPSIS
        Deletes a customer. Refuses if it still has environments, unless -Force,
        which cascade-deletes its environments (and their projects and tasks).
    .PARAMETER Id     Customer id.
    .PARAMETER Force  Cascade-delete all children.
    #>
    param([Parameter(Mandatory)][int]$Id, [switch]$Force)
    $envs = @(Get-Entities "environments" | Where-Object { $_.customer_id -eq $Id })
    if ($envs.Count -gt 0 -and -not $Force) {
        throw "Cannot delete customer ${Id}: it has $($envs.Count) environment(s). Remove them first."
    }
    foreach ($e in $envs) { Remove-Environment -Id $e.id -Force }
    $all = @(Get-Entities "customers" | Where-Object { $_.id -ne $Id })
    Save-Entities "customers" $all
}

# ---------------------------------------------------------------------------
# environments (the UI calls them "domains")
# ---------------------------------------------------------------------------

function Test-EnvironmentColorUnique {
    <#
    .SYNOPSIS  Throws if $Color already belongs to a different environment.
    .PARAMETER Color     Color to check.
    .PARAMETER ExceptId  Environment id to ignore (for updates); 0 for creates.
    #>
    param([Parameter(Mandatory)]$Color, [int]$ExceptId = 0)
    $target = ConvertTo-ColorKey $Color
    foreach ($e in @(Get-Entities "environments")) {
        if ($e.id -eq $ExceptId) { continue }
        if ((ConvertTo-ColorKey $e.color) -eq $target) {
            throw "Environment color already used by '$($e.name)'. Colors must be unique."
        }
    }
}

function New-Environment {
    <#
    .SYNOPSIS  Creates an environment under a customer.
    .PARAMETER CustomerId  Parent customer id.
    .PARAMETER Name        Environment name (e.g. Production).
    .PARAMETER Color       Unique color (enforced across all environments).
    #>
    param(
        [Parameter(Mandatory)][int]$CustomerId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Color
    )
    if (-not (@(Get-Entities "customers") | Where-Object { $_.id -eq $CustomerId })) {
        throw "Customer $CustomerId not found"
    }
    Test-ColorValue -Color $Color
    Test-EnvironmentColorUnique -Color $Color
    $all = @(Get-Entities "environments")
    $item = [PSCustomObject]@{
        id          = Get-NextId "environment"
        customer_id = $CustomerId
        name        = $Name
        color       = $Color
    }
    $all += $item
    Save-Entities "environments" $all
    return $item
}

function Get-Environments {
    <#
    .SYNOPSIS  Returns environments, optionally filtered by customer.
    .PARAMETER CustomerId  0 = all.
    #>
    param([int]$CustomerId = 0)
    $all = @(Get-Entities "environments")
    if ($CustomerId -gt 0) { $all = @($all | Where-Object { $_.customer_id -eq $CustomerId }) }
    return @($all)
}

function Set-Environment {
    <#
    .SYNOPSIS  Updates an environment's name and/or color (color stays unique).
    .PARAMETER Id     Environment id.
    .PARAMETER Name   New name (optional).
    .PARAMETER Color  New color (optional).
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name,
        $Color
    )
    if ($PSBoundParameters.ContainsKey('Color')) {
        Test-ColorValue -Color $Color
        Test-EnvironmentColorUnique -Color $Color -ExceptId $Id
    }
    $all = @(Get-Entities "environments")
    $found = $false
    foreach ($e in $all) {
        if ($e.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('Name'))  { $e.name  = $Name }
            if ($PSBoundParameters.ContainsKey('Color')) { $e.color = $Color }
            $found = $true
        }
    }
    if (-not $found) { throw "Environment $Id not found" }
    Save-Entities "environments" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Environment {
    <#
    .SYNOPSIS
        Deletes an environment. Refuses if it still has projects, unless -Force,
        which cascade-deletes its projects (and their tasks).
    .PARAMETER Id     Environment id.
    .PARAMETER Force  Cascade-delete all children.
    #>
    param([Parameter(Mandatory)][int]$Id, [switch]$Force)
    $projs = @(Get-Entities "projects" | Where-Object { $_.domain_id -eq $Id })
    if ($projs.Count -gt 0 -and -not $Force) {
        throw "Cannot delete environment ${Id}: it has $($projs.Count) project(s). Remove them first."
    }
    foreach ($p in $projs) { Remove-Project -Id $p.id -Force }
    $all = @(Get-Entities "environments" | Where-Object { $_.id -ne $Id })
    Save-Entities "environments" $all
}

# ---------------------------------------------------------------------------
# projects
# ---------------------------------------------------------------------------

function Get-ProjectCustomerId {
    <# .SYNOPSIS  Resolves a project's owning customer id (project -> environment -> customer). #>
    param([Parameter(Mandatory)][int]$ProjectId, $Projects, $Environments)
    if (-not $Projects)     { $Projects     = @(Get-Entities "projects") }
    if (-not $Environments) { $Environments = @(Get-Entities "environments") }
    $p = $Projects     | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1
    if (-not $p) { return $null }
    $d = $Environments | Where-Object { $_.id -eq $p.domain_id } | Select-Object -First 1
    if (-not $d) { return $null }
    return [int]$d.customer_id
}

function Get-ProjectDependsOn {
    <# .SYNOPSIS  A project's depends_on as a normalized int array (handles missing/scalar). #>
    param([Parameter(Mandatory)]$Project)
    if ($Project.PSObject.Properties.Name -notcontains 'depends_on') { return @() }
    return @($Project.depends_on | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ })
}

function Get-ProjectLeadDays {
    <#
    .SYNOPSIS
        A project's lead_days (build time it needs before its own deadline), normalized.
        Projects created before the field existed have no property - they get the default.
    #>
    param([Parameter(Mandatory)]$Project)
    if ($Project.PSObject.Properties.Name -notcontains 'lead_days') { return $script:DefaultLeadDays }
    if ($null -eq $Project.lead_days) { return $script:DefaultLeadDays }
    return [int]$Project.lead_days
}

function Test-LeadDays {
    <# .SYNOPSIS  A lead time must be a non-negative whole number of days. #>
    param([Parameter(Mandatory)][int]$LeadDays)
    if ($LeadDays -lt 0) { throw "Lead days must be 0 or greater (got $LeadDays)" }
}

function Test-ProjectDependencies {
    <#
    .SYNOPSIS
        Validates a proposed depends_on set for a project:
        every dependency must exist, belong to the SAME customer (cross-environment
        is fine, cross-customer is rejected), not be the project itself, and not
        introduce a dependency cycle.
    .PARAMETER Id         The project being set. Use 0 for a not-yet-created project.
    .PARAMETER DependsOn  Proposed list of project ids.
    .PARAMETER CustomerId Owning customer of the project (required when Id = 0).
    #>
    param([Parameter(Mandatory)][int]$Id, $DependsOn, [int]$CustomerId = 0)
    $deps = @($DependsOn | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ } | Select-Object -Unique)
    if ($deps.Count -eq 0) { return }

    $projects = @(Get-Entities "projects")
    $envs     = @(Get-Entities "environments")
    $byId = @{}; foreach ($p in $projects) { $byId[[int]$p.id] = $p }

    $myCust = if ($Id -gt 0) { Get-ProjectCustomerId -ProjectId $Id -Projects $projects -Environments $envs } else { $CustomerId }

    foreach ($d in $deps) {
        if ($Id -gt 0 -and $d -eq $Id) { throw "A project cannot depend on itself." }
        if (-not $byId.ContainsKey($d)) { throw "Dependency project $d not found." }
        $dc = Get-ProjectCustomerId -ProjectId $d -Projects $projects -Environments $envs
        if ($dc -ne $myCust) {
            throw "Dependency '$($byId[$d].name)' belongs to a different customer. Dependencies may cross environments but not customers."
        }
    }
    if ($Id -le 0) { return }   # a brand-new project can't be part of an existing cycle

    # cycle check: with Id -> deps applied, Id must not be reachable from any dep
    $adj = @{}
    foreach ($p in $projects) {
        $pid = [int]$p.id
        $adj[$pid] = if ($pid -eq $Id) { $deps } else { Get-ProjectDependsOn -Project $p }
    }
    $stack = New-Object System.Collections.Stack
    foreach ($d in $deps) { $stack.Push($d) }
    $seen = @{}
    while ($stack.Count -gt 0) {
        $n = [int]$stack.Pop()
        if ($n -eq $Id) { throw "That dependency would create a cycle." }
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        if ($adj.ContainsKey($n)) { foreach ($m in @($adj[$n])) { $stack.Push([int]$m) } }
    }
}

function New-Project {
    <#
    .SYNOPSIS  Creates an active project under an environment.
    .PARAMETER DomainId  Parent environment id.
    .PARAMETER Name      Project name.
    .PARAMETER Color     Project color (solid or gradient).
    #>
    param(
        [Parameter(Mandatory)][int]$DomainId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Color,
        [AllowEmptyCollection()][int[]]$DependsOn = @(),
        [string]$Deadline,
        [int]$LeadDays = $script:DefaultLeadDays
    )
    $env = @(Get-Entities "environments") | Where-Object { $_.id -eq $DomainId } | Select-Object -First 1
    if (-not $env) { throw "Environment $DomainId not found" }
    Test-ColorValue -Color $Color
    if (@($DependsOn).Count) {
        Test-ProjectDependencies -Id 0 -DependsOn $DependsOn -CustomerId ([int]$env.customer_id)
    }
    Test-LeadDays -LeadDays $LeadDays
    # optional target/deadline date; empty means "no deadline"
    $dl = $null
    if (-not [string]::IsNullOrWhiteSpace($Deadline)) { Test-DateString -Date $Deadline; $dl = $Deadline }
    $all = @(Get-Entities "projects")
    $item = [PSCustomObject]@{
        id         = Get-NextId "project"
        domain_id  = $DomainId
        name       = $Name
        status     = "active"
        color      = $Color
        created_at = (Get-Date -Format "yyyy-MM-dd")   # local time, never UTC
        closed_at  = $null
        deadline   = $dl
        lead_days  = $LeadDays
        depends_on = @($DependsOn)
    }
    $all += $item
    Save-Entities "projects" $all
    return $item
}

function Get-Projects {
    <#
    .SYNOPSIS  Returns projects, optionally filtered by environment.
    .PARAMETER DomainId  0 = all.
    #>
    param([int]$DomainId = 0)
    $all = @(Get-Entities "projects")
    if ($DomainId -gt 0) { $all = @($all | Where-Object { $_.domain_id -eq $DomainId }) }
    return @($all)
}

function Set-Project {
    <#
    .SYNOPSIS  Updates a project's name, color and/or environment.
    .PARAMETER Id        Project id.
    .PARAMETER Name      New name (optional).
    .PARAMETER Color     New color (optional).
    .PARAMETER DomainId  Move to another environment (optional).
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name,
        $Color,
        [int]$DomainId,
        [AllowEmptyCollection()][int[]]$DependsOn,
        [string]$Deadline,
        [int]$LeadDays
    )
    if ($PSBoundParameters.ContainsKey('Color')) { Test-ColorValue -Color $Color }
    if ($PSBoundParameters.ContainsKey('Deadline') -and -not [string]::IsNullOrWhiteSpace($Deadline)) {
        Test-DateString -Date $Deadline
    }
    if ($PSBoundParameters.ContainsKey('LeadDays')) { Test-LeadDays -LeadDays $LeadDays }
    if ($PSBoundParameters.ContainsKey('DomainId')) {
        if (-not (@(Get-Entities "environments") | Where-Object { $_.id -eq $DomainId })) {
            throw "Environment $DomainId not found"
        }
    }
    # validate dependencies against the project's customer (after any DomainId move,
    # the customer is unchanged since a move only crosses environments of validation below)
    if ($PSBoundParameters.ContainsKey('DependsOn')) {
        Test-ProjectDependencies -Id $Id -DependsOn $DependsOn
    }
    $all = @(Get-Entities "projects")
    $found = $false
    foreach ($p in $all) {
        if ($p.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('Name'))      { $p.name      = $Name }
            if ($PSBoundParameters.ContainsKey('Color'))     { $p.color     = $Color }
            if ($PSBoundParameters.ContainsKey('DomainId'))  { $p.domain_id = $DomainId }
            if ($PSBoundParameters.ContainsKey('Deadline')) {
                # empty string clears the deadline; Add-Member -Force also upgrades pre-deadline projects
                $dl = if ([string]::IsNullOrWhiteSpace($Deadline)) { $null } else { $Deadline }
                $p | Add-Member -NotePropertyName deadline -NotePropertyValue $dl -Force
            }
            if ($PSBoundParameters.ContainsKey('LeadDays')) {
                # Add-Member -Force upgrades projects created before the field existed
                $p | Add-Member -NotePropertyName lead_days -NotePropertyValue $LeadDays -Force
            }
            if ($PSBoundParameters.ContainsKey('DependsOn')) {
                $p | Add-Member -NotePropertyName depends_on -NotePropertyValue @($DependsOn) -Force
            }
            $found = $true
        }
    }
    if (-not $found) { throw "Project $Id not found" }
    Save-Entities "projects" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Close-Project {
    <# .SYNOPSIS Sets status=closed and stamps closed_at=today (soft delete). #>
    param([Parameter(Mandatory)][int]$Id)
    $all = @(Get-Entities "projects")
    $found = $false
    foreach ($p in $all) {
        if ($p.id -eq $Id) {
            $p.status = "closed"
            $p.closed_at = (Get-Date -Format "yyyy-MM-dd")
            $found = $true
        }
    }
    if (-not $found) { throw "Project $Id not found" }
    Save-Entities "projects" $all
}

function Open-Project {
    <# .SYNOPSIS Reopens a project: status=active, closed_at=null. #>
    param([Parameter(Mandatory)][int]$Id)
    $all = @(Get-Entities "projects")
    $found = $false
    foreach ($p in $all) {
        if ($p.id -eq $Id) {
            $p.status = "active"
            $p.closed_at = $null
            $found = $true
        }
    }
    if (-not $found) { throw "Project $Id not found" }
    Save-Entities "projects" $all
}

function Remove-Project {
    <#
    .SYNOPSIS
        Hard-deletes a project. Refuses if it has tasks unless -Force,
        in which case its tasks are cascade-deleted. Prefer Close-Project.
    .PARAMETER Id     Project id.
    .PARAMETER Force  Also delete the project's tasks.
    #>
    param([Parameter(Mandatory)][int]$Id, [switch]$Force)
    $tasks = @(Get-Entities "tasks" | Where-Object { $_.project_id -eq $Id })
    if ($tasks.Count -gt 0 -and -not $Force) {
        throw "Cannot delete project ${Id}: it has $($tasks.Count) task(s). Close it instead, or pass force=1."
    }
    if ($tasks.Count -gt 0) {
        Save-Entities "tasks" @(Get-Entities "tasks" | Where-Object { $_.project_id -ne $Id })
    }
    $all = @(Get-Entities "projects" | Where-Object { $_.id -ne $Id })
    Save-Entities "projects" $all
}

function Copy-ProjectToEnvironment {
    <#
    .SYNOPSIS
        Copies a project AND its whole dependency chain into another environment
        of the SAME customer. A dependency already present (by name) in the target
        environment is reused rather than duplicated, and the copied project's
        depends_on is rewired to the target-environment equivalents - so the copy
        has no "missing dependency" gaps.
    .PARAMETER Id           Source project id.
    .PARAMETER ToDomainId   Target environment id (same customer).
    .OUTPUTS
        { rootId, createdCount, created[] }
    #>
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][int]$ToDomainId)
    $projects = @(Get-Entities "projects")
    $envs     = @(Get-Entities "environments")
    $src   = $projects | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $src) { throw "Project $Id not found" }
    $toEnv = $envs | Where-Object { $_.id -eq $ToDomainId } | Select-Object -First 1
    if (-not $toEnv) { throw "Environment $ToDomainId not found" }
    if ([int]$src.domain_id -eq $ToDomainId) { throw "The project is already in that environment." }
    $srcCust = Get-ProjectCustomerId -ProjectId $Id -Projects $projects -Environments $envs
    if ([int]$toEnv.customer_id -ne $srcCust) {
        throw "Cannot copy: the target environment belongs to a different customer."
    }

    $script:_cpById = @{}; foreach ($p in $projects) { $script:_cpById[[int]$p.id] = $p }
    $script:_cpMap = @{}                                   # source id -> target id
    $script:_cpCreated = New-Object System.Collections.ArrayList
    $script:_cpProjects = $projects
    $script:_cpTo = $ToDomainId

    function _cpFindInTarget([string]$name) {
        $e = $script:_cpProjects | Where-Object { $_.domain_id -eq $script:_cpTo -and $_.name -eq $name } | Select-Object -First 1
        if ($e) { return $e }
        foreach ($c in $script:_cpCreated) { if ($c.domain_id -eq $script:_cpTo -and $c.name -eq $name) { return $c } }
        return $null
    }
    function _cpCopyOne([int]$oldId) {
        if ($script:_cpMap.ContainsKey($oldId)) { return $script:_cpMap[$oldId] }
        $p = $script:_cpById[$oldId]
        $existing = _cpFindInTarget $p.name
        if ($existing) { $script:_cpMap[$oldId] = [int]$existing.id; return [int]$existing.id }
        $newDeps = @()
        foreach ($d in (Get-ProjectDependsOn -Project $p)) { $newDeps += (_cpCopyOne $d) }
        $item = [PSCustomObject]@{
            id         = Get-NextId "project"
            domain_id  = $script:_cpTo
            name       = $p.name
            status     = "active"
            color      = $p.color
            created_at = (Get-Date -Format "yyyy-MM-dd")
            closed_at  = $null
            lead_days  = (Get-ProjectLeadDays -Project $p)
            depends_on = @($newDeps)
        }
        [void]$script:_cpCreated.Add($item)
        $script:_cpMap[$oldId] = [int]$item.id
        return [int]$item.id
    }

    $rootNew = _cpCopyOne $Id
    if ($script:_cpCreated.Count) {
        Save-Entities "projects" (@(Get-Entities "projects") + @($script:_cpCreated))
    }
    return [PSCustomObject]@{ rootId = $rootNew; createdCount = $script:_cpCreated.Count; created = @($script:_cpCreated) }
}

# ---------------------------------------------------------------------------
# tasks
# ---------------------------------------------------------------------------

function New-Task {
    <#
    .SYNOPSIS  Creates a task.
    .PARAMETER PersonId     Assignee, or 0 for an UNASSIGNED task.
    .PARAMETER ProjectId    Owning project (resolves environment + customer + color).
    .PARAMETER Title        Task text.
    .PARAMETER Date         "yyyy-MM-dd" LOCAL date (never UTC - no day shifts).
    .PARAMETER StartMin     Minutes from midnight (480 = 08:00).
    .PARAMETER DurationMin  Length in minutes (e.g. 30 or 60).
    #>
    param(
        [int]$PersonId = 0,
        [Parameter(Mandatory)][int]$ProjectId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][int]$StartMin,
        [Parameter(Mandatory)][int]$DurationMin
    )
    Test-DateString -Date $Date
    if ($PersonId -ne 0 -and -not (@(Get-Entities "people") | Where-Object { $_.id -eq $PersonId })) {
        throw "Person $PersonId not found"
    }
    if (-not (@(Get-Entities "projects") | Where-Object { $_.id -eq $ProjectId })) {
        throw "Project $ProjectId not found"
    }
    if ($StartMin -lt 0 -or $StartMin -gt 1439) { throw "start_min must be 0..1439" }
    if ($DurationMin -le 0) { throw "duration_min must be positive" }
    $all = @(Get-Entities "tasks")
    $item = [PSCustomObject]@{
        id           = Get-NextId "task"
        person_id    = $PersonId
        project_id   = $ProjectId
        title        = $Title
        date         = $Date
        start_min    = $StartMin
        duration_min = $DurationMin
    }
    $all += $item
    Save-Entities "tasks" $all
    return $item
}

function Get-Tasks {
    <#
    .SYNOPSIS  Returns tasks, optionally filtered by date range and/or person.
    .PARAMETER From      Inclusive "yyyy-MM-dd" (optional).
    .PARAMETER To        Inclusive "yyyy-MM-dd" (optional).
    .PARAMETER PersonId  Filter to one person (optional).
    #>
    param([string]$From, [string]$To, [int]$PersonId = 0)
    $all = @(Get-Entities "tasks")
    if ($From)           { $all = @($all | Where-Object { $_.date -ge $From }) }
    if ($To)             { $all = @($all | Where-Object { $_.date -le $To }) }
    if ($PersonId -gt 0) { $all = @($all | Where-Object { $_.person_id -eq $PersonId }) }
    return @($all)
}

function Set-Task {
    <# .SYNOPSIS Updates any subset of a task's fields. #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [int]$PersonId, [int]$ProjectId, [string]$Title,
        [string]$Date, [int]$StartMin, [int]$DurationMin
    )
    if ($PSBoundParameters.ContainsKey('Date')) { Test-DateString -Date $Date }
    if ($PSBoundParameters.ContainsKey('PersonId')) {
        if ($PersonId -ne 0 -and -not (@(Get-Entities "people") | Where-Object { $_.id -eq $PersonId })) {
            throw "Person $PersonId not found"   # 0 = unassigned
        }
    }
    if ($PSBoundParameters.ContainsKey('ProjectId')) {
        if (-not (@(Get-Entities "projects") | Where-Object { $_.id -eq $ProjectId })) {
            throw "Project $ProjectId not found"
        }
    }
    $all = @(Get-Entities "tasks")
    $found = $false
    foreach ($t in $all) {
        if ($t.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('PersonId'))    { $t.person_id    = $PersonId }
            if ($PSBoundParameters.ContainsKey('ProjectId'))   { $t.project_id   = $ProjectId }
            if ($PSBoundParameters.ContainsKey('Title'))       { $t.title        = $Title }
            if ($PSBoundParameters.ContainsKey('Date'))        { $t.date         = $Date }
            if ($PSBoundParameters.ContainsKey('StartMin'))    { $t.start_min    = $StartMin }
            if ($PSBoundParameters.ContainsKey('DurationMin')) { $t.duration_min = $DurationMin }
            $found = $true
        }
    }
    if (-not $found) { throw "Task $Id not found" }
    Save-Entities "tasks" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Task {
    <# .SYNOPSIS Deletes a task (always allowed). #>
    param([Parameter(Mandatory)][int]$Id)
    $all = @(Get-Entities "tasks" | Where-Object { $_.id -ne $Id })
    Save-Entities "tasks" $all
}

# ---------------------------------------------------------------------------
# holidays  (global, date-range; a task on a holiday date is warned, never blocked)
# ---------------------------------------------------------------------------

function New-Holiday {
    <#
    .SYNOPSIS  Creates a holiday spanning an inclusive local date range.
    .PARAMETER Name  Holiday label (e.g. "יום העצמאות").
    .PARAMETER From  Inclusive "yyyy-MM-dd" LOCAL start date.
    .PARAMETER To    Inclusive "yyyy-MM-dd" LOCAL end date (>= From).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Holiday name is required." }
    Test-DateString -Date $From
    Test-DateString -Date $To
    if ($To -lt $From) { throw "Holiday end date must be on or after the start date." }
    $all = @(Get-Entities "holidays")
    $item = [PSCustomObject]@{
        id   = Get-NextId "holiday"
        name = $Name
        from = $From
        to   = $To
    }
    $all += $item
    Save-Entities "holidays" $all
    return $item
}

function Get-Holidays {
    <# .SYNOPSIS Returns all holidays. #>
    return @(Get-Entities "holidays")
}

function Set-Holiday {
    <# .SYNOPSIS Updates any subset of a holiday's fields. #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name, [string]$From, [string]$To
    )
    if ($PSBoundParameters.ContainsKey('From')) { Test-DateString -Date $From }
    if ($PSBoundParameters.ContainsKey('To'))   { Test-DateString -Date $To }
    $all = @(Get-Entities "holidays")
    $found = $false
    foreach ($h in $all) {
        if ($h.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('Name')) { $h.name = $Name }
            if ($PSBoundParameters.ContainsKey('From')) { $h.from = $From }
            if ($PSBoundParameters.ContainsKey('To'))   { $h.to   = $To }
            if ($h.to -lt $h.from) { throw "Holiday end date must be on or after the start date." }
            $found = $true
        }
    }
    if (-not $found) { throw "Holiday $Id not found" }
    Save-Entities "holidays" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Holiday {
    <# .SYNOPSIS Deletes a holiday (always allowed). #>
    param([Parameter(Mandatory)][int]$Id)
    $all = @(Get-Entities "holidays" | Where-Object { $_.id -ne $Id })
    Save-Entities "holidays" $all
}

# ---------------------------------------------------------------------------
# task templates  (global library; a template = a named list of {title,duration_min}.
# Applying one to a project creates back-to-back UNASSIGNED tasks from a start time.)
# ---------------------------------------------------------------------------

function ConvertTo-TemplateTasks {
    <#
    .SYNOPSIS
        Validates/normalizes an array of template tasks to [{title,duration_min}].
        Accepts hashtables or PSCustomObjects; throws on a missing title or a
        non-positive duration. Returns an array (0/1/N items all stay arrays).
    #>
    param([object[]]$Tasks)
    $out = @()
    foreach ($t in @($Tasks)) {
        if ($null -eq $t) { continue }
        if ($t -is [System.Collections.IDictionary]) { $title = $t['title']; $dur = $t['duration_min'] }
        else { $title = $t.title; $dur = $t.duration_min }
        if ([string]::IsNullOrWhiteSpace([string]$title)) { throw "Each template task needs a title." }
        $d = 0
        if (-not [int]::TryParse([string]$dur, [ref]$d) -or $d -le 0) {
            throw "Each template task needs a positive duration (minutes)."
        }
        $out += [PSCustomObject]@{ title = [string]$title; duration_min = $d }
    }
    return ,$out
}

function New-Template {
    <#
    .SYNOPSIS  Creates a task template.
    .PARAMETER Name   Template label (e.g. "New server setup").
    .PARAMETER Tasks  Array of { title, duration_min } (order is preserved).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Tasks = @()
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Template name is required." }
    $norm = ConvertTo-TemplateTasks $Tasks
    $all = @(Get-Entities "templates")
    $item = [PSCustomObject]@{
        id    = Get-NextId "template"
        name  = $Name
        tasks = $norm
    }
    $all += $item
    Save-Entities "templates" $all
    return $item
}

function Get-Templates {
    <# .SYNOPSIS Returns all templates. #>
    return @(Get-Entities "templates")
}

function Set-Template {
    <# .SYNOPSIS Updates a template's name and/or its task list. #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name,
        [object[]]$Tasks
    )
    $all = @(Get-Entities "templates")
    $found = $false
    foreach ($tp in $all) {
        if ($tp.id -eq $Id) {
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ([string]::IsNullOrWhiteSpace($Name)) { throw "Template name is required." }
                $tp.name = $Name
            }
            if ($PSBoundParameters.ContainsKey('Tasks')) { $tp.tasks = ConvertTo-TemplateTasks $Tasks }
            $found = $true
        }
    }
    if (-not $found) { throw "Template $Id not found" }
    Save-Entities "templates" $all
    return ($all | Where-Object { $_.id -eq $Id })
}

function Remove-Template {
    <# .SYNOPSIS Deletes a template (always allowed; never touches existing tasks). #>
    param([Parameter(Mandatory)][int]$Id)
    $all = @(Get-Entities "templates" | Where-Object { $_.id -ne $Id })
    Save-Entities "templates" $all
}

function Add-TemplateToProject {
    <#
    .SYNOPSIS
        Instantiates a template's tasks onto a project: creates one task per
        template entry, laid out back-to-back from $StartMin on $Date, all
        assigned to $PersonId (default 0 = UNASSIGNED). Returns the new tasks.
    #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$ProjectId,
        [Parameter(Mandatory)][string]$Date,
        [int]$StartMin = 480,
        [int]$PersonId = 0
    )
    Test-DateString -Date $Date
    $tpl = @(Get-Entities "templates") | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $tpl) { throw "Template $Id not found" }
    if (-not (@(Get-Entities "projects") | Where-Object { $_.id -eq $ProjectId })) { throw "Project $ProjectId not found" }
    if ($PersonId -ne 0 -and -not (@(Get-Entities "people") | Where-Object { $_.id -eq $PersonId })) { throw "Person $PersonId not found" }
    if ($StartMin -lt 0 -or $StartMin -gt 1439) { throw "start_min must be 0..1439" }
    $tasks = @($tpl.tasks | ForEach-Object { $_ })
    $created = @()
    $cur = $StartMin
    foreach ($tt in $tasks) {
        $dur = [int]$tt.duration_min
        $created += New-Task -PersonId $PersonId -ProjectId $ProjectId -Title ([string]$tt.title) `
                             -Date $Date -StartMin $cur -DurationMin $dur
        $cur += $dur
    }
    # return the items unwrapped; the route re-wraps with ,@(...) for a flat JSON array
    return $created
}

# ---------------------------------------------------------------------------
# body -> named-parameter bridges (PUT handlers pass only present properties)
# ---------------------------------------------------------------------------

function Select-BodyParams {
    <#
    .SYNOPSIS
        Builds a splat hashtable from a JSON body, mapping snake_case
        properties to named parameters, including only those present.
    .PARAMETER Body  Parsed JSON body (PSCustomObject).
    .PARAMETER Map   snake_case property -> parameter name.
    #>
    param([Parameter(Mandatory)]$Body, [Parameter(Mandatory)][hashtable]$Map)
    $splat = @{}
    if ($null -eq $Body) { return $splat }
    $props = $Body.PSObject.Properties.Name
    foreach ($k in $Map.Keys) {
        if ($props -contains $k) { $splat[$Map[$k]] = $Body.$k }
    }
    return $splat
}

function Set-CustomerFromBody {
    <# .SYNOPSIS PUT /api/customers/{id} bridge. #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = Select-BodyParams -Body $Body -Map @{ name = 'Name'; color = 'Color' }
    return Set-Customer -Id $Id @splat
}

function Set-EnvironmentFromBody {
    <# .SYNOPSIS PUT /api/environments/{id} bridge. #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = Select-BodyParams -Body $Body -Map @{ name = 'Name'; color = 'Color' }
    return Set-Environment -Id $Id @splat
}

function Set-ProjectFromBody {
    <# .SYNOPSIS PUT /api/projects/{id} bridge. #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = Select-BodyParams -Body $Body -Map @{ name = 'Name'; color = 'Color'; domain_id = 'DomainId'; deadline = 'Deadline'; lead_days = 'LeadDays' }
    if ($Body -and ($Body.PSObject.Properties.Name -contains 'depends_on')) {
        $splat['DependsOn'] = @($Body.depends_on | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ })
    }
    return Set-Project -Id $Id @splat
}

function Set-TaskFromBody {
    <# .SYNOPSIS PUT /api/tasks/{id} bridge. #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = Select-BodyParams -Body $Body -Map @{
        person_id = 'PersonId'; project_id = 'ProjectId'; title = 'Title'
        date = 'Date'; start_min = 'StartMin'; duration_min = 'DurationMin'
    }
    return Set-Task -Id $Id @splat
}

function Set-HolidayFromBody {
    <# .SYNOPSIS PUT /api/holidays/{id} bridge. #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = Select-BodyParams -Body $Body -Map @{ name = 'Name'; from = 'From'; to = 'To' }
    return Set-Holiday -Id $Id @splat
}

function Set-TemplateFromBody {
    <# .SYNOPSIS PUT /api/templates/{id} bridge (name and/or full task list). #>
    param([Parameter(Mandatory)][int]$Id, $Body)
    $splat = @{}
    if ($Body -and ($Body.PSObject.Properties.Name -contains 'name'))  { $splat['Name']  = $Body.name }
    if ($Body -and ($Body.PSObject.Properties.Name -contains 'tasks')) { $splat['Tasks'] = @($Body.tasks) }
    return Set-Template -Id $Id @splat
}

# ---------------------------------------------------------------------------
# seed data
# ---------------------------------------------------------------------------

function Import-SeedData {
    <#
    .SYNOPSIS
        Seeds the demo customers/environments/projects/people from
        seed-data.json - but ONLY when the store is empty (customers.json = []).
    .PARAMETER SeedPath
        Path to the seed file; defaults to seed-data.json beside the module.
    #>
    param([string]$SeedPath)
    if (-not $SeedPath) { $SeedPath = Join-Path $PSScriptRoot "seed-data.json" }
    if (@(Get-Entities "customers").Count -gt 0) { return }
    if (-not (Test-Path $SeedPath)) { return }
    $raw  = [System.IO.File]::ReadAllText($SeedPath, [System.Text.Encoding]::UTF8)
    $seed = $raw | ConvertFrom-Json
    Save-Entities "people"       @($seed.people)
    Save-Entities "customers"    @($seed.customers)
    Save-Entities "environments" @($seed.environments)
    Save-Entities "projects"     @($seed.projects)
    if ($seed.PSObject.Properties.Name -contains "next_id") {
        $meta = [PSCustomObject]@{ nextId = $seed.next_id }
        Save-RawText -Path (Join-Path $script:DataDir "meta.json") `
                     -Text (ConvertTo-Json -InputObject $meta -Depth 10)
    }
    Write-Host "Seeded demo data from $SeedPath"
}

# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

function Write-JsonResponse {
    <#
    .SYNOPSIS  Writes an object as UTF-8 JSON. StatusCode 0 = leave as-is.
    #>
    param($Response, $Object, [int]$StatusCode = 0)
    if ($StatusCode -gt 0) { $Response.StatusCode = $StatusCode }
    $Response.ContentType = "application/json; charset=utf-8"
    $json  = ConvertTo-Json -InputObject $Object -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Get-QueryInt {
    <#
    .SYNOPSIS  Reads an int query parameter, accepting camelCase or snake_case.
    #>
    param($Query, [string[]]$Names)
    foreach ($n in $Names) {
        $v = $Query[$n]
        if ($v) {
            $parsed = 0
            if ([int]::TryParse($v, [ref]$parsed)) { return $parsed }
        }
    }
    return 0
}

function Invoke-ApiRoute {
    <#
    .SYNOPSIS  Dispatches one request to the right CRUD function.
    .OUTPUTS   The object to serialize, or $null if the handler already wrote
               the response (e.g. the HTML page).
    #>
    param($Method, $Url, $Body, $HtmlPath, $Response)

    $path = $Url.AbsolutePath.TrimEnd('/')
    if ($path -eq "") { $path = "/" }

    # ---- serve the UI ----
    if ($Method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
        $html  = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        $Response.ContentType = "text/html; charset=utf-8"
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        return $null
    }

    # ---- bootstrap: everything in one payload ----
    if ($Method -eq "GET" -and $path -eq "/api/bootstrap") {
        return [PSCustomObject]@{
            people       = @(Get-Entities "people")
            customers    = @(Get-Entities "customers")
            environments = @(Get-Entities "environments")
            projects     = @(Get-Entities "projects")
            tasks        = @(Get-Entities "tasks")
            holidays     = @(Get-Entities "holidays")
            templates    = @(Get-Entities "templates")
            debug        = [bool]$script:DebugMode
        }
    }

    # ---- split "/api/tasks/12/close" => entity "tasks", id 12, sub "close" ----
    $parts = @($path.TrimStart('/').Split('/'))
    if ($parts.Count -lt 2 -or $parts[0] -ne "api") {
        $Response.StatusCode = 404
        return @{ error = "no route for $Method $path" }
    }
    $entity = $parts[1]
    $id = 0
    if ($parts.Count -ge 3) { [void][int]::TryParse($parts[2], [ref]$id) }
    $sub = $null
    if ($parts.Count -ge 4) { $sub = $parts[3] }
    $q = [System.Web.HttpUtility]::ParseQueryString($Url.Query)

    switch ($entity) {
        "tasks" {
            switch ($Method) {
                "GET"    { return ,@(Get-Tasks -From $q["from"] -To $q["to"] -PersonId (Get-QueryInt $q @("person_id","personId"))) }
                "POST"   { return New-Task -PersonId $Body.person_id -ProjectId $Body.project_id -Title $Body.title -Date $Body.date -StartMin $Body.start_min -DurationMin $Body.duration_min }
                "PUT"    { return Set-TaskFromBody -Id $id -Body $Body }
                "DELETE" { Remove-Task -Id $id; return @{ ok = $true } }
            }
        }
        "projects" {
            if ($Method -eq "POST" -and $sub -eq "close") { Close-Project -Id $id; return @{ ok = $true } }
            if ($Method -eq "POST" -and $sub -eq "open")  { Open-Project  -Id $id; return @{ ok = $true } }
            if ($Method -eq "POST" -and $sub -eq "copy")  {
                $toDom = 0
                if ($Body -and ($Body.PSObject.Properties.Name -contains 'to_domain_id')) { $toDom = [int]$Body.to_domain_id }
                return Copy-ProjectToEnvironment -Id $id -ToDomainId $toDom
            }
            switch ($Method) {
                "GET"    { return ,@(Get-Projects -DomainId (Get-QueryInt $q @("domain_id","domainId"))) }
                "POST"   {
                    $deps = @()
                    if ($Body.PSObject.Properties.Name -contains 'depends_on') {
                        $deps = @($Body.depends_on | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ })
                    }
                    $extra = @{}
                    if ($Body.PSObject.Properties.Name -contains 'lead_days' -and $null -ne $Body.lead_days -and "$($Body.lead_days)" -ne '') {
                        $extra['LeadDays'] = [int]$Body.lead_days
                    }
                    return New-Project -DomainId $Body.domain_id -Name $Body.name -Color $Body.color -DependsOn $deps -Deadline $Body.deadline @extra
                }
                "PUT"    { return Set-ProjectFromBody -Id $id -Body $Body }
                "DELETE" {
                    $force = ($q["force"] -eq "1" -or $q["force"] -eq "true")
                    Remove-Project -Id $id -Force:$force
                    return @{ ok = $true }
                }
            }
        }
        "environments" {
            switch ($Method) {
                "GET"    { return ,@(Get-Environments -CustomerId (Get-QueryInt $q @("customer_id","customerId"))) }
                "POST"   { return New-Environment -CustomerId $Body.customer_id -Name $Body.name -Color $Body.color }
                "PUT"    { return Set-EnvironmentFromBody -Id $id -Body $Body }
                "DELETE" {
                    $force = ($q["force"] -eq "1" -or $q["force"] -eq "true")
                    Remove-Environment -Id $id -Force:$force
                    return @{ ok = $true }
                }
            }
        }
        "customers" {
            switch ($Method) {
                "GET"    { return ,@(Get-Customers) }
                "POST"   { return New-Customer -Name $Body.name -Color $Body.color }
                "PUT"    { return Set-CustomerFromBody -Id $id -Body $Body }
                "DELETE" {
                    $force = ($q["force"] -eq "1" -or $q["force"] -eq "true")
                    Remove-Customer -Id $id -Force:$force
                    return @{ ok = $true }
                }
            }
        }
        "people" {
            switch ($Method) {
                "GET"    { return ,@(Get-People) }
                "POST"   { return New-Person -Name $Body.name }
                "PUT"    { return Set-Person -Id $id -Name $Body.name }
                "DELETE" {
                    $rt = Get-QueryInt $q @("reassign_to","reassignTo")
                    Remove-Person -Id $id -ReassignTo $rt
                    return @{ ok = $true }
                }
            }
        }
        "holidays" {
            switch ($Method) {
                "GET"    { return ,@(Get-Holidays) }
                "POST"   { return New-Holiday -Name $Body.name -From $Body.from -To $Body.to }
                "PUT"    { return Set-HolidayFromBody -Id $id -Body $Body }
                "DELETE" { Remove-Holiday -Id $id; return @{ ok = $true } }
            }
        }
        "templates" {
            if ($Method -eq "POST" -and $sub -eq "apply") {
                $sm = 480; if ($Body.PSObject.Properties.Name -contains 'start_min') { $sm = [int]$Body.start_min }
                $pid = 0;  if ($Body.PSObject.Properties.Name -contains 'person_id') { $pid = [int]$Body.person_id }
                return ,@(Add-TemplateToProject -Id $id -ProjectId ([int]$Body.project_id) -Date $Body.date -StartMin $sm -PersonId $pid)
            }
            switch ($Method) {
                "GET"    { return ,@(Get-Templates) }
                "POST"   { return New-Template -Name $Body.name -Tasks @($Body.tasks) }
                "PUT"    { return Set-TemplateFromBody -Id $id -Body $Body }
                "DELETE" { Remove-Template -Id $id; return @{ ok = $true } }
            }
        }
    }
    $Response.StatusCode = 404
    return @{ error = "no route for $Method $path" }
}

function Backup-SchedulerData {
    <#
    .SYNOPSIS
        Zips all JSON data files into a timestamped archive under <DataDir>\backups\.
        Called automatically when the server stops. Safe to call anytime; never throws
        out (failures are reported by the caller). Backups live inside the data folder
        but are excluded from the archive (only *.json in the root are captured).
    .OUTPUTS
        The path of the zip written, or $null if there was nothing to back up.
    #>
    $files = @(Get-ChildItem -Path $script:DataDir -Filter *.json -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $null }
    $backupDir = Join-Path $script:DataDir "backups"
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $zip   = Join-Path $backupDir "backup_$stamp.zip"
    Compress-Archive -Path $files.FullName -DestinationPath $zip -Force
    return $zip
}

function Start-SchedulerServer {
    <#
    .SYNOPSIS
        Runs the local HTTP server until Ctrl+C. No admin rights needed:
        the prefix is http://localhost:PORT/ which Windows allows for
        standard users (no netsh urlacl).
    .PARAMETER Port       TCP port (default 8770). If taken, try another high port.
    .PARAMETER HtmlPath   Path to scheduler_v3.html to serve at "/".
    .PARAMETER NoBrowser  Skip auto-opening the default browser.
    #>
    param(
        [int]$Port = 8770,
        [string]$HtmlPath = (Join-Path $PSScriptRoot "scheduler_v3.html"),
        [switch]$NoBrowser,
        [switch]$Debug
    )
    $script:DebugMode = [bool]$Debug   # surfaced to the UI via /api/bootstrap
    Initialize-Store
    Import-SeedData

    if (-not (Test-Path $HtmlPath)) { throw "HTML file not found: $HtmlPath" }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")   # localhost => no urlacl, no admin
    try {
        $listener.Start()
    }
    catch {
        throw "Could not bind http://localhost:$Port/ - the port may be in use or blocked. Try another high port, e.g. Start-SchedulerServer -Port 8771. ($($_.Exception.Message))"
    }

    Write-Host "Scheduler running at http://localhost:$Port/   (Ctrl+C to stop)"
    Write-Host "Data folder: $script:DataDir"
    if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

    try {
        while ($listener.IsListening) {
            # GetContextAsync + short waits keep Ctrl+C responsive in PS 5.1
            $ctxTask = $listener.GetContextAsync()
            while (-not $ctxTask.AsyncWaitHandle.WaitOne(250)) {
                if (-not $listener.IsListening) { return }
            }
            $ctx = $ctxTask.GetAwaiter().GetResult()
            $req = $ctx.Request
            $res = $ctx.Response
            $res.Headers.Add("Access-Control-Allow-Origin", "*")
            try {
                if ($req.HttpMethod -eq "OPTIONS") {
                    $res.Headers.Add("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
                    $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
                    $res.StatusCode = 204
                }
                else {
                    $body = $null
                    if ($req.HasEntityBody) {
                        $reader  = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $bodyRaw = $reader.ReadToEnd(); $reader.Close()
                        if ($bodyRaw) { $body = $bodyRaw | ConvertFrom-Json }
                    }
                    $result = Invoke-ApiRoute -Method $req.HttpMethod -Url $req.Url -Body $body -HtmlPath $HtmlPath -Response $res
                    if ($null -ne $result) {
                        Write-JsonResponse -Response $res -Object $result
                    }
                }
            }
            catch {
                try { Write-JsonResponse -Response $res -Object @{ error = $_.Exception.Message } -StatusCode 400 } catch {}
            }
            finally {
                try { $res.Close() } catch {}
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        # always snapshot the data on shutdown (Ctrl+C runs this finally block)
        try {
            $zip = Backup-SchedulerData
            if ($zip) { Write-Host "Backup saved: $zip" }
        } catch {
            Write-Warning "Backup on shutdown failed: $($_.Exception.Message)"
        }
        Write-Host "Scheduler stopped."
    }
}

Export-ModuleMember -Function *
