# =========================================================
# EC2 Security Group
# =========================================================

resource "aws_security_group" "app_sg" {
  name        = "application security group"
  description = "for ec2 java applications"
  vpc_id      = var.vpc_id
  tags = {
    Name = "app_sg"
  }
}

# tomcat
resource "aws_vpc_security_group_ingress_rule" "tomcat_ingress" {
  security_group_id = aws_security_group.app_sg.id

  ip_protocol = "tcp"
  from_port   = 8080
  to_port     = 8080
  cidr_ipv4   = "0.0.0.0/0"
}

# ssh
resource "aws_vpc_security_group_ingress_rule" "ssh_ingress" {
  security_group_id = aws_security_group.app_sg.id

  ip_protocol = "tcp"
  from_port   = 22
  to_port     = 22
  cidr_ipv4   = "0.0.0.0/0"
}
#  allow all outbound traffic
resource "aws_vpc_security_group_egress_rule" "http_egress" {
  security_group_id = aws_security_group.app_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

# =========================================================
# RDS Security Group
# =========================================================

resource "aws_security_group" "rds_sg" {
  name        = "rds security group"
  description = "for rds mariadb"
  vpc_id      = var.vpc_id
  tags = {
    Name = "rds_sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_ingress" {
  security_group_id = aws_security_group.rds_sg.id

  referenced_security_group_id = aws_security_group.app_sg.id

  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}

# =========================================================
# Memcached Security Group
# =========================================================

resource "aws_security_group" "memcached_sg" {
  name        = "memcached security group"
  description = "for memcached"
  vpc_id      = var.vpc_id
  tags = {
    Name = "memcached_sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "memcached_ingress" {
  security_group_id = aws_security_group.memcached_sg.id

  referenced_security_group_id = aws_security_group.app_sg.id

  ip_protocol = "tcp"
  from_port   = 11211
  to_port     = 11211
}

resource "aws_vpc_security_group_egress_rule" "memcached_egress" {
  security_group_id = aws_security_group.memcached_sg.id

  ip_protocol       = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}
