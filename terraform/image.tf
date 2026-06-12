data "hcloud_image" "image" {
  with_selector = var.fcos_release != "" ? "os=${var.image},image_type=generic,fcos_release=${var.fcos_release}" : "os=${var.image},image_type=generic"
  with_status   = ["available"]
  most_recent   = true
}
