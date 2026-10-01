# 1 Firefox container launcher. Windows PowerShell 5.1 or PowerShell 7 on Windows.
# Uses Open external links in a container 1.0.3. No Firefox profile files are modified.
# Wrapped in a child scope so irm ... | iex does not leave settings/functions behind.
& {
    $ErrorActionPreference = 'Stop'
    $lockStream = $null

    function Ask-Number([string]$Prompt, [int]$Min, [int]$Max, [int]$Default) {
        while ($true) {
            $answer = (Read-Host "$Prompt [Enter = $Default]").Trim()
            if ($answer -eq '') { return $Default }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge $Min -and $number -le $Max) {
                return $number
            }
            Write-Host "Enter a whole number from $Min to $Max."
        }
    }
    function Ask-CloseFirefox {
        while ($true) {
            $answer = (Read-Host 'Close ALL Firefox windows and tabs before opening? [Y/n, Enter = Yes]').Trim()
            if ($answer -match '^(y|yes)?$') { return $true }
            if ($answer -match '^(n|no)$') { return $false }
            Write-Host 'Enter y or n.'
        }
    }
    function Close-FirefoxNormally {
        Write-Host 'Closing Firefox normally. Respond to any Firefox save/close prompts.'
        $requested = @{}
        # Re-enumerate so another window belonging to the same process can be closed next.
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $processes = @(Get-Process firefox -ErrorAction SilentlyContinue)
            if ($processes.Count -eq 0) { return }
            foreach ($process in $processes) {
                try {
                    $handle = $process.MainWindowHandle.ToInt64()
                    if ($handle -ne 0 -and -not $requested.ContainsKey($handle)) {
                        if ($process.CloseMainWindow()) { $requested[$handle] = $true }
                    }
                } catch {
                    # A process may exit while being inspected. The next poll checks again.
                }
            }
            Start-Sleep -Seconds 1
        }
        if (@(Get-Process firefox -ErrorAction SilentlyContinue).Count -gt 0) {
            throw 'Firefox is still running. Close it manually and run again. No processes were force-killed.'
        }
    }
    function Ask-Fresh {
        while ($true) {
            $answer = (Read-Host 'Delete ALL numbered containers and start fresh? [y/N, Enter = No]').Trim()
            if ($answer -match '^(y|yes)$') { return $true }
            if ($answer -match '^(n|no)?$') { return $false }
            Write-Host 'Enter y or n.'
        }
    }
    function Read-Ini([string]$Path) {
        $sections = @{}
        $section = $null
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*\[([^]]+)\]\s*$') {
                $section = $matches[1]
                $sections[$section] = @{}
            } elseif ($section -and $line -match '^\s*([^=;#]+?)\s*=(.*)$') {
                $sections[$section][$matches[1].Trim()] = $matches[2].Trim()
            }
        }
        return $sections
    }
    function Get-Profiles([string[]]$Roots) {
        $seen = @{}
        foreach ($root in $Roots) {
            $iniPath = Join-Path $root 'profiles.ini'
            if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { continue }
            $ini = Read-Ini $iniPath
            foreach ($key in @($ini.Keys | Sort-Object)) {
                if ($key -notmatch '^Profile\d+$') { continue }
                $p = $ini[$key]
                if (-not $p.Path) { continue }
                $path = $p.Path
                if ($p.IsRelative -eq '1') { $path = Join-Path $root $path }
                if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
                $path = (Resolve-Path -LiteralPath $path).Path
                if ($seen.ContainsKey($path)) { continue }
                $seen[$path] = $true
                [pscustomobject]@{ Name = $p.Name; Path = $path }
            }
        }
    }
    function New-ContainerUri([string]$Name, [string]$Id, [string]$Url, [string]$Color) {
        $target = if ($Id) { 'id=' + [uri]::EscapeDataString($Id) } else { 'name=' + [uri]::EscapeDataString($Name) }
        return 'ext+container:' + $target + '&color=' + $Color + '&icon=circle&url=' + [uri]::EscapeDataString($Url)
    }
    function Send-Tab([string]$Exe, [string]$Profile, [string]$Uri) {
        # Start-Process joins ArgumentList entries. Supply explicit quotes around arguments.
        if ($Profile.Contains('"') -or $Uri.Contains('"')) { throw 'Invalid quote in launch argument.' }
        $arguments = '-profile "' + $Profile.TrimEnd('\') + '" -new-tab "' + $Uri + '"'
        Start-Process -FilePath $Exe -ArgumentList $arguments -ErrorAction Stop | Out-Null
    }

    try {
        if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
        $stateDir = Join-Path $env:LOCALAPPDATA 'FirefoxContainerLauncher'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        try {
            $lockStream = [System.IO.File]::Open((Join-Path $stateDir 'launcher.lock'),
                [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch { throw 'Another launcher is running, or its local lock file cannot be opened.' }

        $exeCandidates = @()
        foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if ($root) { $exeCandidates += Join-Path $root 'Mozilla Firefox\firefox.exe' }
        }
        foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
                            'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe')) {
            if (Test-Path $key) { $exeCandidates += (Get-Item $key).GetValue('') }
        }
        $roots = @(Join-Path $env:APPDATA 'Mozilla\Firefox')
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            foreach ($package in @(Get-AppxPackage -Name '*Mozilla.Firefox*' -ErrorAction SilentlyContinue)) {
                if ($package.InstallLocation) {
                    $exeCandidates += Join-Path $package.InstallLocation 'VFS\ProgramFiles\Firefox Package Root\firefox.exe'
                }
                $roots += Join-Path $env:LOCALAPPDATA "Packages\$($package.PackageFamilyName)\LocalCache\Roaming\Mozilla\Firefox"
            }
        }
        $exeCandidates = @($exeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
        Write-Host "`nFirefox Container Launcher`n"
        if ($exeCandidates.Count -eq 1) {
            $firefoxPath = $exeCandidates[0]
        } elseif ($exeCandidates.Count -gt 1) {
            for ($i = 0; $i -lt $exeCandidates.Count; $i++) { Write-Host "$($i + 1). $($exeCandidates[$i])" }
            $pick = Ask-Number 'Which Firefox installation?' 1 $exeCandidates.Count 1
            $firefoxPath = $exeCandidates[$pick - 1]
        } else {
            $firefoxPath = (Read-Host 'Firefox not found. Enter the full path to firefox.exe').Trim().Trim('"')
        }
        if (-not (Test-Path -LiteralPath $firefoxPath -PathType Leaf) -or
            [IO.Path]::GetFileName($firefoxPath) -ine 'firefox.exe') { throw 'Select a valid firefox.exe file.' }

        # Only consider profiles with the required active extension. A single match is unambiguous.
        $profiles = @(Get-Profiles $roots)
        $eligible = @($profiles | Where-Object {
            $metadata = Join-Path $_.Path 'extensions.json'
            try {
                $data = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json
                @($data.addons | Where-Object {
                    $_.id -eq '{f069aec0-43c5-4bbf-b6b4-df95c4326b98}' -and $_.active -eq $true
                }).Count -eq 1
            } catch { $false }
        })
        if ($eligible.Count -eq 1) {
            $profilePath = $eligible[0].Path
            $profileName = $eligible[0].Name
        } elseif ($eligible.Count -gt 1) {
            Write-Host 'The extension is installed in more than one profile:'
            for ($i = 0; $i -lt $eligible.Count; $i++) { Write-Host "$($i + 1). $($eligible[$i].Name) -- $($eligible[$i].Path)" }
            $pick = Ask-Number 'Which profile?' 1 $eligible.Count 1
            $profilePath = $eligible[$pick - 1].Path
            $profileName = $eligible[$pick - 1].Name
        } else {
            Write-Host 'No profile with the extension was found automatically.'
            $profilePath = (Read-Host 'Enter your Firefox Profile Folder (shown in about:support)').Trim().Trim('"')
            $profileName = 'selected profile'
        }
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { throw 'Profile folder does not exist.' }
        $profilePath = (Resolve-Path -LiteralPath $profilePath).Path
        $extensionPath = Join-Path $profilePath 'extensions.json'
        if (-not (Test-Path -LiteralPath $extensionPath)) { throw "Extension metadata missing: $extensionPath. Start this profile once and install the extension." }
        $extensions = Get-Content -LiteralPath $extensionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $addon = @($extensions.addons | Where-Object { $_.id -eq '{f069aec0-43c5-4bbf-b6b4-df95c4326b98}' -and $_.active -eq $true })
        if ($addon.Count -ne 1) { throw 'Install/enable Open external links in a container in this profile: https://addons.mozilla.org/firefox/addon/open-url-in-container/' }
        if ($addon[0].version -ne '1.0.3') { throw "Extension version $($addon[0].version) detected. This launcher targets 1.0.3; verify the protocol before using a different version." }

        Write-Host "Using Firefox profile: $profileName"
        Write-Host 'Keep only this Firefox profile open. Ctrl+C stops the launcher.'
        Write-Host 'Reuse numbered containers, or choose Start fresh to reset them.'
        Write-Host ''

        $defaultUrl = 'https://glastonbury.seetickets.com/'
        while ($true) {
            $url = (Read-Host "`nURL [Enter = $defaultUrl]").Trim()
            if (-not $url) { $url = $defaultUrl }
            $parsed = $null
            if ($url.Length -le 8000 -and [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed) -and
                $parsed.Scheme -in @('http', 'https') -and $parsed.Host -and -not $parsed.UserInfo) { break }
            Write-Host 'Enter an absolute http:// or https:// URL without embedded credentials (max 8000 characters).'
        }
        $count = Ask-Number 'How many containers?' 1 500 5
        while ($true) {
            $answer = (Read-Host 'Delay in seconds, e.g. 2 or 2-10 [Enter = 2-10]').Trim()
            if (-not $answer) { $answer = '2-10' }
            $minDelay = 0
            $maxDelay = 0
            if ($answer -match '^(\d{1,3})(?:\s*-\s*(\d{1,3}))?$') {
                $minDelay = [int]$matches[1]
                $maxDelay = $minDelay
                if ($matches[2]) { $maxDelay = [int]$matches[2] }
                if ($minDelay -ge 1 -and $maxDelay -ge $minDelay -and $maxDelay -le 300) { break }
            }
            Write-Host 'Enter 1-300 seconds, or a range such as 2-10.'
        }
        $fresh = Ask-Fresh
        if (@(Get-Process firefox -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Host 'This includes ordinary tabs and other Firefox profiles. The script does not clear cookies or delete containers.'
            Write-Host 'Firefox may restore old tabs on startup if session restore is enabled.'
            if (Ask-CloseFirefox) { Close-FirefoxNormally }
        }
        if ($fresh) {
            Write-Host "`nReset needs the included Numbered Container Reset helper in THIS Firefox profile."
            Write-Host '1. Extract Firefox_Container_Reset_Helper.zip to a folder.'
            Write-Host '2. In the Firefox page opening now, click Load Temporary Add-on and select manifest.json.'
            Write-Host '   If already loaded, click its toolbar button: Reset numbered containers.'
            Write-Host '3. Review the list, tick the confirmation, and click Delete numbered containers.'
            Write-Host '   This removes ALL numeric names, including numbers above the requested count.'
            Write-Host '4. Wait for Success (or No numbered containers), then return here.'
            Write-Host 'Temporary helpers must be loaded again after Firefox restarts.'
            Send-Tab $firefoxPath $profilePath 'about:debugging#/runtime/this-firefox'
            $completion = (Read-Host 'Type RESET only after the helper completes; anything else cancels').Trim()
            if ($completion -cne 'RESET') { Write-Host 'Cancelled. No new tabs requested.'; return }
        }
        # Read-only check: existing duplicate names cannot be resolved reliably by name.
        $containerPath = Join-Path $profilePath 'containers.json'
        if (-not $fresh -and (Test-Path -LiteralPath $containerPath)) {
            $inventory = Get-Content -LiteralPath $containerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            for ($n = 1; $n -le $count; $n++) {
                $duplicates = @($inventory.identities | Where-Object { $_.public -eq $true -and $_.name -ceq [string]$n })
                if ($duplicates.Count -gt 1) { throw "More than one container is named $n. Rename the duplicate containers in Firefox, then try again." }
            }
        }
        $colors = @('blue', 'turquoise', 'green', 'yellow', 'orange', 'red', 'pink', 'purple')
        Write-Host "`nOpening containers 1 to $count. Press Ctrl+C to stop.`n"
        for ($i = 1; $i -le $count; $i++) {
            if ($i -gt 1) {
                $delay = Get-Random -Minimum $minDelay -Maximum ($maxDelay + 1)
                Start-Sleep -Seconds $delay
            }
            $uri = New-ContainerUri ([string]$i) '' $url $colors[($i - 1) % $colors.Count]
            Send-Tab $firefoxPath $profilePath $uri
            Write-Host "[$i/$count] Container $i"
        }
        Write-Host "`nDone - $count tab requests sent. Check Firefox for the results."
    } catch {
        Write-Host "`nStopped: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Any tabs already opened remain open. Inspect them before running again.'
    } finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
    }
}
