provider "aws" {
  region = "us-east-1"
}

# --- 1. NETWORKING ---
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "VPC-Lab-Estres" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab_vpc.id
  tags   = { Name = "IGW-Lab-Estres" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "RT-Public-Lab-Estres" }
}

resource "aws_subnet" "subnet_1" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "Subnet-Public1-us-east-1a" }
}

resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "Subnet-Public2-us-east-1b" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# --- 2. SECURITY GROUPS ---
resource "aws_security_group" "web_sg" {
  name        = "SG_Web_Total"
  description = "Allow HTTP and SSH"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
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
  tags = { Name = "SG_Web_Total" }
}

# --- 3. LOAD BALANCER & TARGET GROUP ---
resource "aws_lb" "app_lb" {
  name               = "ALB-Estres"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  tags               = { Name = "ALB-Estres" }
}

resource "aws_lb_target_group" "tg" {
  name     = "TG-HelloWorld"
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

# --- 4. LAUNCH TEMPLATE & ASG ---
resource "aws_launch_template" "docker_lt" {
  name_prefix   = "Template-Docker-"
  image_id      = "ami-0fa3fe0fa7920f68e" # Amazon Linux 2023 (us-east-1)
  instance_type = "t2.small"
  key_name      = "vockey" # <--- CAMBIA ESTO SI TU LLAVE SE LLAMA DIFERENTE

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

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
}

resource "aws_autoscaling_group" "asg" {
  name                = "ASG-Estres"
  vpc_zone_identifier = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
  target_group_arns   = [aws_lb_target_group.tg.arn]
  health_check_type   = "ELB"
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

# --- 5. SCALING POLICIES (CPU & RAM) ---

# Policy 1: CPU > 10%
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

# Policy 2: RAM (Memory) - Requisito del profesor
# OJO: Esto requiere que las instancias envíen métricas custom (CloudWatch Agent).
# Aquí configuramos la "intención" de escalar por memoria.
resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "TargetTracking-Memory"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "MemoryUtilization" # Nombre estándar del agente CW
      namespace   = "CWAgent"           # Namespace estándar
      statistic   = "Average"
    }
    target_value = 50.0 # Escalar si la RAM pasa del 50%
  }
}

# --- 6. LOAD GENERATOR ---
resource "aws_instance" "load_generator" {
  ami           = "ami-0fa3fe0fa7920f68e"
  instance_type = "t2.micro"
  key_name      = "vockey" # <--- CAMBIA ESTO
  subnet_id     = aws_subnet.subnet_1.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  
  tags = {
    Name = "Load-Generator"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd-tools
              EOF
}

# --- OUTPUTS ---
output "alb_dns" {
  value = aws_lb.app_lb.dns_name
}
output "attacker_ip" {
  value = aws_instance.load_generator.public_ip
}