﻿$AuthToken = [string]::Empty
$SigninTime = $null
$LastSessionCheck = $null
$RestEndpointURI = 'https://api.dynect.net/REST'

$DynECTPersist = $False
$DynECTCustomerName = [string]::Empty
$DynECTUserName = [string]::Empty
$DynECTPassword = $null

## Configurable Options
$DynECTSessionCheckInterval = 60

$DynECTRateLimitPerSecond = 5
$DynECTRateLimitPerMinute = 300

$DynECTRatePerSecond = 0
$DynECTRatePerMinute = 0

$DynECTSecondLimitStart = (Get-Date)
$DynECTMinuteLimitStart = (Get-Date)

$DynECTResourceRecordData = @()
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'A'
    ResourceUri = 'ARecord'
    TypeName = 'ARecordInfo'
    RDataProps = @('Address')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'AAAA'
    ResourceUri = 'AAAARecord'
    TypeName = 'AAAARecordInfo'
    RDataProps = @('Address')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'ALIAS'
    ResourceUri = 'ALIASRecord'
    TypeName = 'ALIASRecordInfo'
    RDataProps = @('ALIAS')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'CNAME'
    ResourceUri = 'CNAMERecord'
    TypeName = 'CNAMERecordInfo'
    RDataProps = @('CNAME')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'NS'
    ResourceUri = 'NSRecord'
    TypeName = 'NSRecordInfo'
    RDataProps = @('NsDName')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'MX'
    ResourceUri = 'MXRecord'
    TypeName = 'MXRecordInfo'
    RDataProps = @('Exchange', 'Preference')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'PTR'
    ResourceUri = 'PTRRecord'
    TypeName = 'PTRRecordInfo'
    RDataProps = @('PtrDName')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'TXT'
    ResourceUri = 'TXTRecord'
    TypeName = 'TXTRecordInfo'
    RDataProps = @('TXTData')
}
$DynECTResourceRecordData += New-Object PSObject -Property @{
    RecordType = 'SRV'
    ResourceUri = 'SRVRecord'
    TypeName = 'SRVRecordInfo'
    RDataProps = @('Port', 'Priority', 'Target', 'Weight')
}

$DynECTRRTypeMap = ($DynECTResourceRecordData | Group-Object RecordType -AsHashTable)
$DynECTRRUriMap = ($DynECTResourceRecordData | Group-Object ResourceUri -AsHashTable)

<# Known Types of the Module

 Kittyfox.DynECT.ZoneInfo
 Kittyfox.DynECT.ZoneChangeInfo
 Kittyfox.DynECT.ZonePublishInfo

 Kittyfox.DynECT.NodeInfo

 Kittyfox.DynECT.ARecordInfo
 Kittyfox.DynECT.CNAMERecordInfo
#>

<# Type-Setting Snippet

    foreach ($Item in $DataSet) {
        $Item.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.Class') 
    }

   New Commandlet Snippet

Function FunctionName {
    [CmdletBinding()]
    Param(
    )

    Begin {
        throw [System.NotImplementedException]::New('This commandlet is not yet implemented.')
    }

    Process {
    }

    End {
    }
}

#>

# Learn something new every day...
#    https://docs.microsoft.com/en-us/dotnet/api/system.management.automation.psmoduleinfo.onremove?view=powershellsdk-1.1.0
#
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {

    # We really need to disconnect prior to losing our token. Check, and disconnect if necessary. 
    If (Test-DynECTSession) {
        Write-Verbose 'Connected session detected. Disconnecting on unload.'

        Disconnect-DynECTSession
    }

 }

#region DynECT Session Commandlets
Function Connect-DynECTSession {
    [CmdletBinding()]
    Param(
        [string]
        $CustomerName,

        [string]
        $UserName,

        [ValidateNotNull()]
        [SecureString]
        $Password,

        [switch]
        $Persist
    )

    $Credential = New-Object PSCredential -ArgumentList $UserName,$Password
    
    $SessionProperties = @{
        customer_name = $CustomerName
        user_name = $UserName
        password = $Credential.GetNetworkCredential().Password
    }
    $SessionData = New-Object PSObject -Property $SessionProperties

    $Response = Helper-InvokeRestMethod -Method 'Post' -Uri '/Session' -Body $SessionData

    if ($Response.status -eq 'success') {
        $Script:AuthToken = $Response.data.token
        $Script:SigninTime = (Get-Date)
        $Script:LastSessionCheck = (Get-Date)

        if ($Persist) {
            $Script:DynECTPersist = $True
            $Script:DynECTCustomerName = $CustomerName
            $Script:DynECTUserName = $UserName
            $Script:DynECTPassword = $Password
        }

        # Output the message from the remote side, verbose form.
        $Response.msgs | foreach { Write-Verbose $_.INFO }

        Write-Verbose "Successful Login, Token: $AuthToken"
    } else {
        $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

        Write-Error $Message

        # If we failed our connect AND we were persisting (whatever reason, blocked, user deleted, etc), wipe our persisted data
        if ($Script:DynECTPersist) {
            $Script:DynECTPersist = $False
            $Script:DynECTCustomerName = [string]::Empty
            $Script:DynECTUserName = [string]::Empty
            $Script:DynECTPassword = $null
        }
    }
}

Function Test-DynECTSession {
    [CmdletBinding()]
    Param(
        [switch]
        $Reconnect
    )

    $AuthToken = $Script:AuthToken
    $LastSessionCheck = $Script:LastSessionCheck
    $CheckInterval = $Script:DynECTSessionCheckInterval
    $IsConnected = $False

    if (-not [string]::IsNullOrEmpty($AuthToken)) {
        Write-Verbose "Test Session, Token: $AuthToken"

        # Buffer our calls to check. We don't need to assert it more than once a minute, maybe longer.
        # Especially since many methods will make an assertion check using this commandlet.
        if ((New-Timespan -Start $LastSessionCheck -End (Get-Date)).TotalSeconds -le $CheckInterval) {
            $IsConnected = $True
            Write-Verbose "Skipped check, within the session check interval of $($CheckInterval)s since last test."
        } else {
            $Response = Helper-InvokeRestMethod -Method 'Get' -Uri '/Session'

            if ($Response.status -eq 'success') {
                $Script:LastSessionCheck = (Get-Date)
                $IsConnected = $True
                Write-Verbose "Successfully Tested Session."
            } else {
                # Our auth-token is expired. Remove it.
                $Script:AuthToken = [string]::Empty
            }
        }
    } else {
        Write-Verbose "No Session Currently Detected."
    }

    if (-not $IsConnected -and $Reconnect -and $Script:DynECTPersist) {
        try {
            $ConnectParams = @{
                CustomerName = $Script:DynECTCustomerName
                UserName = $Script:DynECTUserName
                Password = $Script:DynECTPassword
            }
            Connect-DynECTSession @ConnectParams -ErrorAction Stop
            $IsConnected = $True
        } catch {
            Write-Error "Reconnect requested, attempt failed: $($_.Exception.Message)"

            # What if we have persisted credentials and don't want to reconnect. Clear them or leave them?
        }
    }

    Write-Output $IsConnected
}

Function Disconnect-DynECTSession {
    [CmdletBinding()]
    Param(
    )

    $Persistent = $Script:DynECTPersist

    if (Test-DynECTSession) {
        Write-Verbose "Invoking Disconnect Call."

        $Response = Helper-InvokeRestMethod -Method 'Delete' -Uri '/Session'

        if ($Response.status -eq 'success') {
            $Script:AuthToken = [string]::Empty
            $Script:SigninTime = $null

            Write-Verbose "Succesfully Disconnected from DynECT and emptied state variables."
        } else {
            $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

            Write-Error $Message
        }
    }

    # We did this after a successful disconnect. I think it bears doing outside, as we can use Disconnect- as a way to clear
    # persisted credentials, in case we timed out. Otherwise, perhaps unknowingly, a Test- using -Reconnect might reconnect our
    # session long after we wanted it to be.
    if ($Persistent) {
        $Script:DynECTPersist = $False
        $Script:DynECTCustomerName = [string]::Empty
        $Script:DynECTUserName = [string]::Empty
        $Script:DynECTPassword = $null
    }
}
#endregion DynECT Session Commandlets

#region DynECT Zone Commandlets
Function New-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AdminContact,

        [Parameter(Mandatory=$True, Position=2)]
        [ValidateScript({ [int]::TryParse($_, [ref] $null) })]
        [string]
        $TimeToLive,

        [Parameter(Mandatory=$False)]
        [ValidateSet('Increment', 'Epoch', 'Day', 'Minute')]
        [string]
        $SerialStyle = 'Increment'
    )

    # https://help.dyn.com/create-primary-zone-api/

    throw [System.NotImplementedException]::new("This commandlet is not yet implemented.")
}

Function Get-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$False, ValueFromPipeline=$True)]
        [string[]]
        $Zone
    )

    Begin {
        $UriBase = '/Zone'
        $IsConnected = Test-DynECTSession -Reconnect
        $IsZoneSpecified = $PSBoundParameters.ContainsKey('Zone')

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
            if ($PSBoundParameters.ContainsKey('Zone')) {
                $Uri = "$UriBase/$Zone"
            }

            $Response = Helper-InvokeRestMethod -Method GET -Uri $Uri

            if ($Response.status -eq 'success') {
                if ($IsZoneSpecified) {
                    $ZoneInfo = [ordered] @{
                        Name = $Response.data.zone
                        Type = $Response.data.zone_type
                        SerialStyle = $Response.data.serial_style
                        SerialNumber = $Response.data.serial
                    }
                    $ZoneData = New-Object -Type PSObject -Property $ZoneInfo
                    $ZoneData.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.ZoneInfo')

                    Write-Output $ZoneData
                } else {
                    foreach ($Entry in $Response.data) {
                        $EntryItem = ($Entry.Split('/') | where { -not [string]::IsNullOrEmpty($_) })[-1]
                        Get-DynECTZone -Zone $EntryItem
                    }
                }
            } else {
                $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                Write-Error $Message
            }
    }

    End {
    }
}

Function Lock-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1, 
                   ValueFromPipeline=$True, ValueFromPipelineByPropertyName=$True)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Zone
    )

    Begin {
        # https://help.dyn.com/update-zone-api/
        # - Freeze option

        Helper-UpdateDynECTZone -Zone $Zone -Freeze
    }

    Process {
    }

    End {
    }
}

Function Unlock-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1, 
                   ValueFromPipeline=$True, ValueFromPipelineByPropertyName=$True)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Zone
    )

    Begin {
        # https://help.dyn.com/update-zone-api/
        # - Freeze option

        Helper-UpdateDynECTZone -Zone $Zone -Thaw
    }

    Process {
    }

    End {
    }
}

Function Publish-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Zone,

        [Parameter(Mandatory=$False)]
        [string]
        $Notes
    )

    # https://help.dyn.com/update-zone-api/
    # - Publish option

    Helper-UpdateDynECTZone -Zone $Zone -Publish -Notes $Notes
}

Function Remove-DynECTZone {
    [CmdletBinding()]
    Param(
    )

    throw [System.NotImplementedException]::new("This commandlet is not yet implemented.")
}

Function Get-DynECTZoneChanges {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
        [string[]]
        $Zone
    )

    Begin {
        $UriBase = '/ZoneChanges'
        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
        foreach ($Item in $Zone) {
            $Uri = "$UriBase/$Item"

            $Response = Helper-InvokeRestMethod -Method GET -Uri $Uri

            if ($Response.status -eq 'success') {
                # Output the message from the remote side, verbose form.
                $Response.msgs | foreach { Write-Verbose $_.INFO }

                foreach ($Change in $Response.data) {
                    
                    $ZoneChanges = [ordered] @{
                        ID = $Change.id
                        User = $Change.user_id
                        Zone = $Change.zone
                        FQDN = $Change.fqdn
                        SerialNumber = $Change.serial
                        TTL = $Change.ttl
                        RecordType = $Change.rdata_type
                    }

                    # Type appears to be the standard DNS Type abbreviation
                    switch ($Change.rdata_type) {
                        { $_ -in @('A', 'AAAA') } {
                            $ZoneChanges.Add("Value", $Change.rdata."rdata_$($Change.rdata_type)".address)
                        }
                        "CNAME" {
                            $ZoneChanges.Add("Value", $Change.rdata.rdata_cname.cname)
                        }
                        { $_ -in @("TXT", "SPF") } {
                            $ZoneChanges.Add("Value", $Change.rdata."rdata_$($Change.rdata_type)".txtdata)
                        }
                        default {
                            Write-Error "Change type '$($Change.rdata_type)' handler not yet implemented."
                        }
                    }
                    $ZoneChangeData = New-Object -TypeName PSObject -Property $ZoneChanges
                    $ZoneChangeData.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.ZoneChangeInfo')

                    Write-Output $ZoneChangeData
                }
            } else {
                $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                Write-Error $Message
            }
        }
    }

    End {
    }
}

Function Clear-DynECTZoneChanges {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
        [string[]]
        $Zone
    )

    Begin {
        $UriBase = '/ZoneChanges'
        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
        foreach ($Item in $Zone) {
            $Uri = "$UriBase/$Item"

            $Response = Helper-InvokeRestMethod -Method DELETE -Uri $Uri

            if ($Response.status -eq 'success') {

                # Output the message from the remote side, verbose form.
                $Response.msgs | foreach { Write-Verbose $_.INFO }
            } else {
                $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                Write-Error $Message
            }  
        }
    }

    End {
    }
}
#endregion DynECT Session Commandlets

#region DynECT Record Commandlets
Function Get-DynECTNode {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=0)]
        [ValidateNotNull()]
        [string]
        $Zone,

        [Parameter(Mandatory=$False, Position=1, ValueFromPipeline=$True)]
        [ValidateNotNull()]
        [string[]]
        $FQDN
    )

    Begin {
        $UriBase = "/NodeList/$Zone"
        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }

        $Queue = New-Object -Type System.Collections.Queue
    }

    Process {
        if ($PSBoundParameters.ContainsKey('FQDN')) {
            foreach ($Name in $FQDN) {
                $Queue.Enqueue("$UriBase/$Name")
            }
        } else {
            $Queue.Enqueue($UriBase)
        }

        while ($Queue.Count -gt 0) {
            $Uri = $Queue.Dequeue()

            $Response = Helper-InvokeRestMethod -Method GET -Uri $Uri

            if ($Response.status -eq 'success') {
                # Output the message from the remote side, verbose form.
                $Response.msgs | foreach { Write-Verbose $_.INFO }

                foreach ($Node in $Response.data) {
                    $NodeInfo = [ordered] @{
                        Zone = $Zone
                        FQDN = $Node
                    }
                    $NodeData = New-Object -Type PSObject -Property $NodeInfo
                    $NodeData.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.NodeInfo')
                    Write-Output $NodeData
                }
            } else {
                $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                Write-Error $Message
            }
        }
    }

    End {
    }
}

Function Remove-DynECTNode {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=0)]
        [ValidateNotNull()]
        [string]
        $Zone,

        [Parameter(Mandatory=$False, Position=1, ValueFromPipeline=$True)]
        [ValidateNotNull()]
        [string[]]
        $FQDN,

        [Parameter(Mandatory=$False)]
        [switch]
        $Recurse
    )

    Begin {
        throw [System.NotImplementedException]::New('This commandlet is not yet implemented.')

        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
    }

    End {
    }
}

Function Add-DynECTResourceRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]
        $Zone,

        [Parameter(Mandatory=$true, Position=1, ParameterSetName='A')]
        [Parameter(Mandatory=$true, Position=1, ParameterSetName='AAAA')]
        [Parameter(Mandatory=$true, Position=1, ParameterSetName='CNAME')]
        [Parameter(Mandatory=$true, Position=1, ParameterSetName='TXT')]
        [Alias('FQDN')]
        [string]
        $Name,

        [Parameter(Mandatory=$false)]
        [ValidateScript({[int]::TryParse($_, [ref] $null)})]
        [string]
        $TTL = 0,

        [Parameter(ParameterSetName='A', Position=2, Mandatory=$true)]
        [switch]
        $A,

        [Parameter(ParameterSetName='AAAA', Position=2, Mandatory=$true)]
        [switch]
        $AAAA,

        [Parameter(ParameterSetName='A', Mandatory=$true)]
        [Parameter(ParameterSetName='AAAA', Mandatory=$true)]
        [ValidateScript({[ipaddress]::TryParse($_, [ref] $null)})]
        [string]
        $Address,

        [Parameter(ParameterSetName='CNAME', Position=2, Mandatory=$true)]
        [switch]
        $CNAME,

        [Parameter(ParameterSetName='CNAME', Mandatory=$true)]
        [string]
        $HostNameAlias,

        [Parameter(ParameterSetName='TXT', Position=2, Mandatory=$true)]
        [switch]
        $TXT,

        [Parameter(ParameterSetName='TXT', Mandatory=$true)]
        [string]
        $TXTData

    )

    Begin {
        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }

        if ($Name.EndsWith($Zone)) {
            $FQDN = $Name
        } else {
            $FQDN = "$Name.$Zone"
        }
    }

    Process {
        $RecordType = $PSCmdlet.ParameterSetName

        $RDataSet = New-Object Hashtable -ArgumentList $PSBoundParameters

        $RecordData = Helper-FormatResourceRecordRData -RecordType $RecordType -RDataSet $RDataSet

        Helper-StoreDynECTResourceRecord -Zone $Zone -FQDN $FQDN -TTL $TTL -RecordType $RecordType -AddRecordData $RecordData
    }

    End {
    }
}

Function Get-DynECTResourceRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=0)]
        [string]
        $Zone,

        [Parameter(Mandatory=$true, Position=1)]
        [string]
        $Name,

        [Parameter(Mandatory=$false, Position=2)]
        [string]
        $RecordId,

        [Parameter(Mandatory=$false, Position=3)]
        [ValidateSet('A', 'AAAA', 'ALIAS', 'CNAME', 'NS', 'MX', 'PTR', 'SRV', 'TXT')]
        [string]
        $RecordType
    )

    Begin {
        $RRTypeMap = $Script:DynECTRRTypeMap
        $RRUriMap = $Script:DynECTRRUriMap

        # Check to see if we're connected. Fail if not.
        $IsConnected = Test-DynECTSession -Reconnect
        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }

        # Did we get a record type? 
        # If so, check to see if we're properly mapped internally (fail violently if not).
        # If not, we're checking for all records. Use ANYRecord lookup for efficiency.
        if ($PSBoundParameters.ContainsKey('RecordType')) {
            if (-not $RRTypeMap.ContainsKey($RecordType)) {
                throw [System.ArgumentException]::New('Supplied RecordType is not correctly mapped within the module.')
            }

            $ResourceUri = $RRTypeMap[$RecordType].ResourceUri
            [array] $RDataProps = $RRTypeMap[$RecordType].RDataProps
        } else {
            Write-Verbose "Beginning ANY Record Processing."
            $GetAllTypes = $true
            $ResourceUri = 'ANYRecord'
        }

        if ($Name.EndsWith($Zone)) {
            $FQDN = $Name
        } else {
            $FQDN = "$Name.$Zone"
        }
    }

    Process {
        $Uri = "/$ResourceUri/$Zone/$FQDN"
        if (-not [string]::IsNullOrEmpty($RecordId)) {
            $ByRecordId = $True
            $Uri = "$Uri/$RecordId"
        }

        $Response = Helper-InvokeRestMethod -Method GET -Uri $Uri

        if ($Response.status -eq 'success') {
            # Output the message from the remote side, verbose form.
            $Response.msgs | foreach { Write-Verbose $_.INFO }

            if ($ByRecordId) {
                $RecordInfo = [ordered] @{
                    Zone = $Response.data.zone
                    FQDN = $Response.data.fqdn
                    RecordType = $Response.data.record_type
                    RecordId = $RecordId
                    TTL = $Response.data.ttl
                }
        
                Write-Verbose "Processing $($RDataProps.Count) Record data properties"
                foreach ($Prop in $RRTypeMap[$RecordType].RDataProps) {
                    Write-Debug "Processing RecordData property $Prop"
                    $RecordInfo.Add($Prop, $Response.data.rdata."$Prop")
                }

                $RecordData = New-Object -Type PSObject -Property $RecordInfo
                $RecordData.PSObject.TypeNames.Insert(0,"Kittyfox.DynECT.$($RRTypeMap[$RecordType].TypeName)")
                Write-Output $RecordData
            } else {
                $NodeList = @()

                $FoundType = $RecordType
                foreach ($Entry in $Response.data) {
                    $EntryData = ($Entry.Split('/') | where { -not [string]::IsNullOrEmpty($_) })
                    $FoundId = $EntryData[-1]

                    if ($GetAllTypes -eq $true) {
                        if (-not $DynECTRRUriMap.ContainsKey($EntryData[1])) {
                            Write-Verbose "Unknown Uri $($EntryData[1]) in ANY Record lookup, skipping."
                            continue
                        }
                        $FoundType = $DynECTRRUriMap[$EntryData[1]].RecordType
                    }
                    Get-DynECTResourceRecord -Zone $Zone -Name $FQDN -RecordId $FoundId -RecordType $FoundType
                }
            }
        } else {
            $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

            Write-Error $Message
        }
    }

    End {
    }
}

Function Set-DynECTResourceRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]
        $Zone,

        [Parameter(Mandatory=$true, Position=1)]
        [Alias('FQDN')]
        [string]
        $Name,

        [Parameter(Mandatory=$false)]
        [ValidateScript({[int]::TryParse($_, [ref] $null)})]
        [string]
        $TTL = 0,

        [Parameter(Mandatory=$false)]
        [string]
        $RecordId,

        [Parameter(ParameterSetName='A', Position=2, Mandatory=$true)]
        [switch]
        $A,

        [Parameter(ParameterSetName='AAAA', Position=2, Mandatory=$true)]
        [switch]
        $AAAA,

        [Parameter(ParameterSetName='A', Mandatory=$true)]
        [Parameter(ParameterSetName='AAAA', Mandatory=$true)]
        [ValidateScript({[ipaddress]::TryParse($_, [ref] $null)})]
        [string]
        $Address,

        [Parameter(ParameterSetName='CNAME', Position=2, Mandatory=$true)]
        [switch]
        $CNAME,

        [Parameter(ParameterSetName='CNAME', Mandatory=$true)]
        [string]
        $HostNameAlias,

        [Parameter(ParameterSetName='TXT', Position=2, Mandatory=$true)]
        [switch]
        $TXT,

        [Parameter(ParameterSetName='TXT', Mandatory=$true)]
        [string]
        $TXTData

    )

    Begin {
        $RRTypeMap = $Script:DynECTRRTypeMap

        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }

        if ($Name.EndsWith($Zone)) {
            $FQDN = $Name
        } else {
            $FQDN = "$Name.$Zone"
        }
    }

    Process {
        $RecordType = $PSCmdlet.ParameterSetName

        $RDataSet = New-Object Hashtable -ArgumentList $PSBoundParameters
        $RecordData = Helper-FormatResourceRecordRData -RecordType $RecordType -RDataSet $RDataSet

        if ($PSBoundParameters.ContainsKey('RecordId')) {
            $SetParamData = @{RecordId = $RecordId}
        } else {
            $SetParamData = @{Replace = $True}
        }
        $SetParamData.Add('UpdateRecordData', $RecordData)

        Helper-StoreDynECTResourceRecord -Zone $Zone -FQDN $FQDN -TTL $TTL -RecordType $RecordType @SetParamData
    }

    End {
    }
}

Function Remove-DynECTResourceRecord {
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
        [Parameter(Mandatory=$True, Position=0)]
        [string]
        $Zone,

        [Parameter(Mandatory=$true, Position=1)]
        [string]
        $Name,

        [Parameter(Mandatory=$true, Position=3)]
        [ValidateSet('A', 'AAAA', 'ALIAS', 'CNAME', 'NS', 'MX', 'PTR', 'SRV', 'TXT')]
        [string]
        $RecordType,

        [Parameter(Mandatory=$false)]
        [string]
        $RecordId,

        [Parameter(Mandatory=$false)]
        [switch]
        $Force
    )

    Begin {
        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }

        $RRTypeMap = $Script:DynECTRRTypeMap

        if (-not $RRTypeMap.ContainsKey($RecordType)) {
            throw [System.ArgumentException]::New('Supplied RecordType is not correctly mapped within the module.')
        }

        $ResourceUri = $RRTypeMap[$RecordType].ResourceUri

        $RemoveMsg = 'All'
        if ($PSBoundParameters.ContainsKey($RecordId)) {
            $RemoveMsg = 'Single'
        }

        if ($Name.EndsWith($Zone)) {
            $FQDN = $Name
        } else {
            $FQDN = "$Name.$Zone"
        }
    }

    Process {
        $Uri = "/$ResourceUri/$Zone/$FQDN"
        if (-not [string]::IsNullOrEmpty($RecordId)) {
            $ByRecordId = $True
            $Uri = "$Uri/$RecordId"
        }

        if ($PSCmdlet.ShouldProcess($Url, "Remove $RemoveMsg $RecordType Resource Record from $FQDN in $Zone")) {
            if ($Force -eq $true -or $PSCmdlet.ShouldContinue("Are you sure you want to remove $RecordType record(s) from $FQDN in $($Zone)?", "Confirm Record Deletion")) {

                $Response = Helper-InvokeRestMethod -Method DELETE -Uri $Uri

                if ($Response.status -eq 'success') {
                    # Output the message from the remote side, verbose form.
                    $Response.msgs | foreach { Write-Verbose $_.INFO }
                } else {
                    $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                    Write-Error $Message
                }
            }
        }
    }

    End {
    }
}
#endregion DynECT Record Commandlets

#region DynECT Helper Commandlets
Function Helper-UpdateDynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(ParameterSetName='Freeze', Mandatory=$True, Position=0, ValueFromPipeline=$True)]
        [Parameter(ParameterSetName='Thaw', Mandatory=$True, Position=0, ValueFromPipeline=$True)]
        [Parameter(ParameterSetName='Publish', Mandatory=$True, Position=0, ValueFromPipeline=$True)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Zone,

        [Parameter(ParameterSetName='Freeze', Mandatory=$True)]
        [switch]
        $Freeze,

        [Parameter(ParameterSetName='Thaw', Mandatory=$True)]
        [switch]
        $Thaw,

        [Parameter(ParameterSetName='Publish', Mandatory=$True)]
        [switch]
        $Publish,

        [Parameter(ParameterSetName='Publish', Mandatory=$False)]
        [string]
        $Notes
    )

    Begin {
        $UriBase = "/Zone"

        $IsConnected = Test-DynECTSession -Reconnect

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
        foreach ($Item in $Zone) {
            $Uri = "$UriBase/$Item"
            $ZoneOptions = @{}

            switch ($PSCmdlet.ParameterSetName) {
                'Freeze' {
                    $ZoneOptions.Add('freeze', $True)
                }
                'Thaw' {
                    $ZoneOptions.Add('thaw', $True)
                }
                'Publish' {
                    $ZoneOptions.Add('publish', $True)

                    if (-not [string]::IsNullOrEmpty($Notes)) {
                        $ZoneOptions.Add('notes', $Notes)
                    }
                }
            }
            $ZoneData = New-Object -TypeName PSObject -Property $ZoneOptions

            $Response = Helper-InvokeRestMethod -Method PUT -Uri $Uri -Body $ZoneData

            if ($Response.status -eq 'success') {
                if ($PSCmdlet.ParameterSetName -eq 'Publish') {
                    # Output the message from the remote side, verbose form.
                    $Response.msgs | foreach { Write-Verbose $_.INFO }

                    $ZoneInfo = [ordered] @{
                        Name = $Response.data.zone
                        Type = $Response.data.zone_type
                        PublishTask = $Response.data.task_id
                        SerialStyle = $Response.data.serial_style
                        SerialNumber = $Response.data.serial
                    }
                    $ZoneData = New-Object -Type PSObject -Property $ZoneInfo
                    $ZoneData.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.ZonePublishInfo')

                    Write-Output $ZoneData
                }
            } else {
                $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

                Write-Error $Message
            }
        }
    }

    End {
    }
}

Function Helper-BuildHeaders {
    [CmdletBinding()]
    Param(
        [string]
        $AuthToken = $Script:AuthToken
    )

    $Headers = New-Object Hashtable

    if (-not [string]::IsNullOrEmpty($AuthToken)) {
        $Headers.Add('Auth-Token', $AuthToken)
    }

    Write-Output $Headers
}

Function Helper-InvokeRestMethod {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [ValidateSet('POST', 'PUT', 'GET', 'DELETE')]
        [string]
        $Method,

        [Parameter(Mandatory=$True, Position=2)]
        [string]
        $Uri,
        
        [Parameter(Mandatory=$False)]
        [PSObject]
        $Body,

        [Parameter(Mandatory=$False)]
        [Hashtable]
        $Headers = (Helper-BuildHeaders)
    )

    # Formatting Sanity checks. This allows us to easily ingest and use direct Resource Record URIs from such calls as /REST/ANYRecord
    # Which already have the /REST prefix embedded. Also, enables us to be simple above and request just /Session and have it properly
    # reformatted.
    if (-not $Uri.StartsWith('/')) {
        $Uri = "/$Uri"
    }
    if (-not $Uri.StartsWith('/REST')) {
        $Uri = "/REST$Uri"
    }

    $RestMethodParams = @{
        Method = $Method
        Uri = "https://api.dynect.net$Uri"
        ContentType = 'application/json'
    }

    if ($Method -in @('POST', 'PUT') -and $Body -ne $null) {
        $JsonBody = ConvertTo-Json $Body -Depth 5
        $RestMethodParams.Add('Body', $JsonBody)

        # Write-Verbose $JsonBody
    }

    if ($Headers.Count -gt 0) {
        $RestMethodParams.Add('Headers', $Headers)
    }

    try {
        $Response = Invoke-RestMethod @RestMethodParams
    } catch {
        # If we get a 429 Response code, we're ratelocked. Avoid sending requests during this time.
        # Also, throw an error back to the calling code.
        #   https://help.dyn.com/managed-dns-api-rate-limit/

        # Discovered this gem of a response from 
        #   https://stackoverflow.com/questions/18771424/how-to-get-powershell-invoke-restmethod-to-return-body-of-http-500-code-response

        $WebResponse = $_.Exception.Response
        $Stream = $WebResponse.GetResponseStream()
        $Reader = New-Object System.IO.StreamReader($Stream)
        $Reader.BaseStream.Position = 0
        $Reader.DiscardBufferedData()
        $Response = ConvertFrom-Json ($Reader.ReadToEnd())
    }

    Write-Output $Response
}

Function Helper-DynECTRateLock {
    [CmdletBinding()]
    Param(
    )

    throw [System.NotImplementedException]::New("This commandlet is not yet implemented")
}

Function Helper-FormatResourceRecordRData {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateScript({$Script:DynECTRRTypeMap.ContainsKey($_)})]
        [string]
        $RecordType,

        [Parameter(Mandatory=$true, Position=1)]
        [Hashtable]
        $RDataSet
    )

    Begin {
    }

    Process {
        $RecordData = New-Object System.Collections.Hashtable

        switch ($RecordType) {
            {$_ -in 'A', 'AAAA'} {
                $RecordData.Add('address', $RDataSet.Address)
            }
            'CNAME' {
                $RecordData.Add('cname', $RDataSet.HostNameAlias)
            }
            'TXT' {
                $RecordData.Add('txtdata', $RDataSet.TXTData)
            }
            default {
                throw [System.NotImplementedException]::New('This Resource Record Type is not yet implemented.')
            }
        }

        Write-Output $RecordData
    }

    End {
    }
}

Function Helper-StoreDynECTResourceRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=0)]
        [string]
        $Zone,

        [Parameter(Mandatory=$true, Position=1)]
        [string]
        $FQDN,

        [Parameter(Mandatory=$false, Position=2)]
        [ValidateScript({[int]::TryParse($_, [ref] $null)})]
        [string]
        $TTL = 0,

        [ValidateScript({$Script:DynECTRRTypeMap.ContainsKey($_)})]
        [string]
        $RecordType,

        [Parameter(ParameterSetName='AddNew', Mandatory=$true, Position=4)]
        [hashtable]
        $AddRecordData,

        [Parameter(ParameterSetName='UpdateOne', Mandatory=$true, Position=4)]
        [string]
        $RecordId,

        [Parameter(ParameterSetName='ReplaceAll', Mandatory=$true)]
        [switch]
        $Replace,

        [Parameter(ParameterSetName='UpdateOne', Mandatory=$true, Position=5)]
        [Parameter(ParameterSetName='ReplaceAll', Mandatory=$true)]
        [hashtable]
        $UpdateRecordData
    )

    $ResourceMap = $Script:DynECTRRTypeMap

    $ResourceUri = $ResourceMap[$RecordType].ResourceUri
    [array] $RDataProps = $ResourceMap[$RecordType].RDataProps

    $Uri = "/$ResourceUri/$Zone/$FQDN"

    switch ($PSCmdlet.ParameterSetName) {
        'AddNew' {
            $Method = 'POST'
            $RecordInfo = @{
                rdata = $AddRecordData
                ttl = $TTL
            }
        }
        'UpdateOne' {
            $Method = 'PUT'
            $Uri = "$Uri/$RecordId"
            $RecordInfo = @{
                rdata = $UpdateRecordData
                ttl = $TTL
            }
        }
        'ReplaceAll' {
            $Method = 'PUT'
            $ReplaceTag = "$($ResourceMap[$RecordType].ResourceUri)s"
            $RecordInfo = @{
                $ReplaceTag = @(@{
                    rdata = $UpdateRecordData
                    ttl = $TTL
                })
            }
        }
        default {
            throw [System.ArgumentException]::New("There be dragons here. Invalid Parameter Set Name after processing.")
        }
    }

    $Response = Helper-InvokeRestMethod -Method $Method -Uri $Uri -Body $RecordInfo

    if ($Response.status -eq 'success') {
        # Output the message from the remote side, verbose form.
        $Response.msgs | foreach { Write-Verbose $_.INFO }

        $RecordInfo = [ordered] @{
            Zone = $Response.data.zone
            FQDN = $Response.data.fqdn
            RecordType = $Response.data.record_type
            TTL = $Response.data.ttl
        }
        
        Write-Verbose "Processing $($RDataProps.Count) Record data properties"
        foreach ($Prop in $ResourceMap[$RecordType].RDataProps) {
            Write-Debug "Processing RecordData property $Prop"
            $RecordInfo.Add($Prop, $Response.data.rdata."$Prop")
        }

        $RecordData = New-Object -Type PSObject -Property $RecordInfo
        $RecordData.PSObject.TypeNames.Insert(0,"Kittyfox.DynECT.$($ResourceMap[$RecordType].TypeName)")
        Write-Output $RecordData
    } else {
        $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

        $Message | foreach { Write-Error $_ }
    }
}

#endregion DynECT Helper Commandlets

Export-ModuleMember -Function Connect-*, Disconnect-*, Test-*, Get-*, Add-*, Set-*, New-*, Remove-*, Lock-*, Unlock-*, Publish-*, Clear-*
