# Le staging de TaskFlow, traduction de compose.staging.yaml.
# Mêmes noms qu'avec Compose : réseau taskflow-staging, volume
# taskflow-staging-pgdata (importé, jamais recréé), conteneurs
# taskflow-staging-db|api|front.

locals {
  prefix = "taskflow-${var.environment}"

  # Mot de passe fourni (volume existant) ou, à défaut, généré.
  db_password  = coalesce(var.db_password, random_password.db.result)
  database_url = "postgres://taskflow:${local.db_password}@db:5432/taskflow"
}

# Sans caractères spéciaux : il finit dans l'URL de connexion de l'API.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "docker_network" "this" {
  name = local.prefix
}

resource "docker_volume" "pgdata" {
  name = "${local.prefix}-pgdata"

  # Le volume vient de Compose, qui y a posé ses labels com.docker.compose.*.
  # Sans cette ligne, le plan voudrait le recréer, donc vider la base.
  lifecycle {
    ignore_changes = [labels]
  }
}

# --- Images -----------------------------------------------------------------
# keep_locally : un destroy ne supprime pas les images du poste (la prod
# utilise les mêmes).

resource "docker_image" "db" {
  name         = "docker.io/library/postgres:16-alpine"
  keep_locally = true
}

resource "docker_image" "api" {
  name         = "ghcr.io/${var.ghcr_owner}/taskflow-api:${var.image_tag}"
  keep_locally = true
}

resource "docker_image" "front" {
  name         = "ghcr.io/${var.ghcr_owner}/taskflow-front:${var.image_tag}"
  keep_locally = true
}

# --- Conteneurs ---------------------------------------------------------------
# wait = true attend le healthcheck vert : l'équivalent de
# depends_on: condition: service_healthy dans Compose.

resource "docker_container" "db" {
  name    = "${local.prefix}-db"
  image   = docker_image.db.image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_USER=taskflow",
    "POSTGRES_PASSWORD=${local.db_password}",
    "POSTGRES_DB=taskflow",
  ]

  volumes {
    volume_name    = docker_volume.pgdata.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name    = docker_network.this.name
    aliases = ["db"]
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U taskflow -d taskflow"]
    interval = "10s"
    timeout  = "3s"
    retries  = 10
  }

  wait         = true
  wait_timeout = 120
}

resource "docker_container" "api" {
  name    = "${local.prefix}-api"
  image   = docker_image.api.image_id
  restart = "unless-stopped"

  env = [
    "DATABASE_URL=${local.database_url}",
    "APP_ENV=${var.environment}",
  ]

  # Alias "api" : c'est le nom que front/nginx.conf utilise pour joindre l'API.
  networks_advanced {
    name    = docker_network.this.name
    aliases = ["api"]
  }

  healthcheck {
    test         = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:3000/health || exit 1"]
    interval     = "10s"
    timeout      = "3s"
    retries      = 3
    start_period = "10s"
  }

  wait         = true
  wait_timeout = 120

  depends_on = [docker_container.db]
}

# Seul conteneur qui publie un port.
resource "docker_container" "front" {
  name    = "${local.prefix}-front"
  image   = docker_image.front.image_id
  restart = "unless-stopped"

  ports {
    internal = 80
    external = var.front_port
  }

  networks_advanced {
    name = docker_network.this.name
  }

  healthcheck {
    test         = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/ || exit 1"]
    interval     = "10s"
    timeout      = "3s"
    retries      = 3
    start_period = "5s"
  }

  depends_on = [docker_container.api]
}
