# Versions d'OpenTofu et des providers.
# Le backend "local" est volontairement vide : le chemin du state est donné à
# l'init (-backend-config="path=$STAGING_DIR/terraform.tfstate"). Le state
# contient le mot de passe de la base, il ne doit jamais arriver dans Git.
terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "local" {}
}
