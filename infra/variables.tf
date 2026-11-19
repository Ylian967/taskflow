variable "ghcr_owner" {
  description = "Propriétaire des images sur ghcr.io, en minuscules (ex. ylian967)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.ghcr_owner))
    error_message = "ghcr_owner : minuscules, chiffres et tirets uniquement."
  }
}

variable "image_tag" {
  description = "Tag des images api et front : SHA court du commit ou latest."
  type        = string
  default     = "latest"

  validation {
    condition     = can(regex("^([0-9a-f]{7}|latest)$", var.image_tag))
    error_message = "image_tag : SHA court (7 caractères hexadécimaux) ou latest."
  }
}

variable "front_port" {
  description = "Port publié sur le poste pour le front du staging."
  type        = number
  default     = 8081

  validation {
    condition     = var.front_port >= 1024 && var.front_port <= 65535
    error_message = "front_port doit être compris entre 1024 et 65535."
  }
}

variable "environment" {
  description = "Nom de l'environnement, renvoyé par /health (APP_ENV)."
  type        = string
  default     = "staging"
}

variable "db_password" {
  description = "Mot de passe Postgres. Null : un mot de passe aléatoire est généré. Pour reprendre un volume existant, passer celui qui l'a initialisé."
  type        = string
  default     = null
  sensitive   = true
}

variable "ghcr_username" {
  description = "Utilisateur pour tirer les images privées sur ghcr.io."
  type        = string
  default     = null
}

variable "ghcr_token" {
  description = "Jeton (read:packages) pour tirer les images privées sur ghcr.io."
  type        = string
  default     = null
  sensitive   = true
}
