resource "local_file" "ansible_inventory" {
  content = <<EOF
[web]
${aws_instance.app.public_ip}
EOF

  filename = "${path.module}/../ansible/inventory.ini"
}

