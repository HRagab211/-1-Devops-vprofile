#global variables
variable "vpc_id" {
  type    = string
  default = "vpc-030e6a5fcc393a772"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

# ec2 variables
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

# DB variables
variable "db_name" {
  type    = string
  default = "mydb"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_password" {
  type    = string
  default = "admin123"
}