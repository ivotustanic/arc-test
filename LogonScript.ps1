Start-Transcript -Path C:\Temp\LogonScript.log

## Deploy AKS EE

# Parameters
$AksEdgeRemoteDeployVersion = "1.6.384.0"
$schemaVersion = "1.1"
$versionAksEdgeConfig = "1.0"
$aksEdgeDeployModules = "main"
$aksEEReleasesUrl = "https://api.github.com/repos/Azure/AKS-Edge/releases"

# Requires -RunAsAdministrator

New-Variable -Name AksEdgeRemoteDeployVersion -Value $AksEdgeRemoteDeployVersion -Option Constant -ErrorAction SilentlyContinue

if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}

if ($env:kubernetesDistribution -eq "k8s") {
    $productName = "AKS Edge Essentials - K8s"
    $networkplugin = "calico"
} else {
    $productName = "AKS Edge Essentials - K3s"
    $networkplugin = "flannel"
}

Write-Host "Fetching the latest AKS Edge Essentials release."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$latestReleaseTag = (Invoke-WebRequest $aksEEReleasesUrl -UseBasicParsing | ConvertFrom-Json)[0].tag_name

$AKSEEReleaseDownloadUrl = "https://github.com/Azure/AKS-Edge/archive/refs/tags/$latestReleaseTag.zip"
$output = Join-Path "C:\temp" "$latestReleaseTag.zip"
Invoke-WebRequest $AKSEEReleaseDownloadUrl -OutFile $output -UseBasicParsing
Expand-Archive $output -DestinationPath "C:\temp" -Force
$AKSEEReleaseConfigFilePath = "C:\temp\AKS-Edge-$latestReleaseTag\tools\aksedge-config.json"
$jsonContent = Get-Content -Raw -Path $AKSEEReleaseConfigFilePath | ConvertFrom-Json
$schemaVersionAksEdgeConfig = $jsonContent.SchemaVersion
# Clean up the downloaded release files
Remove-Item -Path $output -Force
Remove-Item -Path "C:\temp\AKS-Edge-$latestReleaseTag" -Force -Recurse

# Here string for the json fcontent
$aideuserConfig = @"
{
    "SchemaVersion": "$AksEdgeRemoteDeployVersion",
    "Version": "$schemaVersion",
    "AksEdgeProduct": "$productName",
    "AksEdgeProductUrl": "",
    "Azure": {
        "SubscriptionId": "$env:subscriptionId",
        "TenantId": "$env:tenantId",
        "ResourceGroupName": "$env:resourceGroup",
        "Location": "$env:location"
    },
    "AksEdgeConfigFile": "aksedge-config.json"
}
"@

if ($env:windowsNode -eq $true) {
    $aksedgeConfig = @"
{
    "SchemaVersion": "$schemaVersionAksEdgeConfig",
    "Version": "$versionAksEdgeConfig",
    "DeploymentType": "SingleMachineCluster",
    "Init": {
        "ServiceIPRangeSize": 0
    },
    "Network": {
        "NetworkPlugin": "$networkplugin",
        "InternetDisabled": false
    },
    "User": {
        "AcceptEula": true,
        "AcceptOptionalTelemetry": true
    },
    "Machines": [
        {
            "LinuxNode": {
                "CpuCount": 8,
                "MemoryInMB": 16384,
                "DataSizeInGB": 30
            },
            "WindowsNode": {
                "CpuCount": 2,
                "MemoryInMB": 4096
            }
        }
    ]
}
"@
} else {
    $aksedgeConfig = @"
{
    "SchemaVersion": "$schemaVersionAksEdgeConfig",
    "Version": "$versionAksEdgeConfig",
    "DeploymentType": "SingleMachineCluster",
    "Init": {
        "ServiceIPRangeSize": 10
    },
    "Network": {
        "NetworkPlugin": "$networkplugin",
        "InternetDisabled": false
    },
    "User": {
        "AcceptEula": true,
        "AcceptOptionalTelemetry": true
    },
    "Machines": [
        {
            "LinuxNode": {
                "CpuCount": 8,
                "MemoryInMB": 16384,
                "DataSizeInGB": 30
            }
        }
    ]
}
"@
}

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge
$url = "https://github.com/Azure/AKS-Edge/archive/$aksEdgeDeployModules.zip"
$zipFile = "$aksEdgeDeployModules.zip"
$installDir = "C:\AksEdgeScript"
$workDir = "$installDir\AKS-Edge-main"

if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
}

Push-Location $installDir

Write-Host "`n"
Write-Host "About to silently install AKS Edge Essentials, this will take a few minutes." -ForegroundColor Green
Write-Host "`n"

try {
    function download2() { $ProgressPreference = "SilentlyContinue"; Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installDir\$zipFile }
    download2
}
catch {
    Write-Host "Error: Downloading Aide Powershell Modules failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

if (!(Test-Path -Path "$workDir")) {
    Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
}

$aidejson = (Get-ChildItem -Path "$workDir" -Filter aide-userconfig.json -Recurse).FullName
Set-Content -Path $aidejson -Value $aideuserConfig -Force
$aksedgejson = (Get-ChildItem -Path "$workDir" -Filter aksedge-config.json -Recurse).FullName
Set-Content -Path $aksedgejson -Value $aksedgeConfig -Force

$aksedgeShell = (Get-ChildItem -Path "$workDir" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# Download, install and deploy AKS EE 
Write-Host "Step 2: Download, install and deploy AKS Edge Essentials"
# invoke the workflow, the json file already stored above.
$retval = Start-AideWorkflow -jsonFile $aidejson
# report error via Write-Error for Intune to show proper status
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Error -Message "Deployment failed" -Category OperationStopped
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

if ($env:windowsNode -eq $true) {
    # Get a list of all nodes in the cluster
    $nodes = kubectl get nodes -o json | ContFrom-Json

    # Loop through each node and check the OSImage field
    foreach ($node in $nodes.items) {
        $os = $node.status.nodeInfo.osImage
        if ($os -like '*windows*') {
            # If the OSImage field contains "windows", assign the "worker" role
            kubectl label nodes $node.metadata.name node-role.kubernetes.io/worker=worker
        }
    }
}

Write-Host "`n"
Write-Host "Checking kubernetes nodes"
Write-Host "`n"
kubectl get nodes -o wide | Write-Host
Write-Host "`n"

Write-Host "Prep for AIO workload deployment" -ForegroundColor Cyan
Write-Host "Deploy local path provisioner"
try {
    $localPathProvisionerYaml= (Get-ChildItem -Path "$workdir" -Filter local-path-storage.yaml -Recurse).FullName
    kubectl apply -f $localPathProvisionerYaml | Write-Host
    Write-Host "Successfully deployment the local path provisioner from $localPathProvisionerYaml"
}
catch {
    Write-Host "Error: local path provisioner deployment failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Configuring firewall specific to AIO"
try {
    $fireWallRuleExists = Get-NetFirewallRule -DisplayName "AIO MQTT Broker"  -ErrorAction SilentlyContinue
    if ( $null -eq $fireWallRuleExists ) {
        Write-Host "Add firewall rule for AIO MQTT Broker"
        New-NetFirewallRule -DisplayName "AIO MQTT Broker" -Direction Inbound -Action Allow | Out-Null
    }
    else {
        Write-Host "firewall rule for AIO MQTT Broker exists, skip configuring firewall rule..."
    }   
}
catch {
    Write-Host "Error: Firewall rule addition for AIO MQTT broker failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Configuring port proxy for AIO"
try {
    $deploymentInfo = Get-AksEdgeDeploymentInfo
    # Get the service ip address start to determine the connect address
    $connectAddress = $deploymentInfo.LinuxNodeConfig.ServiceIpRange.split("-")[0]
    $portProxyRulExists = netsh interface portproxy show v4tov4 | findstr /C:"1883" | findstr /C:"$connectAddress"
    if ( $null -eq $portProxyRulExists ) {
        Write-Host "Configure port proxy for AIO"
        netsh interface portproxy add v4tov4 listenport=1883 listenaddress=0.0.0.0 connectport=1883 connectaddress=$connectAddress | Out-Null
    }
    else {
        Write-Host "Port proxy rule for AIO exists, skip configuring port proxy..."
    } 
}
catch {
    Write-Host "Error: port proxy update for AIO failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Update the iptables rules"
try {
    $iptableRulesExist = Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables-save | grep -- '-m tcp --dport 9110 -j ACCEPT'" -ignoreError
    if ( $null -eq $iptableRulesExist ) {
        Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 9110 -j ACCEPT"
        Write-Host "Updated runtime iptable rules for node exporter"
        Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i '/-A OUTPUT -j ACCEPT/i-A INPUT -p tcp -m tcp --dport 9110 -j ACCEPT' /etc/systemd/scripts/ip4save"
        Write-Host "Persisted iptable rules for node exporter"
    }
    else {
        Write-Host "iptable rule exists, skip configuring iptable rules..."
    } 
}
catch {
    Write-Host "Error: iptable rule update failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}



# az version
az -v

# Login as service principal
az login --service-principal --username $Env:appId --password=$Env:password --tenant $Env:tenantId

# Set default subscription to run commands against
# "subscriptionId" value comes from clientVM.json ARM template, based on which 
# subscription user deployed ARM template to. This is needed in case Service 
# Principal has access to multiple subscriptions, which can break the automation logic
az account set --subscription $Env:subscriptionId

# Installing Azure CLI extensions
# Making extension install dynamic
az config set extension.use_dynamic_install=yes_without_prompt
Write-Host "`n"
Write-Host "Installing Azure CLI extensions"
az extension add --name connectedk8s
az extension add --name k8s-extension
Write-Host "`n"

# Registering Azure Arc providers
Write-Host "Registering Azure Arc providers, hold tight..."
Write-Host "`n"
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait

# Onboarding the cluster to Azure Arc
Write-Host "Onboarding the AKS Edge Essentials cluster to Azure Arc..."
Write-Host "`n"

$Env:arcClusterName = "$Env:clusterName"

# https://github.com/Azure/azure-cli-extensions/issues/6637
Invoke-WebRequest -Uri https://secure.globalsign.net/cacert/Root-R1.crt -OutFile c:\globalsignR1.crt
Import-Certificate -FilePath c:\globalsignR1.crt -CertStoreLocation Cert:\LocalMachine\Root

if ($env:kubernetesDistribution -eq "k8s") {
    az connectedk8s connect --name $Env:arcClusterName `
    --resource-group $Env:resourceGroup `
    --location $env:location `
    --custom-locations-oid 51dfe1e8-70c6-4de5-a08e-e18aff23d815 `
    --onboarding-timeout 1200 `
    --distribution aks_edge_k8s | Write-Host
} else {
    az connectedk8s connect --name $Env:arcClusterName `
    --resource-group $Env:resourceGroup `
    --location $env:location `
    --custom-locations-oid 51dfe1e8-70c6-4de5-a08e-e18aff23d815 `
    --onboarding-timeout 1200 `
    --distribution aks_edge_k3s | Write-Host
}

# enable features
az connectedk8s enable-features --name $Env:arcClusterName --resource-group $Env:resourceGroup --features cluster-connect custom-locations --custom-locations-oid 51dfe1e8-70c6-4de5-a08e-e18aff23d815

Stop-Transcript
exit 0