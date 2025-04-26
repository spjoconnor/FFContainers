# Start with the Firefox installation check
$firefoxPath = "C:\Program Files\Mozilla Firefox\firefox.exe"

if (-Not (Test-Path $firefoxPath)) {
    Write-Host ""
    Write-Host "Firefox is not installed. Please install Firefox from https://www.mozilla.org/firefox/ and rerun this script."
    return
}

# Define default URL
$defaultUrl = "https://glastonbury.seetickets.com/"

# Define icon and color options
$colors = @("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple")
$icons = @("fingerprint", "briefcase", "dollar", "cart", "circle", "vacation", "gift", "food", "fruit", "pet", "tree", "chill", "fence")

# Get the Firefox profiles.ini
$profilesIniPath = "$env:APPDATA\Mozilla\Firefox\profiles.ini"
if (-Not (Test-Path $profilesIniPath)) {
    Write-Host "Could not find profiles.ini"
    return
}

# Read and parse profiles.ini
$lines = Get-Content $profilesIniPath
$profiles = @()
$currentProfile = @{}

foreach ($line in $lines) {
    if ($line -match "^\[Profile\d+\]") {
        if ($currentProfile.Count -gt 0) {
            $profiles += $currentProfile
            $currentProfile = @{}
        }
    }
    elseif ($line -match "^Name=(.+)") {
        $currentProfile.Name = $matches[1]
    }
    elseif ($line -match "^Path=(.+)") {
        $currentProfile.Path = $matches[1]
    }
    elseif ($line -match "^IsRelative=(\d)") {
        $currentProfile.IsRelative = [int]$matches[1]
    }
    elseif ($line -match "^Default=(\d)") {
        $currentProfile.Default = [int]$matches[1]
    }
}
if ($currentProfile.Count -gt 0) {
    $profiles += $currentProfile
}

$selectedProfile = $profiles | Where-Object { $_.Name -eq "default-release" }

if (-not $selectedProfile) {
    $selectedProfile = $profiles | Where-Object { $_.Default -eq 1 } | Select-Object -First 1
}

if (-not $selectedProfile) {
    Write-Host "No suitable Firefox profile found."
    return
}

$profileFolder = if ($selectedProfile.IsRelative -eq 1) {
    Join-Path (Join-Path $env:APPDATA "Mozilla\Firefox") $selectedProfile.Path
} else {
    $selectedProfile.Path
}

Write-Host "Using Firefox profile at: $profileFolder"

# Check for extension
$extensionsJsonPath = Join-Path $profileFolder "extensions.json"

if (-Not (Test-Path $extensionsJsonPath)) {
    Write-Host "Could not find extensions.json"
    return
}

$extensionsData = Get-Content $extensionsJsonPath -Raw | ConvertFrom-Json

$targetExtensionName = "Open external links in a container"
$extensionFound = $extensionsData.addons | Where-Object {
    $_.defaultLocale.name -like "*external links in a container*" -and $_.active -eq $true
}

if (-not $extensionFound) {
    Write-Host "Please install the extension from: https://addons.mozilla.org/en-GB/firefox/addon/open-url-in-container/"
    return
}

# Load containers
$containersJsonPath = Join-Path $profileFolder "containers.json"

if (-Not (Test-Path $containersJsonPath)) {
    Write-Host "Could not find containers.json"
    return
}

$containersJson = Get-Content $containersJsonPath -Raw | ConvertFrom-Json

$currentContainers = $containersJson.identities | Where-Object { $_.public -eq $true }
$currentCount = $currentContainers.Count

Write-Host ""
Write-Host "You currently have $currentCount containers."
Write-Host ""

$internalContainers = $containersJson.identities | Where-Object { $_.public -ne $true }

$delete = Read-Host "Do you want to delete all user-defined containers? (y/n)"
if ($delete -eq "y") {
    $containersJson.identities = $internalContainers
    $containersJson.lastUserContextId = 5
    Write-Host "User-defined containers deleted. Internal containers preserved."
}

$proceed = Read-Host "Do you want to proceed with creating new containers? (y/n)"
if ($proceed -ne "y") {
    Write-Host "User chose not to create new containers. Ending script."
    return
}

$newCount = Read-Host "How many new containers would you like to create?"
$newCount = [int]$newCount
$newContainers = @()

$startId = $containersJson.lastUserContextId + 1

for ($i = 0; $i -lt $newCount; $i++) {
    $color = Get-Random -InputObject $colors
    $icon = Get-Random -InputObject $icons
    $name = "$($i + 1)"
    $id = $startId + $i

    $container = [PSCustomObject]@{
        name          = $name
        color         = $color
        icon          = $icon
        public        = $true
        userContextId = $id
    }

    $newContainers += $container
}

$containersJson.identities += $newContainers
$containersJson.lastUserContextId = $startId + $newCount - 1

$containersJson | ConvertTo-Json -Depth 10 | Set-Content -Path $containersJsonPath -Encoding UTF8

Write-Host ""
Write-Host "Created $newCount new containers."

function Get-ValidContainerCount {
    param (
        [int]$maxContainers
    )

    $attempts = 0
    while ($attempts -lt 3) {
        $input = Read-Host "How many containers would you like to open the URL in? (Enter 1 to $maxContainers)"
        if ([int]::TryParse($input, [ref]$null)) {
            $num = [int]$input
            if ($num -ge 1 -and $num -le $maxContainers) {
                return $num
            }
        }
        Write-Host "Invalid input. Please try again."
        $attempts++
    }

    Write-Host "Too many invalid attempts. Ending script."
    return $null
}

$inputUrl = Read-Host "Do you want to open $defaultUrl or enter a new URL? Press Enter to accept default."
if (-not $inputUrl) {
    $inputUrl = $defaultUrl
}

$currentContainers = $containersJson.identities | Where-Object { $_.public -eq $true }
$currentCount = $currentContainers.Count

$containersToOpen = Get-ValidContainerCount -maxContainers $currentCount
if (-not $containersToOpen) {
    return
}

$adjustDelay = Read-Host "Would you like to adjust the opening delay from the default 2-10 seconds? (y/n)"
if ($adjustDelay -eq "y") {
    $minDelayInput = Read-Host "Enter minimum delay in seconds (Default: 2, Min: 1)."
    $minDelay = if ($minDelayInput) { [math]::Max([int]$minDelayInput,1) } else { 2 }

    $maxDelayInput = Read-Host "Enter maximum delay in seconds (Default: 10, Min: 1)."
    $maxDelay = if ($maxDelayInput) { [math]::Max([int]$maxDelayInput,1) } else { 10 }

    if ($maxDelay -lt $minDelay) {
        $maxDelay = $minDelay
    }
} else {
    $minDelay = 2
    $maxDelay = 10
}

$closeFirefox = Read-Host "Would you like to close all Firefox windows before opening containers? (Recommended) (y/n)"
if ($closeFirefox -eq "y") {
    Get-Process firefox -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Write-Host "Closed all Firefox processes."
}

for ($i = 0; $i -lt $containersToOpen; $i++) {
    $container = $currentContainers[$i]

    $containerUrl = "ext+container:name=$($container.name)&url=$inputUrl"
    $arguments = @($containerUrl)

    Write-Host "Running command: $firefoxPath $($arguments -join ' ')"
    Start-Process -FilePath $firefoxPath -ArgumentList $arguments

    if ($i -lt ($containersToOpen - 1)) {
        $delay = Get-Random -Minimum $minDelay -Maximum ($maxDelay + 1)
        Write-Host "Waiting for $delay seconds before opening the next container."
        Start-Sleep -Seconds $delay
    }
}

Write-Host "Opened $inputUrl in $containersToOpen containers."
