
provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 10
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

variable "eks_name" {
  description = "Variable received from the main module"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

data "aws_vpc" "existing" {
  id   = var.vpc_id
}

locals {
  name   = var.eks_name
  region = "us-west-2"
  vpc_id  = data.aws_vpc.existing.id

  vpc_cidr = "172.31.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}




################################################################################
# Cluster
################################################################################

#tfsec:ignore:aws-eks-enable-control-plane-logging

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15.3"
  cluster_name                   = local.name
  cluster_endpoint_public_access = true
  cluster_endpoint_private_access = true
  cluster_version     = "1.27"
  enable_irsa = true
  vpc_id              = local.vpc_id
  subnet_ids          = aws_subnet.private[*].id

    eks_managed_node_groups = {
    initial = {
      instance_types = ["t2.medium"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }
  create_aws_auth_configmap = false
  manage_aws_auth_configmap = true
  aws_auth_roles = flatten([
    module.eks_blueprints_admin_team.aws_auth_configmap_role,
    [for team in module.eks_blueprints_dev_teams : team.aws_auth_configmap_role],
  ])

  tags = local.tags
}

################################################################################
# EKS Blueprints Teams
################################################################################

module "eks_blueprints_admin_team" {
  source  = "aws-ia/eks-blueprints-teams/aws"
  version = "~> 1.0"

  name = "admin-team"

  enable_admin = true
  users        = [data.aws_caller_identity.current.arn]
  cluster_arn  = module.eks.cluster_arn

  tags = local.tags
}

module "eks_blueprints_dev_teams" {
  source  = "aws-ia/eks-blueprints-teams/aws"
  version = "~> 1.0"

  for_each = {
    red = {
      labels = {
        project = "SuperSecret"
      }
    }
    blue = {}
  }
  name = "team-${each.key}"

  users             = [data.aws_caller_identity.current.arn]
  cluster_arn       = module.eks.cluster_arn
  oidc_provider_arn = module.eks.oidc_provider_arn

  labels = merge(
    {
      team = each.key
    },
    try(each.value.labels, {})
  )

  annotations = {
    team = each.key
  }

  namespaces = {
    "team-${each.key}" = {
      labels = {
        appName     = "${each.key}-team-app",
        projectName = "project-${each.key}",
      }

      resource_quota = {
        hard = {
          "requests.cpu"    = "2000m",
          "requests.memory" = "4Gi",
          "limits.cpu"      = "4000m",
          "limits.memory"   = "16Gi",
          "pods"            = "20",
          "secrets"         = "20",
          "services"        = "20"
        }
      }

      limit_range = {
        limit = [
          {
            type = "Pod"
            max = {
              cpu    = "200m"
              memory = "1Gi"
            }
          },
          {
            type = "PersistentVolumeClaim"
            min = {
              storage = "24M"
            }
          },
          {
            type = "Container"
            default = {
              cpu    = "50m"
              memory = "24Mi"
            }
          }
        ]
      }
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resoruces
################################################################################

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = local.vpc_id
  cidr_block        = "172.31.${count.index + 64}.0/24"
  availability_zone = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    "kubernetes.io/role/elb" = 1,
    "kubernetes.io/cluster/${local.name}" = "owned"
  }
}


# Create subnets, NAT gateway, and route table
resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = local.vpc_id
  cidr_block        = "172.31.${count.index + 69}.0/24"
  availability_zone = local.azs[count.index]

  tags = {
    "kubernetes.io/role/internal-elb" = "1",
    "kubernetes.io/cluster/${local.name}" = "owned"
  }
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public[0].id  # Replace with the desired subnet ID

}

resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_route_table_association" "private_subnet_association" {
  count             = length(aws_subnet.private)
  subnet_id         = aws_subnet.private[count.index].id
  route_table_id    = aws_route_table.private_subnet_route_table.id
  depends_on        = [aws_nat_gateway.nat_gateway]
}

resource "aws_route_table" "private_subnet_route_table" {
  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_gateway.id
  }
}

