module "eks_module" {
  source   = "../module"
  eks_name = var.eks_name
  vpc_id    = var.vpc_id

}


variable "eks_name" {
  description = "Variable in the main module"
  type        = string
  default     = "testing"
}

variable "vpc_id" {
  description = "Variable in the main module"
  type        = string
  default     = "vpc-0dd2a14e052b80c54"
}

output "eks_module_outputs" {
  value = {
    admin_team                          = module.eks_module.eks_blueprints_admin_team_configure_kubectl
    application_teams_configure_kubectl = module.eks_module.eks_blueprints_dev_teams_configure_kubectl
  }
}

