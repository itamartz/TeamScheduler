# TeamScheduler entry point - no admin rights required.
# Run with:  powershell -ExecutionPolicy Bypass -File .\Run-Scheduler.ps1
# (-ExecutionPolicy Bypass is per-process and needs no elevation.)
param(
    [int]$Port = 8770,
    [switch]$NoBrowser,
    [switch]$Debug        # UI prefixes names/titles with #id (for pointing at records by id)
)

Add-Type -AssemblyName System.Web
Import-Module (Join-Path $PSScriptRoot "Scheduler.psm1") -Force
Start-SchedulerServer -Port $Port -HtmlPath (Join-Path $PSScriptRoot "scheduler_v3.html") -NoBrowser:$NoBrowser -Debug:$Debug
