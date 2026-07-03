resource "hcloud_load_balancer" "lb" {
  name               = "lb.${var.dns_domain}"
  load_balancer_type = "lb11"
  location           = var.location
  dynamic "target" {
    for_each = concat(module.master.server_ids, module.worker.server_ids, module.bootstrap.server_ids)
    content {
      type      = "server"
      server_id = target.value
    }
  }
}

resource "hcloud_load_balancer_network" "lb_network" {
  load_balancer_id = hcloud_load_balancer.lb.id
  subnet_id        = hcloud_network_subnet.lb_subnet.id
  ip               = "192.168.254.254"
}

resource "hcloud_load_balancer_service" "lb_api" {
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  # HTTP(S) health check against the kube-apiserver readiness endpoint instead of a
  # bare TCP connect. During bootstrap the masters' apiservers open :6443 long before
  # they can serve requests (etcd/cert rollout restarts them repeatedly); a TCP-only
  # check marks those backends healthy, so the LB round-robins clients onto a socket
  # that accepts then immediately closes the connection -> "EOF" on the client. Probing
  # /readyz (200 only when the apiserver is actually ready) keeps not-ready masters out
  # of rotation until they can serve. `tls = true` speaks HTTPS; hcloud does not verify
  # the apiserver's self-signed cert, so no CA wiring is needed.
  health_check {
    protocol = "http"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
    http {
      path         = "/readyz"
      tls          = true
      status_codes = ["200"]
    }
  }
}

resource "hcloud_load_balancer_service" "lb_mcs" {
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = 22623
  destination_port = 22623

  health_check {
    protocol = "tcp"
    port     = 22623
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "lb_ingress_http" {
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "lb_ingress_https" {
  load_balancer_id = hcloud_load_balancer.lb.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
