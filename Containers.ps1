# Define default URL
$defaultUrl = "www.google.com"

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


# Check if the required Firefox extension is active
$extensionsJsonPath = Join-Path $profileFolder "extensions.json"

if (-Not (Test-Path $extensionsJsonPath)) {
    Write-Host "Could not find extensions.json at $extensionsJsonPath"
    exit
}

$extensionsData = Get-Content $extensionsJsonPath -Raw | ConvertFrom-Json

$targetExtensionName = "Open external links in a container"
$extensionFound = $extensionsData.addons | Where-Object {
    $_.defaultLocale.name -eq $targetExtensionName -and $_.active -eq $true
}

if (-not $extensionFound) {
    Write-Host ""
    Write-Host "The required extension '$targetExtensionName' is not active or not installed."
    Write-Host "Please install it from: https://addons.mozilla.org/en-GB/firefox/addon/open-url-in-container/"
    exit
}

Write-Host "Extension '$targetExtensionName' is active. Proceeding..."

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



# Prompt user for URL (with a 10-second timeout)
$inputUrl = Read-Host "Do you want to open $defaultUrl or enter a new URL? You have 10 seconds to input a new URL. Press Enter to continue." 
if (-not $inputUrl) {
    Write-Host "No URL entered. Defaulting to $defaultUrl."
    $inputUrl = $defaultUrl
}

# Count current containers
$currentContainers = $containersJson.identities | Where-Object { $_.public -eq $true }
$currentCount = $currentContainers.Count

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

