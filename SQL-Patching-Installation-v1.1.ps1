#Requires -RunAsAdministrator

<#
.SYNOPSIS
    MS SQL Server Patching silent installation script

.DESCRIPTION
    This script installs MS SQL Server Patching unattended from the EXE image.
    Transcript of entire operation is recorded in the log file.
.NOTES
    Version:
#>

$ErrorActionPreference = 'STOP'
$scriptName = (Split-Path -Leaf $PSCommandPath).Replace('.ps1', '')

$start = Get-Date
Start-Transcript "$PSScriptRoot\$scriptName-$($start.ToString('s').Replace(':','-')).log"

$ExePath = "https://azmphedge.astrazeneca.net/public-archives/download/Artifact/SQLServer2019-KB5054833_15.0.4430.1_x64.exe"
$sqlServerInstPath = Join-Path $ENV:Temp "sqlServerPackages"

if (-not (Test-Path $sqlServerInstPath)) {
    New-Item $sqlServerInstPath -ItemType Directory | Out-Null
    Write-Host "Created folder: $sqlServerInstPath"
} else {
    Write-Host "Folder already exists, skipping creation."
}

$ExeName = $ExePath -split '/' | Select-Object -Last 1
$savePath = Join-Path $sqlServerInstPath $ExeName
Write-Host "`savePath: " $savePath
if (Test-Path $savePath){
	Write-Host "EXE already downloaded, checking hashsum..."
	$hash    = Get-FileHash -Algorithm MD5 $savePath | % Hash
	$oldHash = Get-Content "$savePath.md5" -ErrorAction 0
}

if ($hash -and $hash -eq $oldHash) { Write-Host "Hash is OK" } else {
	if ($hash) { Write-Host "Hash is NOT OK"}
	Write-Host "Downloading: $ExePath"
	$expectedSize = 930763280  # Optional: set known EXE size in bytes if you have it
	$maxRetries = 5
	$retryDelay = 5  # seconds

	$wc = New-Object System.Net.WebClient

	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		try {
			Write-Host "[$attempt/$maxRetries] Downloading EXE..."
			$wc.DownloadFile($ExePath, $savePath)

			# Verify file exists and optionally size
			if (Test-Path $savePath) {
				$fileSize = (Get-Item $savePath).Length
				if ($expectedSize -and $fileSize -ne $expectedSize) {
					throw "Downloaded file size $fileSize bytes does not match expected $expectedSize bytes."
				}
				if ($fileSize -gt 0) {
					Write-Host "Download complete: $fileSize bytes"
					break
				}
			}
			throw "File not downloaded or size is zero."
		}
		catch {
			Write-Warning "Download failed: $($_.Exception.Message)"
			if ($attempt -lt $maxRetries) {
				Write-Host "Retrying in $retryDelay seconds..."
				Start-Sleep -Seconds $retryDelay
			}
			else {
				throw "All $maxRetries attempts failed."
			}
		}
	}

	Get-FileHash -Algorithm MD5 $savePath | % Hash | Out-File "$savePath.md5"
}
#$existingSqlVersion = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\MSSQLServer\MSSQLServer\CurrentVersion' -Name 'CurrentVersion' -ErrorAction SilentlyContinue).CurrentVersion
#installation begins
$cmd =@(
    "${savePath}"
    '/QUIET'                                   # Silent install
    '/IACCEPTSQLSERVERLICENSETERMS'            # Must be included in unattended installations
    '/ACTION=patch'                            # Required to indicate the installation workflow
    '/AllInstances'
)

Invoke-Expression "$cmd"
if ($LastExitCode) {
    if ($LastExitCode -ne 3010) { throw "SqlServer Patch failed, exit code: $LastExitCode" }
    Write-Warning "SYSTEM REBOOT IS REQUIRED"
}

"`nInstallation length: {0:f1} minutes" -f ((Get-Date) - $start).TotalMinutes

Stop-Transcript
