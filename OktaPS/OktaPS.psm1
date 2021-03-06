﻿#################################################################################################################################################################################################################################
#Core Functions
#################################################################################################################################################################################################################################
#Function to convert Epoch Time to a DateTime object
function Convert-UnixTimeToDateTime([int]$UnixTime) {
    Try {
        [timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($UnixTime))
    } Catch {
        Write-Warning "Wow you figured out how to break time? You broke her. You taught her time and time again that nothing she does, ever, is good enough."
    }
}

#Function to build the configuration parameters to connect to Okta
function Set-OktaConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Token,

        [Parameter(Mandatory=$true,Position=1)]
        [string]$OktaOrg,

        [Parameter(Mandatory=$false)]
        [switch]$Preview = $false
    )

    Write-Verbose 'Building OktaHeaders to authenticate to Okta'
    Try {
        $OktaHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $OktaHeaders.Add("Authorization", "SSWS $Token")
        $OktaHeaders.Add("Accept", 'application/json')
        $OktaHeaders.Add("Content-Type", 'application/json')
        $OktaHeaders | Set-Variable OktaHeaders -Scope Global

        #Load the .Net type because it doesn't always load
        Add-Type -AssemblyName System.Web

        Write-Verbose 'Set the BaseURI for the Okta orgin'
        if (!($Preview)) {$BaseURI = "https://$OktaOrg.okta.com/api/v1"} else {$BaseURI = "https://$OktaOrg.oktapreview.com/api/v1"}

        Write-Verbose 'Set some variables for use in the rest of the module'
        $BaseURI | Set-Variable BaseURI -Scope Global
        $OktaOrg | Set-Variable OktaOrg -Scope Global
    } Catch {
        Write-Warning "Unable to build the Okta config, bailing out!"
        exit
    }
}

#Function to check our API Limit
function Get-OktaAPILimit ($APILimitRange) {
    #Make a dumb API call and limit our response to avoid burning up resources, this must be Invoke-WebRequest and not Invoke-RestMethod
    Try {
        $OktaAPICall = Invoke-WebRequest -Method Head -Uri "$BaseURI/groups?limit=1" -Headers $OktaHeaders -UseBasicParsing | Select-Object -ExpandProperty Headers
    } Catch {
        Write-Warning "Unable to make a dumb api call to $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }

    [int]$OktaAPIMaxCalls = ($OktaAPICall.GetEnumerator() | Where-Object {($PSItem.Key -eq 'X-Rate-Limit-Limit')}).Value
    [int]$OktaAPICurrentCalls = ($OktaAPICall.GetEnumerator() | Where-Object {($PSItem.Key -eq 'X-Rate-Limit-Remaining')}).Value
    $OktaAPIResetTime = ($OktaAPICall.GetEnumerator() | Where-Object {($PSItem.Key -eq 'X-Rate-Limit-Reset')}).Value

    $DateTimeConversion = ((Get-Date) - (Convert-UnixTimeToDateTime -UnixTime $OktaAPIResetTime)).Seconds

    Write-Debug "We have $OktaAPICurrentCalls Okta API calls left"

    if ($OktaAPICurrentCalls -lt $APILimitRange) {
        Write-Verbose "Sleeping for $($DateTimeConversion * -1) seconds because we have $OktaAPICurrentCalls api calls left which is below the $APILimitRange"
        Start-Sleep ($DateTimeConversion * -1)
    }

}

#Function to automatically get all listings by pagination, this function will use the default Okta Limit parameter. Which is 1000 as the time of this making.
#Invoke-OktaPagedMethod is based on the _oktaRecGet() function from https://github.com/mbegan/Okta-PSModule/blob/master/Okta.psm1
function Invoke-OktaPagedMethod {
    param
    (
        [string]$Uri,
        [array]$col,
        [int]$loopcount = 0
    )
       
    try {
        #[System.Net.HttpWebResponse]$response = $request.GetResponse()
        $OktaResponse = Invoke-WebRequest -Method Get -UseBasicParsing -Uri $Uri -Headers $OktaHeaders -TimeoutSec 300
        
        #Build an Hashtable to store the links
        $link = @{}
        if ($OktaResponse.Headers.Link) { # Some searches (eg List Users with Search) do not support pagination.
            foreach ($header in $OktaResponse.Headers.Link.split(",")) {
                if ($header -match '<(.*)>; rel="(.*)"') {
                    $link[$matches[2]] = $matches[1]
                }
            }
        }

        $link = @{
            next = $link.next
        }
        
        try {
            $psobj = ConvertFrom-Json -InputObject $OktaResponse.Content
            $col = $col + $psobj
        } catch {
            throw "Json Exception : " + $OktaResponse
        }
    } catch { 
        throw $_
    }
        
    if ($link.next) {
        $loopcount++
        if ($oktaVerbose) { Write-Host "fetching next page $loopcount : " -ForegroundColor Cyan}
        Invoke-OktaPagedMethod -Uri $link.next -col $col -loopcount $loopcount   
    } else {
        return $col
    }
}

#Function to test the Okta API
function Test-OktaAPI {
    Try {
        $Response = Invoke-WebRequest -Method Head -Uri "$BaseURI/groups?limit=1" -Headers $OktaHeaders -UseBasicParsing
    } Catch {
        Write-Warning "Our API call to Okta failed $($Error[0].Exception.Message)"
    }
    Write-Output "$($Response.StatusCode)"
}

#################################################################################################################################################################################################################################
#User related functions
#################################################################################################################################################################################################################################
#Function to get an Okta User
function Get-OktaUser {
    <#
        .SYNOPSIS
        Find user(s) in Okta based upon shortname, email, or OktaID
    
        .DESCRIPTION
        Find user(s) in Okta based upon shortname, email, or OktaID to log out to a database, text file, or pipeline
    
        .PARAMETER Users
        Users SamAccountName

        .PARAMETER UserIDs
        Allows a boolean value to be specified to allow batch automation

        .PARAMETER Email
        Okta had to be the good guy and adhere to freaking case sensitivity here as defined in RFC 5321

        .EXAMPLE
        Get-OktaUser -Users John.Doe,Mary.Smith,

        .EXAMPLE
        Get-OktaUser -UserIDs 00u8d1xmfpgzRAeGU0h7,00u8d1xkpnWRRbxQN0h7

        .EXAMPLE
        Get-OktaUser John.Doe@example.com
    #>

    [CmdletBinding(DefaultParameterSetName='ByUserName')]
    param (
        [Parameter(Mandatory=$True,ParameterSetName='ByUserName',Position=0,ValueFromPipeline=$True)]
        [Array]$Users,

        [Parameter(Mandatory=$True,ParameterSetName='ByUserID',Position=0,ValueFromPipeline=$True)]
        [Array]$UserIDs,

        [Parameter(Mandatory=$True,ParameterSetName='ByEmailAddress',Position=0)]
        [String]
        $Emails
    )

    Process {
        #Put UsersID into Users if specified
        if ($UsersIDs) {$Users = $UserIDs}

        if ($Users) {
            foreach ($User in $Users) {
                Write-Verbose "Get the User $User"
                $User = [System.Web.HttpUtility]::UrlEncode($User)
                Try {
                    (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$User" -Headers $OktaHeaders)
                } Catch {Write-Warning "User $User does not exist in $OktaOrg"}
            }
        } elseif ($Emails) {
            foreach ($Email in $Emails) {
                Write-Verbose "Get the User $Email"
                $OktaFilterString = 'profile.email eq "{0}"' -f $Email
                $OktaFilterString = [System.Web.HttpUtility]::UrlEncode($OktaFilterString)
                Try {
                    Invoke-RestMethod -Method Get -Uri "$BaseURI/users?filter=$OktaFilterString" -Headers $OktaHeaders
                } Catch {
                    Write-Warning "$User does not exist in $OktaOrg"
                    Write-Output $_.Exception.Response.StatusCode.value__ 
                }
            }
        }
    }
}

#Function to get all Okta Users
function Get-OktaUsers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [ValidateSet('Any','STAGED','PROVISIONED','ACTIVE','RECOVERY','LOCKED_OUT','PASSWORD_EXPIRED','SUSPENDED','DEPROVISIONED')]
        [String]$Status
    )

    Process {
        switch ($Status) {
            'STAGED' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "STAGED"')}
            'PROVISIONED' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "PROVISIONED"')}
            'ACTIVE' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "ACTIVE"')}
            'RECOVERY' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "RECOVERY"')}
            'LOCKED_OUT' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "LOCKED_OUT"')}
            'PASSWORD_EXPIRED' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "PASSWORD_EXPIRED"')}
            'SUSPENDED' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "SUSPENDED"')}
            'DEPROVISIONED' {$OktaFilterString = [System.Web.HttpUtility]::UrlEncode('status eq "DEPROVISIONED"')}
            default {$OktaFilterString = $null}
        }     
        
        #Find the user with the filter string
        if ($Status -like 'Any') {
            Invoke-OktaPagedMethod -Uri "$BaseURI/users"
        } else {
            Invoke-OktaPagedMethod -Uri "$BaseURI/users?filter=$OktaFilterString"
        }
    }
}

#Function to get groups an Okta user is a apart of
function Get-OktaUserGroups {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True,Position=0,ValueFromPipeline=$True)]
        [Array]$id
    )

    Process {
        #Accept pipeline input from Get-OktaUser by reseting the variable to get the information we need
        if (($id | Get-Member).Name -eq 'id') {$id = $id.id}
        foreach ($OktaId in $Id) {
            Write-Verbose "Getting the groups of $OktaID"
            Try {
                Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$OktaId/groups" -Headers $OktaHeaders
            } Catch {
                Write-Warning "Unable to find $OktaId $OktaOrg"
                Write-Output $_.Exception.Response.StatusCode.value__ 
            }
        }
    }
}

#Function to get Okta API User
function Get-OktaUserWhoAmI {
    Try {
        $OktaUserWhoAmI = (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/me" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to find out who we are in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }

    $OktaUserWhoAmI
    Write-Verbose "You are $($OktaUserWhoAmI.profile.login)"
}

#Function to update profile attribute on a Okta Users profile
function Update-OktaUserAttribute {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID,

        [Parameter(Mandatory=$true,Position=1)]
        [string]$AttributeName,

        [Parameter(Mandatory=$true,Position=2)]
        [AllowEmptyString()]
        [string]$AttributeValue
    )

    Write-Verbose 'Build the JSON for the User modification'
    $emptyarray = @() #Required to make a blank array object in the JSON Blob
    $JSONTemplate = [PSCustomObject]@{
        profile = [PSCustomObject]@{
            $AttributeName = $AttributeValue
        }
    }

    Try {
        $Response = Invoke-RestMethod -Method Post -Uri "$BaseURI/users/$UserID" -Body ($JSONTemplate | ConvertTo-Json -Depth 20) -Headers $OktaHeaders
    } Catch [System.Net.WebExceptionStatus] {
        Write-Warning "Unable to update user attribute $($AttributeName)"
        Write-Output '400' #Hardcode a status code so the error logic is handled within
    } Catch {
        Write-Warning "Unable to update user attribute $($AttributeName)"
        if ($_.Exception.Response.StatusCode.value__) {
            Write-Output $_.Exception.Response.StatusCode.value__
        } else {
            Write-Output '400' #Hardcode a status code so the error logic is handled within
        }
    }

    if ($Response.Profile.$AttributeName -eq $AttributeValue) {
        Write-Output "Successfully updated attribute $AttributeName"
    }
}

#################################################################################################################################################################################################################################
#Group Related Functions
#################################################################################################################################################################################################################################
#Function to get all Okta org groups
function Get-OktaGroups {
    Invoke-OktaPagedMethod -Uri "$BaseURI/groups"
}

#Function to get specific Okta Group by name or ID
function Get-OktaGroup {
    [CmdletBinding(DefaultParameterSetName='ByGroupName')]
    param (
        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupName')]
        [String]
        $GroupName,

        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupId')]
        [String]
        $GroupID
    )

    if ($GroupName) {
        Try {
            (Invoke-RestMethod -Method Get -Uri "$BaseURI/groups" -Headers $OktaHeaders) | Where-Object {($PSItem.profile.name -like $GroupName)}
        } Catch {
            Write-Warning "Unable to query $GroupName in  $OktaOrg"
            Write-Output $_.Exception.Response.StatusCode.value__ 
        }
    } elseif ($GroupID) {
        $OktaFilterString = 'id eq "{0}"' -f $GroupID
        $OktaFilterString = [System.Web.HttpUtility]::UrlEncode($OktaFilterString)
        Try {
            Invoke-RestMethod -Method Get -Uri "$BaseURI/groups?filter=$OktaFilterString" -Headers $OktaHeaders
        } Catch {
            Write-Warning "Unable to query $GroupID in $OktaOrg"
            Write-Output $_.Exception.Response.StatusCode.value__ 
        }
    }
}

#Function to create a new group in the Okta Org
function New-OktaGroup ($GroupName, $GroupDescription) {
    Write-Verbose 'Build the JSON for the group'
    $JSONTemplate = [PSCustomObject]@{
        profile = [PSCustomObject]@{
            name = $GroupName
            description = $GroupDescription
        }
    }

    Write-Verbose 'Create the new group in okta'
    Try {
        Invoke-RestMethod -Method Post -Uri "$BaseURI/groups" -Headers $OktaHeaders -Body ($JSONTemplate | ConvertTo-Json) 
    } Catch [System.Net.WebExceptionStatus] {
        Write-Warning "Unable to create $($JSONTemplate.profile.name) in $OktaOrg"
        Write-Output '400' #Hardcode a status code so the error logic is handled within
    } Catch {
        Write-Warning "Unable to create $($JSONTemplate.profile.name) in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to update a Okta Group
function Update-OktaGroup {
    [CmdletBinding(DefaultParameterSetName='ByGroupName')]
    param (
        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupName')]
        [String]$GroupID,

        [Parameter(Mandatory=$true,Position=1,ParameterSetName='ByGroupName')]
        [String]$GroupName,

        [Parameter(Mandatory=$false,Position=2,ParameterSetName='ByGroupName')]
        [String]$GroupDescription
    )

    Write-Verbose 'Build the JSON for the group'
    $JSONTemplate = [PSCustomObject]@{
        profile = [PSCustomObject]@{
            name = $GroupName
            description = $GroupDescription
        }
    }

    Write-Verbose 'Update an existing group in okta'
    Try {
        Invoke-RestMethod -Method Put -Uri "$BaseURI/groups/$GroupID" -Headers $OktaHeaders -Body ($JSONTemplate | ConvertTo-Json)
    } Catch [System.Net.WebExceptionStatus] {
        Write-Warning "Unable to update Group ID $GroupID in $OktaOrg"
        Write-Output '400' #Hardcode a status code so the error logic is handled within
    } Catch {
        Write-Warning "Unable to update Group ID $GroupID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to remove a group in the Okta Org
function Remove-OktaGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True,ValueFromPipeline=$True,ValueFromPipelinebyPropertyName=$True)]
        [Array]$ID
    )

    Process {
        foreach ($GroupID in $ID) {
            Write-Verbose 'Delete the group'
            Try {
                Invoke-RestMethod -Method Delete -Uri "$BaseURI/groups/$ID" -Headers $OktaHeaders
                if ($?) {Write-Output "Successfully deleted $GroupID from $OktaOrg"}
            } Catch [System.Net.WebExceptionStatus] {
                Write-Warning "Unable to delete $GroupID in $OktaOrg"
                Write-Output '400' #Hardcode a status code so the error logic is handled within
            } Catch {
                Write-Warning "Unable to delete $GroupID in $OktaOrg"
                Write-Output $_.Exception.Response.StatusCode.value__ 
            }
        }
    }
}

#Function to list all members of a Okta Group
function Get-OktaGroupMembers {
    [CmdletBinding(DefaultParameterSetName='ByGroupName')]
    param (
        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupName')]
        [String]
        $GroupName,

        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupId')]
        [String]
        $GroupID
    )

    Try {
        $GroupID = ((Invoke-RestMethod -Method Get -Uri "$BaseURI/groups" -Headers $OktaHeaders) | Where-Object {($PSItem.profile.name -like $GroupName)}).id
    } Catch {
        Write-Warning "Unable to query for GroupID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
    
    Invoke-OktaPagedMethod -Uri "$BaseURI/groups/$GroupID/users"
}

#Function to add user to an Okta user to an Okta Group
function Add-OktaGroupMember {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True,Position=0,ValueFromPipeline=$True)]
        [Array]$UserIDs,
        [Parameter(Mandatory=$True,Position=1,ValueFromPipeline=$True)]
        [Array]$GroupIDs
    )

    Process {
        foreach ($User in $UserIDs) {
            Write-Verbose "Adding groups for $User"
            foreach ($Group in $GroupIDs) {
                Write-Verbose "Adding $User to $GroupID"
                Try {
                    Invoke-RestMethod -Method Put -Uri "$BaseURI/groups/$Group/users/$User" -Headers $OktaHeaders
                } Catch [System.Net.WebExceptionStatus] {
                    Write-Warning "Unable to add user $User to group $Group in $OktaOrg"
                    Write-Output '400' #Hardcode a status code so the error logic is handled within
                } Catch {
                    Write-Warning "Unable to add user $User to group $Group in $OktaOrg"
                    Write-Output $_.Exception.Response.StatusCode.value__ 
                }
            }
        }
    }
}

#Function to remove an Okta User from an Okta Group
function Remove-OktaGroupMember {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True,Position=0,ValueFromPipeline=$True)]
        [Array]$UserIDs,
        [Parameter(Mandatory=$True,Position=1,ValueFromPipeline=$True)]
        [Array]$GroupIDs
    )

    Process {
        foreach ($User in $UserIDs) {
            Write-Verbose "Removing groups for $User"
            foreach ($Group in $GroupIDs) {
                Write-Verbose "Removing $User to $GroupID"
                Try {
                    Invoke-RestMethod -Method Delete -Uri "$BaseURI/groups/$Group/users/$User" -Headers $OktaHeaders
                } Catch [System.Net.WebExceptionStatus] {
                    Write-Warning "Unable to remove user $User from group $Group in $OktaOrg"
                    Write-Output '400' #Hardcode a status code so the error logic is handled within
                } Catch {
                    Write-Warning "Unable to remove user $User from group $Group in $OktaOrg"
                    Write-Output $_.Exception.Response.StatusCode.value__ 
                }
            }
        }
    }
}

#Function to get all applications assigned to a group
function Get-OktaGroupApplicationAssignment {
    [CmdletBinding(DefaultParameterSetName='ByGroupName')]
    param (
        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupName')]
        [String]
        $GroupName,

        [Parameter(Mandatory=$true,Position=0,ParameterSetName='ByGroupId')]
        [String]
        $GroupID
    )

    Try {
        if ($GroupName) {
            $GroupID = ((Invoke-RestMethod -Method Get -Uri "$BaseURI/groups" -Headers $OktaHeaders) | Where-Object {($PSItem.profile.name -like $GroupName)}).id
        }

        (Invoke-RestMethod -Method Get -Uri "$BaseURI/groups/$GroupID/apps" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get group application assignment(s) for $GroupID"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#################################################################################################################################################################################################################################
#IDP Related Functions
#################################################################################################################################################################################################################################
#Function to list out IDPs
function Get-OktaIdentityProviders {
    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/idps" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to query IDPs in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to get specific Identity Provider
function Get-OktaIdentityProvider {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Name
    )

    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/idps?q=$Name" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to query IDP $Name in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to add new Okta Identity Provider Group Sync Group IDs
function Add-OktaIdentityProviderGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [Array]$IDPNames,
        [Parameter(Mandatory=$true,Position=1)]
        [Array]$GroupIDs
    )
	
    foreach ($IDP in $IDPNames) {
        #Query the IDP to get the original JSON
        $IDPJSON = Get-OktaIdentityProvider -Name $IDP

        #Take the original groups and foreach them to build an array that we will later replace in the JSON
        $GroupsToReplace = @() #Build Array

        #Foreach through the existing groups and add them to the array, this is done so we don't lose our existing groups
        foreach ($GroupID in ($IDPJSON.policy.provisioning.groups.filter)) {
            $GroupsToReplace += $GroupID
        }

        #Foreach through the group ids to be added
        foreach ($GroupID in $GroupIDs) {
            $GroupsToReplace += $GroupID
        }

        $GroupsToReplace = $GroupsToReplace | Select-Object -Unique #Consolidate down the groups and verify they are unique just in case :)

        #Replace the JSON groups and rebuild the JSON
        $IDPJSON.policy.provisioning.groups.filter = $GroupsToReplace

        Try {
            Invoke-RestMethod -Method Put -Uri "$BaseURI/idps/$($IDPJSON.id)" -Body ($IDPJSON | ConvertTo-Json -Depth 20) -Headers $OktaHeaders
        } Catch {
            Write-Warning "Unable to add group to IDP $Name in $OktaOrg"
            Write-Output $_.Exception.Response.StatusCode.value__ 
        }
    }

}

#Function to remove existing Okta Identity Provider Group Sync Group IDs
function Remove-OktaIdentityProviderGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [Array]$IDPNames,
        [Parameter(Mandatory=$true,Position=1)]
        [Array]$GroupIDs
    )
	
    foreach ($IDP in $IDPNames) {
        #Query the IDP to get the original JSON
        $IDPJSON = Get-OktaIdentityProvider -Name $IDP

        #Take the original groups and foreach them to build an array that we will later replace in the JSON
        $GroupsToReplace = @() #Build Array

        [System.Collections.ArrayList]$GroupIDsAll = $IDPJSON.policy.provisioning.groups.filter

        #Foreach through the group ids to be removed
        foreach ($GroupID in $GroupIDs) {
            $GroupIDsAll.Remove($GroupID)
        }

        #Replace the JSON groups and rebuild the JSON
        $IDPJSON.policy.provisioning.groups.filter = $GroupIDsAll

        Try {
            Invoke-RestMethod -Method Put -Uri "$BaseURI/idps/$($IDPJSON.id)" -Body ($IDPJSON | ConvertTo-Json -Depth 20) -Headers $OktaHeaders
        } Catch {
            Write-Warning "Unable to remove group from IDP $Name in $OktaOrg"
            Write-Output $_.Exception.Response.StatusCode.value__ 
        }
    }

}

#################################################################################################################################################################################################################################
#Factor Related Functions
#################################################################################################################################################################################################################################
#Function to get a okta users enrolled factors
Function Get-OktaUserEnrolledFactors {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID
    )

    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$UserID/factors" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get Enrolled factors for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to get a specific factor of a Okta user
Function Get-OktaUserFactor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$FactorID
    )

    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$UserID/factors/$FactorID" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get factor $FactorID for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to get available factors that a user can enroll in
Function Get-OktaUserAvailableFactors {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID,
        [Parameter(Mandatory = $false)]
        [ValidateSet('NOT_SETUP','ACTIVE')]
        [String]$Status
    )

    Try {
        $OktaUserAvailableFactors = (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$UserID/factors/catalog" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get available factors for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }

    if (!($Status)) {
        $OktaUserAvailableFactors
    } else {
        $OktaUserAvailableFactors | Where-Object {($PSItem.status -eq $Status)}
    }
}

#Function to get a specific factor of a Okta user
Function Get-OktaUserAvailableFactorsSecurityQuestion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID
    )

    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/users/$UserID/factors/questions" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get available factors security question for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to remove a Okta users factor
Function Remove-OktaUserFactor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID,
        [Parameter(Mandatory=$true,Position=1)]
        [String]$FactorID
    )

    Try {
        Invoke-RestMethod -Method Delete -Uri "$BaseURI/users/$UserID/factors/$FactorID" -Headers $OktaHeaders
    } Catch {
        Write-Warning "Unable to remove factor $FactorID for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to test a users hardware token factor
Function Test-OktaUserTokenFactor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$UserID,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$FactorID,
        [Parameter(Mandatory=$true,Position=2)]
        [String]$OTP
    )

    Try {
        Invoke-RestMethod -Method Post -Uri "$BaseURI/users/$UserID/factors/$FactorID/verify" -Headers $OktaHeaders -Body ([PSCustomObject]@{passcode = $OTP} | ConvertTo-Json)
    } Catch {
        Write-Warning "Unable to verify token factor $FactorID for $UserID in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#################################################################################################################################################################################################################################
#Schema Related Functions
#################################################################################################################################################################################################################################
#Function to get back the entire JSON blob of the Okta Schema
function Get-OktaUserSchemaAll {
    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/meta/schemas/user/default" -Headers $OktaHeaders)
    } Catch {
        Write-Warning "Unable to get back the full Okta user schema in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to get specific Schema type back from Okta
function Get-OktaUserSchema {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateSet('base','custom')]
        [string]$Type
    )

    Try {
        (Invoke-RestMethod -Method Get -Uri "$BaseURI/meta/schemas/user/default" -Headers $OktaHeaders).definitions.$($Type).properties
    } Catch {
        Write-Warning "Unable to get Okta User Schema in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to add a property to the Okta user schema
function Add-OktaUserSchemaProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$AttributeName,

        [Parameter(Mandatory=$true,Position=1)]
        [string]$AttributeDescription,

        [Parameter(Mandatory=$true,Position=2)]
        [ValidateSet('string','boolean','date','number','integer','array')]
        [string]$AttributeType = 'string',

        [Parameter(Mandatory=$true,Position=3)]
        [ValidateSet('HIDE','READ_ONLY','READ_WRITE')]
        [string]$AttributeActionType = 'READ_WRITE',

        [Parameter(Mandatory=$false)]
        [int]$AttributeMinLength = 1,

        [Parameter(Mandatory=$false)]
        [int]$AttributeMaxLength = 25,

        [Parameter(Mandatory=$false)]
        [boolean]$AttributeRequired = $false
    )

    Write-Verbose 'Build the JSON for the Schema modification'
    #http://developer.okta.com/docs/api/resources/schemas.html#user-profile-custom-subschema
    $emptyarray = @() #Required to make a blank array object in the JSON Blob
    $JSONTemplate = [PSCustomObject]@{
        definitions = [PSCustomObject]@{
            custom = [PSCustomObject]@{
                id = '#custom'
                type = 'object'
                properties = [PSCustomObject]@{
                    $AttributeName = [PSCustomObject]@{
                        title = $AttributeName
                        description = $AttributeDescription
                        type = $AttributeType
                        required = $($AttributeRequired)
                        minLength = $AttributeMinLength
                        maxLength = $AttributeMaxLength
                        permissions = [array][PSCustomObject]@{
                            principal = 'SELF'
                            action = $AttributeActionType
                        }
                    }
                }
                required = $emptyarray
            }
        }
    }

    Try {
        Invoke-RestMethod -Method Post -Uri "$BaseURI/meta/schemas/user/default" -Body ($JSONTemplate | ConvertTo-Json -Depth 20) -Headers $OktaHeaders
    } Catch {
        Write-Warning "Unable to create $($AttributeName) in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}

#Function to remove a property from the Okta user schema
function Remove-OktaUserSchemaProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$AttributeName
    )

    Write-Verbose 'Build the JSON for the Schema modification'
    #http://developer.okta.com/docs/api/resources/schemas.html#user-profile-custom-subschema
    $emptyarray = @() #Required to make a blank array object in the JSON Blob
    $JSONTemplate = [PSCustomObject]@{
        definitions = [PSCustomObject]@{
            custom = [PSCustomObject]@{
                id = '#custom'
                type = 'object'
                properties = [PSCustomObject]@{
                    $AttributeName = $null
                }
                required = $emptyarray
            }
        }
    }

    Try {
        Invoke-RestMethod -Method Post -Uri "$BaseURI/meta/schemas/user/default" -Body ($JSONTemplate | ConvertTo-Json -Depth 20) -Headers $OktaHeaders
    } Catch {
        Write-Warning "Unable to remove $($AttributeName) in $OktaOrg"
        Write-Output $_.Exception.Response.StatusCode.value__ 
    }
}