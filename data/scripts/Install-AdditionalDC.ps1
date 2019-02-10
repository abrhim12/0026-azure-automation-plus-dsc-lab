    #Requires -Version 5.1
    #Requires -RunAsAdministrator
    <#
    .SYNOPSIS
        Promote a existing VMs assigned to the domain controller role that are domained joined to a domain controller.

    .DESCRIPTION
		This script prepares a member servers to be promoted to a domain controller. Note that as a pre-requisite, the server must first be joined to the domain. This is accomplished by intializing, partitioning and formating a new drive that was previously added. Next the directory structure is created for the NTDS, SYSVOL and LOG files, required features are installed, and roles and modules are added. Finally, the member server is promoted to a domain controller.

    .PARAMETER  TBD

    .EXAMPLE
		.\Install-AdditionalDC.ps1 -TargetNodes <computerName>

    .INPUTS
		This script does not accept any piped input objects or parameter names from the pipeline.

    .OUTPUTS
		The output generated by this script will show the verbose acitivity of the server promotion to a domain controller.

    .NOTES
        The MIT License (MIT)
		Copyright (c) 2018 Preston K. Parsard

		Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
		to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

		The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

		LEGAL DISCLAIMER:
		This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment.�
		THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
		INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.�
		We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the object code form of the Sample Code, provided that You agree:
		(i) to not use Our name, logo, or trademarks to market Your software product in which the Sample Code is embedded;
		(ii) to include a valid copyright notice on Your software product in which the Sample Code is embedded; and
		(iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against any claims or lawsuits, including attorneys' fees, that arise or result from the use or distribution of the Sample Code.
		This posting is provided "AS IS" with no warranties, and confers no rights.

    .LINK
        Active Directory - Installing Secord or Additional Domain Controller: https://harmikbatth.com/2017/04/25/active-directory-installing-second-or-additional-domain-controller/
		Joins an existing Windows VM to AD Domain: https://azure.microsoft.com/en-us/resources/templates/201-vm-domain-join-existing/

    .COMPONENT
        DNS

    .ROLE
        Infrastructure Developer
		Infrastructure Engineer
		Active Directory Administrator

    .FUNCTIONALITY
        Promotes a member server with an additional new hard drive to a domain controller.
#>

# Join existing VM to domain first (if necessary)
# See: https://azure.microsoft.com/en-us/resources/templates/201-vm-domain-join-existing/ (click on the 'Deploy to Azure' button)

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true,
    HelpMessage = "Enter the new target domain controllers to promote")]
    [ValidateNotNullOrEmpty()]
    [ValidateCount(1,2)]
    [ValidateScript({($_ -notin (Get-ADDomain).ReplicaDirectoryServers)})]
    [string[]]$targetNodes
) # end param


$FeaturesToAdd = @(
	"RSAT-DNS-Server", 
	"RSAT-AD-AdminCenter",
	"RSAT-ADDS",
	"RSAT-AD-PowerShell",
	"RSAT-AD-Tools",
	"GPMC"
) # end array

# Install features on local script source (dev) server
ForEach ($feature in $FeaturesToAdd)
{
	Install-WindowsFeature -Name $feature -IncludeAllSubFeature -IncludeManagementTools -Verbose
} # end foreach
$currentDomainController = ((Get-ADDomain).ReplicaDirectoryServers).Split(".")[0]
$newDomainControllersFilter = "(name -like 'AZRADS*') -and (name -notlike $currentDomainController)"
# $targetNodes = ((Get-ADObject -Filter $newDomainControllersFilter).DistinguishedName | Get-ADComputer).DnsHostName

$adminUserName = "adm.infra.user@dev.adatum.com"
$adminCred = Get-Credential -UserName $adminUserName -Message "Enter password for user: $adminUserName"

$session = New-PSSession -ComputerName $targetNodes -Credential $adminCred
$FeaturesToAdd = @(
	"RSAT-DNS-Server", 
	"RSAT-AD-AdminCenter",
	"RSAT-ADDS",
	"RSAT-AD-PowerShell",
	"RSAT-AD-Tools",
	"GPMC"
) # end array

# Load AD module
Import-Module -Name ActiveDirectory -Verbose -Force -ErrorAction SilentlyContinue

# Get current AD site name
$initialSite = (Get-ADReplicationSite).Name

# Get domain name
$dnsDomainName = (Get-ADDomain).DnsRoot

$RolesToAdd = @(
	"AD-Domain-Services",
	"RSAT-Role-Tools"
) # end hashtable

$diskProperties = @{
	pInitialPartitionStyle = 'raw';
	pTargetPartitionStyle = "MBR";
	pDriveLetter = "F";
	pFileSystem = "NTFS";
	pFileSystemLabel = "DATA"
} # end hastable

$adPaths = @{
	pLOGS = "F:\LOGS";
	pNTDS = "F:\NTDS";
	pSYSV = "F:\SYSV";
} # end hashtable

$sbDiskSetup = {
	# Initialize, partition and format new disk
	$sbDiskProperties = $using:diskProperties
	Get-Disk | Where-Object { $_.partitionstyle -eq "$($sbDiskProperties.pInitialPartitionStyle)" } | 	
	Initialize-Disk -PartitionStyle "$($sbDiskProperties.pTargetPartitionStyle)" -PassThru | 	
	New-Partition -DriveLetter "$($sbDiskProperties.pDriveLetter)" -UseMaximumSize | 	
	Format-Volume -FileSystem "$($sbDiskProperties.pFileSystem)" -NewFileSystemLabel "$($sbDiskProperties.pFileSystemLabel)" -Confirm:$false
} # end scriptblock

# Setup data disk
Invoke-Command -Session $session -ScriptBlock $sbDiskSetup -Verbose

# Create directory structure for AD
$sbDirectorySetup = {
	# Create DC directory structure
	New-Item -Path "F:\NTDS","F:\SYSV","F:\LOGS" -ItemType Directory -Force
} # end scriptblock

Invoke-Command -Session $session -ScriptBlock $sbDirectorySetup -Verbose

# AD Active Directory features and tools
$sbFeatures = {
	# Install features
	$featuresList = $using:featuresToAdd	
	ForEach ($feature in $featuresList)
	{
		Install-WindowsFeature -Name $feature -IncludeAllSubFeature -IncludeManagementTools
	} # end foreach
} # end scriptblock

Invoke-Command -Session $session -ScriptBlock $sbFeatures -Verbose

# Add Active Directory roles
$sbRoles = {
	# Install roles
	$rolesList = $using:RolesToAdd
	ForEach ($role in $rolesList)
	{
		Install-WindowsFeature -Name $role -IncludeAllSubFeature -IncludeManagementTools
	} # end foreach
} # end foreach

Invoke-Command -Session $session -ScriptBlock $sbRoles -Verbose

# Install Active Directory
$sbInstallDcInExistingDomain = {
	# Install DC
	$paths = $using:adPaths
	Install-ADDSDomainController -NoGlobalCatalog:$false `
	-CreateDnsDelegation:$false `
	-CriticalReplicationOnly:$false `
	-DomainName $using:dnsDomainName `
	-InstallDns:$true `
	-LogPath $paths.pLOGS `
	-DatabasePath $paths.pNTDS `
	-SysvolPath $paths.pSYSV `
	-NoRebootOnCompletion:$false `
	-SiteName $using:initialSite `
	-Credential $using:adminCred `
	-Force:$true
} # end scriptblock

Invoke-Command -Session $session -ScriptBlock $sbInstallDcInExistingDomain -Verbose

# Wait 10 minutes for replication to complete
Do
{
	# Wait for 10 minutes
	Start-Sleep -Seconds 600	
	$dcList = (Get-ADDomain).ReplicaDirectoryServers
}
While (($targetNode -notin $dcList))

# Show list of DCs
Write-Output "List of DCs"
$dcList

# Clean up by removing session
Remove-PSSession -Session $session