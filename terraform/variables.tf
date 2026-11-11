variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "landing_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for the landing zone."
}

variable "monthly_credit_quota" {
  type = object({
    transform = number
    bi        = number
  })
  description = "Monthly credits per workload monitor. Warehouses suspend at 100%."
  default = {
    transform = 300
    bi        = 200
  }
}

variable "warehouse_size_override" {
  type        = string
  description = "If set (e.g. XSMALL on a trial account), every warehouse uses this size."
  default     = null
}

variable "bi_max_clusters" {
  type        = number
  description = "Multi-cluster ceiling for BI_WH (Enterprise edition). 1 disables scale-out."
  default     = 3
}

variable "dbt_public_key_path" {
  type        = string
  description = "Path to the PEM public key for the SVC_DBT service user (the private key never leaves your machine / GitHub secret)."
}

variable "notify_users" {
  type        = list(string)
  description = "Snowflake users e-mailed by resource monitors."
  default     = []
}

variable "admin_user" {
  type        = string
  description = "Your human admin user. Gets the BI/PII roles so you can test masking and row access (make sf-verify)."
}

variable "force_destroy_bucket" {
  type        = bool
  description = "Let terraform destroy delete a non-empty landing bucket. Only for throwaway/trial setups."
  default     = false
}
