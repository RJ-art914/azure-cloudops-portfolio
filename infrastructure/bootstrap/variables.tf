variable "resource_group_name" {
  type        = string
  description = "Resource group for Terraform state."
  default     = "rg-cloudops-tfstate"
}

variable "location" {
  type        = string
  description = "Azure region for Terraform state resources."
  default     = "germanywestcentral"
}

variable "tags" {
  type        = map(string)
  description = "Common tags."
  default = {
    project     = "azure-cloudops-portfolio"
    environment = "shared"
    managed_by  = "terraform"
    purpose     = "terraform-state"
  }
}
