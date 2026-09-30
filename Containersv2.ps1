# Firefox container launcher. Windows PowerShell 5.1 or PowerShell 7 on Windows.
# Uses Open external links in a container 1.0.3. No Firefox profile files are modified.
# Wrapped in a child scope so irm ... | iex does not leave settings/functions behind.
& {
    $ErrorActionPreference = 'Stop'
    $lockStream = $null

    function Ask-Yes([string]$Prompt) {
        while ($true) {
            $answer = (Read-Host "$Prompt [y/N]").Trim()
            if ($answer -match '^(y|yes)$') { return $true }
            if ($answer -match '^(n|no)?$') { return $false }
            Write-Host 'Please enter y or n.'
        }
    }
    function Ask-Number([string]$Prompt, [int]$Min, [int]$Max, [int]$Default) {
        while ($true) {
            $answer = (Read-Host "$Prompt [$Default, range $Min-$Max]").Trim()
            if ($answer -eq '') { return $Default }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge $Min -and $number -le $Max) {
                return $number
            }
            Write-Host "Enter a whole number from $Min to $Max."
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
        for ($i = 0; $i -lt $exeCandidates.Count; $i++) { Write-Host "$($i + 1). $($exeCandidates[$i])" }
        if ($exeCandidates.Count -gt 0) {
            $pick = Ask-Number 'Firefox installation (0 = enter path)' 0 $exeCandidates.Count 1
        } else { $pick = 0 }
        if ($pick -eq 0) {
            $firefoxPath = (Read-Host 'Full path to firefox.exe').Trim().Trim('"')
        } else { $firefoxPath = $exeCandidates[$pick - 1] }
        if (-not (Test-Path -LiteralPath $firefoxPath -PathType Leaf) -or
            [IO.Path]::GetFileName($firefoxPath) -ine 'firefox.exe') { throw 'Select a valid firefox.exe file.' }

        $profiles = @(Get-Profiles $roots)
        Write-Host "`nProfiles (check the correct folder in Firefox at about:support):"
        for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host "$($i + 1). $($profiles[$i].Name) -- $($profiles[$i].Path)" }
        if ($profiles.Count -gt 0) {
            $pick = Ask-Number 'Profile (0 = enter folder)' 0 $profiles.Count 1
        } else { $pick = 0 }
        if ($pick -eq 0) {
            $profilePath = (Read-Host 'Full Firefox profile folder path').Trim().Trim('"')
        } else { $profilePath = $profiles[$pick - 1].Path }
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { throw 'Profile folder does not exist.' }
        $profilePath = (Resolve-Path -LiteralPath $profilePath).Path
        $extensionPath = Join-Path $profilePath 'extensions.json'
        if (-not (Test-Path -LiteralPath $extensionPath)) { throw "Extension metadata missing: $extensionPath. Start this profile once and install the extension." }
        $extensions = Get-Content -LiteralPath $extensionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $addon = @($extensions.addons | Where-Object { $_.id -eq '{f069aec0-43c5-4bbf-b6b4-df95c4326b98}' -and $_.active -eq $true })
        if ($addon.Count -ne 1) { throw 'Install/enable Open external links in a container in this profile: https://addons.mozilla.org/firefox/addon/open-url-in-container/' }
        if ($addon[0].version -ne '1.0.3') { throw "Extension version $($addon[0].version) detected. This launcher targets 1.0.3; verify the protocol before using a different version." }

        if (@(Get-Process firefox -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Host "`nFirefox is running. Keep ONLY the selected profile open: $profilePath"
            Write-Host 'Check about:support > Profile Folder in that window. Close other Firefox profiles normally.'
            if (-not (Ask-Yes 'Is the selected profile the only Firefox profile running?')) { return }
        }
        $logPath = Join-Path $stateDir 'last-run.json'
        if (Test-Path -LiteralPath $logPath) {
            Write-Host "`nA previous launch record exists: $logPath"
            Write-Host 'This script cannot inspect live tabs. Continuing may open additional tabs.'
            if (-not (Ask-Yes 'Start another run?')) { return }
        }

        $defaultUrl = 'https://glastonbury.seetickets.com/'
        while ($true) {
            $url = (Read-Host "`nURL [Enter = $defaultUrl]").Trim()
            if (-not $url) { $url = $defaultUrl }
            $parsed = $null
            if ($url.Length -le 8000 -and [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed) -and
                $parsed.Scheme -in @('http', 'https') -and $parsed.Host -and -not $parsed.UserInfo) { break }
            Write-Host 'Enter an absolute http:// or https:// URL without embedded credentials (max 8000 characters).'
        }
        $mode = Ask-Number '1 = fresh containers, 2 = select existing containers' 1 2 1
        $targets = @()
        if ($mode -eq 1) {
            $count = Ask-Number 'How many fresh containers?' 1 500 5
            $batch = 'Batch-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
            for ($i = 1; $i -le $count; $i++) {
                $targets += [pscustomobject]@{ Name = ('{0}-{1:D3}' -f $batch, $i); Id = '' }
            }
        } else {
            $containerPath = Join-Path $profilePath 'containers.json'
            if (-not (Test-Path -LiteralPath $containerPath)) { throw "No container inventory at $containerPath. Create containers in Firefox first." }
            $inventory = Get-Content -LiteralPath $containerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existing = @($inventory.identities | Where-Object { $_.public -eq $true })
            if ($existing.Count -eq 0) { throw 'No existing public containers found.' }
            for ($i = 0; $i -lt $existing.Count; $i++) {
                $label = $existing[$i].name
                if (-not $label) { $label = $existing[$i].l10nID }
                Write-Host "$($i + 1). $label (ID $($existing[$i].userContextId))"
            }
            while ($true) {
                $selection = (Read-Host 'Enter numbers separated by commas, or all').Trim()
                $indices = @()
                $valid = $true
                if ($selection -ieq 'all') { $indices = @(1..$existing.Count) }
                else {
                    foreach ($token in $selection.Split(',')) {
                        $n = 0
                        if (-not [int]::TryParse($token.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $existing.Count) { $valid = $false; break }
                        $indices += $n
                    }
                }
                $indices = @($indices | Select-Object -Unique)
                if ($valid -and $indices.Count -gt 0 -and $indices.Count -le 500) { break }
                Write-Host 'Choose 1-500 valid entries. Example: 1,3,5'
            }
            foreach ($n in $indices) {
                $c = $existing[$n - 1]
                $id = 0
                if (-not [int]::TryParse([string]$c.userContextId, [ref]$id) -or $id -lt 1) { throw 'Invalid container ID in inventory.' }
                $label = $c.name
                if (-not $label) { $label = "Container $id" }
                $targets += [pscustomobject]@{ Name = $label; Id = "firefox-container-$id" }
            }
        }
        $minDelay = Ask-Number 'Minimum delay between launches, seconds' 1 300 2
        $maxDelay = Ask-Number 'Maximum delay between launches, seconds' $minDelay 300 ([math]::Max(10, $minDelay))
        $batchSize = Ask-Number 'Pause for confirmation after every N launches' 1 500 10
        Write-Host "`nProfile: $profilePath`nURL: $url`nTabs requested: $($targets.Count)`nDelay: $minDelay-$maxDelay seconds"
        if (-not (Ask-Yes 'Open the first tab?')) { return }

        $record = [ordered]@{ Started = (Get-Date).ToString('o'); Profile = $profilePath; Url = $url; Targets = $targets; Attempts = @() }
        $colors = @('blue', 'turquoise', 'green', 'yellow', 'orange', 'red', 'pink', 'purple')
        $sent = 0
        for ($i = 0; $i -lt $targets.Count; $i++) {
            if ($i -eq 1) {
                Write-Host 'Check Firefox: the first page should be in the intended container. Handle any protocol prompt.'
                if (-not (Ask-Yes 'Did the first container tab open correctly? Continue?')) { break }
            } elseif ($i -gt 0 -and ($i % $batchSize) -eq 0) {
                if (-not (Ask-Yes "$sent launch requests sent. Continue with the next batch?")) { break }
            }
            if ($i -gt 0) {
                $delay = Get-Random -Minimum $minDelay -Maximum ($maxDelay + 1)
                Write-Host "Waiting $delay seconds... (Ctrl+C to stop)"
                Start-Sleep -Seconds $delay
            }
            $target = $targets[$i]
            $uri = New-ContainerUri $target.Name $target.Id $url $colors[$i % $colors.Count]
            # Record before dispatch: after interruption, an attempt may or may not have opened.
            $record.Attempts += [pscustomobject]@{ Name = $target.Name; Time = (Get-Date).ToString('o'); Status = 'Dispatch pending or uncertain' }
            $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8
            Send-Tab $firefoxPath $profilePath $uri
            $sent++
            $record.Attempts[-1].Status = 'Launch request sent; tab not verified'
            $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding UTF8
            Write-Host "[$sent/$($targets.Count)] Requested: $($target.Name)"
        }
        Write-Host "`n$sent launch requests sent. Check Firefox for actual results. Record: $logPath"
    } catch {
        Write-Host "`nStopped: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Any tabs already opened remain open. Inspect them before running again.'
    } finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
    }
}
