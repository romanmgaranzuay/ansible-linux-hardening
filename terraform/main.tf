terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Custom Isolated VPC & Public Subnet
resource "aws_vpc" "hardening_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "hardening-vpc"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.hardening_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "hardening-public-subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hardening_vpc.id

  tags = {
    Name = "hardening-igw"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.hardening_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "hardening-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 2. Zero-Ingress Security Group (No port 22 exposed to the public)
resource "aws_security_group" "zero_ingress" {
  name        = "zero-inbound-ssm-sg"
  description = "Block all inbound traffic; allow outbound for apt updates and SSM"
  vpc_id      = aws_vpc.hardening_vpc.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "zero-ingress-sg"
  }
}

# 3. IAM Role & Profile for AWS Systems Manager (SSM)
resource "aws_iam_role" "ssm_role" {
  name = "EC2HardeningSSMRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Name = "EC2HardeningSSMRole"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "EC2HardeningSSMProfile"
  role = aws_iam_role.ssm_role.name
}

# 4. Fetch the Latest Official Ubuntu 24.04 ARM64 AMI
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 5. EC2 Instance (t4g.micro - AWS Free Tier Eligible ARM64 instance)
resource "aws_instance" "target_node" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "t4g.micro"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.zero_ingress.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "ansible-target-ubuntu-arm64"
    Environment = "Security-Hardening-Lab"
  }
}

# 6. Add an S3 bucket for Ansible artifact staging

# Random suffix for the S3 bucket name to ensure uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "ssm_staging" {
  bucket = "ansible-ssm-staging-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "ansible-ssm-staging"
    Environment = "Security-Hardening-Lab"
  }
}

resource "aws_s3_bucket_public_access_block" "block_public_access" {
  bucket = aws_s3_bucket.ssm_staging.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Grant EC2 instance read/write permissions to the S3 bucket for artifact staging
resource "aws_iam_policy" "ssm_s3_policy" {
  name        = "EC2HardeningSSMS3Policy"
  description = "Policy to allow EC2 instance to read/write to S3 bucket for Ansible artifact staging"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketAndObjectAccess"
        Effect   = "Allow"
        Action   = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.ssm_staging.arn,
          "${aws_s3_bucket.ssm_staging.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_s3_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = aws_iam_policy.ssm_s3_policy.arn
}

output "s3_bucket_name" {
  description = "Bucket used by Ansible SSM plugin for artifact staging"
  value       = aws_s3_bucket.ssm_staging.bucket
}

# Output the Instance ID to feed into Ansible
output "instance_id" {
  description = "The EC2 Instance ID used for SSM target connection"
  value       = aws_instance.target_node.id
}