<#
.SYNOPSIS
Starts and controls an isolated Goblinoria development playtest session.

.DESCRIPTION
The launcher owns a run directory under .playtest and starts Godot with a
child-only APPDATA/LOCALAPPDATA environment. It communicates with the
Godot-side PlaytestTransport over authenticated loopback TCP. It never sends
credentials to stdout and never kills a process that it cannot identify by
PID, executable path, startup identity, and run ID.

.EXAMPLE
./tools/playtest.ps1 Start -Scenario stair_preview

.EXAMPLE
./tools/playtest.ps1 Status

.EXAMPLE
./tools/playtest.ps1 Send -Operation act -ArgsJson '{"events":[{"kind":"pointer_move","point":[960,540]}]}'

.EXAMPLE
./tools/playtest.ps1 Observe -Wait

.EXAMPLE
./tools/playtest.ps1 Reset -Scenario stair_continuation

.EXAMPLE
./tools/playtest.ps1 Stop

.NOTES
The bootstrap script is intentionally a separate Godot entry point:
res://tools/playtest_bootstrap.gd. This client does not use desktop UI
automation and does not queue gameplay jobs directly.
##>
[CmdletBinding()]
param(
	[ValidateSet('Start', 'Status', 'Send', 'Observe', 'Reset', 'Stop')]
	[string]$Command = 'Status',
	[string]$RunId,
	[string]$RunRoot,
	[ValidateSet('stair_preview', 'stair_continuation')]
	[string]$Scenario = 'stair_preview',
	[ValidateSet('status', 'act', 'set_view', 'advance', 'run_until', 'pause', 'observe', 'operation_status', 'shutdown')]
	[string]$Operation = 'status',
	[Alias('Args')]
	[string]$ArgsJson = '{}',
	[switch]$Wait,
	[ValidateRange(1, 120)]
	[int]$TimeoutSec = 30,
	[ValidateRange(0, 2147483647)]
	[int]$Sequence = -1,
	[string]$GodotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:PlaytestRoot = Join-Path $script:RepoRoot '.playtest'
$script:Clock = [Diagnostics.Stopwatch]::StartNew()

function Get-Field($Object, [string]$Name) {
	if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
		return $Object.PSObject.Properties[$Name].Value
	}
	return $null
}

function ConvertTo-StartupIdentity($Value) {
	if ($null -eq $Value) { return '' }
	if ($Value -is [DateTimeOffset]) {
		return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
	}
	if ($Value -is [DateTime]) {
		return ([DateTimeOffset]$Value.ToUniversalTime()).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
	}
	$text = [string]$Value
	$parsed = [DateTimeOffset]::MinValue
	if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
		[Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
		return $parsed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
	}
	return $text
}

function Get-RemainingMilliseconds([int]$LimitSec) {
	$remaining = [int64]$LimitSec * 1000 - $script:Clock.ElapsedMilliseconds
	if ($remaining -le 0) { throw 'Playtest operation timed out.' }
	return [int]$remaining
}

function ConvertTo-JsonFile($Value, [string]$Path) {
	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	$text = $Value | ConvertTo-Json -Depth 64 -Compress
	[IO.File]::WriteAllText($Path, $text, $script:Utf8)
}

function Read-JsonFile([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
	try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
	catch { throw 'Playtest metadata is not valid JSON.' }
}

function Get-SafeRunId([string]$Value) {
	if ([string]::IsNullOrWhiteSpace($Value)) {
		return 'run-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
	}
	if ($Value -notmatch '^[A-Za-z0-9_-]{1,96}$') { throw 'RunId must contain only letters, numbers, underscore, and hyphen.' }
	return $Value
}

function Get-RunRootPath([string]$RequestedRoot, [string]$RequestedId) {
	if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
		$full = [IO.Path]::GetFullPath($RequestedRoot)
	} elseif (-not [string]::IsNullOrWhiteSpace($RequestedId)) {
		$full = [IO.Path]::GetFullPath((Join-Path $script:PlaytestRoot $RequestedId))
	} else {
		$current = Read-JsonFile (Join-Path $script:PlaytestRoot 'current.json')
		if ($null -eq $current) { throw 'No current playtest session. Start one first or provide -RunId.' }
		$full = [IO.Path]::GetFullPath([string](Get-Field $current 'run_root'))
	}
	$allowed = [IO.Path]::GetFullPath($script:PlaytestRoot).TrimEnd('\') + '\'
	if (-not $full.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
		throw 'RunRoot must be inside the repository .playtest directory.'
	}
	return $full
}

function Get-Manifest([string]$Root) {
	$manifest = Read-JsonFile (Join-Path $Root 'session.json')
	if ($null -eq $manifest -or [string]::IsNullOrWhiteSpace([string](Get-Field $manifest 'run_id'))) {
		throw 'Playtest session manifest is missing or invalid.'
	}
	if ([string](Get-Field $manifest 'run_root') -and
		[IO.Path]::GetFullPath([string](Get-Field $manifest 'run_root')) -ne [IO.Path]::GetFullPath($Root)) {
		throw 'Playtest session manifest does not match the requested run directory.'
	}
	return $manifest
}

function Get-GitMetadata {
	$revision = ''
	$dirty = $false
	try {
		$revision = (& git -C $script:RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
		$dirty = -not [string]::IsNullOrWhiteSpace((& git -C $script:RepoRoot status --porcelain 2>$null))
	} catch { }
	return @{ source_revision = $revision; dirty_worktree = $dirty }
}

function Get-ProjectIdentity {
	$projectPath = Join-Path $script:RepoRoot 'project.godot'
	$text = Get-Content -LiteralPath $projectPath -Raw
	$nameMatch = [regex]::Match($text, '(?m)^config/name="([^"]+)"\s*$')
	if (-not $nameMatch.Success -or [string]::IsNullOrWhiteSpace($nameMatch.Groups[1].Value)) {
		throw 'Cannot derive the Goblinoria project name from project.godot.'
	}
	$projectName = $nameMatch.Groups[1].Value
	if ($projectName -cne 'Goblinoria') { throw 'Playtest isolation expects project name Goblinoria.' }
	$customName = [regex]::Match($text, '(?m)^config/custom_user_dir_name="([^"]*)"\s*$')
	$customEnabled = [regex]::Match($text, '(?m)^config/use_custom_user_dir=true\s*$')
	if ($customName.Success -or $customEnabled.Success) {
		throw 'Unexpected custom user directory configuration would invalidate playtest isolation.'
	}
	return $projectName
}

function ConvertTo-ProcessArgument([string]$Value) {
	if ($null -eq $Value) { return '""' }
	if ($Value -notmatch '[\s"]') { return $Value }
	# All launcher paths are absolute paths without a trailing separator. Escape
	# embedded quotes for CreateProcess while keeping spaces inside the argument.
	return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-GodotExecutable {
	$candidates = @()
	if (-not [string]::IsNullOrWhiteSpace($GodotPath)) { $candidates += $GodotPath }
	if (-not [string]::IsNullOrWhiteSpace($env:GODOT_PATH)) { $candidates += $env:GODOT_PATH }
	$command = Get-Command godot -ErrorAction SilentlyContinue
	if ($null -ne $command) { $candidates += $command.Source }
	$candidates += (Join-Path $env:USERPROFILE 'Downloads/Godot_v4.7.2-stable_win64.exe')
	foreach ($candidate in $candidates) {
		if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
			return [IO.Path]::GetFullPath($candidate)
		}
	}
	throw 'Godot executable not found. Provide -GodotPath or set GODOT_PATH.'
}

function Save-Current([string]$Root, [string]$Id) {
	ConvertTo-JsonFile @{ run_id = $Id; run_root = $Root } (Join-Path $script:PlaytestRoot 'current.json')
}

function Read-Descriptor([string]$Path) {
	$descriptor = Read-JsonFile $Path
	$hostName = [string](Get-Field $descriptor 'host')
	$port = Get-Field $descriptor 'port'
	$token = [string](Get-Field $descriptor 'token')
	$session = [string](Get-Field $descriptor 'session_id')
	$processId = Get-Field $descriptor 'pid'
	if ($hostName -cne '127.0.0.1' -or $null -eq $port -or $port -is [string] -or
		[double]$port -ne [Math]::Floor([double]$port) -or [int]$port -lt 1 -or [int]$port -gt 65535 -or
		$token -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($session) -or $null -eq $processId) {
		throw 'Playtest descriptor is invalid.'
	}
	return $descriptor
}

function Get-Descriptor([string]$Root, $Manifest) {
	$control = Join-Path $Root 'control'
	$expected = [string](Get-Field $Manifest 'descriptor_path')
	if (-not [string]::IsNullOrWhiteSpace($expected) -and (Test-Path -LiteralPath $expected -PathType Leaf)) {
		return Read-Descriptor $expected
	}
	if (-not (Test-Path -LiteralPath $control -PathType Container)) { throw 'Playtest control descriptor is not ready.' }
	$found = @()
	foreach ($file in (Get-ChildItem -LiteralPath $control -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
		try { $found += Read-Descriptor $file.FullName } catch { }
	}
	if ($found.Count -ne 1) { throw 'Playtest control descriptor is missing or ambiguous.' }
	$descriptor = $found[0]
	$Manifest.descriptor_path = (Get-ChildItem -LiteralPath $control -Filter '*.json' -File | Select-Object -First 1).FullName
	ConvertTo-JsonFile $Manifest (Join-Path $Root 'session.json')
	return $descriptor
}

function Invoke-PlaytestRequest($Descriptor, [string]$OperationName, $Arguments, [int]$LimitSec) {
	$id = [Guid]::NewGuid().ToString('N')
	$wireObject = @{ id = $id; token = [string](Get-Field $Descriptor 'token'); op = $OperationName; args = $Arguments }
	$wire = $wireObject | ConvertTo-Json -Depth 64 -Compress
	$bytes = $script:Utf8.GetBytes($wire + "`n")
	if ($bytes.Length -gt 8192) { throw 'Playtest request exceeds 8 KiB.' }
	$socket = [Net.Sockets.TcpClient]::new()
	$socket.NoDelay = $true
	$response = [IO.MemoryStream]::new()
	try {
		$connect = $socket.ConnectAsync('127.0.0.1', [int](Get-Field $Descriptor 'port'))
		if (-not $connect.Wait((Get-RemainingMilliseconds $LimitSec))) { throw 'Playtest connection timed out.' }
		$stream = $socket.GetStream()
		$write = $stream.WriteAsync($bytes, 0, $bytes.Length)
		if (-not $write.Wait((Get-RemainingMilliseconds $LimitSec))) { throw 'Playtest request timed out while writing.' }
		$buffer = [byte[]]::new(8192)
		$complete = $false
		while (-not $complete) {
			$read = $stream.ReadAsync($buffer, 0, $buffer.Length)
			if (-not $read.Wait((Get-RemainingMilliseconds $LimitSec))) { throw 'Playtest response timed out.' }
			$count = $read.Result
			if ($count -le 0) { throw 'Playtest connection closed before a complete response.' }
			$newline = [Array]::IndexOf($buffer, [byte]10, 0, $count)
			$take = $count
			if ($newline -ge 0) { $take = $newline + 1; $complete = $true }
			if ($response.Length + $take -gt 262144) { throw 'Playtest response exceeds 256 KiB.' }
			$response.Write($buffer, 0, $take)
		}
		$reply = $script:Utf8.GetString($response.ToArray()) | ConvertFrom-Json
		if ($null -eq $reply -or (Get-Field $reply 'id') -cne $id) { throw 'Playtest response ID is invalid.' }
		if ($null -ne (Get-Field $reply 'error')) { throw 'Playtest server rejected the request.' }
		return $reply
	} finally {
		$response.Dispose()
		$socket.Close()
	}
}

function Get-Status($Descriptor, [int]$LimitSec) {
	return (Invoke-PlaytestRequest $Descriptor 'status' ([PSCustomObject]@{}) $LimitSec).result
}

function ConvertTo-Arguments([string]$Json) {
	if ([string]::IsNullOrWhiteSpace($Json)) { $Json = '{}' }
	try { $value = $Json | ConvertFrom-Json } catch { throw 'ArgsJson must be valid JSON.' }
	if ($value -isnot [PSCustomObject]) { throw 'ArgsJson must be a JSON object.' }
	$arguments = @{}
	foreach ($property in $value.PSObject.Properties) { $arguments[$property.Name] = $property.Value }
	return $arguments
}

function Get-ClientState([string]$Root, [string]$SessionId) {
	$path = Join-Path $Root 'client.json'
	$state = Read-JsonFile $path
	if ($null -eq $state -or [string](Get-Field $state 'session_id') -cne $SessionId) {
		return @{ session_id = $SessionId; next_sequence = 1 }
	}
	return @{ session_id = $SessionId; next_sequence = [int](Get-Field $state 'next_sequence') }
}

function Prepare-Arguments($Arguments, [string]$OperationName, [string]$Root, $Manifest, $Descriptor, [int]$ExplicitSequence, [int]$LimitSec) {
	if ($OperationName -eq 'operation_status') {
		if (-not $Arguments.ContainsKey('session_id')) {
			$Arguments.session_id = [string](Get-Field $Descriptor 'session_id')
		}
		return $Arguments
	}
	$mutating = $OperationName -in @('act', 'set_view', 'advance', 'run_until', 'pause', 'observe', 'shutdown')
	if (-not $mutating) { return $Arguments }
	$status = Get-Status $Descriptor $LimitSec
	$sessionId = [string](Get-Field $status 'session_id')
	if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = [string](Get-Field $Descriptor 'session_id') }
	if (-not $Arguments.ContainsKey('session_id')) { $Arguments.session_id = $sessionId }
	if (-not $Arguments.ContainsKey('seq')) {
		if ($ExplicitSequence -ge 0) { $Arguments.seq = $ExplicitSequence }
		else {
			$state = Get-ClientState $Root $sessionId
			$serverNext = [int](Get-Field $status 'last_sequence') + 1
			if ($serverNext -lt 1) { $serverNext = 1 }
			# The server is authoritative after a transport timeout or a rejected
			# request. This prevents a client-side sequence gap on the next call.
			$Arguments.seq = $serverNext
			$state.next_sequence = [int]$Arguments.seq + 1
			ConvertTo-JsonFile $state (Join-Path $Root 'client.json')
		}
	}
	if (-not $Arguments.ContainsKey('world_epoch')) {
		$epoch = Get-Field $status 'world_epoch'
		if ($null -eq $epoch) { throw 'Playtest status did not provide world_epoch.' }
		$Arguments.world_epoch = $epoch
	}
	if ($OperationName -in @('act', 'set_view') -and -not $Arguments.ContainsKey('view_id')) {
		$view = Get-Field $status 'view_id'
		if ($null -ne $view) { $Arguments.view_id = $view }
	}
	return $Arguments
}

function Wait-Operation($Descriptor, $Reply, [int]$LimitSec) {
	$operationId = Get-Field $Reply.result 'operation_id'
	if ([string]::IsNullOrWhiteSpace([string]$operationId)) { return $Reply }
	$deadline = $script:Clock.ElapsedMilliseconds + [int64]$LimitSec * 1000
	while ($true) {
		if ($script:Clock.ElapsedMilliseconds -ge $deadline) { throw 'Playtest operation timed out.' }
		Start-Sleep -Milliseconds 250
		$poll = Invoke-PlaytestRequest $Descriptor 'operation_status' @{ session_id = [string](Get-Field $Descriptor 'session_id'); operation_id = [string]$operationId } $LimitSec
		$state = [string](Get-Field $poll.result 'state')
		if ($state -in @('complete', 'completed', 'succeeded', 'failed', 'error', 'cancelled', 'canceled', 'timeout')) { return $poll }
	}
}

function Start-Session([string]$RequestedId, [string]$RequestedScenario) {
	if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'tools/playtest_bootstrap.gd') -PathType Leaf)) {
		throw 'Playtest bootstrap is missing: res://tools/playtest_bootstrap.gd.'
	}
	$runIdValue = Get-SafeRunId $RequestedId
	$root = if ([string]::IsNullOrWhiteSpace($RunRoot)) { Join-Path $script:PlaytestRoot $runIdValue } else { Get-RunRootPath $RunRoot $runIdValue }
	if (Test-Path -LiteralPath $root) { throw 'The selected playtest run directory already exists.' }
	foreach ($directory in @($root, (Join-Path $root 'appdata'), (Join-Path $root 'localappdata'), (Join-Path $root 'control'), (Join-Path $root 'logs'), (Join-Path $root 'observations'))) {
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	$meta = Get-GitMetadata
	$projectName = Get-ProjectIdentity
	$userDataRoot = Join-Path (Join-Path (Join-Path $root 'appdata') 'Godot/app_userdata') $projectName
	New-Item -ItemType Directory -Path $userDataRoot -Force | Out-Null
	$startupConfig = Join-Path $userDataRoot 'playtest_startup.cfg'
	[IO.File]::WriteAllText($startupConfig, "[display]`r`nwindow/size/no_focus=true`r`n", $script:Utf8)
	$manifest = @{
		protocol_version = 1; run_id = $runIdValue; project_name = $projectName; scenario = $RequestedScenario; scenario_version = 1
		run_root = [IO.Path]::GetFullPath($root); state = 'starting'; process_id = 0; startup_identity = ''
		godot_executable = ''; descriptor_path = ''; started_at = (Get-Date).ToUniversalTime().ToString('o')
		source_revision = $meta.source_revision; dirty_worktree = $meta.dirty_worktree
	}
	ConvertTo-JsonFile $manifest (Join-Path $root 'session.json')
	$godot = Get-GodotExecutable
	$manifest.godot_executable = $godot
	ConvertTo-JsonFile $manifest (Join-Path $root 'session.json')
	$logPath = Join-Path $root 'logs/godot.log'
	$info = [Diagnostics.ProcessStartInfo]::new()
	$info.FileName = $godot
	$info.WorkingDirectory = $script:RepoRoot
	$info.UseShellExecute = $false
	$info.CreateNoWindow = $true
	$info.RedirectStandardInput = $true
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	$info.Arguments = (@('--path', $script:RepoRoot, '--display-driver', 'windows', '--rendering-method', 'forward_plus', '--resolution', '1920x1080', '--max-fps', '60', '--script', 'res://tools/playtest_bootstrap.gd', '--log-file', $logPath, '--audio-driver', 'Dummy', '--', '--playtest', '--run-id', $runIdValue, '--run-root', [IO.Path]::GetFullPath($root), '--scenario', $RequestedScenario) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
	$info.EnvironmentVariables['APPDATA'] = Join-Path $root 'appdata'
	$info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $root 'localappdata'
	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $info
	if (-not $process.Start()) { throw 'Godot playtest process could not be started.' }
	# Godot writes its durable output to --log-file. Close inherited pipe ends
	# immediately so this launcher can return without waiting for the game.
	$process.StandardInput.Close()
	$process.StandardOutput.Close()
	$process.StandardError.Close()
	$manifest.process_id = $process.Id
	try { $manifest.startup_identity = $process.StartTime.ToUniversalTime().ToString('o') } catch { $manifest.startup_identity = '' }
	ConvertTo-JsonFile $manifest (Join-Path $root 'session.json')
	Save-Current $root $runIdValue
	$script:Clock = [Diagnostics.Stopwatch]::StartNew()
	$deadline = $TimeoutSec
	$descriptor = $null
	$status = $null
	while ($script:Clock.ElapsedMilliseconds -lt ([int64]$deadline * 1000)) {
		if ($process.HasExited) { throw 'Playtest bootstrap exited before becoming ready; inspect the run logs.' }
		try {
			$descriptor = Get-Descriptor $root $manifest
			$status = Get-Status $descriptor $TimeoutSec
			if ((Get-Field $status 'ready') -eq $true) { break }
		} catch { }
		Start-Sleep -Milliseconds 100
	}
	if ($null -eq $descriptor -or $null -eq $status -or (Get-Field $status 'ready') -ne $true) {
		throw 'Playtest bootstrap did not become ready before the timeout.'
	}
	$manifest.state = 'ready'; $manifest.descriptor_path = (Get-ChildItem -LiteralPath (Join-Path $root 'control') -Filter '*.json' -File | Select-Object -First 1).FullName
	ConvertTo-JsonFile $manifest (Join-Path $root 'session.json')
	$reply = @{ run_id = $runIdValue; run_root = $root; status = $status }
	# The manifest retains the PID and startup identity; this launcher no longer
	# needs an open process handle once readiness has been reported.
	$process.Close()
	$reply | ConvertTo-Json -Depth 64
}

function Test-OwnedProcess($Manifest) {
	$ownedProcessId = [int](Get-Field $Manifest 'process_id')
	if ($ownedProcessId -le 0) { return $false }
	try {
		$process = Get-Process -Id $ownedProcessId -ErrorAction Stop
		$path = $process.MainModule.FileName
		$expected = [IO.Path]::GetFullPath([string](Get-Field $Manifest 'godot_executable'))
		if ([IO.Path]::GetFullPath($path) -ne $expected) { return $false }
	$identity = ConvertTo-StartupIdentity (Get-Field $Manifest 'startup_identity')
	if ([string]::IsNullOrWhiteSpace($identity)) { return $false }
	$actualIdentity = ConvertTo-StartupIdentity $process.StartTime
	if ($actualIdentity -ne $identity) { return $false }
		return $true
	} catch { return $false }
}

function Stop-Session([string]$Root) {
	$manifest = Get-Manifest $Root
	if (-not (Test-OwnedProcess $manifest)) { throw 'Owned Godot process could not be verified; no process was stopped.' }
	$descriptor = Get-Descriptor $Root $manifest
	$status = Get-Status $descriptor $TimeoutSec
	if ([string](Get-Field $status 'run_id') -cne [string](Get-Field $manifest 'run_id')) { throw 'Playtest status run_id does not match the manifest.' }
	$args = Prepare-Arguments @{} 'shutdown' $Root $manifest $descriptor $Sequence $TimeoutSec
	$reply = Invoke-PlaytestRequest $descriptor 'shutdown' $args $TimeoutSec
	$script:Clock = [Diagnostics.Stopwatch]::StartNew()
	while ($script:Clock.ElapsedMilliseconds -lt ([int64]$TimeoutSec * 1000)) {
		try { Get-Process -Id ([int](Get-Field $manifest 'process_id')) -ErrorAction Stop | Out-Null; Start-Sleep -Milliseconds 100 }
		catch { $manifest.state = 'stopped'; ConvertTo-JsonFile $manifest (Join-Path $Root 'session.json'); return $reply }
	}
	throw 'Playtest shutdown was requested but the owned process did not exit.'
}

try {
	if ($Command -eq 'Start') { Start-Session $RunId $Scenario; exit 0 }
	$root = Get-RunRootPath $RunRoot $RunId
	$manifest = Get-Manifest $root
	if ($Command -eq 'Status') {
		$descriptor = Get-Descriptor $root $manifest
		@{ run_id = $manifest.run_id; run_root = $root; status = Get-Status $descriptor $TimeoutSec } | ConvertTo-Json -Depth 64
	} elseif ($Command -eq 'Send' -or $Command -eq 'Observe') {
		$descriptor = Get-Descriptor $root $manifest
		$op = if ($Command -eq 'Observe') { 'observe' } else { $Operation }
		$args = ConvertTo-Arguments $ArgsJson
		$args = Prepare-Arguments $args $op $root $manifest $descriptor $Sequence $TimeoutSec
		$reply = Invoke-PlaytestRequest $descriptor $op $args $TimeoutSec
		if ($Wait -or $Command -eq 'Observe') { $reply = Wait-Operation $descriptor $reply $TimeoutSec }
		$reply | ConvertTo-Json -Depth 64
	} elseif ($Command -eq 'Stop') {
		Stop-Session $root | ConvertTo-Json -Depth 64
	} elseif ($Command -eq 'Reset') {
		$nextScenario = if ($PSBoundParameters.ContainsKey('Scenario')) { $Scenario } else { [string](Get-Field $manifest 'scenario') }
		Stop-Session $root | Out-Null
		$RunRoot = ''
		Start-Session '' $nextScenario
	}
} catch {
	# Keep transport credentials and raw socket details out of user-facing errors.
	$message = $_.Exception.Message
	if ($message -match '[0-9a-f]{64}') { $message = 'Playtest operation failed.' }
	Write-Error -Message $message -ErrorAction Continue
	exit 1
}
