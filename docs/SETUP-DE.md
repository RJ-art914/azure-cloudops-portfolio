# Einrichtung – Azure CloudOps Portfolio Lab

## 1. Benötigte Programme

Installieren Sie lokal:

- Visual Studio Code
- Git
- Azure CLI
- Terraform
- Python 3.12
- Azure Functions Core Tools v4
- Node.js (für die Azure Static Web Apps CLI)

Prüfen Sie danach im Terminal:

```bash
git --version
az version
terraform version
python --version
func --version
node --version
npm --version
```

## 2. Azure-Anmeldung

```bash
az login
az account list --output table
```

Falls Sie mehrere Subscriptions besitzen:

```bash
az account set --subscription "IHRE-SUBSCRIPTION-ID"
```

Prüfen:

```bash
az account show --output table
```

## 3. Projekt in VS Code öffnen

Öffnen Sie den Ordner `azure-cloudops-portfolio` in VS Code.

## 4. Automatische Bereitstellung

### Windows PowerShell

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./scripts/deploy.ps1
```

### macOS/Linux

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

Das Script führt aus:

1. Azure-Login prüfen
2. Terraform State Storage einmalig erzeugen
3. Remote Backend initialisieren
4. Demo-Infrastruktur planen und bereitstellen
5. API-URL ins Frontend schreiben
6. Python Function veröffentlichen
7. Static Web App veröffentlichen
8. URLs ausgeben

## 5. GitHub Repository erzeugen

Im Projektordner:

```bash
git init
git add .
git commit -m "feat: initial Azure CloudOps portfolio foundation"
git branch -M main
```

Erzeugen Sie auf GitHub ein **öffentliches Repository** namens:

`azure-cloudops-portfolio`

Danach:

```bash
git remote add origin https://github.com/IHR-GITHUB-NAME/azure-cloudops-portfolio.git
git push -u origin main
```

## 6. Kostenkontrolle

Lassen Sie zunächst nur diese Demo-Umgebung bestehen. Die spätere Netzwerk-/Container-Lab-Umgebung wird separat aufgebaut und nach Übungen mit `terraform destroy` entfernt.

## 7. Demo-Umgebung später aktualisieren

```bash
cd infrastructure/environments/demo
terraform plan -out=demo.tfplan
terraform apply demo.tfplan
```

Für Codeänderungen der Function:

```bash
cd app/api
func azure functionapp publish FUNCTION_APP_NAME
```

Für Frontendänderungen wird später die GitHub-Actions-Pipeline automatisiert. Bis dahin können Sie erneut `scripts/deploy.ps1` bzw. `scripts/deploy.sh` ausführen.
