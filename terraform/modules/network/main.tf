locals {
  name_prefix = var.env
  nat_count   = var.nat_gateway_per_az ? 3 : 1
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-${substr(var.azs[count.index], -2, 2)}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-app-${substr(var.azs[count.index], -2, 2)}"
    Tier = "app"
  }
}

resource "aws_subnet" "db" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-db-${substr(var.azs[count.index], -2, 2)}"
    Tier = "db"
  }
}

# NAT GW 用 EIP: 1 (Tier 0) or 3 (Tier 1)
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  }
}

# NAT Gateway: 1 (Tier 0、1a のみ) or 3 (Tier 1、各 AZ)
resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-gw-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-public"
  }
}

# App 用 RT: NAT 台数と同数。
# Tier 1 (nat_gateway_per_az=true) は各 AZ 専用、Tier 0 は 1 個共有。
resource "aws_route_table" "app" {
  count  = local.nat_count
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name = "${local.name_prefix}-rt-app-${count.index}"
  }
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-rt-db"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# App subnet は per-AZ NAT 構成なら同 AZ の RT に、単一 NAT なら全て RT[0] に
resource "aws_route_table_association" "app" {
  count          = 3
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = var.nat_gateway_per_az ? aws_route_table.app[count.index].id : aws_route_table.app[0].id
}

resource "aws_route_table_association" "db" {
  count          = 3
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
