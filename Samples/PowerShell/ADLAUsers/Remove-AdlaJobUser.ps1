<#
.SYNOPSIS
Script used to remove permissions for an ADLA job user

.DESCRIPTION
This script removes permissions for the specified user or group to submit and browse jobs in the specified ADLA account

.PARAMETER Account
The name of the ADLA account to remove the user from.

.PARAMETER EntityIdToRemove
The ObjectID of the user or group to remove.
The recommendation to ensure the right user is added is to run Get-AzureRMAdUser or Get-AzureRMAdGroup and pass in the ObjectID
returned by that cmdlet.

.PARAMETER EntityType
Indicates if the entity to be removed is a user or a group

.PARAMETER FullReplication
If explicitly passed in we will do the full permissions removal for the user
as a blocking call. This will take a very long time depending on the size of the job history.
The recommendation is to not pass this value in, and let the script submit an async job to perform this action.

.EXAMPLE
Remove-AdlaJobUser.ps1 -Account myadlsaccount -EntityIdToRemove 546e153e-0ecf-417b-ab7f-aa01ce4a7bff -EntityType User
#>
param
(
	[Parameter(Mandatory=$true)]
	[string] $Account,
	[Parameter(Mandatory=$true)]
	[Guid] $EntityIdToRemove,
	[ValidateSet("User", "Group")]
	[Parameter(Mandatory=$true)]
	[string] $EntityType,
	[Parameter(Mandatory=$false)]
	[switch] $FullReplication = $false
)

function removeaccess
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path,
		[Parameter(Mandatory=$true)]
		[Guid] $IdToRemove,
		[Parameter(Mandatory=$true)]
		[string] $entityType,
		[Parameter(Mandatory=$false)]
		[switch] $isDefault = $false,
		[Parameter(Mandatory=$true)]
		[string] $loginProfilePath
	)
	
	$aceToRemove = "$entityType`:$IdToRemove`:---"
	if($isDefault)
	{
		$aceToRemove = "default:$aceToRemove,$aceToRemove"
	}
	
	return Start-Job -ScriptBlock {param ($loginProfilePath, $Account, $Path, $aceToRemove) Select-AzureRMProfile -Path $loginProfilePath | Out-Null; Remove-AzureRmDataLakeStoreItemAclEntry -Account $Account -Path $Path -Acl "$aceToRemove"} -ArgumentList $loginProfilePath, $Account, $Path, $aceToRemove
}

function removeacls
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path,
		[Parameter(Mandatory=$true)]
		[Guid] $IdToRemove,
		[Parameter(Mandatory=$true)]
		[string] $entityType,
		[Parameter(Mandatory=$true)]
		[string] $loginProfilePath
	)
	
	$itemList = Get-AzureRMDataLakeStoreChildItem -Account $Account -Path $Path;
	foreach($item in $itemList)
	{
		$pathToSet = Join-Path -Path $Path -ChildPath $item.PathSuffix;
		$pathToSet = $pathToSet.Replace("\", "/");
		
		if ($item.Type -ieq "FILE")
		{
			# set the ACL without default using "All" permissions
			removeaccess -Account $Account -Path $Path -IdToRemove $IdToRemove -entityType $entityType -loginProfilePath $loginProfilePath | Out-Null
		}
		elseif ($item.Type -ieq "DIRECTORY")
		{
			# set permission and recurse on the directory
			removeaccess -Account $Account -Path $Path -IdToRemove $IdToRemove -entityType $entityType -isDefault -loginProfilePath $loginProfilePath  | Out-Null
			removeacls -Account $Account -Path $pathToSet -IdToRemove $IdToRemove -entityType $entityType -loginProfilePath $loginProfilePath  | Out-Null
		}
		else
		{
			throw "Invalid path type of: $($item.Type). Valid types are 'DIRECTORY' and 'FILE'"
		}
	}
}

# This script assumes the following:
# 1. The Azure PowerShell environment is installed
# 2. The current session has already run "Login-AzureRMAccount" with a user account that has permissions to the specified ADLS account
try
{	$executingDir = Split-Path -parent $MyInvocation.MyCommand.Definition
	$executingFile = Split-Path -Leaf $MyInvocation.MyCommand.Definition
	
	# get the datalake store account that this ADLA account uses
	$adlsAccount = $(Get-AzureRmDataLakeAnalyticsAccount -Name $Account).Properties.DefaultDataLakeStoreAccount
	$profilePath = Join-Path $env:TEMP "jobprofilesession.tmp"
	if(! (Test-Path $profilePath))
	{
		Save-AzureRMProfile -path $profilePath | Out-Null
	}
	
	if($FullReplication)
	{
		Write-Host "Request to remove entity: $EntityIdToRemove successfully submitted and will propagate over time depending on the size of the folder."
		Write-Host "Please do not close this powershell window as the propagation will be cancelled"
		removeacls -Account $adlsAccount -Path /system -IdToRemove $EntityIdToRemove -entityType $EntityType -loginProfilePath $profilePath | Out-Null
	}
	else
	{
		# Now give and check access for the user on the following folders:
		# / (x)
		# /system (rwx)
		# /system/jobservice (rwx)
		# /system/jobservice/jobs (rwx)
		$allJobs = @()
		$pathList = @("/", "/system", "/system/jobservice", "/system/jobservice/jobs", "/system/jobservice/jobs/Usql")
		foreach ($item in $pathList)
		{
			if (!([string]::IsNullOrEmpty($item)) -and (Test-AzureRMDataLakeStoreItem -Account $adlsAccount -Path $item))
			{
				$allJobs += removeaccess -Account $adlsAccount -Path $item -IdToRemove $EntityIdToRemove -entityType $entityType -isDefault -loginProfilePath $profilePath
			}
		}
	
		$job = Start-Job -ScriptBlock {param ($Account, $EntityIdToRemove, $EntityType, $profilePath, $ScriptToRun) Select-AzureRMProfile -Path $profilePath | Out-Null; &$ScriptToRun -Account $Account -EntityIdToRemove $EntityIdToRemove -EntityType $EntityType -FullReplication} -ArgumentList $Account, $EntityIdToRemove, $EntityType, $profilePath, $MyInvocation.MyCommand.Definition
	
		Write-Host "Request to remove entity: $EntityIdToRemove successfully submitted and will propagate over time depending on the size of the folder."
		Write-Host "Please leave this powershell window open and track the progress of the full propagation with the returned job: $($job.Id)"
		return $job
	}
}
catch
{
	Write-Error "ACL Propagation failed with the following error: $($error[0])"
}