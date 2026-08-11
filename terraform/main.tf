

# create Rds data base mariaDB

resource "aws_db_instance" "vprofile_db" {
  allocated_storage      = 10
  storage_type           = "gp2"
  engine                 = "mariadb"
  engine_version         = "10.5"
  instance_class         = "db.t3.micro"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.mariadb10.5"
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

#  EC2 instance
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

resource "aws_instance" "java_ec2" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "c7i-flex.large"
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = aws_key_pair.deployer.ubuntu2
  associate_public_ip_address = true
  tags = {
    Name = "java application"
  }
}

# create memcached using elasticache
resource "aws_elasticache_cluster" "java_memcached" {
  cluster_id           = "cluster-java-memcached"
  engine               = "memcached"
  node_type            = "cache.m4.large"
  num_cache_nodes      = 2
  parameter_group_name = "default.memcached1.4"
  port                 = 11211
  security_group_ids   = [aws_security_group.memcached_sg.id]
}