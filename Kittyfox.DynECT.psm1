$AuthToken = [string]::Empty
$SigninTime = $null
$LastSessionCheck = $null
$RestEndpointURI = 'https://api.dynect.net/REST'

$DynECTPersist = $False
$DynECTCustomerName = [string]::Empty
$DynECTUserName = [string]::Empty
$DynECTPassword = [SecureString]::new()

## Configurable Options
$DynECTSessionCheckInterval = 60

<# Known Types of the Module

 Kittyfox.DynECT.ZoneInfo



#>

<# Type-Setting Snippet

    foreach ($Item in $DataSet) {
        $Item.PSObject.TypeNames.Insert(0,'Kittyfox.DynECT.Class') 
    }

#>

Function Connect-DynECTSession {
    [CmdletBinding()]
    Param(
        [string]
        $CustomerName,

        [string]
        $UserName,

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

        Write-Verbose "Successful Login, Token: $AuthToken"
    } else {
        $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

        Write-Error $Message
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
    $IsConnected = $False

    if (-not [string]::IsNullOrEmpty($AuthToken)) {
        Write-Verbose "Test Session, Token: $AuthToken"

        if ((New-Timespan -Start $LastSessionCheck -End (Get-Date)).TotalSeconds -le $Script:DynECTSessionCheckInterval) {
            $IsConnected = $True
            Write-Verbose "Skipped check, within the session check interval of $($Script:DynECTSessionCheckInterval)s since last test."
        } else {
            $Response = Helper-InvokeRestMethod -Method 'Get' -Uri '/Session'

            if ($Response.status -eq 'success') {
                $IsConnected = $True
                Write-Verbose "Successfully Tested Session."
            } else {
                if ($Reconnect -and $Script:DynECTPersist) {
                    try {
                        $ConnectParams = @{
                            CustomerName = $Script:DynECTCustomerName
                            UserName = $Script:DynECTUserName
                            Password = $Script:DynECTPassword
                        }
                        Connect-DynECTSession @ConnectParams -ErrorAction Stop
                    } catch {
                        Write-Error "Reconnect requested, attempt failed: $($_.Exception.Message)"

                        $Script:DynECTPersist = $False
                        $Script:DynECTCustomerName = [string]::Empty
                        $Script:DynECTUserName = [string]::Empty
                        $Script:DynECTPassword = [SecureString]::new()
                    }
                }
            }
        }
    } else {
        Write-Verbose "No Session Currently Detected."
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

            if ($Persistent) {
                $Script:DynECTPersist = $False
                $Script:DynECTCustomerName = [string]::Empty
                $Script:DynECTUserName = [string]::Empty
                $Script:DynECTPassword = [SecureString]::new()
            }

            Write-Verbose "Succesfully Disconnected from DynECT and emptied state variables."
        } else {
            $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

            Write-Error $Message
        }
    }
}

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
        [string]
        $Zone
    )

    Begin {
        $IsConnected = Test-DynECTSession -Reconnect
        $IsZoneSpecified = $PSBoundParameters.ContainsKey('Zone')

        if (-not $IsConnected) {
            Write-Error "Not connected to DynECT Managed DNS Service."
            return
        }
    }

    Process {
            $Uri = '/Zone'
            if ($PSBoundParameters.ContainsKey('Zone')) {
                $Uri += ('/' + $Zone)
            }

            $Response = Helper-InvokeRestMethod -Method GET -Uri $Uri

            if ($Response.status -eq 'success') {
                if ($IsZoneSpecified) {
                    $ZoneInfo = @{
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
        [Parameter(Mandatory=$True, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Zone
    )

    # https://help.dyn.com/update-zone-api/
    # - Freeze option

    Helper-UpdateDynECTZone -Zone $Zone -Freeze
}

Function Unlock-DynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Zone
    )

    # https://help.dyn.com/update-zone-api/
    # - Thaw option

    Helper-UpdateDynECTZone -Zone $Zone -Thaw
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

Function Helper-UpdateDynECTZone {
    [CmdletBinding()]
    Param(
        [Parameter(ParameterSetName='Freeze', Mandatory=$True, Position=1, ValueFromPipeline=$True)]
        [Parameter(ParameterSetName='Thaw', Mandatory=$True, Position=1, ValueFromPipeline=$True)]
        [Parameter(ParameterSetName='Publish', Mandatory=$True, Position=1, ValueFromPipeline=$True)]
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

    # $Response = Helper-InvokeRestMethod -Method PUT -Uri $Uri -Body $ZoneData

    if ($Response.status -eq 'success') {
        if ($PSCmdlet.ParameterSetName -eq 'Publish') {
            
        }
    } else {
        $Message = ($Response.msgs | where { $_.LVL -eq 'ERROR' }).INFO

        Write-Error $Message
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

    $RestMethodParams = @{
        Method = $Method
        Uri = "https://api.dynect.net/REST$Uri"
        ContentType = 'application/json'
    }

    if ($Method -eq 'POST' -and $Body -ne $null) {
        $JsonBody = ConvertTo-Json $Body
        $RestMethodParams.Add('Body', $JsonBody)

        Write-Debug $JsonBody
    }

    if ($Headers.Count -gt 0) {
        $RestMethodParams.Add('Headers', $Headers)
    }

    try {
        $Response = Invoke-RestMethod @RestMethodParams
    } catch {
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

Export-ModuleMember -Function Connect-*, Disconnect-*, Test-*, Get-*, Set-*, New-*, Remove-*
