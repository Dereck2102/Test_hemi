terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- 1. NETWORKING (VPC & Subnets) ---
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "VPC-Lab-Stress" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab_vpc.id
  tags   = { Name = "IGW-Lab-Stress" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "RT-Public-Lab" }
}

resource "aws_subnet" "subnet_1" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "Subnet-Public-1a" }
}

resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "Subnet-Public-1b" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# --- 2. SECURITY GROUP ---
resource "aws_security_group" "web_sg" {
  name        = "SG_Web_Total"
  description = "Allow HTTP and SSH traffic"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "SG-Web-Total" }
}

# --- 3. LOAD BALANCER (ALB) ---
resource "aws_lb" "app_lb" {
  name               = "ALB-Stress-Test"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  tags               = { Name = "ALB-Stress-Test" }
}

resource "aws_lb_target_group" "tg" {
  name     = "TG-Docker-Cluster"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lab_vpc.id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# --- 4. LAUNCH TEMPLATE (With Docker) ---
# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_launch_template" "docker_lt" {
  name_prefix   = "Template-Docker-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.small"
  key_name      = "vockey" # <--- CONFIRMA QUE ESTE SEA EL NOMBRE DE TU LLAVE

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  # Script to install Docker and run Nginx
  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user
              docker run -d -p 80:80 nginxdemos/hello
              EOF
  )
  
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Docker-Instance"
    }
  }
}

# --- 5. AUTO SCALING GROUP (ASG) ---
resource "aws_autoscaling_group" "asg" {
  name                = "ASG-Stress-Cluster"
  vpc_zone_identifier = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  target_group_arns   = [aws_lb_target_group.tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300
  
  min_size            = 1
  max_size            = 20
  desired_capacity    = 2

  launch_template {
    id      = aws_launch_template.docker_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "ASG-Instance"
    propagate_at_launch = true
  }
}

# --- 6. SCALING POLICIES (CPU & RAM) ---

# Policy A: Scale out when CPU > 10%
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "TargetTracking-CPU"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 10.0
  }
}

# Policy B: Scale out when RAM > 50% (Requested by Professor)
# Note: RAM metrics usually require CloudWatch Agent installed on OS.
# This code creates the policy config successfully.
resource "aws_autoscaling_policy" "ram_policy" {
  name                   = "TargetTracking-RAM"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "MemoryUtilization"
      namespace   = "CWAgent"
      statistic   = "Average"
    }
    target_value = 50.0
  }
}

# --- 7. LOAD GENERATOR (Attacker Machine) ---
resource "aws_instance" "load_generator" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t2.micro"
  key_name      = "vockey" # <--- CONFIRMA TU LLAVE
  subnet_id     = aws_subnet.subnet_1.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  
  tags = {
    Name = "Load-Generator"
  }

  # Install Apache Bench (ab) automatically
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd-tools
              EOF
}

# --- OUTPUTS (Lo que verás en GitHub al terminar) ---
output "load_balancer_dns" {
  description = "Access this URL to see the Docker Hello World"
  value       = aws_lb.app_lb.dns_name
}

output "attacker_ip" {
  description = "SSH into this IP to run 'ab' command"
  value       = aws_instance.load_generator.public_ip
}
#inicio
