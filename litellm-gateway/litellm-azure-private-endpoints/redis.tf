###############################################################################
#  Self-contained Redis (LiteLLM router cache) — runs as a PRIVATE Container App
#  in the same ACA environment, reachable only over the internal load balancer
#  (external_enabled = false, TCP). It gives every LiteLLM replica a SHARED
#  view of cooldowns / rate-limit + usage counters so load balancing and 429
#  failover stay correct when litellm_max_replicas > 1 — without a (pricey,
#  Premium-tier-for-private-endpoint) Azure Cache for Redis.
#
#  Redis here is an EPHEMERAL cache only: it holds throwaway routing counters.
#  All durable state (virtual keys, teams, budgets, spend) lives in PostgreSQL,
#  so a Redis restart is harmless (LiteLLM rebuilds cooldown state and, if Redis
#  is briefly unavailable, falls back to per-replica in-memory state).
###############################################################################

resource "random_password" "redis" {
  count   = var.enable_redis ? 1 : 0
  length  = 32
  special = false # avoid shell-quoting issues in the redis-server command
}

resource "azurerm_container_app" "redis" {
  count                        = var.enable_redis ? 1 : 0
  name                         = "ca-redis-${local.suffix}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  secret {
    name  = "redis-password"
    value = random_password.redis[0].result
  }

  # Internal (VNet-only) TCP ingress on 6379 — never exposed publicly.
  ingress {
    external_enabled = false
    target_port      = 6379
    exposed_port     = 6379
    transport        = "tcp"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Single Redis instance (the shared cache). It is a single point of failure
    # by design; acceptable because it only holds ephemeral routing state.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "redis"
      image  = var.redis_image
      cpu    = var.redis_cpu
      memory = var.redis_memory

      # Shell form so the password env var is expanded reliably.
      command = [
        "sh", "-c",
        "redis-server --requirepass \"$REDIS_PASSWORD\" --maxmemory ${var.redis_maxmemory} --maxmemory-policy allkeys-lru",
      ]

      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-password"
      }
    }
  }
}
