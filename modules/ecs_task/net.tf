resource "aws_security_group" "task" {
  name   = "${var.project}_${var.task}_${var.env}"
  vpc_id = var.vpc_id


  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}


