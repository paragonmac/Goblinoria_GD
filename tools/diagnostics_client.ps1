<#
.SYNOPSIS
Queries a running Goblinoria Live Diagnostics session over authenticated loopback TCP.
.EXAMPLE
./tools/diagnostics_client.ps1 -ListSessions
.EXAMPLE
./tools/diagnostics_client.ps1 -Session playtest -Operation inspect_cell -ArgsJson '{"pos":[1,2,3]}'
.EXAMPLE
./tools/diagnostics_client.ps1 -Session playtest -Operation inspect_worker -ArgsJson '{"world_epoch":1,"id":7}'
.EXAMPLE
./tools/diagnostics_client.ps1 -Session playtest -Operation list_workers -ArgsJson '{"limit":20}'
.EXAMPLE
./tools/diagnostics_client.ps1 -DescriptorPath C:/temp/session-123.json -Operation capture_bug -WaitCapture -TimeoutSec 60
.NOTES
Credentials are read from the descriptor and never included in session listings.
Use -DescriptorRoot for a custom Godot user directory. Multiple sessions require
an explicit -Session (session ID or descriptor filename stem) or -DescriptorPath.
The timeout covers the entire query, including capture polling.
Fresh coordinate/screen queries and list first pages automatically obtain a
missing world_epoch from status; inspect_screen also obtains a missing view_id
from status.data. Worker/task/item inspections require the explicit world_epoch
associated with their integer id because IDs can be reused. Every list request
with a cursor must supply the epoch associated with that cursor. Use the returned
cursor object unchanged; an empty object is not a valid cursor. Explicit stamps
are preserved. Cell, chunk, and stockpile queries use pos:[x,y,z].
capture_bug automatically generates a missing request_key. Supply your own key
to deduplicate retries across client invocations. capture_status takes no args;
capture polling verifies that the latest capture still has the requested ID.
#>
[CmdletBinding()]
param(
	[string]$Session,
	[string]$DescriptorPath,
	[string]$DescriptorRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Godot/app_userdata/Goblinoria/diagnostics/bridge'),
	[switch]$ListSessions,
	[ValidateSet('status', 'inspect_screen', 'inspect_cell', 'inspect_chunk', 'list_workers', 'list_tasks', 'inspect_worker', 'inspect_task', 'inspect_item', 'inspect_stockpile', 'recent_events', 'capture_bug', 'capture_status')]
	[string]$Operation = 'status',
	[Alias('Args')][string]$ArgsJson = '{}',
	[ValidateRange(1, 3600)][int]$TimeoutSec = 10,
	[switch]$WaitCapture,
	[ValidateRange(100, 5000)][int]$PollIntervalMs = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:credential = ''
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-Field($Object, [string]$Name) {
	if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
		return $Object.PSObject.Properties[$Name].Value
	}
	return $null
}

function Get-RemainingMilliseconds {
	$remaining = [int64]$TimeoutSec * 1000 - $script:clock.ElapsedMilliseconds
	if ($remaining -le 0) { throw 'Diagnostics request timed out.' }
	return [int]$remaining
}

function Get-CaptureData($Reply) {
	$data = Get-Field $Reply.result 'data'
	if ($null -eq $data) { $data = $Reply.result }
	if ($null -ne (Get-Field $Reply.result 'error') -or $null -ne (Get-Field $data 'error')) {
		# Failed terminal captures also carry an error and should still be returned.
		if ((Get-Field $data 'state') -ne 'failed') { throw 'Capture request failed; the service reported an error.' }
	}
	return $data
}

function Read-Descriptor([string]$Path) {
	try {
		$value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
	} catch { throw 'Cannot read a valid diagnostics descriptor.' }
	$hostName = Get-Field $value 'host'
	$portValue = Get-Field $value 'port'
	$tokenValue = Get-Field $value 'token'
	if ($hostName -cne '127.0.0.1' -or $null -eq $portValue -or
		$portValue -is [string] -or $portValue -lt 1 -or $portValue -gt 65535 -or
		[double]$portValue -ne [Math]::Floor([double]$portValue) -or
		$tokenValue -isnot [string] -or $tokenValue -cnotmatch '^[0-9a-f]{64}$' -or
		(Get-Field $value 'session_id') -isnot [string] -or
		(Get-Field $value 'pid') -isnot [ValueType]) {
		throw 'Invalid diagnostics descriptor fields; expected an authenticated loopback endpoint.'
	}
	return $value
}

function Invoke-DiagnosticsRequest($Descriptor, [string]$Op, $Arguments) {
	$id = [Guid]::NewGuid().ToString('N')
	$wire = @{ id = $id; token = $script:credential; op = $Op; args = $Arguments } | ConvertTo-Json -Depth 64 -Compress
	$bytes = $script:utf8.GetBytes($wire + "`n")
	if ($bytes.Length -gt 8192) { throw 'Diagnostics request exceeds 8 KiB.' }
	$socket = [Net.Sockets.TcpClient]::new()
	$socket.NoDelay = $true
	$buffer = [byte[]]::new(8192)
	$response = [IO.MemoryStream]::new()
	try {
		$task = $socket.ConnectAsync('127.0.0.1', [int]$Descriptor.port)
		if (-not $task.Wait((Get-RemainingMilliseconds))) { throw 'Diagnostics connection timed out.' }
		$stream = $socket.GetStream()
		$task = $stream.WriteAsync($bytes, 0, $bytes.Length)
		if (-not $task.Wait((Get-RemainingMilliseconds))) { throw 'Diagnostics write timed out.' }
		$complete = $false
		while (-not $complete) {
			$task = $stream.ReadAsync($buffer, 0, $buffer.Length)
			if (-not $task.Wait((Get-RemainingMilliseconds))) { throw 'Diagnostics response timed out.' }
			$count = $task.Result
			if ($count -eq 0) { throw 'Diagnostics connection closed before a complete response.' }
			$newline = [Array]::IndexOf($buffer, [byte]10, 0, $count)
			$take = $count
			if ($newline -ge 0) { $take = $newline + 1; $complete = $true }
			if ($response.Length + $take -gt 262144) { throw 'Diagnostics response exceeds 256 KiB.' }
			$response.Write($buffer, 0, $take)
		}
		try {
			$decoded = $script:utf8.GetString($response.ToArray())
			$reply = $decoded | ConvertFrom-Json
		} catch { throw 'Diagnostics server returned invalid JSON or UTF-8.' }
		if ($reply -isnot [PSCustomObject]) { throw 'Diagnostics server returned an invalid response object.' }
		$errorValue = Get-Field $reply 'error'
		if ($null -ne $errorValue) {
			# Do not reflect server-provided messages or identifiers into errors.
			if ((Get-Field $errorValue 'code') -eq 'unauthorized') { throw 'Diagnostics authentication failed; refresh the session descriptor.' }
			throw 'Diagnostics server rejected the request (see operation, arguments, and transport limits).'
		}
		if ((Get-Field $reply 'id') -cne $id -or (Get-Field $reply 'result') -isnot [PSCustomObject]) {
			throw 'Diagnostics response ID or result is invalid.'
		}
		return $reply
	} finally {
		$response.Dispose()
		$socket.Close()
	}
}

try {
	if ($DescriptorPath -and $Session) { throw 'Choose either -DescriptorPath or -Session.' }
	if ($DescriptorPath -and $ListSessions) { throw 'Use -DescriptorRoot with -ListSessions.' }
	if ($ListSessions -or -not $DescriptorPath) {
		$entries = @()
		if (Test-Path -LiteralPath $DescriptorRoot -PathType Container) {
			foreach ($file in (Get-ChildItem -LiteralPath $DescriptorRoot -Filter '*.json' -File | Sort-Object Name)) {
				try { $descriptor = Read-Descriptor $file.FullName } catch { continue }
				$entries += [PSCustomObject]@{
					session_id = $descriptor.session_id; pid = $descriptor.pid
					port = $descriptor.port; descriptor_path = $file.FullName
				}
			}
		}
		if ($ListSessions) {
			ConvertTo-Json -InputObject @($entries) -Depth 4
			return
		}
		if ($Session) {
			$entries = @($entries | Where-Object {
				$_.session_id -ceq $Session -or [IO.Path]::GetFileNameWithoutExtension($_.descriptor_path) -ceq $Session
			})
		}
		if ($entries.Count -eq 0) { throw 'No matching diagnostics session. Enable Live Diagnostics or specify -DescriptorRoot.' }
		if ($entries.Count -ne 1) { throw 'Multiple diagnostics sessions found. Select one with -Session or -DescriptorPath.' }
		$DescriptorPath = $entries[0].descriptor_path
	}
	$descriptor = Read-Descriptor $DescriptorPath
	$script:credential = $descriptor.token
	# Windows PowerShell can wrap/unwrap JSON arrays as PSObjects. Check the
	# JSON root as well as its converted type before it can enter the envelope.
	if (-not $ArgsJson.TrimStart().StartsWith('{')) { throw 'ArgsJson must be a JSON object.' }
	try { $arguments = ConvertFrom-Json -InputObject $ArgsJson } catch { throw 'ArgsJson must be valid JSON.' }
	if ($arguments -isnot [PSCustomObject]) { throw 'ArgsJson must be a JSON object.' }
	if ($WaitCapture -and $Operation -notin @('capture_bug', 'capture_status')) {
		throw '-WaitCapture requires capture_bug or capture_status.'
	}
	if ($Operation -eq 'capture_bug' -and $null -eq $arguments.PSObject.Properties['request_key']) {
		$arguments | Add-Member -NotePropertyName 'request_key' -NotePropertyValue ([Guid]::NewGuid().ToString('N'))
	}
	$needsEpoch = ($Operation.StartsWith('inspect_') -or $Operation.StartsWith('list_')) -and
		$null -eq $arguments.PSObject.Properties['world_epoch']
	$requiresExplicitEpoch = $Operation -in @('inspect_worker', 'inspect_task', 'inspect_item') -or
		($Operation.StartsWith('list_') -and $null -ne $arguments.PSObject.Properties['cursor'])
	if ($needsEpoch -and $requiresExplicitEpoch) {
		throw 'This query requires explicit world_epoch from the original entity or cursor observation.'
	}
	$needsView = $Operation -eq 'inspect_screen' -and $null -eq $arguments.PSObject.Properties['view_id']
	if ($needsEpoch -or $needsView) {
		$statusReply = Invoke-DiagnosticsRequest $descriptor 'status' ([PSCustomObject]@{})
		if ($needsEpoch) {
			$epoch = Get-Field $statusReply.result 'world_epoch'
			if ($null -eq $epoch) { throw 'Status did not provide the required world_epoch.' }
			$arguments | Add-Member -NotePropertyName 'world_epoch' -NotePropertyValue $epoch
		}
		if ($needsView) {
			$view = Get-Field (Get-Field $statusReply.result 'data') 'view_id'
			if ($null -eq $view) { throw 'Status did not provide the required view_id.' }
			$arguments | Add-Member -NotePropertyName 'view_id' -NotePropertyValue $view
		}
	}
	$reply = Invoke-DiagnosticsRequest $descriptor $Operation $arguments
	$captureFailed = $false
	if ($WaitCapture) {
		$captureData = Get-CaptureData $reply
		$captureId = Get-Field $captureData 'capture_id'
		if ($null -eq $captureId) { $captureId = Get-Field $arguments 'capture_id' }
		while ($true) {
			$observedId = Get-Field $captureData 'capture_id'
			if ($null -ne $captureId -and $null -ne $observedId -and $observedId -cne $captureId) {
				throw 'The active capture changed while waiting for the requested capture.'
			}
			$state = Get-Field $captureData 'state'
			if ($null -eq $state) { $state = Get-Field $captureData 'status' }
			if ($state -in @('complete', 'completed', 'succeeded', 'failed', 'error', 'cancelled', 'canceled') -or
				(Get-Field $captureData 'completed') -eq $true) {
				$captureFailed = $state -in @('failed', 'error', 'cancelled', 'canceled')
				break
			}
			if ($null -eq $captureId) { throw 'Capture response did not include a capture_id.' }
			Start-Sleep -Milliseconds ([Math]::Min($PollIntervalMs, (Get-RemainingMilliseconds)))
			$reply = Invoke-DiagnosticsRequest $descriptor 'capture_status' ([PSCustomObject]@{})
			$captureData = Get-CaptureData $reply
		}
	}
	$outputJson = $reply | ConvertTo-Json -Depth 64
	$outputJson.Replace($script:credential, '[redacted]')
	if ($captureFailed) { exit 1 }
} catch {
	$message = $_.Exception.Message
	if ($script:credential) { $message = $message.Replace($script:credential, '[redacted]') }
	Write-Error -Message $message -ErrorAction Continue
	exit 1
}
