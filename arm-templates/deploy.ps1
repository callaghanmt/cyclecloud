<#
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER resourceGroupLocation
    Optional, a resource group location. If specified, will try to create a new resource group in this location. If not specified, assumes resource group is existing.

 .PARAMETER deploymentName
    The deployment name.

 .PARAMETER templateFilePath
    Optional, path to the template file. Defaults to create-infrastructure.json.

 .PARAMETER parametersFilePath
    Optional, path to the parameters file. Defaults to parameters.json. If file is not found, will prompt for parameter values based on template.
#>

param(
 [Parameter(Mandatory=$True)]
 [string]
 $subscriptionId,

 [Parameter(Mandatory=$True)]
 [string]
 $resourceGroupName,

 [string]
 $resourceGroupLocation,

 [Parameter(Mandatory=$True)]
 [string]
 $deploymentName,

 [string]
 $templateFilePath = "create-infrastructure.json",

 [string]
 $parametersFilePath = "parameters.json"
)

<#
.SYNOPSIS
    Registers RPs
#>
Function RegisterRP {
    Param(
        [string]$ResourceProviderNamespace
    )

    Write-Host "Registering resource provider '$ResourceProviderNamespace'";
    Register-AzureRmResourceProvider -ProviderNamespace $ResourceProviderNamespace;
}

# Install necessary Azure modules
Uninstall-AzureRm #Conflicts with Az module
Install-Module AzureAD
Install-Module Az -AllowClobber # Allow conflicts with Az.Accounts

# Enable backwards-compatibility with AzureRM
Enable-AzureRmAlias

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

# sign in
Write-Host "Logging in...";
Login-AzureRmAccount;

# select subscription
Write-Host "Selecting subscription '$subscriptionId'";
Select-AzureRmSubscription -SubscriptionID $subscriptionId;

# Register RPs
$resourceProviders = @("microsoft.network","microsoft.storage","microsoft.compute");
if($resourceProviders.length) {
    Write-Host "Registering resource providers"
    foreach($resourceProvider in $resourceProviders) {
        RegisterRP($resourceProvider);
    }
}

#Create or check for existing resource group
$resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if(!$resourceGroup)
{
    Write-Host "Resource group '$resourceGroupName' does not exist. To create a new resource group, please enter a location.";
    if(!$resourceGroupLocation) {
        $resourceGroupLocation = Read-Host "resourceGroupLocation";
    }
    Write-Host "Creating resource group '$resourceGroupName' in location '$resourceGroupLocation'";
    New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation
}
else{
    Write-Host "Using existing resource group '$resourceGroupName'";
}

# Start the deployment
Write-Host "Starting deployment...";
if(Test-Path $parametersFilePath) {
    New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name $deploymentName -TemplateFile $templateFilePath -TemplateParameterFile $parametersFilePath -debug
} else {
    New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name $deploymentName -TemplateFile $templateFilePath -debug
}

# Parse the parameters file to get the VM name out
$parsedParameters = Get-Content -Raw -Path $parametersFilePath | ConvertFrom-Json
$vmName = $parsedParameters.parameters.virtualMachineName.value

# Get the ID of the VM we just created
Connect-AzureAD -Confirm
$vmServicePrincipalId = $(Get-AzureADServicePrincipal -Filter "DisplayName eq '$vmName'").ObjectId

if($vmServicePrincipalId) {
    # Try and assign the role
    try {
        New-AzRoleAssignment -ObjectId $vmServicePrincipalId -RoleDefinitionName Contributor -ResourceGroupName $resourceGroupName
        New-AzRoleAssignment -ObjectId $vmServicePrincipalId -RoleDefinitionName Reader -Scope "/subscriptions/$subscriptionId"
    }
    catch {
        # Unable to assign role - possibly permissions error
        Write-Host "Error assigning Contributor role to VM's Managed Identity Service Principal."
        Write-Host "Ask your Azure Administrator to run the following in their Azure CLI:"
        Write-Host "1) New-AzRoleAssignment -ObjectId $vmServicePrincipalId -RoleDefinitionName Contributor -ResourceGroupName $resourceGroupName"
        Write-Host "2) New-AzRoleAssignment -ObjectId $vmServicePrincipalId -RoleDefinitionName Reader -Scope `"/subscriptions/$subscriptionId`""
    }
}
else {
    # There was a problem getting the SP
    Write-Host "Error getting Managed Identity Service Principal for VM $vmName. "
}