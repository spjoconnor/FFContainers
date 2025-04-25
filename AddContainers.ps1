# Define icon and color options
$colors = @("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple")
$icons = @("fingerprint", "briefcase", "dollar", "cart", "circle", "vacation", "gift", "food", "fruit", "pet", "tree", "chill", "fence")

# Get the Firefox profiles.ini
$profilesIniPath = "$env:APPDATA\Mozilla\Firefox\profiles.ini"
if (-Not (Test-Path $profilesIniPath)) {
    Write-Host "Could not find profiles.ini"
    exit
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

# Find the default profile (prefer default-release if it exists)
$selectedProfile = $profiles | Where-Object { $_.Name -eq "default-release" }

if (-not $selectedProfile) {
    $selectedProfile = $profiles | Where-Object { $_.Default -eq 1 } | Select-Object -First 1
}

if (-not $selectedProfile) {
    Write-Host "No suitable Firefox profile found."
    exit
}

# Build full profile path
# Prevent double "Profiles\Profiles" issue
$profileFolder = if ($selectedProfile.IsRelative -eq 1) {
    Join-Path (Join-Path $env:APPDATA "Mozilla\Firefox") $selectedProfile.Path
} else {
    $selectedProfile.Path
}

Write-Host "Using Firefox profile at: $profileFolder"


$containersJsonPath = Join-Path $profileFolder "containers.json"

if (-Not (Test-Path $containersJsonPath)) {
    Write-Host "Could not find containers.json at $containersJsonPath"
    exit
}

# Load containers.json
$containersJson = Get-Content $containersJsonPath -Raw | ConvertFrom-Json

# Count current containers
$currentContainers = $containersJson.identities | Where-Object { $_.public -eq $true }
$currentCount = $currentContainers.Count

Write-Host ""
Write-Host "You currently have $currentCount containers."
Write-Host ""

# Separate internal (non-public) and user-created (public) containers
$internalContainers = $containersJson.identities | Where-Object { $_.public -ne $true }

# Ask if user wants to delete all public containers
$delete = Read-Host "Do you want to delete all user-defined containers? (y/n)"
if ($delete -eq "y") {
    $containersJson.identities = $internalContainers
    $containersJson.lastUserContextId = 5  # Leave it here; we will increment it for new ones
    Write-Host "User-defined containers deleted. Internal containers preserved."
}


# Ask how many new containers to create
$newCount = Read-Host "How many new containers would you like to create?"
$newCount = [int]$newCount
$newContainers = @()

# Start IDs from last known
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

# Save back to containers.json
$containersJson | ConvertTo-Json -Depth 10 | Set-Content -Path $containersJsonPath -Encoding UTF8

Write-Host ""
Write-Host "Created $newCount new containers in profile: $profilePath"
