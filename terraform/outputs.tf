# RDS outputs

output "rds_endpoint" {
  value = aws_db_instance.vprofile_db.endpoint
}

# EC2 outputs

output "ec2_public_ip" {
  value = aws_instance.java_ec2.public_ip
}

# Memcached outputs

output "memcached_endpoint" {
  value = aws_elasticache_cluster.java_memcached.cluster_address
}