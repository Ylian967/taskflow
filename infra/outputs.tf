output "url" {
  description = "Adresse du front du staging."
  value       = "http://localhost:${var.front_port}"
}

output "health_url" {
  description = "Adresse de /health (passe par le Nginx du front)."
  value       = "http://localhost:${var.front_port}/health"
}

output "image_tag" {
  description = "Version déployée."
  value       = var.image_tag
}

output "containers" {
  description = "Noms des conteneurs."
  value       = [docker_container.db.name, docker_container.api.name, docker_container.front.name]
}

output "network" {
  description = "Réseau du staging."
  value       = docker_network.this.name
}
