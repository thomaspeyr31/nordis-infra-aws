# =============================================================================
# vpc.tf - Réseau du projet Nordis Distribution (module A2627_5066)
# Auteur  : Thomas Peyrusaubes
# Version : 1.1 - 2026-10-21
#
# VPC 10.50.0.0/16 : 1 sous-réseau public (WAN de FW01), 1 sous-réseau
# d'inspection (LAN de FW01) et 6 sous-réseaux privés (ex-VLAN).
# Tout le trafic des sous-réseaux privés (Internet ET entre sous-réseaux)
# passe par FW01 grâce aux tables de routage.
# =============================================================================

locals {
  # Une seule zone : les deux interfaces de FW01 doivent être dans la
  # même zone de disponibilité que l'instance.
  az = "eu-west-3a"

  # Sous-réseaux privés (ex-VLAN) : chacun aura sa propre table de routage.
  sous_reseaux_prives = {
    serveurs          = aws_subnet.sn_serveurs
    dmz               = aws_subnet.sn_dmz
    management        = aws_subnet.sn_management
    postes_admin      = aws_subnet.sn_postes_admin
    postes_commercial = aws_subnet.sn_postes_commercial
    postes_logistique = aws_subnet.sn_postes_logistique
  }
}

# --- VPC PRINCIPAL ---
resource "aws_vpc" "nordis_vpc" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vpc-nordis"
  }
}

# --- INTERNET GATEWAY ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.nordis_vpc.id

  tags = {
    Name = "igw-nordis"
  }
}

# --- JEU D'OPTIONS DHCP ---
# DNS et NTP = FW01 (Unbound renvoie ad.nordis.test vers DC01/DC02).
# Les IP des instances sont données par AWS (pas de DHCP Windows).
resource "aws_vpc_dhcp_options" "nordis" {
  domain_name         = "ad.nordis.test"
  domain_name_servers = ["10.50.0.20"]
  ntp_servers         = ["10.50.0.20"]

  tags = {
    Name = "dopt-nordis"
  }
}

resource "aws_vpc_dhcp_options_association" "nordis" {
  vpc_id          = aws_vpc.nordis_vpc.id
  dhcp_options_id = aws_vpc_dhcp_options.nordis.id
}

# --- SUBNETS ---
# 1. Sous-réseau public : interface WAN de FW01 (seule IP publique du lab)
resource "aws_subnet" "sn_firewall" {
  vpc_id                  = aws_vpc.nordis_vpc.id
  cidr_block              = "10.50.0.0/28"
  availability_zone       = local.az
  map_public_ip_on_launch = false # l'IP publique de FW01 est une Elastic IP

  tags = {
    Name = "sn-public-fw"
  }
}

# 2. Sous-réseau d'inspection : interface LAN de FW01.
#    Il doit être séparé des sous-réseaux privés, sinon AWS refuse de faire
#    passer le trafic entre sous-réseaux par FW01.
resource "aws_subnet" "sn_inspection" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.0.16/28"
  availability_zone = local.az

  tags = {
    Name = "sn-inspection-fw"
  }
}

# 3. Sous-réseaux privés (ex-VLAN)
resource "aws_subnet" "sn_serveurs" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.10.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-serveurs-vlan10"
  }
}

resource "aws_subnet" "sn_dmz" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.20.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-dmz-vlan20"
  }
}

resource "aws_subnet" "sn_management" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.99.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-management-vlan99"
  }
}

resource "aws_subnet" "sn_postes_admin" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.30.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-postes-admin-vlan30"
  }
}

resource "aws_subnet" "sn_postes_commercial" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.40.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-postes-commercial-vlan40"
  }
}

resource "aws_subnet" "sn_postes_logistique" {
  vpc_id            = aws_vpc.nordis_vpc.id
  cidr_block        = "10.50.50.0/24"
  availability_zone = local.az

  tags = {
    Name = "sn-postes-logistique-vlan50"
  }
}

# --- TABLES DE ROUTAGE ---
# Public : sortie Internet directe par l'Internet Gateway
resource "aws_route_table" "rt_public" {
  vpc_id = aws_vpc.nordis_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "rtb-public"
  }
}

resource "aws_route_table_association" "rta_public" {
  subnet_id      = aws_subnet.sn_firewall.id
  route_table_id = aws_route_table.rt_public.id
}

# Inspection : uniquement la route "local" (créée automatiquement)
resource "aws_route_table" "rt_inspection" {
  vpc_id = aws_vpc.nordis_vpc.id

  tags = {
    Name = "rtb-inspection"
  }
}

resource "aws_route_table_association" "rta_inspection" {
  subnet_id      = aws_subnet.sn_inspection.id
  route_table_id = aws_route_table.rt_inspection.id
}

# Privés : une table par sous-réseau.
#  - 0.0.0.0/0                  -> FW01 (Internet, NAT fait par OPNsense)
#  - chacun des autres /24      -> FW01 (filtrage entre sous-réseaux)
resource "aws_route_table" "rt_prive" {
  for_each = local.sous_reseaux_prives
  vpc_id   = aws_vpc.nordis_vpc.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.fw01_lan.id
  }

  dynamic "route" {
    for_each = { for nom, sn in local.sous_reseaux_prives : nom => sn.cidr_block if nom != each.key }
    content {
      cidr_block           = route.value
      network_interface_id = aws_network_interface.fw01_lan.id
    }
  }

  tags = {
    Name = "rtb-${replace(each.key, "_", "-")}"
  }
}

resource "aws_route_table_association" "rta_prive" {
  for_each       = local.sous_reseaux_prives
  subnet_id      = each.value.id
  route_table_id = aws_route_table.rt_prive[each.key].id
}

# --- INTERFACES RESEAU PARE-FEU (FW01) ---
# source_dest_check = false : FW01 transmet du trafic qui ne lui est pas
# destiné (routage). Sans ça, AWS le jette.
resource "aws_network_interface" "fw01_wan" {
  subnet_id         = aws_subnet.sn_firewall.id
  private_ips       = ["10.50.0.4"]
  security_groups   = [aws_security_group.sg_fw_wan.id]
  source_dest_check = false

  tags = {
    Name = "eni-fw01-wan"
  }
}

resource "aws_network_interface" "fw01_lan" {
  subnet_id         = aws_subnet.sn_inspection.id
  private_ips       = ["10.50.0.20"]
  security_groups   = [aws_security_group.sg_internal_default.id]
  source_dest_check = false

  tags = {
    Name = "eni-fw01-lan"
  }
}

# Elastic IP : IP publique fixe de FW01, posée sur son interface WAN
resource "aws_eip" "fw01" {
  domain            = "vpc"
  network_interface = aws_network_interface.fw01_wan.id
  depends_on        = [aws_internet_gateway.igw]

  tags = {
    Name = "eip-fw01"
  }
}

# --- INSTANCE EC2 PARE-FEU (FW01) ---
# Démarre sur FreeBSD 15.1, puis devient OPNsense avec fw01_bootstrap.sh.
# Les deux interfaces sont branchées dès le démarrage.
variable "ami_fw01" {
  description = "AMI FreeBSD 15.1-RELEASE amd64 base UFS (voir README)"
  type        = string
}

resource "aws_instance" "fw01" {
  ami           = var.ami_fw01
  instance_type = "t3.medium" # OPNsense demande 3 Go de RAM minimum
  key_name      = var.cle_ssh

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # Après la conversion, l'instance est OPNsense : ne jamais la recréer
  # parce qu'une nouvelle image FreeBSD est sortie.
  lifecycle {
    ignore_changes = [ami]
  }

  network_interface {
    network_interface_id = aws_network_interface.fw01_wan.id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.fw01_lan.id
    device_index         = 1
  }

  tags = {
    Name = "FW01-OPNsense"
  }
}

# --- ACCES ADMIN PRIVE : EC2 Instance Connect Endpoint (gratuit) ---
# Permet d'atteindre FW01 (IP LAN 10.50.0.20) sans exposer de port
# d'administration sur Internet, quelle que soit l'IP publique de l'admin.
resource "aws_ec2_instance_connect_endpoint" "admin" {
  subnet_id          = aws_subnet.sn_management.id
  security_group_ids = [aws_security_group.sg_internal_default.id]
  preserve_client_ip = false

  tags = {
    Name = "eice-nordis"
  }
}

output "eice_id" {
  value = aws_ec2_instance_connect_endpoint.admin.id
}
