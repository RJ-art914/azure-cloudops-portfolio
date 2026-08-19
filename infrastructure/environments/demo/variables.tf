variable "location" {
  type        = string
  description = "Primary Azure region for the demo backend."
  default     = "germanywestcentral"
}

variable "static_web_app_location" {
  type        = string
  description = "Azure Static Web Apps deployment region."
  default     = "eastus2"
}

variable "environment" {
  type        = string
  description = "Environment name."
  default     = "demo"
}

variable "project_name" {
  type        = string
  description = "Short project name used for resource naming."
  default     = "cloudops"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags."
  default     = {}
}
