locals {
  # A complete cold restore boots every node from its own image. The original
  # Packer base image may have been removed and is not needed for this path.
  required_node_names = concat(
    [for i in range(var.replicas_master) : format("master%02d.%s", i + 1, var.dns_domain)],
    [for i in range(var.replicas_worker) : format("worker%02d.%s", i + 1, var.dns_domain)]
  )
  complete_snapshot_restore = !var.bootstrap && length(var.restore_nodes) > 0 && alltrue([
    for name in local.required_node_names : contains(keys(var.restore_nodes), name)
  ])
  # The fallback is unused by restored nodes but is required by the shared
  # module interface (including the zero-count bootstrap module).
  node_base_image = local.complete_snapshot_restore ? values(var.restore_nodes)[0].image : data.hcloud_image.image[0].id
}

data "hcloud_image" "image" {
  count         = local.complete_snapshot_restore ? 0 : 1
  with_selector = var.fcos_release != "" ? "os=${var.image},image_type=generic,fcos_release=${var.fcos_release}" : "os=${var.image},image_type=generic"
  with_status   = ["available"]
  most_recent   = true
}
