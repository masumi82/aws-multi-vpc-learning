resource "aws_lb" "this" {
  name               = "${var.env}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false # 学習用: destroy 即可

  tags = { Name = "${var.env}-alb" }
}

# Fargate (awsvpc) は必ず target_type = "ip"
resource "aws_lb_target_group" "this" {
  name        = "${var.env}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # ALB Listener 削除前に TG を消そうとして失敗するのを防ぐ
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.env}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.app_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
