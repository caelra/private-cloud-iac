output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "egress_subnet_ids" {
  value = aws_subnet.egress[*].id
}

output "isolated_subnet_ids" {
  value = aws_subnet.isolated[*].id
}

output "egress_route_table_id" {
  value = aws_route_table.egress.id
}

output "isolated_route_table_id" {
  value = aws_route_table.isolated.id
}

output "nat_gateway_id" {
  # Depending on this output also guarantees the default route exists.
  value      = aws_nat_gateway.this.id
  depends_on = [aws_route.egress_default]
}
