#Requires -Version 5.1

<#
.SYNOPSIS
    Installs and provisions the managed openSUSE WSL distributions.

.DESCRIPTION
    Registers both managed distributions without launching them, which keeps the distribution OOBE from running, and
    then provisions each one by running site.yml as root, limited to that distribution's inventory group. The
    workstation is installed first and set as the default distribution, while provisioning runs against the
    orchestrator first so the control plane is available before the workstation tooling is configured.

    The script refuses to continue when either distribution name is already registered. Nothing is installed, removed,
    or reconfigured in that case, so an existing environment is never silently replaced.

.PARAMETER RepositoryPath
    Path to this repository. The directory is mounted into each distribution through DrvFs and used as the working
    directory for Ansible. Defaults to the directory containing this script.

.PARAMETER OrchestratorTags
    Ansible tags applied to the orchestrator play. Every role except common/core and common/user is gated behind a
    never tag, so a role only runs when its tag is listed here.

.PARAMETER WorkstationTags
    Ansible tags applied to the workstation play. The dotfiles role additionally asserts that the git tag is present.

.EXAMPLE
    .\bootstrap.ps1

    Installs both distributions and provisions them with the full default role set.

.EXAMPLE
    .\bootstrap.ps1 -WorkstationTags core, user, ssh, git, dotfiles

    Installs both distributions but limits the workstation to the shell environment, leaving Ansible in place because
    the cleanup tag is omitted.
#>

[CmdletBinding()]
param(
	[ValidateNotNullOrEmpty()]
	[string] $RepositoryPath = $PSScriptRoot,

	[ValidateNotNullOrEmpty()]
	[string[]] $OrchestratorTags = @('core', 'user', 'ssh', 'nvidia-stack', 'podman', 'rke2', 'cleanup'),

	[ValidateNotNullOrEmpty()]
	[string[]] $WorkstationTags = @('core', 'user', 'ssh', 'git', 'dotfiles', 'kubernetes', 'cleanup')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Forces wsl.exe to emit UTF-8 instead of UTF-16LE, so its output can be parsed without stripping null bytes.
$env:WSL_UTF8 = '1'

# The Ansible entry point and the files it cannot run without, checked before anything is installed so a partial
# checkout fails fast rather than halfway through provisioning.
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
		[Parameter(Mandatory)][string] $Path
	)

	Write-Stage 'Checking prerequisites'

	if (-not (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue))
	{
		throw 'wsl.exe was not found. Install the Windows Subsystem for Linux before running this bootstrap.'
	}

	# Also proves the installed WSL release is recent enough to accept --name and --no-launch.
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
	if ($conflicting.Count -gt 0)
	{
		throw "Refusing to continue because the following WSL distributions are already registered: " +
				"$( $conflicting -join ', ' ). Remove them with 'wsl --unregister <name>' and run this bootstrap again."
	}

	Write-Host "Repository path: $Path"
	Write-Host 'No conflicting distributions are registered.'
}

function Install-Distribution
{
	param([Parameter(Mandatory)][object] $Distribution)

	Write-Stage "Installing $( $Distribution.Image ) as $( $Distribution.Name )"

	# --no-launch registers the distribution without starting it, so the image OOBE never runs and every later command
	# can be issued as root.
	Invoke-Wsl `
        -Arguments @('--install', $Distribution.Image, '--name', $Distribution.Name, '--no-launch') `
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
		[Parameter(Mandatory)][string] $Path
	)

	Write-Stage "Provisioning $( $Distribution.Name ) as the $( $Distribution.Limit ) group"

	# The repository is reached through a DrvFs mount, which is world writable, and Ansible ignores an ansible.cfg it
	# discovers in a world writable working directory. ANSIBLE_CONFIG is not subject to that check, and the path is
	# relative because --cd has already placed the shell in the repository root.
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

	# The playbook rewrites /etc/wsl.conf and /etc/wsl-distribution.conf, and both are only re-read on a cold start.
	Invoke-Wsl -Arguments @('--terminate', $Distribution.Name) -Activity "Terminating $( $Distribution.Name )"
}

# Ansible skips become when it is already running as the target user, so sudo is not required for the play level
# `become: true`. The become_user transition in workstation/dotfiles does need it, and common/core installs it long
# before that role runs.
$workstation = [pscustomobject]@{
	Image    = 'openSUSE-Tumbleweed'
	Name     = 'openSUSE-Tumbleweed'
	Limit    = 'workstation'
	Packages = @('ansible-core')
	Tags     = $WorkstationTags
}

$orchestrator = [pscustomobject]@{
	Image    = 'openSUSE-Leap-16.0'
	Name     = 'openSUSE-Leap'
	Limit    = 'orchestrator'
	Packages = @('ansible-core', 'libexpat1')
	Tags     = $OrchestratorTags
}

# The workstation is installed first so it becomes the default distribution, while the orchestrator is provisioned
# first so its control plane exists before the workstation is configured against it.
$installOrder = @($workstation, $orchestrator)
$provisionOrder = @($orchestrator, $workstation)

$resolvedPath = (Resolve-Path -LiteralPath $RepositoryPath).ProviderPath

Assert-Prerequisite -Distribution $installOrder -Path $resolvedPath

foreach ($distribution in $installOrder)
{
	Install-Distribution -Distribution $distribution
}

Write-Stage "Setting $( $workstation.Name ) as the default distribution"
Invoke-Wsl -Arguments @('--set-default', $workstation.Name) -Activity "Setting $( $workstation.Name ) as the default distribution"

foreach ($distribution in $provisionOrder)
{
	Initialize-Distribution -Distribution $distribution
	Invoke-Provisioning -Distribution $distribution -Path $resolvedPath
}

Write-Stage 'Bootstrap complete'
Write-Host "Orchestrator: wsl --distribution $( $orchestrator.Name )"
Write-Host "Workstation:  wsl --distribution $( $workstation.Name )  (default)"
