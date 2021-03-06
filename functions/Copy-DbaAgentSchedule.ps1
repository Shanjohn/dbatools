function Copy-DbaAgentSchedule {
    <#
    .SYNOPSIS
        Copy-DbaAgentSchedule migrates shared job schedules from one SQL Server to another.

    .DESCRIPTION
        All shared job schedules are copied.

        If the associated credential for the account does not exist on the destination, it will be skipped. If the shared job schedule already exists on the destination, it will be skipped unless -Force is used.

    .PARAMETER Source
        Source SQL Server. You must have sysadmin access and server version must be SQL Server version 2000 or higher.

    .PARAMETER SourceSqlCredential
        Login to the target instance using alternative credentials. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

    .PARAMETER Destination
        Destination SQL Server. You must have sysadmin access and the server must be SQL Server 2000 or higher.

    .PARAMETER DestinationSqlCredential
        Login to the target instance using alternative credentials. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

    .PARAMETER WhatIf
        If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.

    .PARAMETER Confirm
        If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.

    .PARAMETER Force
        If this switch is enabled, the Operator will be dropped and recreated on Destination.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Migration, Agent
        Author: Chrissy LeMaire (@cl), netnerds.net

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

        Requires: sysadmin access on SQL Servers

    .LINK
        https://dbatools.io/Copy-DbaAgentSchedule

    .EXAMPLE
        PS C:\> Copy-DbaAgentSchedule -Source sqlserver2014a -Destination sqlcluster

        Copies all shared job schedules from sqlserver2014a to sqlcluster using Windows credentials. If shared job schedules with the same name exist on sqlcluster, they will be skipped.

    .EXAMPLE
        PS C:\> Copy-DbaAgentSchedule -Source sqlserver2014a -Destination sqlcluster -WhatIf -Force

        Shows what would happen if the command were executed using force.

    #>
    [CmdletBinding(DefaultParameterSetName = "Default", SupportsShouldProcess)]
    param (
        [parameter(Mandatory)]
        [DbaInstanceParameter]$Source,
        [PSCredential]
        $SourceSqlCredential,
        [parameter(Mandatory)]
        [DbaInstanceParameter[]]$Destination,
        [PSCredential]
        $DestinationSqlCredential,
        [switch]$Force,
        [Alias('Silent')]
        [switch]$EnableException
    )
    begin {
        Test-DbaDeprecation -DeprecatedOn "1.0.0" -Alias Copy-DbaAgentSharedSchedule
        try {
            $sourceServer = Connect-SqlInstance -SqlInstance $Source -SqlCredential $SourceSqlCredential -MinimumVersion 9
        } catch {
            Stop-Function -Message "Error occured while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $Source
            return
        }
        $serverSchedules = $sourceServer.JobServer.SharedSchedules
    }
    process {
        if (Test-FunctionInterrupt) { return }
        foreach ($destinstance in $Destination) {
            try {
                $destServer = Connect-SqlInstance -SqlInstance $destinstance -SqlCredential $DestinationSqlCredential -MinimumVersion 9
            } catch {
                Stop-Function -Message "Error occured while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $destinstance -Continue
            }

            $destSchedules = $destServer.JobServer.SharedSchedules
            foreach ($schedule in $serverSchedules) {
                $scheduleName = $schedule.Name
                $copySharedScheduleStatus = [pscustomobject]@{
                    SourceServer      = $sourceServer.Name
                    DestinationServer = $destServer.Name
                    Type              = "Agent Schedule"
                    Name              = $scheduleName
                    Status            = $null
                    Notes             = $null
                    DateTime          = [Sqlcollaborative.Dbatools.Utility.DbaDateTime](Get-Date)
                }

                if ($schedules.Length -gt 0 -and $schedules -notcontains $scheduleName) {
                    continue
                }

                if ($destSchedules.Name -contains $scheduleName) {
                    if ($force -eq $false) {
                        if ($Pscmdlet.ShouldProcess($destinstance, "Shared job schedule $scheduleName exists at destination. Use -Force to drop and migrate.")) {
                            $copySharedScheduleStatus.Status = "Skipped"
                            $copySharedScheduleStatus.Notes = "Already exists on destination"
                            $copySharedScheduleStatus | Select-DefaultView -Property DateTime, SourceServer, DestinationServer, Name, Type, Status, Notes -TypeName MigrationObject
                            Write-Message -Level Verbose -Message "Shared job schedule $scheduleName exists at destination. Use -Force to drop and migrate."
                            continue
                        }
                    } else {
                        if ($Pscmdlet.ShouldProcess($destinstance, "Schedule [$scheduleName] has associated jobs. Skipping.")) {
                            if ($destServer.JobServer.Jobs.JobSchedules.Name -contains $scheduleName) {
                                $copySharedScheduleStatus.Status = "Skipped"
                                $copySharedScheduleStatus | Select-DefaultView -Property DateTime, SourceServer, DestinationServer, Name, Type, Status, Notes -TypeName MigrationObject
                                Write-Message -Level Verbose -Message "Schedule [$scheduleName] has associated jobs. Skipping."
                            }
                            continue
                        } else {
                            if ($Pscmdlet.ShouldProcess($destinstance, "Dropping schedule $scheduleName and recreating")) {
                                try {
                                    Write-Message -Level Verbose -Message "Dropping schedule $scheduleName"
                                    $destServer.JobServer.SharedSchedules[$scheduleName].Drop()
                                } catch {
                                    $copySharedScheduleStatus.Status = "Failed"
                                    $copySharedScheduleStatus | Select-DefaultView -Property DateTime, SourceServer, DestinationServer, Name, Type, Status, Notes -TypeName MigrationObject
                                    Stop-Function -Message "Issue dropping schedule" -Target $scheduleName -ErrorRecord $_ -Continue
                                }
                            }
                        }
                    }
                }

                if ($Pscmdlet.ShouldProcess($destinstance, "Creating schedule $scheduleName")) {
                    try {
                        Write-Message -Level Verbose -Message "Copying schedule $scheduleName"
                        $sql = $schedule.Script() | Out-String

                        Write-Message -Level Debug -Message $sql
                        $destServer.Query($sql)

                        $copySharedScheduleStatus.Status = "Successful"
                        $copySharedScheduleStatus | Select-DefaultView -Property DateTime, SourceServer, DestinationServer, Name, Type, Status, Notes -TypeName MigrationObject
                    } catch {
                        $copySharedScheduleStatus.Status = "Failed"
                        $copySharedScheduleStatus | Select-DefaultView -Property DateTime, SourceServer, DestinationServer, Name, Type, Status, Notes -TypeName MigrationObject
                        Stop-Function -Message "Issue creating schedule" -Target $scheduleName -ErrorRecord $_ -Continue
                    }
                }
            }
        }
    }
    end {
        Test-DbaDeprecation -DeprecatedOn "1.0.0" -EnableException:$false -Alias Copy-SqlSharedSchedule
    }
}