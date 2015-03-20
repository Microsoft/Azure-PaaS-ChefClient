﻿# Installer chef client

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"


function Install-ChefClient
{
  <#
    .SYNOPSIS
      Install Chef Client from Assemblies directory 
    
    .DESCRIPTION
      Run the offline installer for Chef Client
    
    .NOTES
      Downloaded from: http://www.getchef.com/chef/install/
    
    .EXAMPLE
      Install-ChefClient -verbose
  #>
  [CmdLetBinding()]
  param(
    [ValidateNotNullOrEmpty()]
    [string] $InstallLocation = "C:\Opscode",
    [ValidateNotNullOrEmpty()]
    [string] $RootDrive = $env:SystemDrive,
    [ValidateNotNullOrEmpty()]
    [string] $RootPath = "C:\Chef",
    [ValidateNotNullOrEmpty()]
    [string] $ConfigFile = "Client.rb",
    [ValidateNotNullOrEmpty()]
    [string] $LogFile = "client.log"
  )

    Process
    {
        # chef repository 
        md $RootPath -ErrorAction SilentlyContinue | Out-Null

        $pathToConfigFile = Join-Path $RootPath $ConfigFile
        $pathToLogFile = Join-Path $RootPath $LogFile

        $msi = (Resolve-Path (Join-Path $PSScriptRoot "\resources\*.msi")).Path
        write-verbose "Installing chef client from $msi."
        start-process msiexec -ArgumentList "/qn /i $msi ADDLOCAL=`"ChefClientFeature,ChefServiceFeature`" InstallLocation=`"$InstallLocation`" ROOTDRIVE=`"$RootDrive\`" /L $($msi).log" -Wait
        Invoke-SC failure "chef-client" reset= 86400 actions= restart/5000
        
        $rubyPath = Join-Path $InstallLocation "\chef\embedded\bin\ruby.exe"
        $servicePath = Join-Path $InstallLocation "\chef\bin\chef-windows-service"
        # Add the --Config and --LogFile paramters to the binpath of the service
        Invoke-SC config "chef-client" binpath= "`"$rubyPath $servicePath -c $pathToConfigFile -l $pathToLogFile`""

        # For running knife commands in the same process as the installer. The installer sets the path variable but in a different context, so we can't run knife otherwise.
        Set-Path (Join-Path $InstallLocation "chef\bin")
    }
}

function Get-ChefClientConfig
{
  <#
    .SYNOPSIS
      Loads the Chef Client Config into memory

    .DESCRIPTION
      Loads the Chef Client Config for itempotency and easy editing of config values

    .EXAMPLE
      Get-ChefClientConfig -Path .\Client.rb
    
    .EXAMPLE
      Get-ChefClientConfig 
  #>
  [CmdLetBinding()]
  param(
    [AllowNull()]
    [string] $Path = $null
  )

  Process
  {
    $InitialProperties = @{
        "log_level" = "";
        "log_location" = "";
        "cache_path" = "";
        "client_key" = "";
        "node_name" = "";
        "chef_server_url" = "";
        "encrypted_data_bag_secret" = "";
        "validation_client_name" = "";
        "validation_key" = "";
        "interval" = "";
        "json_attribs" = "";
        "ssl_verify_mode" = ""; 
        "environment" = "_default"}

    if ($Path -and (Test-Path -Path $Path))
    {
        # Regex matches simple "somekey value" pattern
        # Parses out custom Ruby (like now = Time.new)
        Get-Content -Path $Path | where { $_ } | foreach {
            if (-not ($_ -match "^[a-zA-Z0-9_]*\s*[:'`"0-9].*['`"]?" ))
            {
                # Ran into this scenario before
                Write-Warning "The configuration might contain some unsupported values for this cmdlet. When piped into the Save-ChefClientConfig function, ensure the values are properly set"
            }

            $tokens = $_.Split(@(" ", "`t"), "RemoveEmptyEntries")
            $key = $tokens[0]
            $value = ($tokens | Select-Object -Last ($tokens.Count - 1)) -join " "
            $InitialProperties.$key = $value.Trim("'", '"');
        }
    }

    $InitialProperties.Add("AdditionalProperties", @{})
    New-Object -TypeName PSObject -Property $InitialProperties
  }
}

function Save-ChefClientConfig
{
  <#
    .SYNOPSIS
      Save the Chef Client Config object to a file

    .DESCRIPTION
      Takes a dictionary or PSObject and writes a Client.rb file for chef to use

    .EXAMPLE
      Save-ChefClientConfig -Path .\Client.rb

    .EXAMPLE
      Save-ChefClientConfig -Path .\Client.rb -Append

    .EXAMPLE
      Save-ChefClientConfig -Path .\Client.rb -Overwrite
    
    .EXAMPLE
      Save-ChefClientConfig 
  #>
  [CmdLetBinding(DefaultParameterSetName="Append")]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    $InputObject,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(ParameterSetName="Append")]
    [switch]$Append = $false,

    [Parameter(ParameterSetName="Overwrite")]
    [switch]$Overwrite = $false
  )

  
  Process
  {
    if (Test-Path $Path)
    {
        if ($Overwrite)
        {
            Remove-Item $Path -Force
        }
        elseif (-not $Append)
        {
            throw "Cannot save chef Client.rb to '$Path' because the file already exists. Use -Overwrite to overwrite or -Append to add"
        }
    }

    $hashToWrite = @{}
    if ($InputObject -is [HashTable])
    {
        $hashToWrite = $InputObject
    }
    elseif ($InputObject -is [PSObject])
    {
        $InputObject | Get-Member -MemberType NoteProperty | where { $_.Name -ne "AdditionalProperties" } | foreach {
            $hashToWrite.$($_.Name) = $InputObject.$($_.Name)
        }

        # Overwrite with anything in the AdditionalProperties property
        $InputObject.AdditionalProperties.Keys | foreach {
            $hashToWrite.$_ = $InputObject.AdditionalProperties.$_
        }
    }

    $contents = @()
    if ($Append)
    {
        $contents = Get-Content -Path $Path
    }

    # TODO: Could use some optimization
    $hashToWrite.Keys | where { $hashToWrite[$_] } | foreach {
        $key = $_
        $value = $hashToWrite[$key]

        # symbols and numbers should not be surrounded in quotes
        if (-not $value.StartsWith(":") -and -not ($value -match "^[0-9.]*$") -and -not $value.StartsWith("="))
        {
            $value = "'$value'"
        }

        $newLineToAdd = "{0}    {1}" -f $key,$value
        
        # Check if the line already exists in the file (i.e. if we're just appending), if so replace that line, rather than add a new line
        # TODO: More optimization. -Match and -Replace could do two iterations
        if ($contents -match "^$key\s")
        {
            $contents = $contents -replace "^$key\s.*$",$newLineToAdd
        }
        else
        {
            $contents += $newLineToAdd
        }
    }

    $contents -join "`n" | Set-Content $Path
  }
}

function Get-ChefNodeList 
{
  <#
    .SYNOPSIS
      Gets the list of nodes from the chef server

    .DESCRIPTION
      Uses knife to connect to the server and retrieve the node list

    .EXAMPLE
      Get-ChefNodeList -Config .\Client.rb
    
    .EXAMPLE
      Get-ChefNodeList -Config $configObject

    .EXAMPLE
      Get-ChefNodeList
  #>
  [CmdletBinding()]
  param(
    [AllowNull()]
    $Config
  )

  $TemporaryConfigFile = $null
  $ConfigArgument = $null

  try
  {
      if ($Config)
      {
        if ($Config -is [PSObject])
        {
            $TemporaryConfigFile = [IO.Path]::GetRandomFileName()
            Save-ChefClientConfig -InputObject $Config -Path $TemporaryConfigFile
            $Config = $TemporaryConfigFile
        }
        elseif (-not (Test-Path $Config))
        {
            throw "$config is not a valid config object or path to a config file"
        }

        $ConfigArgument = "-c"
      }

      Invoke-Knife node list $ConfigArgument $Config
  }
  finally
  {
      if ($TemporaryConfigFile)
      {
        Remove-Item -Path $TemporaryConfigFile -Force -ErrorAction SilentlyContinue | Out-Null
      }
  }
}

function Export-ChefAzureOhaiHints
{
  <#
    .SYNOPSIS
    Generate Azure Ohai Hints File
  #>
  [CmdletBinding()]
  param(
    [ValidateNotNullOrEmpty()]
    [string]$PathToOhaiHints = 'c:/chef/ohai/hints'
  )

    # There may be some issues with calling Get-CloudServiceRoleInstance, so call it twice to make sure we get the proper object
    Get-CloudServiceRoleInstance -Current -ErrorAction SilentlyContinue | out-Null
    $roleInstance = Get-CloudServiceRoleInstance -Current

    # Because Ohai::Config[:hints_path] is actual ruby code, not a configuration settting, we can't use the ClientRBObject.
    # So just hard code the path here. Alternatively, we could try to read/parse from the client.rb file directly, but that's costly.
    # And since it's ruby code, it might be a non-string (path_to_hints.to_s or something weird like that) that PSH wouldn't know what to do with.
    # This seemed the least hacky way...

    # TL;DR - Important! If the path to \Ohai\Hints ($PathToOhaiHints) is changed, also change it in Client.Rb directly!

    # Azure Ohai Plugin specifically looks for an "azure" hint file (which would be named azure.json)
    New-Item $PathToOhaiHints -Force -ItemType Directory -ErrorAction SilentlyContinue
    $azureJsonFile = Join-Path $PathToOhaiHints "azure.json"

    New-Item -Type Directory -Force -Path $PathToOhaiHints -ErrorAction SilentlyContinue | Out-Null

    $azureHints = @{}
    $azureHints["deployment_id"] = $roleInstance.DeploymentID
    $azureHints["instance_id"] = $roleInstance.Id
    $azureHints["update_domain"] = $roleInstance.UpdateDomain
    $azureHints["fault_domain"] = $roleInstance.FaultDomain
    $azureHints["role"] = $roleInstance.Role.Name

    $azureHints["instance_endpoints"] = @{}
    foreach($endpointKey in $roleInstance.InstanceEndpoints.Keys) {
        $endpoint = $roleInstance.InstanceEndpoints[$endpointKey]

        $azureHints["instance_endpoints"][$endpointKey] = @{
        "ip_endpoint" = Convert-ToStringSafe $endpoint.IPEndpoint
        "public_ip_endpoint" = Convert-ToStringSafe $endpoint.PublicIPEndpoint
        "protocol" = $endpoint.Protocol
        }
    }

    $azureHints["virtual_ip_groups"] = @{}
    foreach($ipGroupKey in $roleInstance.VirtualIPGroups.Keys) {
        $group = $roleInstance.VirtualIPGroups[$ipGroupKey]
        $vip_ip_endpoints = @{}

        foreach($vipEndpointKey in $group.VirtualIPEndpoints.Keys) {
            $vipEndpoint = $group.VirtualIPEndpoints[$vipEndpointKey]
            $vip_instance_endpoints = @{}
            foreach($instanceEndpointKey in $vipEndpoint.InstanceEndpoints.Keys) {
                $instanceEndpoint = $vipEndpoint.InstanceEndpoints[$instanceEndpointKey]
                $vip_instance_endpoints[(Convert-ToStringSafe $instanceEndpointKey)] = @{
                    "ip_endpoint" = Convert-ToStringSafe $instanceEndpoint.IPEndpoint
                    "public_ip_endpoint" = Convert-ToStringSafe $instanceEndpoint.PublicIPEndpoint
                    "protocol" = $instanceEndpoint.Protocol
                }
            }

            $vip_ip_endpoints[(Convert-ToStringSafe $vipEndpointKey)] = @{
                "public_ip_address" = Convert-ToStringSafe $vipEndpoint.PublicIPAddress
                "instance_endpoints" = $vip_instance_endpoints
            }
        }

        $azureHints["virtual_ip_groups"][$ipGroupKey] = @{
            "group_name" = $group.VirtualIPGroupName
            "virtual_ip_endpoints" = $vip_ip_endpoints
        }
    }

    # In my testing, it can go as deep as depth "6". Any less than that and the cmdlet will just call .ToString() on nested collections
    $azureHints | ConvertTo-Json -Depth 6 | Set-Content $azureJsonFile
}

function Convert-ToStringSafe
{
  <#
    .SYPNOSIS
    Quick utility function to prevent things from getting too deserialized (e.g. IPAddress getting each of its properties deserialized)
  #>
  param(
    $value
  )

    if($value -or ($value -eq 0))
    {
        $value.ToString()
    }
    else
    {
        ""
    }
}

# Wrap cmd exe files to make things mockable. Can't use Start-Process because I want the output (Start-Process would write to a file first with -RedirectStandardOutput)
function Invoke-Knife
{
    knife $args
    if ($LASTEXITCODE -ne 0)
    {
        throw "Knife exited with error code: $LASTEXITCODE"
    }
}

function Invoke-SC
{
    sc.exe $args

    if ($LASTEXITCODE -ne 0)
    {
        throw "sc.exe exited with error code: $LASTEXITCODE"
    }
}


# Same with env:path
function Set-Path
{
[CmdletBinding()]
param(
  [ValidateNotNullOrEmpty()]
  [string]$newPath
)

    if (-not $env:Path.Contains($newPath))
    {
        $env:Path += ";$newPath;"
    }
}

Export-ModuleMember Install-ChefClient
Export-ModuleMember Get-ChefClientConfig
Export-ModuleMember Save-ChefClientConfig
Export-ModuleMember Get-ChefNodeList 
Export-ModuleMember Export-ChefAzureOhaiHints