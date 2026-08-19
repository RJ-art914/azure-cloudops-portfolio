$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BootstrapDir = Join-Path $RootDir "infrastructure\bootstrap"
$DemoDir = Join-Path $RootDir "infrastructure\environments\demo"
$ApiDir = Join-Path $RootDir "app\api"
$FrontendDir = Join-Path $RootDir "app\frontend"

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' ist nicht installiert oder nicht im PATH."
    }
}

@("az", "terraform", "python", "func", "node", "npm") | ForEach-Object { Assert-Command $_ }

try {
    az account show | Out-Null
} catch {
    Write-Host "Azure-Anmeldung erforderlich. Starte az login..." -ForegroundColor Yellow
    az login | Out-Null
}

$SubscriptionId = (az account show --query id -o tsv).Trim()
$TenantId = (az account show --query tenantId -o tsv).Trim()
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

Write-Host "Azure Subscription: $SubscriptionId" -ForegroundColor Cyan

Write-Host "[1/6] Terraform Remote State bootstrap..." -ForegroundColor Cyan
Push-Location $BootstrapDir
terraform init -upgrade
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
$StateRg = (terraform output -raw resource_group_name).Trim()
$StateStorage = (terraform output -raw storage_account_name).Trim()
$StateContainer = (terraform output -raw container_name).Trim()
Pop-Location

Write-Host "Warte kurz auf RBAC-Propagation..." -ForegroundColor DarkGray
Start-Sleep -Seconds 15

Write-Host "[2/6] Demo-Backend initialisieren..." -ForegroundColor Cyan
$env:ARM_USE_AZUREAD = "true"
$env:ARM_USE_CLI = "true"
Push-Location $DemoDir
terraform init -upgrade -reconfigure `
    -backend-config="resource_group_name=$StateRg" `
    -backend-config="storage_account_name=$StateStorage" `
    -backend-config="container_name=$StateContainer" `
    -backend-config="key=demo.terraform.tfstate" `
    -backend-config="use_azuread_auth=true" `
    -backend-config="use_cli=true" `
    -backend-config="tenant_id=$TenantId"

terraform fmt -recursive $RootDir\infrastructure
terraform validate
terraform plan -out=demo.tfplan

Write-Host "[3/6] Demo-Infrastruktur bereitstellen..." -ForegroundColor Cyan
terraform apply demo.tfplan

$FunctionAppName = (terraform output -raw function_app_name).Trim()
$ApiBaseUrl = (terraform output -raw api_base_url).Trim()
$SwaName = (terraform output -raw static_web_app_name).Trim()
$FrontendUrl = (terraform output -raw frontend_url).Trim()
$ResourceGroup = (terraform output -raw resource_group_name).Trim()
Pop-Location

Write-Host "[4/6] API-URL ins Frontend schreiben..." -ForegroundColor Cyan
@"
window.CLOUDOPS_CONFIG = {
  apiBaseUrl: "$ApiBaseUrl"
};
"@ | Set-Content -Path (Join-Path $FrontendDir "config.js") -Encoding UTF8

Write-Host "[5/6] Azure Functions API veröffentlichen..." -ForegroundColor Cyan
Push-Location $ApiDir
func azure functionapp publish $FunctionAppName --python --build remote
Pop-Location

Write-Host "[6/6] Azure Static Web App veröffentlichen..." -ForegroundColor Cyan
$DeploymentToken = (az staticwebapp secrets list --name $SwaName --resource-group $ResourceGroup --query properties.apiKey -o tsv).Trim()
$env:SWA_CLI_DEPLOYMENT_TOKEN = $DeploymentToken
Push-Location $RootDir
npx -y @azure/static-web-apps-cli deploy $FrontendDir --env production
Pop-Location
Remove-Item Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue
$DeploymentToken = $null

Write-Host "" 
Write-Host "Bereitstellung abgeschlossen." -ForegroundColor Green
Write-Host "Frontend: $FrontendUrl"
Write-Host "API:      $ApiBaseUrl"
Write-Host ""
Write-Host "Health-Test:" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$ApiBaseUrl/health" | ConvertTo-Json -Depth 5
} catch {
    Write-Warning "Health-Test war noch nicht erfolgreich. Prüfen Sie die Function App Logs, falls dies nach kurzer Zeit weiterhin so bleibt."
}
