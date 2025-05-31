data "aws_route53_zone" "main" {
  name         = var.domain
  private_zone = false
}

resource "aws_acm_certificate" "grafana" {
  domain_name       = var.grafana_hostname
  validation_method = "DNS"
}

resource "aws_route53_record" "grafana_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.grafana.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "grafana" {
  certificate_arn         = aws_acm_certificate.grafana.arn
  validation_record_fqdns = [for record in aws_route53_record.grafana_cert_validation : record.fqdn]
}
