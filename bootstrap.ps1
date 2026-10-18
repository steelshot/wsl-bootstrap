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

    With -Teardown the distribution is unregistered and the files the bootstrap created on the Windows host are
    removed: the exported SSH keys and Host entries, the matching known_hosts entries, the synchronized kubeconfig,
    and the Podman connection. It works whether or not the distribution is still registered.

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

.PARAMETER Teardown
    Unregisters the distribution, which deletes its filesystem permanently, and removes the files it created on the
    Windows host. Cannot be combined with -Update, -Cleanup or -Tags.

.PARAMETER DryRun
    With -Teardown, lists what would be removed without removing anything.

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

.EXAMPLE
    .\bootstrap.ps1 -Teardown -DryRun

    Lists what a teardown would remove without removing anything.
#>

[CmdletBinding()]
param(
	[ValidateNotNullOrEmpty()]
	[string] $RepositoryPath = $PSScriptRoot,

	[ValidateNotNullOrEmpty()]
	[string[]] $Tags = @('core', 'user', 'ssh', 'nvidia-stack', 'podman', 'rke2', 'git', 'dotfiles', 'kubernetes'),

	[switch] $Update,

	[switch] $Cleanup,

	[switch] $Teardown,

	[switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Forces wsl.exe to emit UTF-8 instead of UTF-16LE, so its output can be parsed without stripping null bytes.
$env:WSL_UTF8 = '1'

if ($Teardown -and ($Update -or $Cleanup -or $PSBoundParameters.ContainsKey('Tags')))
{
	throw '-Teardown cannot be combined with -Update, -Cleanup or -Tags.'
}

if ($DryRun -and -not $Teardown)
{
	throw '-DryRun is only supported together with -Teardown.'
}

$script:DryRun = $DryRun

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

function Test-Execute
{
	param(
		[Parameter(Mandatory)][string] $Action,
		[Parameter(Mandatory)][string] $Target
	)

	if ($script:DryRun)
	{
		Write-Host "Would ${Action}: $Target" -ForegroundColor Yellow
		return $false
	}

	return $true
}

function Invoke-Teardown
{
	[CmdletBinding()]
	param([Parameter(Mandatory)][object] $Distribution)

	if (-not (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue))
	{
		throw 'wsl.exe was not found. Install the Windows Subsystem for Linux before running this bootstrap.'
	}

	Write-Stage "Removing $( $Distribution.Name )"

	if ((Get-RegisteredDistribution) -contains $Distribution.Name)
	{
		if (Test-Execute -Action 'Unregister the WSL distribution and delete its filesystem' -Target $Distribution.Name)
		{
			Invoke-Wsl -Arguments @('--unregister', $Distribution.Name) -Activity "Unregistering $( $Distribution.Name )"
		}
	}
	else
	{
		Write-Host "$( $Distribution.Name ) is not registered."
	}

	Write-Stage 'Removing the files the bootstrap created on the Windows host'

	$sshDirectory = Join-Path -Path $env:USERPROFILE -ChildPath '.ssh'
	$exportDirectory = Join-Path -Path $sshDirectory -ChildPath 'wsl'
	$hostEntries = @()
	$exportedFiles = @()

	# The Host entries record the port and identity that the distribution's SSH export used, so they identify which
	# known_hosts entries and key files belong to the bootstrap without asking the distribution.
	$distributionConnection = $Distribution.Name.ToLowerInvariant()
	foreach ($configuration in @(Get-ChildItem -LiteralPath $exportDirectory -Filter "$distributionConnection.conf" -File -ErrorAction SilentlyContinue))
	{
		$hostName = 'localhost'
		$port = 22
		$identity = $null

		foreach ($line in (Get-Content -LiteralPath $configuration.FullName))
		{
			if ($line -match '^\s*HostName\s+(\S+)')
			{
				$hostName = $Matches[1]
			}
			elseif ($line -match '^\s*Port\s+(\d+)')
			{
				$port = [int] $Matches[1]
			}
			elseif ($line -match '^\s*IdentityFile\s+(\S+)')
			{
				$identity = Split-Path -Path $Matches[1] -Leaf
			}
		}

		$hostEntries += [pscustomobject]@{
			Host      = $hostName
			Port      = $port
			KnownHost = $(if ($port -eq 22) { $hostName } else { "[$hostName]:$port" })
		}

		$exportedFiles += $configuration.FullName
		if ($identity)
		{
			$exportedFiles += (Join-Path -Path $exportDirectory -ChildPath $identity)
			$exportedFiles += (Join-Path -Path $exportDirectory -ChildPath "$identity.pub")
		}
	}

	foreach ($file in $exportedFiles)
	{
		if ((Test-Path -LiteralPath $file -PathType Leaf) -and (Test-Execute -Action 'Remove the exported SSH file' -Target $file))
		{
			Remove-Item -LiteralPath $file -Force
		}
	}

	# Files that are about to be removed do not count, so that a dry run reports the steps that depend on them.
	$exportedNames = @($exportedFiles | ForEach-Object { Split-Path -Path $_ -Leaf })
	$remaining = @(Get-ChildItem -LiteralPath $exportDirectory -Force -ErrorAction SilentlyContinue |
			Where-Object { $exportedNames -notcontains $_.Name })
	if ((Test-Path -LiteralPath $exportDirectory -PathType Container) -and $remaining.Count -eq 0 -and
			(Test-Execute -Action 'Remove the empty export directory' -Target $exportDirectory))
	{
		Remove-Item -LiteralPath $exportDirectory -Force
	}

	$sshConfiguration = Join-Path -Path $sshDirectory -ChildPath 'config'
	$includePattern = '(?m)^[ \t]*Include[ \t]+wsl/\*\.conf[ \t]*\r?\n?'
	$remainingConfigurations = @(Get-ChildItem -LiteralPath $exportDirectory -Filter '*.conf' -File -ErrorAction SilentlyContinue |
			Where-Object { $exportedNames -notcontains $_.Name })
	if ((Test-Path -LiteralPath $sshConfiguration -PathType Leaf) -and $remainingConfigurations.Count -eq 0)
	{
		$content = [IO.File]::ReadAllText($sshConfiguration)
		if ($content -match $includePattern -and
				(Test-Execute -Action 'Remove the Include wsl/*.conf line' -Target $sshConfiguration))
		{
			[IO.File]::WriteAllText($sshConfiguration, ($content -replace $includePattern, ''), (New-Object Text.UTF8Encoding($false)))
		}
	}

	$knownHosts = Join-Path -Path $sshDirectory -ChildPath 'known_hosts'
	if (Test-Path -LiteralPath $knownHosts -PathType Leaf)
	{
		foreach ($entry in ($hostEntries | Select-Object -ExpandProperty KnownHost -Unique))
		{
			$present = Select-String -LiteralPath $knownHosts -Pattern ('^' + [regex]::Escape($entry) + ' ') -Quiet
			if ($present -and (Test-Execute -Action "Remove the $entry host keys" -Target $knownHosts))
			{
				if (-not (Get-Command -Name ssh-keygen.exe -ErrorAction SilentlyContinue))
				{
					Write-Warning "ssh-keygen.exe was not found, so the $entry host keys were left in $knownHosts."
					continue
				}

				$preference = $ErrorActionPreference
				$ErrorActionPreference = 'Continue'
				try
				{
					& ssh-keygen.exe -R $entry -f $knownHosts *> $null
				}
				finally
				{
					$ErrorActionPreference = $preference
				}
			}
		}
	}

	if (Get-Command -Name podman.exe -ErrorAction SilentlyContinue)
	{
		$preference = $ErrorActionPreference
		$ErrorActionPreference = 'Continue'
		try
		{
			$listing = (& podman.exe system connection list --format json 2>$null) -join "`n"
			$connections = if ($listing) { ConvertFrom-Json -InputObject $listing } else { @() }
			$stale = @(foreach ($connection in @($connections))
				{
					$uri = $connection.URI
					if ($connection.Name -eq $distributionConnection -or
							@($hostEntries | Where-Object { $uri -match ('^ssh://[^@]+@' + [regex]::Escape($_.Host) + ':' + $_.Port + '/') }).Count -gt 0)
					{
						$connection.Name
					}
				})

			foreach ($name in $stale)
			{
				if (Test-Execute -Action 'Remove the Podman connection' -Target $name)
				{
					& podman.exe system connection remove $name *> $null
				}
			}
		}
		finally
		{
			$ErrorActionPreference = $preference
		}
	}

	$kubeDirectory = Join-Path -Path $env:USERPROFILE -ChildPath '.kube'
	$kubeconfig = Join-Path -Path $kubeDirectory -ChildPath 'config'
	if (Test-Path -LiteralPath $kubeconfig -PathType Leaf)
	{
		# The synchronization overwrites this file with the RKE2 kubeconfig, whose API server is the loopback address.
		if ((Get-Content -LiteralPath $kubeconfig -Raw) -notmatch 'https://127\.0\.0\.1:6443')
		{
			Write-Warning "$kubeconfig does not point at the RKE2 API server, so it was left in place."
		}
		else
		{
			if (Test-Execute -Action 'Remove the synchronized kubeconfig' -Target $kubeconfig)
			{
				Remove-Item -LiteralPath $kubeconfig -Force
			}

			$kubeRemaining = @(Get-ChildItem -LiteralPath $kubeDirectory -Force | Where-Object { $_.Name -notin 'config', 'cache' })
			if ($kubeRemaining.Count -eq 0 -and (Test-Execute -Action 'Remove the .kube directory' -Target $kubeDirectory))
			{
				Remove-Item -LiteralPath $kubeDirectory -Recurse -Force
			}
		}
	}

	Write-Stage 'Teardown complete'
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

if ($Teardown)
{
	Invoke-Teardown -Distribution $distribution
	return
}

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
