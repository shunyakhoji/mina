module "kubernetes_testnet" {
  providers = { google = google.gke }
  source    = "../kubernetes/testnet"

  cluster_name   = var.cluster_name
  cluster_region = var.cluster_region
  k8s_context    = var.k8s_context
  testnet_name   = var.testnet_name

  coda_image         = var.coda_image
  coda_archive_image = var.coda_archive_image
  coda_agent_image   = var.coda_agent_image
  coda_bots_image    = var.coda_bots_image
  coda_points_image  = var.coda_points_image

  log_level             = "Trace"
  log_txn_pool_gossip   = true
  log_snark_work_gossip = true

  additional_peers = []
  runtime_config   = var.runtime_config

  seed_zone   = "us-west1-a"
  seed_region = "us-west1"

  archive_node_count  = var.archive_node_count

  snark_worker_replicas   = var.snark_worker_replicas
  snark_worker_fee        = var.snark_worker_fee
  snark_worker_public_key = var.snark_worker_public_key
  snark_worker_host_port  = local.snark_worker_host_port

  block_producer_key_pass = "naughty blue worm"
  block_producer_configs  = [
    for index, config in var.block_producer_configs : {
      name                   = config.name
      id                     = config.id
      class                  = "test",
      external_port          = local.block_producer_starting_host_port + index
      private_key_secret     = config.keypair_secret
      libp2p_secret          = config.libp2p_secret
      isolated               = false
      enable_gossip_flooding = false
      run_with_user_agent    = false
      run_with_bots          = false
      enable_peer_exchange   = true
    }
  ]
}
