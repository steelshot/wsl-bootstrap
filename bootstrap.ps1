#Requires -Version 5.1

<#
.SYNOPSIS
    Installs and provisions the managed openSUSE Tumbleweed WSL distribution.

.DESCRIPTION
    Registers the distribution without launching it, sets it as the default distribution, and then provisions it by
    running site.yml as root, limited to its inventory group. The distribution keeps the name WSL gives it.

    The script refuses to continue when the distribution name is already registered. Nothing is installed, removed,
    or reconfigured in that case. With -Update the opposite applies: the distribution must already be registered, and
    the playbook is run against it again to upgrade it. One-shot steps such as the locale and password setup are
    skipped on a rerun, while the upgradable roles converge to the newest versions.

    Ansible is left installed unless -Cleanup is given.

.PARAMETER RepositoryPath
    Path to this repository. The directory is mounted into the distribution through DrvFs and used as the working
    directory for Ansible. Defaults to the directory containing this script.

.PARAMETER Tags
    Ansible tags applied to the play. Every role except system/core and system/user is gated behind a never tag, and
    only runs when its tag is listed here. The dotfiles role additionally asserts that the git tag is present.

.PARAMETER Update
    Provisions an already registered distribution again instead of installing it. The distribution is not terminated
    afterwards, so that running sessions survive. Restart it to apply changes to /etc/wsl.conf.

.PARAMETER Cleanup
    Removes Ansible and its provisioning state as the last step. Ansible is reinstalled on the next run.

.EXAMPLE
    .\bootstrap.ps1

    Installs the distribution and provisions it with the full default role set.

.EXAMPLE
    .\bootstrap.ps1 -Update

    Upgrades an installed distribution, including RKE2 and the GPU Operator when a newer release is available.

.EXAMPLE
    .\bootstrap.ps1 -Cleanup

    Installs the distribution and removes Ansible afterwards.

.EXAMPLE
    .\bootstrap.ps1 -Tags core, user, ssh, git, dotfiles

    Installs the distribution but limits it to the shell environment.
#>

[CmdletBinding()]
param(
	[ValidateNotNullOrEmpty()]
	[string] $RepositoryPath = $PSScriptRoot,

	[ValidateNotNullOrEmpty()]
	[string[]] $Tags = @('core', 'user', 'ssh', 'nvidia-stack', 'podman', 'rke2', 'git', 'dotfiles', 'kubernetes'),

	[switch] $Update,

	[switch] $Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Forces wsl.exe to emit UTF-8 instead of UTF-16LE, so its output can be parsed without stripping null bytes.
$env:WSL_UTF8 = '1'

$script:Playbook = 'site.yml'
$script:RequiredRepositoryFile = @(
	$script:Playbook,
	'ansible.cfg',
	'requirements.yml',
	'inventory\hosts.yml'
)

function Write-Stage
{
	param([Parameter(Mandatory)][string] $Message)

	Write-Host ''
	Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Wsl
{
	param(
		[Parameter(Mandatory)][string[]] $Arguments,
		[Parameter(Mandatory)][string] $Activity
	)

	# Native tools such as zypper write progress to stderr, which a Stop preference would surface as a terminating
	# error, so success is determined from the exit code instead.
	$preference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try
	{
		& wsl.exe @Arguments
		$exitCode = $LASTEXITCODE
	}
	finally
	{
		$ErrorActionPreference = $preference
	}

	if ($exitCode -ne 0)
	{
		throw "$Activity failed with exit code $exitCode."
	}
}

function Get-RegisteredDistribution
{
	$preference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try
	{
		$output = & wsl.exe --list --quiet 2>&1
		$exitCode = $LASTEXITCODE
	}
	finally
	{
		$ErrorActionPreference = $preference
	}

	if ($exitCode -ne 0)
	{
		throw "Unable to enumerate the registered WSL distributions (exit code $exitCode)."
	}

	$names = @($output | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })

	# The unary comma stops the pipeline from unrolling an empty result set into a null value.
	return ,$names
}

function Invoke-DistributionCommand
{
	param(
		[Parameter(Mandatory)][string] $Name,
		[Parameter(Mandatory)][string[]] $Command,
		[Parameter(Mandatory)][string] $Activity,
		[string] $WorkingDirectory
	)

	$arguments = @('--distribution', $Name, '--user', 'root')
	if ($WorkingDirectory)
	{
		$arguments += @('--cd', $WorkingDirectory)
	}

	Invoke-Wsl -Arguments ($arguments + '--' + $Command) -Activity $Activity
}

function Assert-Prerequisite
{
	param(
		[Parameter(Mandatory)][object[]] $Distribution,
		[Parameter(Mandatory)][string] $Path,
		[switch] $Update
	)

	Write-Stage 'Checking prerequisites'

	if (-not (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue))
	{
		throw 'wsl.exe was not found. Install the Windows Subsystem for Linux before running this bootstrap.'
	}

	Invoke-Wsl -Arguments @('--version') -Activity 'Querying the installed WSL version'

	foreach ($relativePath in $script:RequiredRepositoryFile)
	{
		$fullPath = Join-Path -Path $Path -ChildPath $relativePath
		if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf))
		{
			throw "'$fullPath' was not found. Run this script from a complete checkout of the repository."
		}
	}

	$registered = Get-RegisteredDistribution
	$conflicting = @($Distribution | Where-Object { $registered -contains $_.Name } | ForEach-Object { $_.Name })
	if ($Update)
	{
		$missing = @($Distribution | Where-Object { $registered -notcontains $_.Name } | ForEach-Object { $_.Name })
		if ($missing.Count -gt 0)
		{
			throw "Refusing to update because the following WSL distributions are not registered: " +
					"$( $missing -join ', ' ). Run this bootstrap without -Update to install them."
		}

		Write-Host "Repository path: $Path"
		Write-Host 'The distribution is registered and will be updated.'
		return
	}

	if ($conflicting.Count -gt 0)
	{
		throw "Refusing to continue because the following WSL distributions are already registered: " +
				"$( $conflicting -join ', ' ). Remove them with 'wsl --unregister <name>' and run this bootstrap again, " +
				"or use -Update to upgrade the existing distribution."
	}

	Write-Host "Repository path: $Path"
	Write-Host 'No conflicting distributions are registered.'
}

function Install-Distribution
{
	param([Parameter(Mandatory)][object] $Distribution)

	Write-Stage "Installing $( $Distribution.Image )"

	Invoke-Wsl `
        -Arguments @('--install', $Distribution.Image, '--no-launch') `
        -Activity "Installing $( $Distribution.Image )"
}

function Initialize-Distribution
{
	param([Parameter(Mandatory)][object] $Distribution)

	Write-Stage "Installing provisioning packages in $( $Distribution.Name )"

	Invoke-DistributionCommand `
        -Name $Distribution.Name `
        -Command @('zypper', '--non-interactive', '--gpg-auto-import-keys', 'refresh') `
        -Activity "Refreshing the zypper repositories in $( $Distribution.Name )"

	Invoke-DistributionCommand `
        -Name $Distribution.Name `
	    -Command (@('zypper', '--non-interactive', 'install', '--auto-agree-with-licenses', '--no-recommends') + $Distribution.Packages) `
        -Activity "Installing the provisioning packages in $( $Distribution.Name )"
}

function Invoke-Provisioning
{
	param(
		[Parameter(Mandatory)][object] $Distribution,
		[Parameter(Mandatory)][string] $Path,
		[switch] $Terminate
	)

	Write-Stage "Provisioning $( $Distribution.Name ) as the $( $Distribution.Limit ) group"

	# The repository is reached through a DrvFs mount, which is world writable, and Ansible ignores an ansible.cfg it
	# discovers in a world writable working directory. ANSIBLE_CONFIG is not subject to that check.
	$ansibleEnvironment = @('env', 'ANSIBLE_CONFIG=ansible.cfg')

	Invoke-DistributionCommand `
        -Name $Distribution.Name `
        -WorkingDirectory $Path `
        -Command ($ansibleEnvironment + @('ansible-galaxy', 'collection', 'install', '--requirements-file', 'requirements.yml')) `
        -Activity "Installing the Ansible collections in $( $Distribution.Name )"

	Invoke-DistributionCommand `
        -Name $Distribution.Name `
        -WorkingDirectory $Path `
        -Command ($ansibleEnvironment + @(
		'ansible-playbook', $script:Playbook,
		'--limit', $Distribution.Limit,
		'--tags', ($Distribution.Tags -join ',')
	)) `
        -Activity "Running $( $script:Playbook ) for $( $Distribution.Limit ) in $( $Distribution.Name )"

	if ($Terminate)
	{
		Invoke-Wsl -Arguments @('--terminate', $Distribution.Name) -Activity "Terminating $( $Distribution.Name )"
	}
}

$provisioningTags = @($Tags | Where-Object { $_ -ne 'cleanup' })
if ($Cleanup -or ($Tags -contains 'cleanup'))
{
	$provisioningTags += 'cleanup'
}

$distribution = [pscustomobject]@{
	Image    = 'openSUSE-Tumbleweed'
	Name     = 'openSUSE-Tumbleweed'
	Limit    = 'tumbleweed'
	Packages = @('ansible-core')
	Tags     = $provisioningTags
}

$resolvedPath = (Resolve-Path -LiteralPath $RepositoryPath).ProviderPath

Assert-Prerequisite -Distribution @($distribution) -Path $resolvedPath -Update:$Update

if (-not $Update)
{
	Install-Distribution -Distribution $distribution

	Write-Stage "Setting $( $distribution.Name ) as the default distribution"
	Invoke-Wsl -Arguments @('--set-default', $distribution.Name) -Activity "Setting $( $distribution.Name ) as the default distribution"
}

Initialize-Distribution -Distribution $distribution
Invoke-Provisioning -Distribution $distribution -Path $resolvedPath -Terminate:(-not $Update)

Write-Stage 'Bootstrap complete'
Write-Host "Distribution: wsl --distribution $( $distribution.Name )  (default)"
if ($Update)
{
	Write-Host "Restart it with 'wsl --terminate $( $distribution.Name )' to apply changes to /etc/wsl.conf."
}
