terraform {
  required_providers {
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "3.6.0"
    }
  }
}

provider "keycloak" {
  client_id                = "admin-cli"
  username                 = "admin"
  password                 = "keycloak"
  url                      = "https://keycloak:8443"
  tls_insecure_skip_verify = true
}


resource "keycloak_realm" "realm" {
  realm   = "kubernetes"
  enabled = true
}

resource "keycloak_openid_client" "openid_client" {
  realm_id      = keycloak_realm.realm.id
  client_id     = "kubernetes"
  client_secret = "kubernetes"
  name          = "kubernetes"
  enabled       = true

  access_type = "CONFIDENTIAL"
  valid_redirect_uris = [
    "http://localhost:7070/callback"
  ]
  standard_flow_enabled = true
}

resource "keycloak_user" "testuser" {
  realm_id = keycloak_realm.realm.id
  username = "testuser"
  enabled  = true

  email          = "testuser@test.com"
  email_verified = true
  first_name     = "Alice"
  last_name      = "Aliceberg"

  initial_password {
    value     = "test"
    temporary = false
  }
}
