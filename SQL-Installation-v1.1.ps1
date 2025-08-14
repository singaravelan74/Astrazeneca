#Requires -RunAsAdministrator

<#
.SYNOPSIS
    MS SQL Server silent installation script

.DESCRIPTION
    This script installs MS SQL Server unattended from the ISO image.
    Transcript of entire operation is recorded in the log file.

    The script lists parameters provided to the native setup but hides sensitive data. See the provided
    links for SQL Server silent install details.
.NOTES
    Version: 1.1 - Initial.
#>

$ErrorActionPreference = 'STOP'
$scriptName = (Split-Path -Leaf $PSCommandPath).Replace('.ps1', '')

$start = Get-Date
Start-Transcript "$PSScriptRoot\$scriptName-$($start.ToString('s').Replace(':','-')).log"

#.net version check
$releaseKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Release
if (-not $releaseKey -or $releaseKey -lt 461808) {
      Write-Host ".NET Framework 4.7.2 not detected. Installing..."
      exit 1
} else {
      Write-Host ".NET Framework 4.7.2 is already installed."
}
$Features = @('SQLEngine', 'Replication', 'FullText','BC', 'Conn', 'SNAC_SDK', 'SDK')
$InstanceName = 'MSSQLSERVER'
$InstallDir = "G:\Program Files\Microsoft SQL Server"
$ServiceAccountName = 'NT Service\MSSQLSERVER'
$SaPassword = "Welcome@12345"
$SystemAdminAccounts = @('EMEA\XAZ-ECAP-DBA-SQL-PROD', 'ASTRAZENECA\XAZU-AZ_AZ-ECAP-DBA-SQL-NONPROD-ADMIN')
$SystemAdminAccounts = ($SystemAdminAccounts | ForEach-Object { '"{0}"' -f $_ }) -join ' '
$DataDir = "D:\Program Files\Microsoft SQL Server"
$SqlUserDbDir = "E:\Data"
$SqlUserDbLogDir= "G:\Log"
$SqlBckDir = "F:\Backup"
$SqlTmpDir = "F:\TempData"
$SqlTmpDbLogDir = "F:\TempLog"
$sqlCollation = "SQL_Latin1_General_CP1_CI_AS"




#RAM check
$minMemoryGB = 6
$totalMemoryBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
$totalMemoryGB = [math]::Round($totalMemoryBytes / 1GB, 2)

Write-Host "[INFO] Total Physical Memory: $totalMemoryGB GB"

if ($totalMemoryGB -lt $minMemoryGB) {
      Write-Host "[ERROR] Minimum required RAM is ${minMemoryGB}GB. Current system has ${totalMemoryGB}GB."
      throw "Insufficient RAM. Installation cannot proceed."
	  exit 1
} else {
      Write-Host "[INFO] RAM check passed."
}

$IsoPath = "https://azmphedge.astrazeneca.net/public-archives/download/Artifact/SW_DVD9_NTRL_SQL_Svr_Ent_Core_2019Dec2019_64Bit_English_OEM_VL_X22-22120.ISO"
$sqlServerInstPath = Join-Path $ENV:Temp "sqlServerPackages"
New-Item $sqlServerInstPath -ItemType Directory -ErrorAction 0 | Out-Null
$isoName = $IsoPath -split '/' | Select-Object -Last 1
$savePath = Join-Path $sqlServerInstPath $isoName
Write-Host "`savePath: " $savePath
if (Test-Path $savePath){
	Write-Host "ISO already downloaded, checking hashsum..."
	$hash    = Get-FileHash -Algorithm MD5 $savePath | % Hash
	$oldHash = Get-Content "$savePath.md5" -ErrorAction 0
}

if ($hash -and $hash -eq $oldHash) { Write-Host "Hash is OK" } else {
	if ($hash) { Write-Host "Hash is NOT OK"}
	Write-Host "Downloading: $isoPath"
	$expectedSize = 1426724864  # Optional: set known ISO size in bytes if you have it
	$maxRetries = 5
	$retryDelay = 5  # seconds

	$wc = New-Object System.Net.WebClient

	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		try {
			Write-Host "[$attempt/$maxRetries] Downloading ISO..."
			$wc.DownloadFile($IsoPath, $savePath)

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

$volume = Mount-DiskImage $savePath -StorageType ISO -PassThru | Get-Volume
$iso_drive = if ($volume) {
    $volume.DriveLetter + ':'
} else {
    # In Windows Sandbox for some reason Get-Volume returns nothing, so lets look for the ISO description
    Get-PSDrive | ? Description -like 'sql*' | % Root
}
if (!$iso_drive) { throw "Can't find mounted ISO drive" } else { Write-Host "ISO drive: $iso_drive" }

#installation begins
$cmd =@(
    "${iso_drive}\setup.exe"
    '/Q'                                       # Silent install
    '/IACCEPTSQLSERVERLICENSETERMS'            # Must be included in unattended installations
    '/ACTION=install'                          # Required to indicate the installation workflow
    '/UPDATEENABLED=false'                     # Should it discover and include product updates.
    '/SUPPRESSPRIVACYSTATEMENTNOTICE=false'    # To Suppress Privacy Statement Notice 
    "/INSTANCEDIR=""$InstallDir"""             # Specify the installation directory.
    "/INSTALLSQLDATADIR=""$DataDir"""          # The Database Engine root data directory.
    "/SQLUSERDBDIR=""$SqlUserDbDir"""          # Default directory for the Database Engine user databases.
	"/SQLUSERDBLOGDIR=""$SqlUserDbLogDir"""    # Default directory for the Database Engine user database logs.
    "/SQLBACKUPDIR=""$SqlBckDir"""             # Default directory for the Database Engine backup files.
    "/SQLTEMPDBDIR=""$SqlTmpDir"""             # Directories for Database Engine TempDB files.
    "/SQLTEMPDBLOGDIR=""$SqlTmpDbLogDir"""     # Directory for the Database Engine TempDB log files.
    "/FEATURES=" + ($Features -join ',')
    "/SQLCOLLATION=""$sqlCollation"""
    #Security
    "/SQLSYSADMINACCOUNTS=" + ($SystemAdminAccounts -join ',')    # Windows account(s) to provision as SQL Server system administrators.
    '/SECURITYMODE=SQL'                 # Specifies the security mode for SQL Server. By default, Windows-only authentication mode is supported.
    "/SAPWD=""$SaPassword"""            # Sa user password
    "/INSTANCENAME=$InstanceName"       # Server instance name
    "/SQLSVCACCOUNT=""$ServiceAccountName"""
    # Service startup types
    "/SQLSVCSTARTUPTYPE=automatic"
    "/AGTSVCSTARTUPTYPE=automatic"
    "/ASSVCSTARTUPTYPE=manual"
)




# remove empty arguments
$cmd_out = $cmd = $cmd -notmatch '/.+?=("")?$'

# show all parameters but remove password details
Write-Host "Install parameters:`n"
'SAPWD', 'SQLSVCPASSWORD' | % { $cmd_out = $cmd_out -replace "(/$_=).+", '$1"****"' }
$cmd_out[1..100] | % { $a = $_ -split '='; Write-Host '   ' $a[0].PadRight(40).Substring(1), $a[1] }
Write-Host

"$cmd_out"
Invoke-Expression "$cmd"
if ($LastExitCode) {
    if ($LastExitCode -ne 3010) { throw "SqlServer installation failed, exit code: $LastExitCode" }
    Write-Warning "SYSTEM REBOOT IS REQUIRED"
}



"`nInstallation length: {0:f1} minutes" -f ((Get-Date) - $start).TotalMinutes

Dismount-DiskImage $savePath
Stop-Transcript
trap { Stop-Transcript; if ($savePath) { Dismount-DiskImage $savePath -ErrorAction 0 } }
