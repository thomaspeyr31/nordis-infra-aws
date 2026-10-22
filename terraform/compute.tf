# =============================================================================
# compute.tf - Instances EC2 du projet Nordis Distribution (module A2627_5066)
# Auteur  : Thomas Peyrusaubes
# Version : 1.1 - 2026-10-21
#
# Une instance par machine du DAT (FW01 est dans vpc.tf).
# Tailles limitées aux types autorisés : t3.micro, t3.medium, t3.large.
# Aucune IP publique : on y accède par le VPN de FW01.
# =============================================================================

variable "cle_ssh" {
  description = "Nom de la paire de clés EC2 (créée dans la console, région Paris)"
  type        = string
}

variable "avec_mon01" {
  description = "Créer MON01 (bonus supervision)"
  type        = bool
  default     = false
}

# --- IMAGES (dernière version publiée au premier déploiement) ---
data "aws_ami" "ws2025_gui" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Full-Base-*"]
  }
}

data "aws_ami" "ws2025_core" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Core-Base-*"]
  }
}

data "aws_ami" "debian13" {
  most_recent = true
  owners      = ["136693071363"] # compte officiel Debian

  filter {
    name   = "name"
    values = ["debian-13-amd64-*"]
  }
}

# --- MACHINES DU DAT ---
# os      = taille du disque système (Go)
# donnees = disques de données EBS (Go)
locals {
  instances = merge({
    DC01 = {
      ami    = data.aws_ami.ws2025_gui.id, type = "t3.medium", windows = true
      subnet = aws_subnet.sn_serveurs.id, ip = "10.50.10.10", os = 40, donnees = []
    }
    DC02 = {
      ami    = data.aws_ami.ws2025_core.id, type = "t3.medium", windows = true
      subnet = aws_subnet.sn_serveurs.id, ip = "10.50.10.12", os = 30, donnees = []
    }
    SRV02 = { # 2 disques en miroir (Storage Spaces) -> lecteur E:
      ami    = data.aws_ami.ws2025_core.id, type = "t3.large", windows = true
      subnet = aws_subnet.sn_serveurs.id, ip = "10.50.10.11", os = 30, donnees = [30, 30]
    }
    LNX01 = { # 3 disques en RAID 5 (mdadm) + LVM
      ami    = data.aws_ami.debian13.id, type = "t3.micro", windows = false
      subnet = aws_subnet.sn_serveurs.id, ip = "10.50.10.20", os = 10, donnees = [10, 10, 10]
    }
    LNX02 = { # intranet nginx (DMZ)
      ami    = data.aws_ami.debian13.id, type = "t3.micro", windows = false
      subnet = aws_subnet.sn_dmz.id, ip = "10.50.20.21", os = 10, donnees = []
    }
    CLI01 = { # poste d'admin : Windows 11 n'existe pas sur EC2 -> WS 2025 + RSAT
      ami    = data.aws_ami.ws2025_gui.id, type = "t3.medium", windows = true
      subnet = aws_subnet.sn_management.id, ip = "10.50.99.10", os = 40, donnees = []
    }
    }, var.avec_mon01 ? {
    MON01 = {
      ami    = data.aws_ami.debian13.id, type = "t3.medium", windows = false
      subnet = aws_subnet.sn_serveurs.id, ip = "10.50.10.30", os = 20, donnees = []
    }
  } : {})

  # Un élément par disque de données : "SRV02-1", "LNX01-3"...
  lettres = ["f", "g", "h"]
  volumes = merge([
    for nom, vm in local.instances : {
      for i, taille in vm.donnees : "${nom}-${i + 1}" => {
        vm     = nom
        taille = taille
        periph = vm.windows ? "xvd${local.lettres[i]}" : "/dev/sd${local.lettres[i]}"
      }
    }
  ]...)
}

# --- INSTANCES ---
resource "aws_instance" "vm" {
  for_each = local.instances

  ami                         = each.value.ami
  instance_type               = each.value.type
  subnet_id                   = each.value.subnet
  private_ip                  = each.value.ip
  key_name                    = var.cle_ssh
  vpc_security_group_ids      = [aws_security_group.sg_internal_default.id]
  associate_public_ip_address = false

  # Premier démarrage : nom de la machine et fuseau horaire
  user_data = each.value.windows ? join("\n", [
    "<powershell>",
    "Set-TimeZone -Id 'Romance Standard Time'",
    "Rename-Computer -NewName '${each.key}' -Force -Restart",
    "</powershell>",
    ]) : join("\n", [
    "#cloud-config",
    "hostname: ${lower(each.key)}",
    "fqdn: ${lower(each.key)}.ad.nordis.test",
    "timezone: Europe/Paris",
  ])

  root_block_device {
    volume_size = each.value.os
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 uniquement
  }

  # Une nouvelle image AWS ne doit jamais recréer un DC existant
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = {
    Name = each.key
  }
}

# --- DISQUES DE DONNEES ---
resource "aws_ebs_volume" "donnees" {
  for_each = local.volumes

  availability_zone = local.az
  size              = each.value.taille
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${each.key}-donnees"
  }
}

resource "aws_volume_attachment" "donnees" {
  for_each = local.volumes

  device_name = each.value.periph
  volume_id   = aws_ebs_volume.donnees[each.key].id
  instance_id = aws_instance.vm[each.value.vm].id
}

# --- SORTIES ---
output "fw01_ip_publique" {
  description = "IP publique de FW01 (VPN et interface web OPNsense)"
  value       = aws_eip.fw01.public_ip
}

output "ip_privees" {
  description = "IP privée de chaque machine"
  value       = { for nom, vm in aws_instance.vm : nom => vm.private_ip }
}
