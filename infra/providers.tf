# Le provider parle au Docker local (socket par défaut).
# Si un jeton ghcr.io est fourni (dans le pipeline : GITHUB_TOKEN), il sert à
# tirer les images. Il configure le provider et n'est pas écrit dans le state.
provider "docker" {
  dynamic "registry_auth" {
    for_each = var.ghcr_token == null ? [] : [1]
    content {
      address  = "ghcr.io"
      username = var.ghcr_username
      password = var.ghcr_token
    }
  }
}
