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

variable "feeds" {
  type    = list(string)
  default = ["customers", "plans", "subscription_events", "payments", "feature_usage"]
}

variable "monthly_credit_quota" {
  type = object({
    transform = number
    bi        = number
  })
  default = {
    transform = 300
    bi        = 200
  }
}

variable "notify_users" {
  type        = list(string)
  description = "Snowflake users e-mailed by resource monitors."
  default     = []
}
