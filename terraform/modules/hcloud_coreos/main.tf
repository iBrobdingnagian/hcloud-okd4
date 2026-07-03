resource "hcloud_server" "server" {
  count       = var.instance_count
  name        = "${format("${var.name}%02d", count.index + 1)}.${var.dns_domain}"
  image       = var.image
  server_type = var.server_type
  keep_disk   = var.keep_disk
  ssh_keys    = var.ssh_keys
  user_data = templatefile("${path.module}/templates/ignition.ign", {
    hostname         = format("%s%02d.%s", var.name, count.index + 1, var.dns_domain)
    hostname_b64     = base64encode(format("%s%02d.%s", var.name, count.index + 1, var.dns_domain))
    resolvconf_b64   = base64encode(file("${path.module}/templates/resolv.conf"))
    ignition_url     = var.ignition_url
    ignition_version = var.ignition_version
    ignition_cacert  = var.ignition_cacert
  })
  location     = var.location
  labels       = var.labels
  backups      = var.backups
  firewall_ids = var.firewall_ids
  lifecycle {
    # `location` is create-only (forces replacement). The hcloud API can report a
    # null datacenter/location for an already-running server, which the provider
    # stores as "" and never repopulates on refresh; comparing that to the
    # configured location then looks like a change and would destroy+recreate a
    # live node on the next apply. These are immutable cattle (we already ignore
    # image drift for the same reason) — ignore location so the node is not
    # replaced out from under a running cluster.
    ignore_changes = [user_data, image, firewall_ids, location]
  }
}

resource "hcloud_rdns" "dns-ptr-ipv4" {
  count      = var.instance_count
  server_id  = element(hcloud_server.server.*.id, count.index)
  ip_address = element(hcloud_server.server.*.ipv4_address, count.index)
  dns_ptr    = element(hcloud_server.server.*.name, count.index)
}

resource "hcloud_rdns" "dns-ptr-ipv6" {
  count      = var.instance_count
  server_id  = element(hcloud_server.server.*.id, count.index)
  ip_address = "${element(hcloud_server.server.*.ipv6_address, count.index)}1"
  dns_ptr    = element(hcloud_server.server.*.name, count.index)
}
