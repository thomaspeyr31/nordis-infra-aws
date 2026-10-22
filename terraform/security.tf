# =============================================================================
# security.tf - Groupes de sécurité du projet Nordis Distribution
# Auteur  : Thomas Peyrusaubes
# Version : 1.1 - 2026-10-21
#
# Attention : le "name" d'un groupe de sécurité ne peut pas commencer par
# "sg-" (AWS le réserve aux identifiants). Le tag "Name", lui, est libre.
# =============================================================================

variable "mon_ip" {
  description = "Ton IP publique en /32 (curl -s ifconfig.me), seule autorisée à administrer FW01"
  type        = string
}

# --- FW01, interface WAN (seule porte vers Internet) ---
resource "aws_security_group" "sg_fw_wan" {
  name        = "nordis-fw01-wan"
  description = "WAN de FW01 : administration et VPN depuis mon IP uniquement"
  vpc_id      = aws_vpc.nordis_vpc.id

  ingress {
    description = "Interface web OPNsense"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.mon_ip]
  }

  ingress {
    description = "SSH OPNsense"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.mon_ip]
  }

  ingress {
    description = "VPN WireGuard"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = [var.mon_ip]
  }

  egress {
    description = "Tout autoriser en sortie"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg-fw01-wan"
  }
}

# --- Ressources internes (LAN de FW01 et toutes les VM) ---
resource "aws_security_group" "sg_internal_default" {
  name        = "nordis-internal-default"
  description = "Regles de base pour les ressources internes"
  vpc_id      = aws_vpc.nordis_vpc.id

  ingress {
    description = "Tout autoriser en interne"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.50.0.0/16"]
  }

  egress {
    description = "Tout autoriser en sortie"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg-internal-default"
  }
}
