# Define default URL
$defaultUrl = "www.google.com"

# Prompt user for URL (with a 10-second timeout)
$inputUrl = Read-Host "Do you want to open $defaultUrl or enter a new URL? You have 10 seconds to input a new URL. Press Enter to continue." 
if (-not $inputUrl) {
    Write-Host "No URL entered. Defaulting to $defaultUrl."
    $inputUrl = $defaultUrl
}

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
            $currentProfile = @{ }
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

# Ask how many containers to open the URL in
$containersToOpen = Read-Host "How many containers would you like to open $inputUrl in? (Enter a number from 1 to $currentCount)"
$containersToOpen = [int]$containersToOpen

# Ensure the number is valid
if ($containersToOpen -lt 1 -or $containersToOpen -gt $currentCount) {
    Write-Host "Invalid number of containers. Exiting."
    exit
}

# Open the URL in the specified number of containers
for ($i = 0; $i -lt $containersToOpen; $i++) {
    $container = $currentContainers[$i]

    # Format the URL for the custom protocol handler
    $containerUrl = "ext+container:name=$($container.name)&url=$inputUrl"

    # Build the Firefox command to open with the custom protocol
    $arguments = @(
        $containerUrl
    )

    # Debug: Print the arguments being passed
    Write-Host "Running command: C:\Program Files\Mozilla Firefox\firefox.exe $($arguments -join ' ')"

    # Open the URL in the container using the custom protocol
    Start-Process -FilePath "C:\Program Files\Mozilla Firefox\firefox.exe" -ArgumentList $arguments

    # Random delay between 5-10 seconds
    $delay = Get-Random -Minimum 1 -Maximum 3
    Write-Host "Waiting for $delay seconds before opening the next container."
    Start-Sleep -Seconds $delay
}

Write-Host "Opened $inputUrl in $containersToOpen containers."
